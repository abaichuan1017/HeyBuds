import Foundation
import HeyBudsProtocol

private struct SonyInbound {
    let frame:SonyFrame
    let duplicate:Bool
}

@MainActor private final class SonyDecoder {
    private var codec=SonyFrameCodec()
    private var lastReceived:SonyFrame?
    func reset() { codec.reset();lastReceived=nil }
    func feed(_ bytes:Data) -> [SonyInbound] {
        codec.feed(bytes).map { frame in
            let data=frame.type == 0x0C || frame.type == 0x0E
            let duplicate=data && frame == lastReceived
            if data { lastReceived=frame }
            return SonyInbound(frame:frame,duplicate:duplicate)
        }
    }
}

/// Allowlisted MDR V1/V2 profiles. Transport ACKs never confirm a setting.
@MainActor final class SonySession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var profile:SonyProfile?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    var onDiagnostic:((String) -> Void)?
    var supportsAmbientLevel:Bool { ready && profile?.supportsAmbientLevel == true }
    var supportsFocusOnVoice:Bool { ready && profile?.supportsFocusOnVoice == true }
    private let channel:ControlChannel<SonyInbound>
    private let catalog:ModelCatalog
    private let advertisedProfile:SonyProfile?
    private let serviceUUID:String?
    private var generation=UUID()
    private var active=false
    private var verifiedGeneration:SonyGeneration?
    private var functions:Set<UInt8>=[]
    private var noiseAvailable=true
    private let requests=RequestGate(),settings=RequestGate()
    private var sequence:UInt8=0
    private var poll:Task<Void,Never>?
    private var lastBattery=Date.distantPast
    private var lastNoise=Date.distantPast

    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=3,serviceUUID:String?=nil) {
        self.catalog=catalog;self.serviceUUID=serviceUUID
        advertisedProfile=SonyProtocol.profile(name:name)
        let named=catalog.model(productID:nil,name:name)
        model=SonyProtocol.supportsModel(named) ? named : nil
        profile=SonyProtocol.profile(model:model)
        let decoder=SonyDecoder()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ decoder.feed($0) },reset:{ decoder.reset() },acknowledge:{ inbound in
            let frame=inbound.frame
            guard frame.type == 0x0C || frame.type == 0x0E else { return nil }
            return try? SonyFrameCodec.encode(SonyFrame(type:1,sequence:frame.sequence ^ 1))
        })
        channel.onMessage={ [weak self] inbound in
            guard let self,self.active,!inbound.duplicate,inbound.frame.type == 0x0C,
                  let version=self.verifiedGeneration,
                  [SonyProtocol.batteryNotification(generation:version),0x65,0x69].contains(inbound.frame.payload.first ?? 0xFF) else { return }
            self.apply(inbound.frame.payload)
        }
        channel.onClose={ [weak self] reason in self?.fail(reason) }
    }
    func open() async throws {
        guard !active else { throw ProtocolError.unsupported }
        let token=generation;active=true
        do {
            try await channel.open()
            guard generation == token else { throw ProtocolError.disconnected }
            let handshake=try await read([0,0],reply:1)
            guard let version=SonyProtocol.generation(fromHandshake:handshake.payload) else { throw ProtocolError.unsupported }
            if let serviceUUID {
                guard SonyProtocol.generation(serviceUUID:serviceUUID) == version else { throw ProtocolError.unsupported }
            }
            verifiedGeneration=version
            let identityType:UInt8=version == .v2 ? (advertisedProfile?.identityFrameType ?? 0x0C) : 0x0C
            let identity=try await read([4,1],reply:5,type:identityType)
            guard let name=SonyProtocol.deviceText(identity.payload,type:1),
                  let identifiedProfile=SonyProtocol.profile(name:name),identifiedProfile.generation == version,
                  let identified=catalog.models.first(where:{$0.id == identifiedProfile.modelID}),
                  SonyProtocol.profile(model:identified) == identifiedProfile else { throw ProtocolError.unsupported }
            // The returned identity and verified protocol always win over names/overrides.
            model=identified;profile=identifiedProfile;state.productID=identified.id
            if identifiedProfile != .whXB910n {
                let firmware=try await read([4,2],reply:5)
                guard let version=SonyProtocol.deviceText(firmware.payload,type:2) else { throw ProtocolError.invalidPayload }
                state.firmware=version;state.observedQueries.insert(Command.firmware)
            }
            // XB910N's documented firmware is an extended Table 2 structure.
            // It is deliberately left unknown until a separately bounded parser exists.
            let supported=try await read([6,0],reply:7)
            guard let functions=SonyProtocol.functions(supported.payload,generation:version) else { throw ProtocolError.invalidPayload }
            self.functions=functions
            try Task.checkCancellation()
            guard generation == token else { throw ProtocolError.disconnected }
            ready=true;onChange?();onDiagnostic?("Sony MDR profile, identity and functions verified")
        } catch { if generation == token { close() };throw error }
    }
    func initialize() async {
        let token=generation
        await refresh()
        guard ready,generation == token,!Task.isCancelled else { return }
        poll?.cancel()
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self,self.ready,self.generation == token else { return }
                if Date().timeIntervalSince(self.lastBattery) >= (self.interactive ? 10 : 40) { try? await self.readBatteries() }
                guard self.ready,self.generation == token,!Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastNoise) >= (self.interactive ? 5 : 40),self.canQuery(Command.noise) { _ = try? await self.readNoise() }
                guard self.ready,self.generation == token,!Task.isCancelled else { return }
                let stale=self.state.batteries.filter { Date().timeIntervalSince($0.value.updatedAt) >= 120 }.map(\.key)
                for slot in stale { self.state.batteries.removeValue(forKey:slot) }
                if !stale.isEmpty { self.onChange?() }
            }
        }
    }
    func refresh() async {
        guard ready,!Task.isCancelled else { return }
        let token=generation
        try? await readBatteries()
        if ready,generation == token,canQuery(Command.noise),!Task.isCancelled { _ = try? await readNoise() }
    }
    private var batterySubtypes:[UInt8] {
        guard let profile,verifiedGeneration == profile.generation else { return [] }
        return SonyProtocol.batteryQueries(functions:functions,single:profile.singleBattery,generation:profile.generation)
    }
    private func readBatteries() async throws {
        guard ready,let profile else { return }
        let token=generation
        for subtype in batterySubtypes {
            guard generation == token,!Task.isCancelled else { throw ProtocolError.disconnected }
            guard let request=SonyProtocol.batteryRequest(subtype:subtype,generation:profile.generation) else { throw ProtocolError.unsupported }
            let reply=try await read(request,reply:SonyProtocol.batteryReply(generation:profile.generation))
            var check=DeviceState()
            guard SonyProtocol.applyBattery(reply.payload,generation:profile.generation,to:&check) else { throw ProtocolError.invalidPayload }
        }
        guard generation == token,!Task.isCancelled else { throw ProtocolError.disconnected }
        lastBattery=Date()
    }
    private func readNoise() async throws -> SonyFrame {
        guard let profile else { throw ProtocolError.unsupported }
        return try await read([0x66,profile.noiseSubtype],reply:0x67)
    }
    func canQuery(_ command:UInt16) -> Bool {
        guard active,let profile,verifiedGeneration == profile.generation,model != nil else { return false }
        switch command {
        case Command.battery:return !batterySubtypes.isEmpty
        case Command.noise:return functions.contains(profile.noiseFunction)
        case Command.firmware:return profile != .whXB910n
        default:return false
        }
    }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        ready && command == Command.setNoise && (reading == nil || reading == Command.noise)
            && canQuery(Command.noise) && noiseAvailable && state.sonyNoise?.settled == true
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome { throw ProtocolError.unsupported }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard let current=state.sonyNoise,let profile else { throw ProtocolError.unsupported }
        // V1 NC reports an ambient value of zero. Enter ambient at the documented
        // maximum when there is no retained usable level; ULT never gets a level.
        let level=profile.supportsAmbientLevel ? current.ambientLevel.flatMap { (1...20).contains($0) ? $0 : nil } ?? 20 : nil
        return try await writeNoise(mode:mode,level:level,voice:current.focusOnVoice)
    }
    func setAmbient(level:Int,focusOnVoice:Bool) async throws -> WriteOutcome {
        guard supportsAmbientLevel,state.noise == .transparency else { throw ProtocolError.unsupported }
        return try await writeNoise(mode:.transparency,level:level,voice:focusOnVoice)
    }
    func setFocusOnVoice(_ enabled:Bool) async throws -> WriteOutcome {
        guard supportsFocusOnVoice,state.noise == .transparency,let current=state.sonyNoise else { throw ProtocolError.unsupported }
        return try await writeNoise(mode:.transparency,level:current.ambientLevel,voice:enabled)
    }
    private func writeNoise(mode:NoiseMode,level:Int?,voice:Bool) async throws -> WriteOutcome {
        let token=generation
        try await settings.acquire();defer { settings.release() }
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        guard canWrite(Command.setNoise),let profile else { throw ProtocolError.unsupported }
        let payload=try SonyProtocol.noiseWrite(mode:mode,level:level,voice:voice,profile:profile)
        _ = try await request(payload,reply:nil)
        guard ready,generation == token else { throw ProtocolError.disconnected }
        for attempt in 0..<6 {
            let reply=try await readNoise()
            try Task.checkCancellation()
            guard ready,generation == token else { throw ProtocolError.disconnected }
            guard let fresh=SonyProtocol.noise(reply.payload,profile:profile) else { throw ProtocolError.invalidPayload }
            if SonyProtocol.noiseReadbackMatches(fresh,mode:mode,level:level,voice:voice,profile:profile) { return .confirmed }
            // Only a complete fresh GET confirms a write, never notifications/cache/ACK.
            if attempt < 5 { try await Task.sleep(for:.milliseconds(200)) }
            guard ready,generation == token else { throw ProtocolError.disconnected }
        }
        throw ProtocolError.readbackMismatch
    }
    private func read(_ payload:[UInt8],reply:UInt8,type:UInt8=0x0C) async throws -> SonyFrame {
        guard let frame=try await request(payload,reply:reply,type:type) else { throw ProtocolError.invalidPayload }
        return frame
    }
    private func request(_ payload:[UInt8],reply:UInt8?,type:UInt8=0x0C) async throws -> SonyFrame? {
        let token=generation
        try await requests.acquire();defer { requests.release() }
        try Task.checkCancellation()
        guard active,generation == token else { throw ProtocolError.disconnected }
        guard verifiedGeneration != nil || payload == [0,0] else { throw ProtocolError.unsupported }
        // Serialize before choosing the one-bit TX sequence. ControlChannel owns
        // serialized writes/ACKs, deadlines, cancellation and transport generations.
        let sentSequence=sequence,subtype=payload.count > 1 ? payload[1] : nil
        var acknowledged=false
        var response:SonyFrame?
        _ = try await channel.request(SonyFrameCodec.encode(SonyFrame(type:type,sequence:sentSequence,payload:payload)),matching:{ [weak self] inbound in
            guard let self,self.active,self.generation == token else { return false }
            let frame=inbound.frame
            if frame.type == 1,frame.payload.isEmpty,frame.sequence == sentSequence ^ 1 {
                acknowledged=true;self.sequence=frame.sequence
            } else if !inbound.duplicate,let reply,frame.type == type,frame.payload.first == reply,
                      frame.payload.count >= 2,frame.payload[1] == subtype,response == nil {
                response=frame
                if type == 0x0C { self.apply(frame.payload) }
            }
            return acknowledged && (reply == nil || response != nil)
        })
        guard active,generation == token else { throw ProtocolError.disconnected }
        return response
    }
    private func apply(_ payload:[UInt8]) {
        guard let profile,verifiedGeneration == profile.generation,model != nil else { return }
        if payload.count >= 2,batterySubtypes.contains(payload[1]),
           SonyProtocol.applyBattery(payload,generation:profile.generation,to:&state) { onChange?() }
        if functions.contains(profile.noiseFunction),let noise=SonyProtocol.noise(payload,profile:profile) {
            state.sonyNoise=noise;state.noise=noise.mode;state.observedQueries.insert(Command.noise)
            lastNoise=Date();onChange?()
        }
        if payload.count == 3,payload[0] == 0x65,payload[1] == profile.noiseSubtype,payload[2] <= 1 {
            noiseAvailable=payload[2] == 0;onChange?()
        }
    }
    private func fail(_ reason:String?) {
        guard active else { return }
        close();onClose?(reason)
    }
    func close() {
        ready=false;active=false;generation=UUID();verifiedGeneration=nil
        poll?.cancel();poll=nil;channel.close();sequence=0
        functions.removeAll();noiseAvailable=true;state=DeviceState();profile=nil;model=nil;onChange?()
        lastBattery = .distantPast;lastNoise = .distantPast
    }
}
