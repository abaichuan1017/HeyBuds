// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HeyBudsProtocol

@MainActor private final class XiaomiAuthContext {
    var machine:XiaomiCommandAuth?
    var failure:Error?
    func reply(_ frame:XiaomiFrame) -> Data? {
        guard machine != nil,[UInt8(0x50),0x51].contains(frame.opcode) else { return nil }
        do { return try machine?.receive(frame).map(XiaomiFrameCodec.encode) }
        catch { failure=error;return nil }
    }
}

/// A model-bound MMA session. It shares request lifetimes with the other
/// backends, but never their command IDs, codecs, authentication or state.
@MainActor final class XiaomiSession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let profile:XiaomiProfile?
    private let channel:ControlChannel<XiaomiFrame>
    private let authentication=XiaomiAuthContext()
    private let operations=RequestGate()
    private let authTimeout:Double
    private var active=false,identified=false,wearUnavailable=false
    private var generation=UUID(),sequence:UInt8=2
    private var retiredSequences:Set<UInt8>=[]
    private var configs:[UInt16:[UInt8]]=[:]
    private var unavailable:Set<UInt16>=[]
    private var noiseRevision:UInt64=0
    private var noiseStrengths:[NoiseMode:UInt8]=[:]
    private var poll:Task<Void,Never>?

    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=2.5,authTimeout:Double=12) {
        self.authTimeout=authTimeout
        let selected=XiaomiProfile.named(name);profile=selected
        model=selected.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        let auth=authentication
        var codec=XiaomiFrameCodec()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ codec.feed($0) },reset:{ codec.reset() },acknowledge:{ frame in
            if let response=auth.reply(frame) { return response }
            guard frame.needsReply,[UInt8(0x0E),0xF4].contains(frame.opcode) else { return nil }
            return try? XiaomiFrameCodec.encode(frame.reply(type:(selected?.requestType ?? 0xC4) & 7))
        })
        channel.onMessage={ [weak self] frame in self?.notification(frame) }
        channel.onClose={ [weak self] reason in self?.close();self?.onClose?(reason) }
    }
    private var allowedConfigs:Set<UInt16> { Set(model?.function["xiaomiConfigIDs"].elements.compactMap { $0.int.flatMap(UInt16.init(exactly:)) } ?? []) }
    private func acceptsReply(_ frame:XiaomiFrame) -> Bool {
        !frame.isRequest && (frame.type & 7 == (profile?.requestType ?? 0xC4) & 7 || frame.type & 7 == 7)
    }
    private func check(_ token:UUID) throws {
        try Task.checkCancellation();guard active,generation == token else { throw ProtocolError.disconnected }
    }
    private func nextSequence() throws -> UInt8 {
        for _ in 0..<256 {
            let next=sequence;sequence &+= 1
            if !retiredSequences.contains(next) { return next }
        }
        close();throw ProtocolError.disconnected
    }
    func open() async throws {
        guard let profile,!profile.systemBatteryOnly,model != nil,!active else { throw ProtocolError.unsupported }
        active=true;let token=generation
        do {
            try await channel.open();try check(token)
            if profile.requiresAuthentication {
                authentication.machine=try XiaomiCommandAuth(type:profile.requestType,sequence:0,challenge:(0..<16).map { _ in UInt8.random(in:0...255) })
                let start=try authentication.machine!.start()
                _ = try await channel.request(XiaomiFrameCodec.encode(start),timeout:authTimeout,matching:{ [authentication] _ in
                    authentication.failure != nil || authentication.machine?.ready == true
                })
                try check(token)
                if let error=authentication.failure { throw error }
                guard authentication.machine?.ready == true else { throw ProtocolError.invalidPayload }
                authentication.machine=nil
            }
            try await readInfo();try check(token)
            ready=true;onChange?()
        } catch { if generation == token { close() };throw error }
    }
    private func request(_ opcode:UInt8,_ payload:[UInt8],optional:Bool=false) async throws -> XiaomiFrame {
        let token=generation,seq=try nextSequence()
        let bytes=try XiaomiFrameCodec.encode(XiaomiFrame(type:profile?.requestType ?? 0xC4,opcode:opcode,sequence:seq,payload:payload))
        do {
            let result=try await channel.request(bytes,timeout:optional ? 0.8 : nil,retireOnTimeout:!optional,matching:{ [self] frame in
                acceptsReply(frame) && frame.opcode == opcode && frame.sequence == seq
            })
            try check(token)
            guard result.status == 0 else { throw ProtocolError.rejected(result.status) }
            return result
        } catch {
            if optional,(error as? ProtocolError) == .timeout(0) { retiredSequences.insert(seq) }
            throw error
        }
    }
    private func send(_ opcode:UInt8,_ payload:[UInt8]) async throws {
        let token=generation,seq=try nextSequence()
        try await channel.send(XiaomiFrameCodec.encode(XiaomiFrame(type:profile?.requestType ?? 0xC4,opcode:opcode,sequence:seq,payload:payload)))
        try check(token)
    }
    private func readInfo() async throws {
        guard let profile else { throw ProtocolError.unsupported }
        let token=generation,seq=try nextSequence()
        let frame=try await channel.request(XiaomiFrameCodec.encode(XiaomiFrame(type:profile.requestType,opcode:2,sequence:seq,payload:[255,255,255,255])),matching:{ [self] frame in
            if acceptsReply(frame),frame.opcode == 2,frame.sequence == seq { return true }
            return profile == .redmi6lite && frame.isRequest && frame.opcode == 0x0E &&
                XiaomiProtocol.records(frame.payload,idBytes:1)?[0].flatMap(XiaomiProtocol.batteries) != nil
        })
        try check(token)
        if frame.opcode == 0x0E {
            notification(frame)
            guard state.observedQueries.contains(Command.battery) else { throw ProtocolError.invalidPayload }
            identified=true;return
        }
        guard frame.status == 0,let records=XiaomiProtocol.records(frame.payload,idBytes:1) else { throw ProtocolError.invalidPayload }
        if let identity=XiaomiProtocol.identity(records) {
            guard profile.accepts(vendor:identity.vendor,product:identity.product) else { throw ProtocolError.unsupported }
            state.productID=String(format:"%04X:%04X",identity.vendor,identity.product)
        } else if profile != .clip && profile != .redmi6lite { throw ProtocolError.invalidPayload }
        guard let bytes=records[7],let batteries=XiaomiProtocol.batteries(bytes) else { throw ProtocolError.invalidPayload }
        state.batteries=batteries;state.observedQueries.insert(Command.battery)
        if let bytes=records[1],let firmware=XiaomiProtocol.firmware(bytes) { state.firmware=firmware;state.observedQueries.insert(Command.firmware) }
        identified=true;onChange?()
    }
    private func valid(_ id:UInt16,_ value:[UInt8]) -> Bool {
        guard allowedConfigs.contains(id),let model else { return false }
        switch id {
        case 2:return XiaomiProtocol.gestures(value) != nil
        case 4,47:return value.count == 1 && value[0] <= 1
        case 7:return value.count == 1 // Unknown preset IDs remain visible but cannot be written.
        case 11:
            guard let mode=XiaomiProtocol.noise(value),!model.noiseOptions.isEmpty else { return false }
            if profile == .redmi8pro { return mode == .anc ? value[1] <= 19 : mode == .transparency ? value[1] <= 2 : value[1] == 0 }
            return true
        case 12:return value.count == 1 && value[0] & 0xF0 == 0
        case 29:return value.count == 1 && value[0] & 0xF0 == 0
        case 55:return XiaomiProtocol.customEQ(value) != nil
        default:return false
        }
    }
    private func apply(_ id:UInt16,_ value:[UInt8]) {
        guard valid(id,value),let model else { return }
        configs[id]=value;unavailable.remove(id)
        switch id {
        case 11:
            state.noise=XiaomiProtocol.noise(value)
            if let mode=state.noise { noiseStrengths[mode]=value[1] }
            noiseRevision &+= 1;state.observedQueries.insert(Command.noise)
        case 7:state.eq=value[0];state.observedQueries.insert(Command.equalizer)
        case 4:state.switches[0x11]=value[0] == 1;state.observedQueries.insert(Command.switches)
        case 47:state.switches[6]=value[0] == 1;state.observedQueries.insert(Command.switches)
        case 29:state.spatial=value[0] & 1 == 0 ? 0 : value[0] & 8 != 0 ? 2 : 1;state.observedQueries.insert(Command.spatial)
        case 12:
            state.placement[.left]=value[0] & 8 != 0 ? 3 : value[0] & 2 != 0 ? 4 : 1
            state.placement[.right]=value[0] & 4 != 0 ? 3 : value[0] & 1 != 0 ? 4 : 1
            state.observedQueries.insert(Command.wear)
        case 55:
            if var entry=XiaomiProtocol.customEQ(value) { entry.selected=state.eq == 10;state.customEQ=[entry];state.observedQueries.insert(Command.customEQ) }
        case 2:
            state.gestures=XiaomiProtocol.gestureEntries(value,model:model)
            state.observedQueries.insert(Command.gestures)
        default:break
        }
        onChange?()
    }
    @discardableResult private func readConfig(_ id:UInt16,optional:Bool=false) async throws -> [UInt8] {
        guard allowedConfigs.contains(id),!optional || !unavailable.contains(id) else { throw ProtocolError.unsupported }
        do {
            let frame=try await request(0xF3,[UInt8(id >> 8),UInt8(truncatingIfNeeded:id)],optional:optional)
            guard let rows=XiaomiProtocol.records(frame.payload,idBytes:2),rows.count == 1,
                  let value=rows[id],valid(id,value) else { throw ProtocolError.invalidPayload }
            apply(id,value);return value
        } catch {
            if active { configs[id]=nil;if optional { unavailable.insert(id) } }
            throw error
        }
    }
    private func readWear(optional:Bool=false) async throws -> Bool {
        guard model?.function["xiaomiWearDetection"].enabled == true,!wearUnavailable else { throw ProtocolError.unsupported }
        do {
            let frame=try await request(9,[0,0,4,0],optional:optional)
            guard let fields=XiaomiProtocol.records(frame.payload,idBytes:1),let bytes=fields[10],bytes.count == 1,bytes[0] <= 1 else { throw ProtocolError.invalidPayload }
            let enabled=bytes[0] == 0;state.switches[4]=enabled;state.observedQueries.insert(Command.switches);onChange?();return enabled
        } catch { if optional { wearUnavailable=true };state.switches[4]=nil;throw error }
    }
    private func notification(_ frame:XiaomiFrame) {
        guard active,frame.isRequest,(identified || profile == .redmi6lite || profile == .clip),authentication.machine == nil else { return }
        if frame.opcode == 0xF4,let records=XiaomiProtocol.records(frame.payload,idBytes:2) {
            for (id,value) in records { apply(id,value) }
        } else if frame.opcode == 0x0E,let records=XiaomiProtocol.records(frame.payload,idBytes:1) {
            let batteryID:UInt16=profile == .clip ? 4 : 0
            if let bytes=records[batteryID],let batteries=XiaomiProtocol.batteries(bytes) {
                state.batteries=batteries;state.observedQueries.insert(Command.battery);onChange?()
            }
            if profile != .clip,let noise=records[4],noise.count == 1,let mode=[UInt8(0):NoiseMode.off,1:.anc,2:.transparency][noise[0]],model?.noiseOptions.isEmpty == false {
                state.noise=mode;noiseRevision &+= 1;onChange?()
            }
        }
    }
    func initialize() async {
        guard ready else { return };let token=generation
        await refresh()
        guard ready,generation == token else { return }
        poll?.cancel();poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 12 : 45)) } catch { return }
                guard let self,self.ready,self.generation == token else { return };await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return };let token=generation
        do {
            try await operations.acquire();defer { operations.release() };try check(token)
            try await readInfo()
            for id in allowedConfigs.sorted() where !unavailable.contains(id) {
                try check(token);_ = try? await readConfig(id,optional:true)
            }
            if !wearUnavailable { _ = try? await readWear(optional:true) }
        } catch { if generation == token { close();onClose?(error.localizedDescription) } }
    }
    var availableFeatures:[FeatureDefinition] {
        var result:[FeatureDefinition]=[]
        if state.switches[4] != nil { result.append(FeatureDefinition("wear",4)) }
        if configs[4] != nil { result.append(FeatureDefinition("dual",0x11)) }
        return result
    }
    func canQuery(_ command:UInt16) -> Bool {
        if [Command.battery,Command.firmware,Command.product].contains(command) { return profile != nil }
        return [Command.noise:UInt16(11),Command.equalizer:7,Command.customEQ:55,Command.gestures:2,Command.spatial:29,Command.wear:12][command].map(allowedConfigs.contains) ?? (command == Command.switches && (!availableFeatures.isEmpty || allowedConfigs.contains(47)))
    }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        guard ready,profile?.controls == true else { return false }
        let read:UInt16
        switch command {
        case Command.setNoise:guard model?.noiseOptions.isEmpty == false,configs[11] != nil || profile == .redmi6lite else { return false };read=Command.noise
        case Command.setEQ:guard configs[7] != nil else { return false };read=Command.equalizer
        case Command.setCustomEQ:guard state.eq == 10,configs[55] != nil else { return false };read=Command.customEQ
        case Command.setGestures:guard configs[2] != nil else { return false };read=Command.gestures
        case Command.setSpatial:guard configs[29] != nil else { return false };read=Command.spatial
        case Command.setSwitch:guard state.switches[4] != nil || configs[4] != nil || configs[47] != nil else { return false };read=Command.switches
        case Command.find:guard model?.function["findDevice"].enabled == true else { return false };read=Command.wear
        default:return false
        }
        return reading == nil || reading == read
    }
    private func writeConfig(_ id:UInt16,_ value:[UInt8],confirm:([UInt8]) -> Bool) async throws -> WriteOutcome {
        try await send(0xF2,XiaomiProtocol.config(id,value))
        for attempt in 0..<3 {
            let actual=try await readConfig(id)
            if confirm(actual) { return .confirmed }
            if attempt < 2 { try await Task.sleep(for:.milliseconds(120)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise),let code=[NoiseMode.off:UInt8(0),.anc:1,.transparency:2][mode] else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        if profile != .redmi6lite { _ = try await readConfig(11) }
        if profile == .redmi8pro {
            // C0/F2 is captured on the Mac endpoint. Retain an observed strength
            // for the target mode; zero is the documented first level/preset.
            let value:[UInt8]=[code,mode == .off ? 0 : noiseStrengths[mode] ?? 0]
            return try await writeConfig(11,value,confirm:{ $0 == value })
        }
        let revision=noiseRevision
        try await send(8,[2,4,code])
        if profile == .redmi6lite {
            let deadline=Date().addingTimeInterval(2)
            repeat {
                try check(token)
                if noiseRevision != revision,state.noise == mode { return .confirmed }
                try await Task.sleep(for:.milliseconds(30))
            } while Date() < deadline
        } else {
            for attempt in 0..<3 {
                if XiaomiProtocol.noise(try await readConfig(11)) == mode { return .confirmed }
                if attempt < 2 { try await Task.sleep(for:.milliseconds(120)) }
            }
        }
        throw ProtocolError.readbackMismatch
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setEQ),model?.presets.contains(where:{$0.id == id}) == true || id == 10 && !state.customEQ.isEmpty else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        _ = try await readConfig(7)
        return try await writeConfig(7,[id],confirm:{ $0 == [id] })
    }
    func setFeature(_ feature:FeatureDefinition,enabled:Bool) async throws -> WriteOutcome {
        guard canWrite(Command.setSwitch),availableFeatures.contains(feature) || feature == FeatureDefinition("game",6) && configs[47] != nil else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        if feature.switchID == 4 {
            _ = try await readWear();try await send(8,[2,6,enabled ? 0 : 1])
            guard try await readWear() == enabled else { throw ProtocolError.readbackMismatch };return .confirmed
        }
        let id:UInt16=feature.switchID == 6 ? 47 : 4
        _ = try await readConfig(id)
        return try await writeConfig(id,[enabled ? 1 : 0],confirm:{ $0 == [enabled ? 1 : 0] })
    }
    func setSpatial(_ mode:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setSpatial),model?.spatialModes.contains(mode) == true else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        let current=try await readConfig(29)[0],value=(current & ~UInt8(9)) | (mode == 0 ? 0 : mode == 1 ? 1 : 9)
        return try await writeConfig(29,[value],confirm:{ $0 == [value] })
    }
    func saveEQ(_ entry:CustomEQEntry) async throws -> WriteOutcome {
        guard canWrite(Command.setCustomEQ) else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        guard try await readConfig(7) == [10],let current=XiaomiProtocol.customEQ(try await readConfig(55)),
              entry.id == 10,entry.minimum == current.minimum,entry.maximum == current.maximum,
              entry.frequencies == current.frequencies else { throw ProtocolError.unsupported }
        let outcome=try await writeConfig(55,XiaomiProtocol.customEQWrite(entry),confirm:{ bytes in
            guard bytes[1] == 10,let actual=XiaomiProtocol.customEQ(bytes) else { return false }
            return actual.frequencies == entry.frequencies && actual.gains == entry.gains
        })
        guard try await readConfig(7) == [10] else { throw ProtocolError.readbackMismatch };return outcome
    }
    func gestureActions(_ entry:GestureEntry) -> [UInt8] {
        guard canWrite(Command.setGestures),let wire=XiaomiProtocol.gestureType(entry.gesture),let rows=configs[2].flatMap(XiaomiProtocol.gestures),rows[wire] != nil else { return [] }
        let allowed=model?.function["xiaomiGestureActions"][String(wire)].elements.compactMap { $0.int.flatMap(UInt8.init(exactly:)) } ?? []
        return XiaomiProtocol.actionToWire.keys.sorted().filter { allowed.contains(XiaomiProtocol.actionToWire[$0]!) }
    }
    func setGesture(_ entry:GestureEntry,action:UInt8) async throws -> WriteOutcome {
        guard entry.mode == 1,(1...2).contains(entry.side),gestureActions(entry).contains(action),let type=XiaomiProtocol.gestureType(entry.gesture),let value=XiaomiProtocol.actionToWire[action] else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        guard var expected=XiaomiProtocol.gestures(try await readConfig(2)),var pair=expected[type] else { throw ProtocolError.invalidPayload }
        pair[Int(entry.side-1)]=value;expected[type]=pair
        let update:[UInt8]=[type,entry.side == 1 ? value : 255,entry.side == 2 ? value : 255]
        return try await writeConfig(2,update,confirm:{ XiaomiProtocol.gestures($0) == expected })
    }
    func find(_ enabled:Bool) async throws -> WriteOutcome {
        guard canWrite(Command.find) else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        if enabled { guard try await readConfig(12)[0] & 12 == 0 else { throw ProtocolError.unsupported } }
        try await send(0xF2,XiaomiProtocol.config(9,[enabled ? 1 : 0,3]))
        return .sent // A sound request has no independently readable completion state.
    }
    func close() {
        active=false;ready=false;identified=false;generation=UUID();poll?.cancel();poll=nil
        channel.close();authentication.machine=nil;authentication.failure=nil
        configs=[:];unavailable=[];retiredSequences=[];noiseStrengths=[:];wearUnavailable=false;state=DeviceState();onChange?()
    }
}
