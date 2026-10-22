// Per-brand sessions ported from OppoPodsManager (GPL-3.0-or-later).
// Command.* values below are shared UI capability keys; only BrandFrameCodec
// produces wire packets. No OPPO framing or handshake reaches another brand.
import Foundation
import HeyBudsProtocol

@MainActor final class BrandSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel
    private(set) var ready=false
    var onChange:(()->Void)?
    var onClose:((String?)->Void)?
    var onDiagnostic:((String)->Void)?
    var interactive=false
    let transport:EarbudTransport
    let family:EarbudFamily
    private let catalog:ModelCatalog
    private let name:String
    private var codec:BrandFrameCodec
    private let gate=RequestGate()
    private var generation=UUID()
    private var poll:Task<Void,Never>?
    private var deadline:Task<Void,Never>?
    private struct Pending {
        let id:UUID
        let accepts:(BrandFrame)->Bool
        let continuation:CheckedContinuation<BrandFrame,Error>
    }
    private var pending:Pending?
    private var huaweiRows:[Int:RemoteHost]=[:]
    private var huaweiExpected:Int?
    private var collectingHosts=false
    private var spatialScene:UInt8?
    private var sequence:UInt8=0x90
    private let localHostAddress:[UInt8]?
    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,family:EarbudFamily,overrideID:String?,localHostAddress:[UInt8]?=nil) {
        self.transport=transport;self.name=name;self.catalog=catalog;self.family=family;self.localHostAddress=localHostAddress
        model=catalog.model(productID:nil,name:name,override:overrideID)
            ?? catalog.models.first(where:{$0.family == family && $0.raw["familyOnly"].enabled})
            ?? .readOnly(name:name,family:family)
        if model.family != family { model = .readOnly(name:name,family:family) }
        codec=BrandFrameCodec(family:family,gaiaVersion:UInt8(model.raw["gaiaVersion"].int ?? 4))
    }
    func open() async throws {
        let token=generation
        transport.onEvent={ [weak self] event in
            guard let self,self.generation == token else { return }
            switch event { case .data(let data):self.receive(data);case .closed(let reason):self.close();self.onClose?(reason) }
        }
        try await transport.open()
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        switch family {
        case .vivo:
            let handshake=try await request(0x0300)
            guard handshake.payload.isEmpty || handshake.payload.first == 0 else { throw ProtocolError.invalidPayload }
            for c in UInt16(0x0202)...0x0206 { try await send(c) }
            try await read(Command.battery)
        case .huawei:
            guard model.raw["route"].text != nil else { throw ProtocolError.unsupported }
            if model.raw["sourceCapabilities"]["SupportsRfcommBattery"].enabled { try? await read(Command.battery) }
            if state.observedQueries.isEmpty,model.raw["sourceCapabilities"]["SupportsAncStateReadback"].enabled { try? await read(Command.noise) }
            guard !state.observedQueries.isEmpty else { throw ProtocolError.invalidPayload }
        case .edifier:
            try? await read(Command.battery)
            if state.observedQueries.isEmpty { try? await read(Command.noise) }
            guard !state.observedQueries.isEmpty else { throw ProtocolError.invalidPayload }
        case .xiaomi:
            // Preserve upstream's optional challenge probe and its documented frame layout.
            let random=(0..<16).map { _ in UInt8.random(in:0...255) }
            if let response=try? await request(2,payload:[1]+random,sequence:0x50,timeout:1.2,accepts:{$0.payload.count == 17}),
               Array(response.payload.dropFirst()) == (try XiaomiAuth.response(random)) {
                try await send(0x51,payload:[3,1],sequence:0,kind:4)
            }
            try await read(Command.battery)
        default:throw ProtocolError.unsupported
        }
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        guard !state.observedQueries.isEmpty else { throw ProtocolError.invalidPayload }
        ready=true;onChange?()
    }
    func initialize() async {
        await refresh()
        guard ready,!Task.isCancelled else { return }
        poll=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for:.seconds(self.interactive ? 15 : 45))
                guard !Task.isCancelled,self.ready else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return }
        let token=generation
        for command in [Command.battery,Command.noise,Command.equalizer,Command.spatial,Command.switches,Command.wear,Command.firmware,Command.hosts] where canQuery(command) {
            guard !Task.isCancelled,ready,generation == token else { return }
            try? await read(command)
        }
        let stale=state.batteries.filter { Date().timeIntervalSince($0.value.updatedAt) >= 120 }.map(\.key)
        for slot in stale { state.batteries[slot]=nil }
        if !stale.isEmpty { onChange?() }
    }
    var availableFeatures:[FeatureDefinition] {
        var features=model.features
        if model.function["hearingProtection"].enabled { features.append(FeatureDefinition("hearingProtection",0x70)) }
        return features
    }
    var gameFeature:FeatureDefinition? {
        (model.supportsGame || family == .xiaomi) && state.switches[6] != nil ? FeatureDefinition("game",6) : nil
    }
    var supportsSpatialAudio:Bool { !model.spatialModes.isEmpty && state.spatial != nil }
    func canQuery(_ command:UInt16) -> Bool {
        switch command {
        case Command.battery:return family != .huawei || model.raw["sourceCapabilities"]["SupportsRfcommBattery"].enabled
        case Command.noise:return !model.noiseOptions.isEmpty && (family != .huawei || model.raw["sourceCapabilities"]["SupportsAncStateReadback"].enabled)
        case Command.equalizer:return !model.presets.isEmpty || !model.customEQFrequencies.isEmpty
        case Command.customEQ:return !model.customEQFrequencies.isEmpty
        case Command.spatial:return !model.spatialModes.isEmpty
        case Command.switches:return !availableFeatures.isEmpty || model.supportsGame || family == .xiaomi
        case Command.hosts:return model.hasMultiDevice
        case Command.wear,Command.firmware:return family == .vivo
        default:return false
        }
    }
    func canWrite(_ command:UInt16,reading:UInt16?) -> Bool {
        guard ready else { return false }
        switch command {
        case Command.setNoise:return !model.noiseOptions.isEmpty && (state.noise != nil || (family == .huawei && model.raw["route"].text == "FreeBuds3"))
        case Command.setEQ:return (!model.presets.isEmpty || !state.customEQ.isEmpty) && state.eq != nil
        case Command.setSpatial:return supportsSpatialAudio
        case Command.setSwitch:return availableFeatures.contains(where:canSetFeature) || gameFeature != nil
        case Command.setCustomEQ:return !model.customEQFrequencies.isEmpty && state.observedQueries.contains(Command.customEQ)
        case Command.operateHost:return model.hasMultiDevice && state.observedQueries.contains(Command.hosts)
        case Command.find:return family == .vivo && model.function["findDevice"].enabled
        default:return false
        }
    }
    func canSetFeature(_ feature:FeatureDefinition) -> Bool {
        guard ready,state.switches[feature.switchID] != nil else { return false }
        if feature.key == "game" { return gameFeature == feature }
        // vivo has no confirmed readable dual-enable state. Do not claim a switch value from a host list.
        if family == .vivo,feature.key == "dual" { return false }
        return availableFeatures.contains(feature)
    }
    private func read(_ command:UInt16) async throws {
        switch family {
        case .vivo:
            switch command {
            case Command.battery:_ = try await readRequest(0x0207)
            case Command.noise:_ = try await readRequest(0x0230,payload:model.raw["gaiaVersion"].int == 3 ? [] : [0])
            case Command.equalizer:_ = try await readRequest(0x0218)
            case Command.spatial:_ = try await readRequest(0x0239)
            case Command.wear:_ = try await readRequest(0x020D)
            case Command.firmware:_ = try await readRequest(0x021C)
            case Command.hosts:_ = try await readRequest(0x0249)
            case Command.switches:
                if model.function["wearDetection"].enabled { _ = try? await readRequest(0x0203) }
                if model.supportsGame { _ = try? await readRequest(0x0251) }
                if model.function["hearingProtection"].enabled { _ = try? await readRequest(0x0252) }
            default:throw ProtocolError.unsupported
            }
        case .huawei:
            switch command {
            case Command.battery:_ = try await readRequest(0x0108,payload:[1,0,2,0,3,0])
            case Command.noise:_ = try await readRequest(0x2B2A,payload:[1,0])
            case Command.equalizer,Command.customEQ:_ = try await readRequest(0x2B4A,payload:(UInt8(1)...8).flatMap { [$0,0] })
            case Command.switches:
                if model.function["wearDetection"].enabled { _ = try? await readRequest(0x2B11,payload:[1,0]) }
                if model.supportsGame { _ = try? await readRequest(0x2B6C,payload:[2,0]) }
                if model.hasMultiDevice { _ = try? await readRequest(0x2B2F,payload:[1,0]) }
            case Command.hosts:try await collectHuaweiHosts()
            default:throw ProtocolError.unsupported
            }
        case .edifier:_ = try await readRequest(command == Command.battery ? 0xD0 : 0xCC)
        case .xiaomi:
            if command == Command.battery { _ = try await readRequest(2,payload:[255,255,255,255],sequence:0x0B,accepts:{$0.sequence == 0x0B && $0.payload.starts(with:[2,2,4,7])}) }
            else if command == Command.switches {
                let seq=nextSequence()
                _ = try await readRequest(0xF3,payload:[2,0,47],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq && $0.payload.starts(with:[3,0,47])})
            } else { throw ProtocolError.unsupported }
        default:throw ProtocolError.unsupported
        }
    }
    private func readRequest(_ command:UInt16,payload:[UInt8]=[],sequence:UInt8=0,accepts:((BrandFrame)->Bool)?=nil) async throws -> BrandFrame {
        let frame=try await request(command,payload:payload,sequence:sequence,accepts:accepts)
        var sample=DeviceState()
        guard BrandState.apply(frame,model:model,to:&sample) else { throw ProtocolError.invalidPayload }
        return frame
    }
    private func nextSequence() -> UInt8 { let s=sequence;sequence=sequence == 255 ? 0x90 : sequence+1;return s }
    private func request(_ command:UInt16,payload:[UInt8]=[],sequence:UInt8=0,timeout:Double=2,accepts:((BrandFrame)->Bool)?=nil) async throws -> BrandFrame {
        try await gate.acquire();defer { gate.release() }
        try Task.checkCancellation()
        let id=UUID(),token=generation
        let bytes=try codec.encode(BrandFrame(command,payload,sequence:sequence))
        let expected=family == .vivo ? command | 0x8000 : command
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                pending=Pending(id:id,accepts:accepts ?? { $0.command == expected },continuation:continuation)
                deadline=Task { [weak self] in
                    try? await Task.sleep(for:.seconds(timeout));guard !Task.isCancelled else { return }
                    self?.finish(id,.failure(ProtocolError.timeout(command)))
                }
                Task { [weak self] in
                    guard let self,self.generation == token else { return }
                    do { try await self.transport.send(bytes) } catch { self.finish(id,.failure(error)) }
                }
            }
        },onCancel:{Task { @MainActor [weak self] in self?.finish(id,.failure(CancellationError())) }})
    }
    private func send(_ command:UInt16,payload:[UInt8]=[],sequence:UInt8=0,kind:UInt8=0xC4) async throws {
        try await gate.acquire();defer { gate.release() };try Task.checkCancellation()
        try await transport.send(try codec.encode(BrandFrame(command,payload,sequence:sequence,kind:kind)))
    }
    private func finish(_ id:UUID,_ result:Result<BrandFrame,Error>) {
        guard let p=pending,p.id == id else { return };pending=nil;deadline?.cancel();deadline=nil;p.continuation.resume(with:result)
    }
    private func receive(_ data:Data) {
        for frame in codec.feed(data) {
            onDiagnostic?(String(format:"%@ RX %04X, %d bytes",family.rawValue,frame.command,frame.payload.count))
            if family == .huawei,frame.command == 0x2B31,collectingHosts,let row=BrandState.huaweiHost(frame.payload) {
                huaweiExpected=row.count
                if let host=row.host { huaweiRows[row.index]=host }
            } else {
                if family == .vivo,frame.command == 0x8239,frame.payload.count >= 3 { spatialScene=frame.payload[2] }
                _ = BrandState.apply(frame,model:model,to:&state)
                if family == .vivo,frame.command == 0x8249 {
                    state.hosts=state.hosts.map { host in var value=host;if value.address == localHostAddress { value.flags |= 1 };return value }
                }
            }
            if let p=pending,p.accepts(frame) {
                if family == .vivo,let status=frame.payload.first,status != 0 { finish(p.id,.failure(ProtocolError.rejected(status))) }
                else { finish(p.id,.success(frame)) }
            }
            if family == .vivo,frame.command == 0x8509 {
                let c=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from:Date())
                let year=c.year ?? 0
                let payload=[year/100,year%100,c.month ?? 1,c.day ?? 1,c.hour ?? 0,c.minute ?? 0,c.second ?? 0].map { UInt8(clamping:$0) }
                Task { [weak self] in try? await self?.send(0x0509,payload:payload) }
            }
            onChange?()
        }
    }
    private func collectHuaweiHosts() async throws {
        try await gate.acquire();defer { gate.release() }
        try Task.checkCancellation()
        huaweiRows=[:];huaweiExpected=nil;collectingHosts=true
        defer { collectingHosts=false }
        let token=generation
        try await transport.send(try codec.encode(BrandFrame(0x2B31,[1,0])))
        let until=Date().addingTimeInterval(2)
        while Date() < until {
            try Task.checkCancellation();guard generation == token else { throw ProtocolError.disconnected }
            if let count=huaweiExpected,huaweiRows.count == count {
                let hosts=huaweiRows.sorted { $0.key < $1.key }.map(\.value)
                guard Set(hosts.map(\.id)).count == hosts.count else { throw ProtocolError.invalidPayload }
                state.hosts=hosts.map { host in var value=host;if value.address == localHostAddress { value.flags |= 1 };return value };state.priorityAddress=hosts.first(where:{$0.preferred})?.address
                // Huawei does not report an automatic-priority switch.
                state.observedQueries.insert(Command.hosts);onChange?();return
            }
            try await Task.sleep(for:.milliseconds(30))
        }
        throw ProtocolError.timeout(0x2B31)
    }
    private func confirmedWrite(command:UInt16,payload:[UInt8],read:UInt16,matches:()->Bool) async throws -> WriteOutcome {
        let token=generation
        // These brand SET ACKs are not proof of applied state. Always query after sending.
        try await send(command,payload:payload)
        try await Task.sleep(for:.milliseconds(family == .vivo && command == 0x0130 ? 2600 : 250))
        let until=Date().addingTimeInterval(3)
        repeat {
            try Task.checkCancellation();guard ready,generation == token else { throw ProtocolError.disconnected }
            if read == Command.switches && family != .xiaomi {
                let query:UInt16
                switch command {
                case 0x0103:query=0x0203
                case 0x0151:query=0x0251
                case 0x0152:query=0x0252
                case 0x2B10:query=0x2B11
                case 0x2B6C:query=0x2B6C
                case 0x2B2E:query=0x2B2F
                default:throw ProtocolError.unsupported
                }
                _ = try await readRequest(query,payload:family == .huawei ? [query == 0x2B6C ? 2 : 1,0] : [])
            } else { try await self.read(read) }
            if matches() { return .confirmed }
            try await Task.sleep(for:.milliseconds(250))
        } while Date() < until
        throw ProtocolError.readbackMismatch
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise,reading:Command.noise),let option=model.noiseOptions.first(where:{$0.mode == mode}) else { throw ProtocolError.unsupported }
        switch family {
        case .vivo:return try await confirmedWrite(command:0x0130,payload:option.writeBytes+model.raw["noiseSuffix"].elements.compactMap { $0.int.flatMap(UInt8.init(exactly:)) },read:Command.noise) { state.noise == mode }
        case .huawei:
            if model.raw["route"].text == "FreeBuds3" { try await send(0x2B04,payload:[1,1,mode == .off ? 0 : 1]);return .sent }
            return try await confirmedWrite(command:0x2B04,payload:[1,2]+option.writeBytes,read:Command.noise) { state.noise == mode || (mode == .anc && state.noise?.group == .anc) }
        case .edifier:return try await confirmedWrite(command:0xC1,payload:option.writeBytes,read:Command.noise) { state.noise == mode }
        default:throw ProtocolError.unsupported
        }
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setEQ,reading:Command.equalizer),model.presets.contains(where:{$0.id == id}) || state.customEQ.contains(where:{$0.id == id}) else { throw ProtocolError.unsupported }
        return try await confirmedWrite(command:family == .vivo ? 0x0118 : 0x2B49,payload:family == .vivo ? [id] : [1,1,id],read:Command.equalizer) { state.eq == id }
    }
    func setSpatial(_ value:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setSpatial,reading:Command.spatial),model.spatialModes.contains(value),family == .vivo else { throw ProtocolError.unsupported }
        return try await confirmedWrite(command:0x0139,payload:[value]+(spatialScene.map { [$0] } ?? []),read:Command.spatial) { state.spatial == value }
    }
    func setFeature(_ feature:FeatureDefinition,enabled:Bool) async throws -> WriteOutcome {
        guard canSetFeature(feature) else { throw ProtocolError.unsupported }
        if family == .xiaomi {
            let seq=nextSequence();try await send(0xF2,payload:[3,0,47,enabled ? 1 : 0],sequence:seq)
            try await read(Command.switches)
            guard state.switches[6] == enabled else { throw ProtocolError.readbackMismatch };return .confirmed
        }
        let command:UInt16
        switch (family,feature.key) {
        case (.vivo,"wear"):command=0x0103
        case (.vivo,"game"):command=0x0151
        case (.vivo,"hearingProtection"):command=0x0152
        case (.huawei,"wear"):command=0x2B10
        case (.huawei,"game"):command=0x2B6C
        case (.huawei,"dual"):command=0x2B2E
        default:throw ProtocolError.unsupported
        }
        return try await confirmedWrite(command:command,payload:(family == .huawei ? [1,1] : [])+[enabled ? 1 : 0],read:Command.switches) { state.switches[feature.switchID] == enabled }
    }
    func saveEQ(_ entry:CustomEQEntry) async throws -> WriteOutcome {
        guard family == .huawei,canWrite(Command.setCustomEQ,reading:Command.customEQ),entry.frequencies == model.customEQFrequencies,entry.gains.count == 10,entry.gains.allSatisfy({(-60...60).contains($0)}),FeatureCodec.validEQName(entry.name),entry.name.utf8.count <= 32 else { throw ProtocolError.unsupported }
        let id:UInt8
        if entry.id == 0 { guard let free=(UInt8(0x64)...0x66).first(where:{id in !state.customEQ.contains(where:{$0.id == id})}) else { throw ProtocolError.unsupported };id=free }
        else { guard (0x64...0x66).contains(entry.id) else { throw ProtocolError.unsupported };id=entry.id }
        let name=Array(entry.name.utf8),route=model.raw["route"].text ?? ""
        let op:UInt8=["FreeBuds6I","FreeBudsPro5","FreeArc"].contains(route) ? 1 : 0
        let payload=[1,1,id,2,1,10,5,1,op,3,10]+entry.gains.map { UInt8(bitPattern:$0) }+[4,UInt8(name.count)]+name
        return try await confirmedWrite(command:0x2B49,payload:payload,read:Command.customEQ) { state.customEQ.contains { $0.id == id && $0.name == entry.name && $0.gains == entry.gains } }
    }
    func canOperateHost(_ operation:FeatureCodec.HostOperation,host:RemoteHost?) -> Bool {
        guard canWrite(Command.operateHost,reading:Command.hosts),operation != .automatic,let host,let latest=state.hosts.first(where:{$0.id == host.id}),!latest.current,let local=localHostAddress,latest.address != local else { return false }
        if operation == .connect { return !latest.connected }
        if operation == .disconnect { return latest.connected }
        return operation == .priority && family == .huawei && latest.connected
    }
    func operateHost(_ operation:FeatureCodec.HostOperation,host:RemoteHost?) async throws -> WriteOutcome {
        guard canOperateHost(operation,host:host),let host else { throw ProtocolError.unsupported }
        let command:UInt16,payload:[UInt8]
        if family == .vivo {
            command=0x014A;payload=state.hosts.flatMap { Array($0.address.reversed())+[$0.id == host.id ? (operation == .disconnect ? UInt8(0) : 2) : $0.connection] }
        } else if family == .huawei {
            command=operation == .priority ? 0x2B32 : 0x2B33
            payload=[operation == .priority || operation == .connect ? 1 : 2,6]+host.address
        } else { throw ProtocolError.unsupported }
        return try await confirmedWrite(command:command,payload:payload,read:Command.hosts) {
            if operation == .priority { return state.priorityAddress == host.address }
            let connected=state.hosts.first(where:{$0.id == host.id})?.connected ?? false
            return operation == .connect ? connected : !connected
        }
    }
    func find(_ enabled:Bool) async throws -> WriteOutcome {
        guard canWrite(Command.find,reading:nil) else { throw ProtocolError.unsupported }
        try await send(0x0120,payload:[enabled ? 1 : 0]);return .sent
    }
    func setModelOverride(_ id:String?) {
        guard let new=catalog.model(productID:state.productID,name:name,override:id),new.family == family else { return }
        model=new;codec=BrandFrameCodec(family:family,gaiaVersion:UInt8(model.raw["gaiaVersion"].int ?? 4));onChange?()
    }
    func close() {
        generation=UUID();ready=false;poll?.cancel();poll=nil;deadline?.cancel();deadline=nil
        if let p=pending { finish(p.id,.failure(ProtocolError.disconnected)) }
        collectingHosts=false;codec=BrandFrameCodec(family:family,gaiaVersion:UInt8(model.raw["gaiaVersion"].int ?? 4));transport.onEvent=nil;transport.close();state=DeviceState();onChange?()
    }
}
