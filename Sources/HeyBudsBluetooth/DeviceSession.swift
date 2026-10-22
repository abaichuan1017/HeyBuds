import Foundation
import HeyBudsProtocol

@MainActor final class RequestGate {
    private var held=false
    private var waiters:[(UUID,CheckedContinuation<Void,Error>)]=[]
    func acquire() async throws {
        try Task.checkCancellation()
        if !held { held=true; return }
        let id=UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in waiters.append((id,c)) }
        }, onCancel: { Task { @MainActor in
            if let i=self.waiters.firstIndex(where:{$0.0 == id}) { self.waiters.remove(at:i).1.resume(throwing:CancellationError()) }
        } })
    }
    func release() { if waiters.isEmpty { held=false } else { waiters.removeFirst().1.resume() } }
}
public enum WriteOutcome: String, Sendable { case confirmed, sent }

@MainActor public final class DeviceSession {
    private var opoState=DeviceState()
    public private(set) var state:DeviceState { get { brandSession?.state ?? opoState } set { opoState=newValue } }
    private var opoModel:DeviceModel?
    public private(set) var model:DeviceModel? { get { brandSession?.model ?? opoModel } set { opoModel=newValue } }
    private var opoReady=false
    public private(set) var ready:Bool { get { brandSession?.ready ?? opoReady } set { opoReady=newValue } }
    private var brandSession:BrandSession?
    public var onChange: (() -> Void)?
    public var onClose: ((String?) -> Void)?
    public var interactive=false { didSet { brandSession?.interactive=interactive } }
    public var onDiagnostic: ((String) -> Void)?
    private let catalog: ModelCatalog
    private let name: String
    private var overrideID: String?
    public let transport: EarbudTransport
    private var codec=OPOFrameCodec()
    private let gate=RequestGate()
    private var sequence: UInt8=0
    private var generation=UUID()
    private struct Pending {
        let id:UUID, command:UInt16, sequence:UInt8
        let continuation:CheckedContinuation<OPOFrame,Error>
    }
    private var pending:Pending?
    private var deadline:Task<Void,Never>?
    private var poll:Task<Void,Never>?
    private var last:[UInt16:Date]=[:]

    public init(transport:EarbudTransport, name:String, catalog:ModelCatalog, overrideID:String?=nil, family:EarbudFamily?=nil, localHostAddress:[UInt8]?=nil) {
        self.transport=transport; self.name=name; self.catalog=catalog; self.overrideID=overrideID
        model=catalog.model(productID:nil,name:name,override:overrideID)
        let selectedFamily=family ?? model?.family ?? catalog.family(name:name) ?? .oppo
        if model?.family != selectedFamily { model=nil }
        if selectedFamily != .oppo {
            let backend=BrandSession(transport:transport,name:name,catalog:catalog,family:selectedFamily,overrideID:overrideID,localHostAddress:localHostAddress)
            brandSession=backend
            backend.onChange={ [weak self] in self?.onChange?() }
            backend.onClose={ [weak self] reason in self?.onClose?(reason) }
            backend.onDiagnostic={ [weak self] line in self?.onDiagnostic?(line) }
        }
    }
    public func open() async throws {
        if let brandSession { try await brandSession.open();return }
        let token=generation
        transport.onEvent = { [weak self] event in
            guard let self, self.generation == token else { return }
            switch event {
            case .data(let bytes): self.receive(bytes)
            case .closed(let reason): self.close(); self.onClose?(reason)
            }
        }
        try await transport.open()
        if transport.label == "BLE GATT" {
            // OPOv1 BLE session opener documented by the reference protocol notes.
            try await transport.send(Data([0xAA,7,0,0,0,1,1,0,0,0x12]))
            try await Task.sleep(for:.seconds(2))
            try await transport.send(try OPOFrameCodec.encode(OPOFrame(command:0x8500,sequence:2,payload:[0,0xB5,0x50,0xA0,0x69])))
            try await Task.sleep(for:.milliseconds(1600))
        }
        _ = try? await request(Command.capabilities)
        _ = try? await request(Command.product)
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        _ = try? await request(Command.battery)
        guard !state.observedQueries.isEmpty || !state.batteries.isEmpty else { throw TransportFailure.unavailable("Control channel opened but no OPOv1 response arrived") }
        ready=true; onChange?()
    }
    public func initialize() async {
        if let brandSession { await brandSession.initialize();return }
        let token=generation
        await subscribe()
        for (command,payload) in initialQueries() {
            guard generation == token, ready, !Task.isCancelled else { return }
            _ = try? await request(command,payload:payload)
            if transport.label == "BLE GATT" { try? await Task.sleep(for:.milliseconds(200)) }
        }
        guard generation == token, ready else { return }
        startPolling()
    }
    public func setModelOverride(_ id:String?) {
        if let brandSession { brandSession.setModelOverride(id);return }
        let selected=catalog.model(productID:state.productID,name:name,override:id)
        guard selected?.family == .oppo || selected == nil else { return }
        overrideID=id; model=selected; onChange?()
    }
    public var supportsSpatialAudio: Bool {
        if let brandSession { return brandSession.supportsSpatialAudio }
        guard model?.spatialModes.isEmpty == false else { return false }
        if let commands=state.supportedCommands { return commands.isSuperset(of:[Command.spatial,Command.setSpatial]) }
        return state.spatial != nil
    }
    public var availableFeatures:[FeatureDefinition] {
        if let brandSession { return brandSession.availableFeatures }
        guard let model else { return [] }
        var features=model.features
        if !model.spatialModes.isEmpty, !supportsSpatialAudio,
           (state.supportedCommands?.contains(Command.setSwitch) == true || state.switches[0x1B] != nil),
           !features.contains(where:{$0.key == "spatialSound"}) { features.append(FeatureDefinition("spatialSound",0x1B)) }
        return features
    }
    public func canQuery(_ command:UInt16) -> Bool {
        if let brandSession { return brandSession.canQuery(command) }
        if [Command.product,Command.capabilities,Command.battery,Command.switches].contains(command) { return true }
        if let supported=state.supportedCommands { return supported.contains(command) }
        guard let model else { return false }
        switch command {
        case Command.noise: return !model.noiseOptions.isEmpty
        case Command.equalizer: return !model.presets.isEmpty
        case Command.spatial: return !model.spatialModes.isEmpty
        case Command.customEQ: return !model.customEQFrequencies.isEmpty
        case Command.bass: return model.function["bassEngineSupport"].enabled
        case Command.gameSound: return !model.gameTypes.isEmpty
        case Command.hosts: return model.hostOperationAvailable("displayPairedDevice",firmware:state.firmwareRevision)
        case Command.priority: return model.hostOperationAvailable("setPriorityDevice",firmware:state.firmwareRevision)
        case Command.wear: return model.function["wearDetection"].enabled
        case Command.gestures: return !model.function["control"].elements.isEmpty
        case Command.firmware,Command.codec: return true
        default: return false
        }
    }
    public func canWrite(_ command:UInt16, reading:UInt16?=nil) -> Bool {
        if let brandSession { return brandSession.canWrite(command,reading:reading) }
        guard ready, model != nil else { return false }
        if model?.isT500 == true, command == Command.setNoise { return state.noise != nil }
        if let supported=state.supportedCommands {
            return supported.contains(command) && (reading.map { supported.contains($0) && state.observedQueries.contains($0) } ?? true)
        }
        return reading.map { state.observedQueries.contains($0) } ?? false
    }
    public func refresh() async {
        if let brandSession { await brandSession.refresh();return }
        guard ready, !Task.isCancelled else { return }
        // Re-read all three battery slots immediately, even if a recent partial
        // notification has postponed polling (for example when opening the case).
        _ = try? await request(Command.battery)
        for (c,p) in initialQueries() where !Task.isCancelled && ready { _ = try? await request(c,payload:p) }
    }
    private func initialQueries() -> [(UInt16,[UInt8])] {
        let queries:[(UInt16,[UInt8])]=[(Command.noise,[1,1]),(Command.switches,FeatureCodec.switchQuery(model:model)),
            (Command.equalizer,[]),(Command.spatial,[]),(Command.firmware,[]),(Command.codec,[]),(Command.wear,[]),
            (Command.customEQ,[]),(Command.bass,[]),(Command.gameSound,[]),(Command.hosts,[]),(Command.priority,[]),
            (Command.gestures,[2,3,1])]
        return queries.filter { canQuery($0.0) && !(model?.isT500 == true && $0.0 == Command.noise) }
    }
    private func subscribe() async {
        guard let frame=try? await request(0x0200), frame.payload.count >= 2, frame.payload[0] == 0 else { return }
        let p=frame.payload
        guard p.count >= 2+Int(p[1]) else { return }
        // Only event types with documented semantics; unknown notification subscriptions are unnecessary.
        let events=Array(p.dropFirst(2).prefix(Int(p[1]))).filter { [UInt8(1),2,3,5,6,0x11,0xF2].contains($0) }
        if state.supportedCommands?.contains(0x0205) == true,
           (try? await request(0x0205,payload:[UInt8(events.count)]+events)) != nil { return }
        for event in events where !Task.isCancelled { _ = try? await request(0x0201,payload:[event]) }
    }
    private func startPolling() {
        poll?.cancel()
        poll=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(1))
                guard !Task.isCancelled, let self, self.ready else { return }
                let queries:[(UInt16,[UInt8],Double)]=[(Command.battery,[],self.interactive ? 10 : 40),
                    (Command.noise,[1,1],self.interactive ? 5 : 40),
                    (Command.switches,FeatureCodec.switchQuery(model:self.model),self.interactive ? 12 : 60),
                    (Command.equalizer,[],self.interactive ? 20 : 90),(Command.spatial,[],self.interactive ? 20 : 90),
                    (Command.hosts,[],self.interactive ? 30 : 120),
                    (Command.priority,[],self.interactive ? 30 : 120)]
                for (command,payload,interval) in queries {
                    guard !Task.isCancelled else { return }
                    if self.canQuery(command), !(self.model?.isT500 == true && command == Command.noise),
                       Date().timeIntervalSince(self.last[command] ?? .distantPast) >= interval {
                        self.last[command]=Date()
                        _ = try? await self.request(command,payload:payload)
                    }
                }
                let cutoff=Date().addingTimeInterval(-120)
                let stale=self.state.batteries.filter { $0.value.updatedAt < cutoff }.map(\.key)
                for slot in stale { self.state.batteries.removeValue(forKey:slot) }
                if !stale.isEmpty { self.onChange?() }
            }
        }
    }
    /// Safe documented query surface for the diagnostic probe. No arbitrary raw writes.
    public func query(_ command:UInt16, payload:[UInt8]=[], timeout:Double=2.5) async throws -> OPOFrame {
        guard brandSession == nil else { throw ProtocolError.unsupported }
        guard Command.safeQueries.contains(command) else { throw ProtocolError.unsupported }
        return try await request(command,payload:payload,timeout:timeout)
    }
    private func request(_ command:UInt16, payload:[UInt8]=[], timeout:Double=2.5) async throws -> OPOFrame {
        try await gate.acquire(); defer { gate.release() }
        try Task.checkCancellation()
        let token=generation
        sequence = sequence == 0x7F ? 1 : sequence + 1
        let seq=sequence, id=UUID()
        let bytes=try OPOFrameCodec.encode(OPOFrame(command:command,sequence:seq,payload:payload))
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending=Pending(id:id,command:command | 0x8000,sequence:seq,continuation:continuation)
                deadline=Task { [weak self] in
                    try? await Task.sleep(for:.seconds(timeout)); guard !Task.isCancelled else { return }
                    self?.finish(id:id,result:.failure(ProtocolError.timeout(command)))
                }
                Task { [weak self] in
                    guard let self, self.generation == token else { return }
                    do { try await self.transport.send(bytes) }
                    catch { self.finish(id:id,result:.failure(error)) }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(id:id,result:.failure(CancellationError())) } })
    }
    private func finish(id:UUID, result:Result<OPOFrame,Error>) {
        guard let p=pending, p.id == id else { return }
        pending=nil; deadline?.cancel(); deadline=nil; p.continuation.resume(with:result)
    }
    private func receive(_ bytes:Data) {
        for frame in codec.feed(bytes) {
            onDiagnostic?(String(format:"RX %04X, %d bytes",frame.command,frame.payload.count))
            if frame.command == 0x8202, frame.payload.count >= 2, frame.payload[0] == 0 {
                let body=Array(frame.payload.dropFirst())
                state.apply(OPOFrame(command:0x0204,payload:body),t500:model?.isT500 == true,model:model)
                noteNotification(body)
                onChange?(); continue
            }
            // Response identity includes the sequence. Push notifications have no pending request.
            if frame.command & 0x8000 != 0 {
                guard let p=pending, frame.command == p.command,
                      frame.sequence == p.sequence else { continue }
                let directPriority=frame.command == Command.priority | 0x8000 && FeatureCodec.hostPriority(frame.payload) != nil
                if let status=frame.payload.first, status != 0, !directPriority {
                    finish(id:p.id,result:.failure(ProtocolError.rejected(status))); continue
                }
                state.apply(frame,t500:model?.isT500 == true,model:model)
                if frame.command == 0x8103 { model=catalog.model(productID:state.productID,name:name,override:overrideID) }
                last[frame.command & ~0x8000]=Date()
                finish(id:p.id,result:.success(frame))
            } else {
                state.apply(frame,t500:model?.isT500 == true,model:model)
                if frame.command == 0x0204 { noteNotification(frame.payload) }
            }
            onChange?()
        }
    }
    private func noteNotification(_ payload:[UInt8]) {
        guard let event=payload.first else { return }
        if let command=[UInt8(1):Command.battery,2:Command.wear,3:Command.noise][event] { last[command]=Date() }
        if event == 5 { last[Command.switches] = .distantPast }
        if event == 6 || event == 0xF2 {
            last[Command.hosts] = .distantPast
            last[Command.priority] = .distantPast
        }
    }
    public func close() {
        if let brandSession { brandSession.close();return }
        ready=false; generation=UUID(); poll?.cancel(); poll=nil; deadline?.cancel(); deadline=nil
        if let p=pending { finish(id:p.id,result:.failure(ProtocolError.disconnected)) }
        transport.onEvent=nil; transport.close(); codec.reset(); state=DeviceState(); last.removeAll(); onChange?()
    }
    @discardableResult private func write(_ command:UInt16, payload:[UInt8], read:UInt16?, readPayload:[UInt8]=[], matches:() -> Bool) async throws -> WriteOutcome {
        guard canWrite(command,reading:read) else { throw ProtocolError.unsupported }
        _ = try await request(command,payload:payload,timeout:3)
        guard let read else { return .sent }
        _ = try await request(read,payload:readPayload)
        guard matches() else { throw ProtocolError.readbackMismatch }
        return .confirmed
    }
    public func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.setNoise(mode) }
        guard let option=model?.noiseOptions.first(where:{$0.mode == mode}) else { throw ProtocolError.unsupported }
        if model?.isT500 == true {
            guard canWrite(Command.setNoise) else { throw ProtocolError.unsupported }
            let old=state.noise
            // Some T500 firmware only pushes state and does not ACK the write.
            do { _ = try await request(Command.setNoise,payload:option.payload,timeout:1) }
            catch ProtocolError.timeout(_) { }
            let deadline=Date().addingTimeInterval(2)
            while Date() < deadline, state.noise != mode { try await Task.sleep(for:.milliseconds(50)) }
            guard state.noise == mode, state.noise != nil || old != nil else { throw ProtocolError.readbackMismatch }
            return .confirmed
        }
        return try await write(Command.setNoise,payload:option.payload,read:Command.noise,readPayload:[1,1]) { state.noise == mode }
    }
    public func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.setEQ(id) }
        guard model?.presets.contains(where:{$0.id == id && $0.available(firmware:state.firmwareRevision)}) == true || state.customEQ.contains(where:{$0.id == id}) else { throw ProtocolError.unsupported }
        if model?.gameBlocksEQ == true, (state.gameSound ?? 0) > 0 { _ = try await setGameSound(0) }
        return try await write(Command.setEQ,payload:[id],read:Command.equalizer) { state.eq == id }
    }
    public func setSpatial(_ mode:UInt8) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.setSpatial(mode) }
        guard model?.spatialModes.contains(mode) == true else { throw ProtocolError.unsupported }
        if mode > 0, model?.function["spatialHiResMutex"].enabled == true {
            guard state.switches[0x18] == false else { throw ProtocolError.unsupported }
        }
        if mode > 0, model?.gameBlocksSpatial == true, (state.gameSound ?? 0) > 0 { _ = try await setGameSound(0) }
        return try await write(Command.setSpatial,payload:[mode],read:Command.spatial) { state.spatial == mode }
    }
    public func setFeature(_ feature:FeatureDefinition, enabled:Bool) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.setFeature(feature,enabled:enabled) }
        guard canSetFeature(feature) else { throw ProtocolError.unsupported }
        if feature.key == "spatialSound", enabled, model?.gameBlocksSpatial == true, (state.gameSound ?? 0) > 0 { _ = try await setGameSound(0) }
        return try await write(Command.setSwitch,payload:[feature.switchID,enabled ? 1 : 0],read:Command.switches,
            readPayload:FeatureCodec.switchQuery(model:model)) { state.switches[feature.switchID] == enabled }
    }
    public func canSetFeature(_ feature:FeatureDefinition) -> Bool {
        if let brandSession { return brandSession.canSetFeature(feature) }
        guard availableFeatures.contains(feature) || gameFeature == feature,
              state.switches[feature.switchID] != nil,
              canWrite(Command.setSwitch,reading:Command.switches) else { return false }
        return feature.key != "hearing" || (state.supportedCommands?.isSuperset(of:[0x0115,0x040D]) ?? false)
    }
    public var gameFeature: FeatureDefinition? {
        if let brandSession { return brandSession.gameFeature }
        guard model?.supportsGame == true else { return nil }
        let modern=state.switches[0x28] != nil, legacy=state.switches[6] != nil
        return modern && (model?.gameTypes.isEmpty == false || !legacy) ? FeatureDefinition("game",0x28) : legacy ? FeatureDefinition("game",6) : nil
    }
    public func setGameSound(_ type:UInt8) async throws -> WriteOutcome {
        guard brandSession == nil else { throw ProtocolError.unsupported }
        guard type == 0 || model?.gameTypes.contains(type) == true else { throw ProtocolError.unsupported }
        if type > 0, model?.gameBlocksSpatial == true {
            if state.spatial.map({$0 > 0}) == true { _ = try await setSpatial(0) }
            if state.switches[0x1B] == true { _ = try await setFeature(FeatureDefinition("spatialSound",0x1B),enabled:false) }
        }
        if type > 0, model?.gameBlocksEQ == true, state.eq.map({$0 != 0}) == true {
            _ = try await setEQ(0)
        }
        return try await write(Command.setGameSound,payload:[type,1],read:Command.gameSound) { state.gameSound == type }
    }
    public func setBass(_ value:UInt8) async throws -> WriteOutcome {
        guard brandSession == nil else { throw ProtocolError.unsupported }
        guard model?.function["bassEngineSupport"].enabled == true, let range=state.bass,
              (range.minimum...range.maximum).contains(value) else { throw ProtocolError.unsupported }
        return try await write(Command.setBass,payload:[range.minimum,range.maximum,value],read:Command.bass) { state.bass?.current == value }
    }
    public func saveEQ(_ entry:CustomEQEntry) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.saveEQ(entry) }
        guard let model, entry.frequencies == model.customEQFrequencies,
              entry.id != 0 || state.customEQ.count < model.customEQMax else { throw ProtocolError.unsupported }
        if entry.id == 0 {
            guard entry.minimum == -6, entry.maximum == 6 else { throw ProtocolError.unsupported }
        } else {
            guard let existing=state.customEQ.first(where:{$0.id == entry.id}),
                  existing.minimum == entry.minimum, existing.maximum == entry.maximum else { throw ProtocolError.unsupported }
        }
        let p=try FeatureCodec.customPayload(entry)
        return try await write(Command.setCustomEQ,payload:p,read:Command.customEQ) {
            state.customEQ.contains { $0.name == entry.name && $0.frequencies == entry.frequencies && $0.gains == entry.gains }
        }
    }
    public func canOperateHost(_ operation:FeatureCodec.HostOperation, host:RemoteHost?=nil) -> Bool {
        if let brandSession { return brandSession.canOperateHost(operation,host:host) }
        let featureType = operation == .priority || operation == .automatic ? "setPriorityDevice" : "connectDisconnectDevice"
        let read:UInt16 = (operation == .priority || operation == .automatic) ? Command.priority : Command.hosts
        guard model?.hostOperationAvailable(featureType,firmware:state.firmwareRevision) == true,
              canWrite(Command.operateHost,reading:read) else { return false }
        if operation == .automatic { return state.automaticPriority != nil }
        guard let host, let latest=state.hosts.first(where:{$0.address == host.address}) else { return false }
        switch operation {
        case .connect:return !latest.current && (latest.connection == 0 || latest.connection == 1)
        case .disconnect:return !latest.current && latest.connected
        case .priority:return latest.connected && state.automaticPriority != nil
        case .automatic:return true
        }
    }
    public func operateHost(_ operation:FeatureCodec.HostOperation, host:RemoteHost?=nil) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.operateHost(operation,host:host) }
        guard canOperateHost(operation,host:host) else { throw ProtocolError.unsupported }
        let p=try FeatureCodec.hostPayload(operation,address:host?.address ?? [])
        let read:UInt16 = (operation == .priority || operation == .automatic) ? Command.priority : Command.hosts
        let token=generation
        _ = try await request(Command.operateHost,payload:p,timeout:3)
        let deadline=Date().addingTimeInterval(3)
        // Host links can settle after ACK. Repeat reads, never the control write.
        repeat {
            try Task.checkCancellation()
            guard generation == token, ready else { throw ProtocolError.disconnected }
            let response=try await request(read,timeout:1.5)
            let valid=read == Command.hosts ? FeatureCodec.remoteHosts(response.payload) != nil : FeatureCodec.hostPriority(response.payload) != nil
            guard valid else { throw ProtocolError.invalidPayload }
            let matches:Bool
            switch operation {
            case .automatic:matches=state.automaticPriority == true
            case .priority:matches=state.automaticPriority == false && state.priorityAddress == host?.address
            case .connect:matches=state.hosts.first(where:{$0.address == host?.address})?.connected == true
            case .disconnect:matches=state.hosts.first(where:{$0.address == host?.address}).map {!$0.connected} ?? true
            }
            if matches {
                let companion=read == Command.hosts ? Command.priority : Command.hosts
                if canQuery(companion) { _ = try? await request(companion,timeout:1) }
                try Task.checkCancellation()
                guard generation == token, ready else { throw ProtocolError.disconnected }
                return .confirmed
            }
            try await Task.sleep(for:.milliseconds(250))
        } while Date() < deadline
        throw ProtocolError.readbackMismatch
    }
    public func find(_ enabled:Bool) async throws -> WriteOutcome {
        if let brandSession { return try await brandSession.find(enabled) }
        guard model?.function["findDevice"].enabled == true else { throw ProtocolError.unsupported }
        return try await write(Command.find,payload:[enabled ? 1 : 0],read:nil) { false }
    }
    public func setGesture(_ entry:GestureEntry, action:UInt8) async throws -> WriteOutcome {
        guard brandSession == nil else { throw ProtocolError.unsupported }
        let allowed=gestureActions(entry)
        guard entry.mode == 1, allowed.contains(action) else { throw ProtocolError.unsupported }
        return try await write(Command.setGestures,payload:[1,entry.side,entry.mode,entry.gesture,action],read:Command.gestures,readPayload:[2,3,1]) {
            state.gestures.contains { $0.id == entry.id && $0.action == action }
        }
    }
    public func gestureActions(_ entry:GestureEntry) -> [UInt8] {
        guard brandSession == nil else { return [] }
        guard let control=model?.function["control"].elements.first(where:{$0["action"].int == Int(entry.gesture)}),
              let mask=control["support"].int, mask > 0 else { return [] }
        return [UInt8(0),1,3,5,6,7,0x0A,0x11].filter { mask & (1 << Int($0)) != 0 }
    }
}
