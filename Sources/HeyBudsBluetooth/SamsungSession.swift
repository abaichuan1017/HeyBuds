import Foundation
import HeyBudsProtocol

@MainActor final class SamsungSession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let profile:SamsungProfile?
    private let channel:ControlChannel<SamsungFrame>
    private var poll:Task<Void,Never>?
    private var generation=UUID()
    private let controls=RequestGate()

    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=3) {
        profile=SamsungProfile.named(name)
        model=profile.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        var codec=SamsungFrameCodec()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ codec.feed($0) },reset:{ codec.reset() },acknowledge:{ frame in
            frame.command == 0x61 ? try? SamsungFrameCodec.encode(SamsungFrame(0x51,[0x61,0])) : nil
        })
        channel.onMessage={ [weak self] in self?.receive($0) }
        channel.onClose={ [weak self] reason in self?.close();self?.onClose?(reason) }
    }
    func open() async throws {
        guard profile != nil,model != nil else { throw ProtocolError.unsupported }
        let token=generation
        do {
            try await channel.open()
            // Known host handshake only; no time/firmware/account/serial operations.
            try await channel.send(SamsungFrameCodec.encode(SamsungFrame(0x51,[0])))
            try await channel.send(SamsungFrameCodec.encode(SamsungFrame(0x88,[1,1,0,1])))
            _ = try await readStatus()
            try Task.checkCancellation();guard generation == token else { throw ProtocolError.disconnected }
            ready=true;onChange?()
        } catch { if generation == token { close() };throw error }
    }
    func initialize() async {
        guard ready else { return };let token=generation
        poll?.cancel();poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 8 : 30)) } catch { return }
                guard let self,self.ready,self.generation == token else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async { guard ready,!Task.isCancelled else { return };_ = try? await readStatus() }
    private func readStatus() async throws -> DeviceState {
        let token=generation
        let frame=try await channel.request(SamsungFrameCodec.encode(SamsungFrame(0x61)),matching:{$0.command == 0x61})
        guard generation == token else { throw ProtocolError.disconnected }
        guard let sample=profile?.status(frame.payload) else {
            state=DeviceState();onChange?();throw ProtocolError.invalidPayload
        }
        return sample
    }
    private func receive(_ frame:SamsungFrame) {
        if frame.command == 0x61,let sample=profile?.status(frame.payload) {
            state=sample;onChange?()
        } else if frame.command == 0x60,frame.payload.count >= 7 {
            let p=frame.payload
            for (offset,slot):(Int,BatterySlot) in [(1,.left),(2,.right),(6,.enclosure)] {
                SamsungProfile.battery(p[offset],slot:slot,charging:false,to:&state)
            }
            onChange?()
        } else if frame.command == 0x77,frame.payload.count == 1,
                  let mode=[UInt8(0):NoiseMode.off,1:.anc,2:.transparency,3:.adaptive][frame.payload[0]],profile?.noiseByte(mode) != nil {
            state.noise=mode;onChange?()
        }
    }
    func canQuery(_ command:UInt16) -> Bool { model != nil && [Command.battery,Command.noise,Command.equalizer].contains(command) }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        guard ready else { return false }
        let read:UInt16
        if command == Command.setNoise { read=Command.noise } else if command == Command.setEQ { read=Command.equalizer } else { return false }
        return (reading == nil || reading == read) && state.observedQueries.contains(read)
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise),let value=profile?.noiseByte(mode) else { throw ProtocolError.unsupported }
        return try await write(0x78,payload:[value]) { $0.noise == mode }
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setEQ),id <= 5 else { throw ProtocolError.unsupported }
        return try await write(0x86,payload:[id]) { $0.eq == id }
    }
    func setTouchLocked(_ locked:Bool) async throws -> WriteOutcome {
        guard ready,let profile,profile != .buds4Pro else { throw ProtocolError.unsupported }
        let fresh=try await readStatus()
        guard let current=fresh.samsungControls else { throw ProtocolError.invalidPayload }
        return try await write(0x90,payload:profile.touchLockPayload(locked,current:current)) { $0.samsungControls?.touchLocked == locked }
    }
    func setANCLevel(_ level:Int) async throws -> WriteOutcome {
        guard ready,profile == .buds4Pro,state.samsungControls?.ancLevel != nil,(0...4).contains(level) else { throw ProtocolError.unsupported }
        return try await write(0x83,payload:[UInt8(level)]) { $0.samsungControls?.ancLevel == level }
    }
    private func write(_ command:UInt8,payload:[UInt8],confirmed:(DeviceState) -> Bool) async throws -> WriteOutcome {
        let token=generation
        try await controls.acquire();defer { controls.release() }
        guard ready,generation == token else { throw ProtocolError.disconnected }
        try await channel.send(SamsungFrameCodec.encode(SamsungFrame(command,payload)))
        for attempt in 0..<6 {
            try Task.checkCancellation();guard ready,generation == token else { throw ProtocolError.disconnected }
            let fresh=try await readStatus()
            guard ready,generation == token else { throw ProtocolError.disconnected }
            if confirmed(fresh) { return .confirmed }
            if attempt < 5 { try await Task.sleep(for:.milliseconds(200)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func close() { ready=false;generation=UUID();poll?.cancel();poll=nil;channel.close();state=DeviceState();onChange?() }
}
