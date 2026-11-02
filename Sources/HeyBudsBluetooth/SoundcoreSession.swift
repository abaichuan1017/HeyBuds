import Foundation
import HeyBudsProtocol

@MainActor final class SoundcoreSession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let profile:SoundcoreProfile?
    private let channel:ControlChannel<SoundcoreFrame>
    private let operations=RequestGate()
    private var active=false,generation=UUID()
    private var poll:Task<Void,Never>?
    private var snapshot:SoundcoreSnapshot?
    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=3) {
        profile=SoundcoreProfile.named(name)
        model=profile.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        var codec=SoundcoreFrameCodec()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ codec.feed($0) },reset:{ codec.reset() })
        channel.onClose={ [weak self] reason in self?.close();self?.onClose?(reason) }
    }
    private func check(_ token:UUID) throws { try Task.checkCancellation();guard active,generation == token else { throw ProtocolError.disconnected } }
    func open() async throws {
        guard profile != nil,model != nil,!active else { throw ProtocolError.unsupported }
        active=true;let token=generation
        do { try await channel.open();_ = try await read();try check(token);ready=true;onChange?() }
        catch { if generation == token { close() };throw error }
    }
    private func read() async throws -> SoundcoreSnapshot {
        let token=generation
        let frame=try await channel.request(SoundcoreFrameCodec.encode(SoundcoreFrame(0x0101)),matching:{ $0.command == 0x0101 && !$0.payload.isEmpty })
        try check(token)
        guard let result=profile?.snapshot(frame.payload) else { snapshot=nil;state=DeviceState();onChange?();throw ProtocolError.invalidPayload }
        snapshot=result;state=result.state;onChange?();return result
    }
    func initialize() async {
        guard ready else { return };let token=generation;poll?.cancel()
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 8 : 30)) } catch { return }
                guard let self,self.ready,self.generation == token else { return };await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return };let token=generation
        do { try await operations.acquire();defer { operations.release() };try check(token);_ = try await read() }
        catch { if generation == token { close();onClose?(error.localizedDescription) } }
    }
    var availableFeatures:[FeatureDefinition] { profile?.dualOffset != nil ? [FeatureDefinition("dual",0x11)] : [] }
    func canQuery(_ command:UInt16) -> Bool { profile != nil && [Command.battery,Command.noise,Command.equalizer,Command.customEQ,Command.firmware,Command.switches].contains(command) }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        guard ready,let snapshot else { return false }
        let target:UInt16
        switch command {
        case Command.setNoise:target=Command.noise
        case Command.setEQ:guard snapshot.eqWritable else { return false };target=Command.equalizer
        case Command.setCustomEQ:guard snapshot.eqWritable else { return false };target=Command.customEQ
        case Command.setSwitch:guard state.switches[0x11] != nil else { return false };target=Command.switches
        default:return false
        }
        return (reading == nil || reading == target) && state.observedQueries.contains(target)
    }
    private func write(_ build:(SoundcoreProfile,SoundcoreSnapshot) throws -> SoundcoreFrame,
                       confirmed:(SoundcoreSnapshot) -> Bool) async throws -> WriteOutcome {
        guard ready,let profile else { throw ProtocolError.unsupported };let token=generation
        try await operations.acquire();defer { operations.release() };try check(token)
        let fresh=try await read(),frame=try build(profile,fresh)
        try check(token);try await channel.send(SoundcoreFrameCodec.encode(frame))
        for attempt in 0..<5 {
            try check(token);let result=try await read();try check(token)
            if confirmed(result) { return .confirmed }
            if attempt < 4 { try await Task.sleep(for:.milliseconds(180)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise) else { throw ProtocolError.unsupported }
        return try await write({ try $0.noiseWrite(mode,snapshot:$1) },confirmed:{ $0.state.noise == mode })
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        if id == 254 {
            guard let current=state.customEQ.first else { throw ProtocolError.unsupported };return try await saveEQ(current)
        }
        guard canWrite(Command.setEQ),let curve=profile?.presetCurves[id] else { throw ProtocolError.unsupported }
        return try await write({ try $0.equalizerWrite(id:UInt16(id),curve:curve,snapshot:$1) },confirmed:{
            $0.eqWritable && $0.equalizerID == UInt16(id) && $0.curves == (self.profile?.singleBattery == true ? curve : curve+curve)
        })
    }
    func saveEQ(_ entry:CustomEQEntry) async throws -> WriteOutcome {
        guard canWrite(Command.setCustomEQ),[UInt8(0),254].contains(entry.id),entry.frequencies == SoundcoreProfile.frequencies,entry.gains.count == 8,entry.gains.allSatisfy({ (-6...6).contains($0) }),let profile else { throw ProtocolError.unsupported }
        let curve=entry.gains.map { UInt8(120+Int($0)*10) }+(profile.oldEQ ? [] : [120,120])
        return try await write({ try $0.equalizerWrite(id:0xFEFE,curve:curve,snapshot:$1) },confirmed:{
            $0.eqWritable && $0.equalizerID == 0xFEFE && $0.curves == (profile.singleBattery ? curve : curve+curve)
        })
    }
    func setFeature(_ feature:FeatureDefinition,enabled:Bool) async throws -> WriteOutcome {
        guard availableFeatures.contains(feature),canWrite(Command.setSwitch) else { throw ProtocolError.unsupported }
        return try await write({ _,fresh in
            guard fresh.state.switches[0x11] != nil else { throw ProtocolError.unsupported }
            return SoundcoreFrame(0x0B84,[enabled ? 1 : 0])
        },confirmed:{ $0.state.switches[0x11] == enabled })
    }
    func close() { active=false;ready=false;generation=UUID();poll?.cancel();poll=nil;channel.close();snapshot=nil;state=DeviceState();onChange?() }
}
