import Foundation
import HeyBudsProtocol

@MainActor final class GoogleSession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let channel:ControlChannel<GoogleRPCFrame>
    private var route:UInt32?
    private var callID=UInt32.random(in:1...1_000_000)
    private var streams:[UInt32:UInt32]=[:]
    private var generation=UUID()
    private var poll:Task<Void,Never>?
    private var lastBattery=Date.distantPast
    private var eqBands:[Float]?
    private var eqSupported=false
    private let controls=RequestGate()
    private let refreshes=RequestGate()

    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=3) {
        let known=["Pixel Buds Pro":"google:pixel-buds-pro","Pixel Buds Pro 2":"google:pixel-buds-pro-2"]
        let n=EarbudFamily.normalize(name)
        model=known.first { n == EarbudFamily.normalize($0.key) || n == EarbudFamily.normalize("Google "+$0.key) }.flatMap { entry in catalog.models.first { $0.id == entry.value } }
        var codec=GoogleFrameCodec()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{codec.feed($0)},reset:{codec.reset()})
        channel.onMessage={ [weak self] in self?.receive($0) }
        channel.onClose={ [weak self] reason in self?.close();self?.onClose?(reason) }
    }
    private func nextCall() -> UInt32 { callID=callID == UInt32.max ? 1 : callID+1;return callID }
    func open() async throws {
        guard model != nil else { throw ProtocolError.unsupported }
        let token=generation
        do {
            try await channel.open()
            // Probe only the four documented logical bud routes using a read.
            // Never write another setting merely to test which bud is primary.
            for candidate in GoogleMaestro.candidates {
                guard generation == token else { throw ProtocolError.disconnected }
                do {
                    let info=try await rpc("GetSoftwareInfo",route:candidate,timeout:0.75,probe:true)
                    guard let version=GoogleMaestro.firmware(info.payload) else { continue }
                    let setting=try await rpc("ReadSetting",payload:ProtoFields.encode(4,.uint(13)),route:candidate,timeout:0.75,probe:true)
                    guard let noise=GoogleMaestro.noise(setting.payload) else { continue }
                    route=candidate;state.firmware=version;state.noise=noise
                    state.observedQueries.formUnion([Command.firmware,Command.noise]);break
                } catch is CancellationError { throw CancellationError() }
                catch { guard generation == token else { throw ProtocolError.disconnected } }
            }
            guard route != nil else { throw ProtocolError.unsupported }
            _ = try? await readEQ()
            try Task.checkCancellation();guard generation == token else { throw ProtocolError.disconnected }
            ready=true;onChange?()
        } catch { if generation == token { close() };throw error }
    }
    private func rpc(_ method:String,payload:[UInt8]=[],route selected:UInt32?=nil,timeout:Double?=nil,probe:Bool=false) async throws -> GoogleRPCFrame {
        guard let route=selected ?? route else { throw ProtocolError.disconnected }
        let hash=GoogleMaestro.hash(method),id=nextCall()
        let request=GoogleRPCFrame(channel:route,method:hash,call:id,payload:payload)
        let response=try await channel.request(GoogleFrameCodec.encode(request),timeout:timeout,retireOnTimeout:!probe,matching:{
            $0.channel == route && $0.service == GoogleMaestro.serviceID && $0.method == hash && $0.call == id && ($0.type == 1 || $0.type == 5)
        })
        guard response.type == 1,response.status == 0 else { throw ProtocolError.unsupported }
        return response
    }
    private func setting(_ id:UInt64) async throws -> [UInt8] {
        try await rpc("ReadSetting",payload:ProtoFields.encode(4,.uint(id))).payload
    }
    private func readNoise() async throws -> NoiseMode {
        let token=generation,payload=try await setting(13)
        guard generation == token else { throw ProtocolError.disconnected }
        guard let mode=GoogleMaestro.noise(payload) else {
            state.noise=nil;state.observedQueries.remove(Command.noise);onChange?();throw ProtocolError.invalidPayload
        }
        state.noise=mode;state.observedQueries.insert(Command.noise);onChange?();return mode
    }
    private func readEQ() async throws -> [Float] {
        let token=generation,payload=try await setting(16)
        guard generation == token else { throw ProtocolError.disconnected }
        guard let bands=GoogleMaestro.equalizer(payload) else {
            state.eq=nil;eqBands=nil;state.observedQueries.remove(Command.equalizer);onChange?();throw ProtocolError.invalidPayload
        }
        eqBands=bands;eqSupported=true;state.eq=GoogleMaestro.preset(bands) ?? 255;state.observedQueries.insert(Command.equalizer);onChange?();return bands
    }
    private func subscribe(_ method:String,firstSnapshot:Bool) async throws {
        guard let route else { throw ProtocolError.disconnected }
        let hash=GoogleMaestro.hash(method)
        if streams.values.contains(hash) { return }
        let id=nextCall();streams[id]=hash
        let request=GoogleRPCFrame(channel:route,method:hash,call:id)
        do {
            if firstSnapshot {
                let frame=try await channel.request(GoogleFrameCodec.encode(request),matching:{
                    $0.channel == route && $0.service == GoogleMaestro.serviceID && $0.method == hash && $0.call == id && [UInt32(1),5,7].contains($0.type)
                })
                guard frame.type == 7,frame.status == 0 else { throw ProtocolError.unsupported }
            } else { try await channel.send(GoogleFrameCodec.encode(request)) }
        } catch { streams.removeValue(forKey:id);throw error }
    }
    private func receive(_ frame:GoogleRPCFrame) {
        guard frame.channel == route,frame.service == GoogleMaestro.serviceID,streams[frame.call] == frame.method else { return }
        if frame.type == 1 || frame.type == 5 { streams.removeValue(forKey:frame.call);return }
        guard frame.type == 7,frame.status == 0 else { return }
        if frame.method == GoogleMaestro.hash("SubscribeRuntimeInfo") {
            if GoogleMaestro.applyRuntime(frame.payload,to:&state) { lastBattery=Date();onChange?() }
        } else if frame.method == GoogleMaestro.hash("SubscribeToSettingsChanges") {
            if let mode=GoogleMaestro.noise(frame.payload) { state.noise=mode;state.observedQueries.insert(Command.noise);onChange?() }
            if let bands=GoogleMaestro.equalizer(frame.payload) {
                eqBands=bands;state.eq=GoogleMaestro.preset(bands) ?? 255;state.observedQueries.insert(Command.equalizer);onChange?()
            }
        }
    }
    func initialize() async {
        let token=generation
        await refresh();guard ready,generation == token,!Task.isCancelled else { return }
        poll?.cancel();poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 8 : 30)) } catch { return }
                guard let self,self.ready,self.generation == token else { return };await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready,!Task.isCancelled else { return };let token=generation
        do {
            try await refreshes.acquire();defer { refreshes.release() }
            guard ready,generation == token else { return }
            _ = try await readNoise()
            guard ready,generation == token else { return }
            if eqSupported { _ = try await readEQ() }
            // Re-subscribe periodically for a fresh snapshot. Pigweed specifies
            // CLIENT_ERROR/CANCELLED for cancelling a server stream; late packets
            // retain their old call ID and cannot update the new subscription.
            if Date().timeIntervalSince(lastBattery) >= 30,let route {
                let method=GoogleMaestro.hash("SubscribeRuntimeInfo")
                for (id,value) in streams where value == method {
                    streams.removeValue(forKey:id)
                    try await channel.send(GoogleFrameCodec.encode(GoogleRPCFrame(type:4,channel:route,method:method,call:id,status:1)))
                }
            }
            try await subscribe("SubscribeRuntimeInfo",firstSnapshot:true)
            try await subscribe("SubscribeToSettingsChanges",firstSnapshot:false)
            guard generation == token else { return }
            if Date().timeIntervalSince(lastBattery) >= 120 { state.batteries.removeAll();onChange?() }
        } catch {
            if generation == token { close();onClose?(error is CancellationError ? nil : error.localizedDescription) }
        }
    }
    func canQuery(_ command:UInt16) -> Bool { model != nil && [Command.battery,Command.noise,Command.equalizer,Command.firmware].contains(command) }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        guard ready else { return false }
        let read:UInt16
        if command == Command.setNoise { read=Command.noise } else if command == Command.setEQ { read=Command.equalizer } else { return false }
        return (reading == nil || reading == read) && state.observedQueries.contains(read)
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise),[.off,.anc,.transparency].contains(mode) else { throw ProtocolError.unsupported }
        let token=generation
        try await controls.acquire();defer { controls.release() }
        guard ready,generation == token else { throw ProtocolError.disconnected }
        _ = try await rpc("WriteSetting",payload:GoogleMaestro.noiseWrite(mode))
        for attempt in 0..<6 {
            try Task.checkCancellation();guard ready,generation == token else { throw ProtocolError.disconnected }
            let fresh=try await readNoise()
            if ready,generation == token,fresh == mode { return .confirmed }
            if attempt < 5 { try await Task.sleep(for:.milliseconds(200)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setEQ),Int(id) < GoogleMaestro.presets.count else { throw ProtocolError.unsupported }
        let target=GoogleMaestro.presets[Int(id)],token=generation
        try await controls.acquire();defer { controls.release() }
        guard ready,generation == token else { throw ProtocolError.disconnected }
        _ = try await rpc("WriteSetting",payload:GoogleMaestro.equalizerWrite(target))
        let fresh=try await readEQ();try Task.checkCancellation()
        guard ready,generation == token else { throw ProtocolError.disconnected }
        guard GoogleMaestro.preset(fresh) == id else { throw ProtocolError.readbackMismatch };return .confirmed
    }
    func close() {
        ready=false;generation=UUID();poll?.cancel();poll=nil;streams.removeAll();route=nil
        channel.close();state=DeviceState();eqBands=nil;eqSupported=false;lastBattery = .distantPast;onChange?()
    }
}
