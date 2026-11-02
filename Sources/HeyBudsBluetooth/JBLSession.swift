import Foundation
import HeyBudsProtocol

@MainActor final class JBLSession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let profile:JBLProfile?
    private let channel:ControlChannel<JBLFrame>
    private let operations=RequestGate()
    private var active=false,generation=UUID()
    private var poll:Task<Void,Never>?
    private var lastSend:ContinuousClock.Instant?
    private let minimumInterval:Duration
    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=8,minimumInterval:Duration = .seconds(2)) {
        self.minimumInterval=minimumInterval
        profile=JBLProfile.named(name);model=profile.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        var codec=JBLFrameCodec(profile:profile ?? .tune230)
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ codec.feed($0) },reset:{ codec.reset() })
        channel.onClose={ [weak self] reason in self?.close();self?.onClose?(reason) }
    }
    private func check(_ token:UUID) throws { try Task.checkCancellation();guard active,generation == token else { throw ProtocolError.disconnected } }
    private func spacing() async throws {
        let token=generation
        if profile?.usesBLE == true,let lastSend {
            let deadline=lastSend.advanced(by:minimumInterval)
            if ContinuousClock.now < deadline { try await Task.sleep(until:deadline,clock:.continuous) }
        }
        try check(token);lastSend=ContinuousClock.now
    }
    private func readNoise() async throws {
        guard let profile else { throw ProtocolError.unsupported };let token=generation
        try await spacing()
        let reply=try await channel.request(JBLFrameCodec.encode(profile.noiseRead,profile:profile),matching:{
            $0.command == profile.noiseRead.command && (profile.usesBLE ? $0.payload.first == 0x12 : $0.payload.count >= 4)
        })
        try check(token)
        state.noise=profile.noise(reply)
        // A complete TalkThru report is still valid protocol evidence; its state
        // stays unnamed in this three-mode UI until the user selects a mode.
        guard state.noise != nil || (profile.usesBLE && reply.payload == [0x12,1,0,2,0,3,1]) else { throw ProtocolError.invalidPayload }
        state.observedQueries.insert(Command.noise);onChange?()
    }
    private func readBattery() async throws {
        guard profile == .waveBuds2 else { return };let token=generation
        try await spacing()
        let reply=try await channel.request(JBLFrameCodec.encode(JBLProfile.informationRead,profile:.waveBuds2),matching:{ $0.command == 6 && $0.payload.first == 2 })
        try check(token);guard let sample=profile?.information(reply.payload) else { throw ProtocolError.invalidPayload }
        state.batteries=sample.batteries;state.firmware=sample.firmware;state.observedQueries.formUnion(sample.observedQueries);onChange?()
    }
    func open() async throws {
        guard let profile,model != nil,!active else { throw ProtocolError.unsupported };let token=generation;active=true
        do {
            try await channel.open()
            if profile.usesBLE { try await spacing();try await channel.send(JBLFrameCodec.encode(JBLFrame(0x9B,[1,1]),profile:profile)) }
            try await readNoise();try await readBattery();try check(token);ready=true;onChange?()
        } catch { if generation == token { close() };throw error }
    }
    func initialize() async {
        guard ready else { return };let token=generation;poll?.cancel()
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 12 : 30)) } catch { return }
                guard let self,self.ready,self.generation == token else { return };await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return };let token=generation
        do { try await operations.acquire();defer { operations.release() };try check(token);try await readNoise();try await readBattery() }
        catch { if generation == token { close();onClose?(error.localizedDescription) } }
    }
    func canQuery(_ command:UInt16) -> Bool { profile != nil && (command == Command.noise || (profile == .waveBuds2 && [Command.battery,Command.firmware].contains(command))) }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool { ready && command == Command.setNoise && (reading == nil || reading == Command.noise) && state.observedQueries.contains(Command.noise) }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise),let profile,let frame=profile.noiseWrite(mode) else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        try await spacing();try await channel.send(JBLFrameCodec.encode(frame,profile:profile))
        for attempt in 0..<4 {
            try await readNoise();try check(token);if state.noise == mode { return .confirmed }
            if attempt < 3 { try await Task.sleep(for:.milliseconds(200)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome { throw ProtocolError.unsupported }
    func close() { active=false;ready=false;generation=UUID();poll?.cancel();poll=nil;channel.close();state=DeviceState();lastSend=nil;onChange?() }
}
