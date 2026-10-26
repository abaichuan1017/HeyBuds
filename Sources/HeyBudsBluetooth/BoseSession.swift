// BMAP session using MIT Bose references and GPL-3.0 Android BLE corrections.
// See Licenses/Bose-MIT.txt. Transport must deliver raw, reassembled BMAP.
import Foundation
import HeyBudsProtocol

@MainActor final class BoseSession: AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model: DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange: (() -> Void)?
    var onClose: ((String?) -> Void)?
    let profile: BoseProfile?
    private(set) var currentModeIndex: UInt8?
    private(set) var modes: [UInt8:BoseModeConfig]=[:]
    private(set) var unknownModePayloads: [UInt8:[UInt8]]=[:]
    private(set) var batteryComponents: [UInt8:BoseBatteryComponent]=[:]
    private(set) var cnc: BoseCNCState?
    private(set) var audioSettings: BoseAudioSettings?
    private var modeCount: Int?
    private let channel: ControlChannel<BoseFrame>
    private let operations=RequestGate()
    private var generation=UUID()
    private var active=false
    private var poll: Task<Void,Never>?

    convenience init(transport: EarbudTransport, name: String, catalog: ModelCatalog, timeout: Double=3) {
        let profile=BoseProfile.named(name)
        let model=profile.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        self.init(transport:transport,profile:profile,model:model,timeout:timeout)
    }
    init(transport: EarbudTransport, profile: BoseProfile?, model: DeviceModel?=nil, timeout: Double=3) {
        self.profile=profile; self.model=model
        var codec=BoseFrameCodec()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ codec.feed($0) },reset:{ codec.reset() })
        channel.onMessage={ [weak self] in self?.receive($0) }
        channel.onClose={ [weak self] reason in self?.close(); self?.onClose?(reason) }
    }
    func open() async throws {
        guard let profile, !active else { throw ProtocolError.unsupported }
        let token=generation; active=true
        do {
            try await channel.open()
            if profile == .qc45 {
                // BMAP-version GET is required to wake QC45's control session.
                // The response is not a product identity or a setting success.
                try await channel.send(BoseFrameCodec.encode(BoseFrame(0,1)))
            }
            try check(token)
            if let reply=try await optionalGet(0,5), let version=String(bytes:reply,encoding:.utf8),
               !version.isEmpty, version.count <= 128,
               version.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }),
               version.contains(".") {
                // This register is firmware in pybmap's tested profiles. bozo's
                // unused enum calls it ProductIdVariant: do not infer an ID.
                state.firmware=version; state.observedQueries.insert(Command.firmware)
            }
            try await readBattery()
            if let favorites=try await optionalGet(31,8) {
                modeCount=BosePayload.modeCount(favorites,profile:profile)
            }
            if let count=modeCount {
                for index in 0..<count { _ = try await readMode(UInt8(index),optional:true) }
            }
            if let current=try await optionalGet(31,3), current.count == 1 {
                applyCurrentMode(current[0]); state.observedQueries.insert(Command.noise)
            }
            if let bytes=try await optionalGet(1,5) { cnc=BosePayload.cnc(bytes) }
            if profile.hasLiveCNC, let bytes=try await optionalGet(31,10) {
                audioSettings=BosePayload.audioSettings(bytes)
            }
            try check(token); ready=true; onChange?()
        } catch { if generation == token { close() }; throw error }
    }
    func initialize() async {
        guard ready else { return }; let token=generation
        poll?.cancel(); poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 8 : 30)) } catch { return }
                guard let self, self.ready, self.generation == token else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return }; let token=generation
        do {
            try await operations.acquire(); defer { operations.release() }
            try check(token); try await readBattery()
            if state.observedQueries.contains(Command.noise) {
                let index=try await readCurrentMode()
                if let count=modeCount, Int(index) < count { _ = try await readMode(index,optional:true) }
            }
            if cnc != nil { cnc=BosePayload.cnc(try await get(1,5)) }
            if audioSettings != nil { audioSettings=BosePayload.audioSettings(try await get(31,10)) }
            try check(token); onChange?()
        } catch {
            if generation == token { close(); onClose?(error is CancellationError ? nil : error.localizedDescription) }
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard active, generation == token else { throw ProtocolError.disconnected }
    }
    private func request(_ block: UInt8, _ function: UInt8, _ op: BoseOperation = .get,
                         _ payload: [UInt8]=[], index: UInt8?=nil) async throws -> BoseFrame {
        let token=generation
        try check(token)
        let frame=try await channel.request(BoseFrameCodec.encode(BoseFrame(block,function,op,payload)),matching:{ frame in
            guard frame.matches(block,function) else { return false }
            if frame.operation == .error { return true }
            // START STATUS is an unsolicited push, never the command result.
            if op == .start { return frame.operation == .result }
            guard frame.operation == .status else { return false }
            return index == nil || frame.payload.first == index || frame.payload.isEmpty
        })
        try check(token)
        if frame.operation == .error {
            guard frame.payload.count == 1 else { throw ProtocolError.invalidPayload }
            throw ProtocolError.rejected(frame.payload[0])
        }
        return frame
    }
    private func get(_ block: UInt8, _ function: UInt8) async throws -> [UInt8] {
        try await request(block,function).payload
    }
    private func optionalGet(_ block: UInt8, _ function: UInt8) async throws -> [UInt8]? {
        do { return try await get(block,function) }
        catch ProtocolError.rejected(let code) where [3,4,7].contains(code) { return nil }
    }
    private func readBattery() async throws {
        let bytes=try await get(2,2)
        guard let readings=BosePayload.battery(bytes) else {
            batteryComponents=[:]; state.batteries=[:]; state.unassignedBatteries=[:]
            throw ProtocolError.invalidPayload
        }
        applyBattery(readings); state.observedQueries.insert(Command.battery)
    }
    private func applyBattery(_ readings: [BoseBatteryComponent]) {
        batteryComponents=Dictionary(uniqueKeysWithValues:readings.map { ($0.id,$0) })
        // A full component response replaces absent/sentinel readings as well.
        state.batteries=[:]; state.unassignedBatteries=[:]
        if profile == .ultraEarbuds2 {
            for component in readings {
                guard let percent=component.percent else { continue }
                let value=BatteryReading(percent:percent,updatedAt:component.updatedAt)
                if component.id == 3 { state.batteries[.enclosure]=value }
                if component.id == 1 || component.id == 2 { state.unassignedBatteries[component.id]=value }
            }
        } else if let overall=readings.first(where:{$0.id == 0}), let percent=overall.percent {
            // Existing app convention for a single-battery headphone, not an ear.
            state.batteries[.left]=BatteryReading(percent:percent,updatedAt:overall.updatedAt)
        }
    }
    private func readMode(_ index: UInt8, optional: Bool=false) async throws -> BoseModeConfig? {
        guard let profile, let count=modeCount, Int(index) < count else { throw ProtocolError.unsupported }
        do {
            let bytes=try await request(31,6,.get,[index],index:index).payload
            guard let value=BosePayload.mode(bytes,profile:profile), value.index == index else {
                modes.removeValue(forKey:index); unknownModePayloads[index]=bytes
                state.noise=BosePayload.noise(index:currentModeIndex,modes:modes)
                if optional { return nil }; throw ProtocolError.invalidPayload
            }
            modes[index]=value; unknownModePayloads.removeValue(forKey:index)
            state.noise=BosePayload.noise(index:currentModeIndex,modes:modes)
            return value
        } catch ProtocolError.rejected(let code) where optional && [3,4,7].contains(code) {
            modes.removeValue(forKey:index); return nil
        }
    }
    private func readCurrentMode() async throws -> UInt8 {
        let payload=try await get(31,3)
        guard payload.count == 1 else { state.noise=nil; currentModeIndex=nil; throw ProtocolError.invalidPayload }
        applyCurrentMode(payload[0]); state.observedQueries.insert(Command.noise); return payload[0]
    }
    private func applyCurrentMode(_ index: UInt8) {
        currentModeIndex=index; state.noise=BosePayload.noise(index:index,modes:modes)
    }
    private func receive(_ frame: BoseFrame) {
        guard ready, frame.route == 0, frame.operation == .status else { return }
        // Pushes may update presentation but never complete a write themselves.
        switch (frame.block,frame.function) {
        case (2,2):
            if let readings=BosePayload.battery(frame.payload) { applyBattery(readings) }
        case (31,3):
            if frame.payload.count == 1 { applyCurrentMode(frame.payload[0]) }
        case (1,5): cnc=BosePayload.cnc(frame.payload)
        case (31,10): if profile?.hasLiveCNC == true { audioSettings=BosePayload.audioSettings(frame.payload) }
        default: return
        }
        onChange?()
    }
    func canQuery(_ command: UInt16) -> Bool {
        profile != nil && [Command.battery,Command.noise,Command.firmware].contains(command)
    }
    func canWrite(_ command: UInt16, reading: UInt16?=nil) -> Bool {
        ready && command == Command.setNoise && (reading == nil || reading == Command.noise)
            && state.observedQueries.contains(Command.noise)
            && BosePayload.noise(index:0,modes:modes) == .anc
            && BosePayload.noise(index:1,modes:modes) == .transparency
    }
    var canSetCNC: Bool {
        guard ready, let profile, let cnc, cnc.maximum <= 10, let index=currentModeIndex,
              let mode=modes[index], profile.isExistingMode(mode) else { return false }
        if profile.hasLiveCNC { return audioSettings.flatMap { try? $0.settingCNC(cnc.level) } != nil }
        return (try? BosePayload.qc45CNCWrite(mode,level:cnc.level)) != nil
    }
    func setNoise(_ mode: NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise), mode == .anc || mode == .transparency else { throw ProtocolError.unsupported }
        let token=generation, index: UInt8=mode == .anc ? 0 : 1
        try await operations.acquire(); defer { operations.release() }
        try check(token)
        _ = try await readMode(index)
        guard BosePayload.noise(index:index,modes:modes) == mode else { throw ProtocolError.unsupported }
        _ = try await request(31,3,.start,[index,0])
        for attempt in 0..<4 {
            // Only a fresh GET after RESULT may confirm. Never cached mode/ACK.
            let fresh=try await readCurrentMode(); try check(token)
            if fresh == index { onChange?(); return .confirmed }
            if attempt < 3 { try await Task.sleep(for:.milliseconds(150)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func setEQ(_ id: UInt8) async throws -> WriteOutcome { throw ProtocolError.unsupported }
    func setCNC(_ level: UInt8) async throws -> WriteOutcome {
        guard canSetCNC, let profile else { throw ProtocolError.unsupported }
        let token=generation
        try await operations.acquire(); defer { operations.release() }
        try check(token)
        guard let freshCNC=BosePayload.cnc(try await get(1,5)), level <= freshCNC.maximum else { throw ProtocolError.invalidPayload }
        cnc=freshCNC
        let index=try await readCurrentMode()
        guard let mode=try await readMode(index), profile.isExistingMode(mode) else { throw ProtocolError.unsupported }
        if profile.hasLiveCNC {
            guard let settings=BosePayload.audioSettings(try await get(31,10)) else { throw ProtocolError.invalidPayload }
            let desired=try settings.settingCNC(level)
            _ = try await request(31,10,.setGet,desired)
            guard let readback=BosePayload.audioSettings(try await get(31,10)), readback.raw == desired else {
                throw ProtocolError.readbackMismatch
            }
            audioSettings=readback
        } else {
            let desired=try BosePayload.qc45CNCWrite(mode,level:level)
            _ = try await request(31,6,.setGet,desired,index:index)
            guard let readback=try await readMode(index),
                  try BosePayload.qc45CNCWrite(readback,level:readback.cnc) == desired else { throw ProtocolError.readbackMismatch }
        }
        let finalIndex=try await readCurrentMode()
        guard let actual=BosePayload.cnc(try await get(1,5)) else { throw ProtocolError.invalidPayload }
        try check(token); cnc=actual; onChange?()
        guard finalIndex == index, actual.level == level else { throw ProtocolError.readbackMismatch }
        return .confirmed
    }
    func close() {
        active=false; ready=false; generation=UUID(); poll?.cancel(); poll=nil; channel.close()
        state=DeviceState(); currentModeIndex=nil; modes=[:]; unknownModePayloads=[:]
        batteryComponents=[:]; cnc=nil; audioSettings=nil; modeCount=nil; onChange?()
    }
}
