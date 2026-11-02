import Foundation
import HeyBudsProtocol

@MainActor final class SennheiserSession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let profile:SennheiserProfile?
    private let channel:ControlChannel<SennheiserFrame>
    private let operations=RequestGate()
    private var active=false,generation=UUID()
    private var poll:Task<Void,Never>?
    private var gains:[UInt8]=[],frequencies:[UInt16]=[]
    private var gainRange:ClosedRange<Int>?,soundMode:UInt8?
    private var maximumConnections:Int?
    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,timeout:Double=3) {
        profile=SennheiserProfile.named(name);model=profile.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        var codec=SennheiserFrameCodec()
        channel=ControlChannel(transport:transport,timeout:timeout,decode:{ codec.feed($0) },reset:{ codec.reset() })
        channel.onClose={ [weak self] reason in self?.close();self?.onClose?(reason) }
    }
    private func check(_ token:UUID) throws { try Task.checkCancellation();guard active,generation == token else { throw ProtocolError.disconnected } }
    private func request(_ command:UInt16,_ payload:[UInt8]=[]) async throws -> [UInt8] {
        let token=generation;try check(token)
        let result=try await channel.request(SennheiserFrameCodec.encode(SennheiserFrame(command,payload)),matching:{
            $0.vendor == 0x0495 && ($0.command == command | 0x0100 || $0.command == command | 0x0180)
        })
        try check(token)
        if result.command & 0x0180 == 0x0180 { throw ProtocolError.rejected(result.payload.first ?? 255) }
        return result.payload
    }
    private func optional(_ command:UInt16,_ payload:[UInt8]=[]) async throws -> [UInt8]? {
        do { return try await request(command,payload) } catch ProtocolError.rejected { return nil }
    }
    func open() async throws {
        guard let profile,model != nil,!active else { throw ProtocolError.unsupported };let token=generation;active=true
        do {
            try await channel.open()
            guard profile.matchesIdentity(try await request(0x1206)),let firmware=SennheiserProfile.firmware(try await request(0x1201)) else { throw ProtocolError.unsupported }
            state.productID=profile.modelID;state.firmware=firmware;state.observedQueries.insert(Command.firmware)
            try await readBattery();try await readNoise()
            if let p=try await optional(0x0401),let wear=SennheiserProfile.boolean(p) { state.switches[4]=wear;state.observedQueries.insert(Command.switches) }
            try await readEQConfiguration();try await readPeers()
            try check(token);ready=true;onChange?()
        } catch { if generation == token { close() };throw error }
    }
    private func readBattery() async throws {
        let p=try await request(0x0603)
        guard let level=p.first,level <= 100 else { state.batteries=[:];throw ProtocolError.invalidPayload }
        let charge=try await optional(0x0602)
        let charging=charge.map { (1...2).contains($0.count) && $0.allSatisfy({ $0 <= 2 }) && $0[0] == 1 } ?? false
        state.batteries=[.left:BatteryReading(percent:Int(level),charging:charging)];state.observedQueries.insert(Command.battery)
    }
    private func readNoise() async throws {
        guard let anc=SennheiserProfile.boolean(try await request(0x1A05)),let ambient=SennheiserProfile.boolean(try await request(0x1805)) else { state.noise=nil;throw ProtocolError.invalidPayload }
        state.noise=anc ? (ambient ? .transparency : .anc) : .off;state.observedQueries.insert(Command.noise)
    }
    private func readSoundMode() async throws {
        let p=try await request(0x0804)
        guard p.count == 2,p[0] == 0,p[1] <= 3 else { soundMode=nil;state.eq=nil;throw ProtocolError.invalidPayload }
        soundMode=p[1];state.eq=p[1] <= 2 ? p[1] : nil;state.observedQueries.insert(Command.equalizer)
    }
    private func readEQConfiguration() async throws {
        try await readSoundMode()
        guard let p=try await optional(0x1000),p.count >= 3,(1...16).contains(p[0]) else { return }
        let low=Int(Int8(bitPattern:p[1])),high=Int(Int8(bitPattern:p[2]))
        guard low < high else { return }
        var hz:[UInt16]=[]
        for band in 0..<p[0] {
            let f=try await request(0x100B,[band]);guard f.count == 3,f[0] == band else { throw ProtocolError.invalidPayload }
            let value=UInt16(f[1]) << 8 | UInt16(f[2]);guard value > 0,value <= 24000 else { throw ProtocolError.invalidPayload };hz.append(value)
        }
        gainRange=low...high;frequencies=hz;try await readGains()
    }
    private func readGains() async throws {
        guard let range=gainRange,!frequencies.isEmpty else { return }
        let p=try await request(0x1003,[0])
        guard p.count == frequencies.count,p.allSatisfy({ range.contains(Int(Int8(bitPattern:$0))) }) else { state.customEQ=[];throw ProtocolError.invalidPayload }
        gains=p
        state.customEQ=[CustomEQEntry(id:254,name:"Custom",selected:soundMode == 1,minimum:Int8(clamping:max(-6,Int(ceil(Double(range.lowerBound)/10)))),maximum:Int8(clamping:min(6,Int(floor(Double(range.upperBound)/10)))),frequencies:frequencies,gains:p.map { Int8((Double(Int8(bitPattern:$0))/10).rounded()) })]
        if soundMode == 1 { state.eq=254 }
        state.observedQueries.insert(Command.customEQ)
    }
    private func readPeers() async throws {
        maximumConnections=nil
        guard let p=try await optional(0x1400),p.count == 2 else {
            state.hosts=[];state.observedQueries.remove(Command.hosts);return
        }
        let count=Int(p[0]) << 8 | Int(p[1]);guard count <= 64 else { throw ProtocolError.invalidPayload }
        let own=try await request(0x1407);guard own.count == 1 else { throw ProtocolError.invalidPayload }
        var peers:[RemoteHost]=[]
        for i in 0..<count {
            guard let peer=SennheiserProfile.peer(try await request(0x1401,[UInt8(i)]),index:UInt8(i),current:own[0]) else { throw ProtocolError.invalidPayload };peers.append(peer)
        }
        if profile == .momentum4,let limit=try await optional(0x1409),limit.count == 1,(1...64).contains(limit[0]) {
            maximumConnections=Int(limit[0])
        }
        state.hosts=peers;state.observedQueries.insert(Command.hosts)
    }
    func initialize() async {
        guard ready else { return };let token=generation;poll?.cancel()
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 10 : 30)) } catch { return }
                guard let self,self.ready,self.generation == token else { return };await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return };let token=generation
        do {
            try await operations.acquire();defer { operations.release() };try check(token)
            try await readBattery();try await readNoise();try await readSoundMode();try await readGains()
            if state.switches[4] != nil { state.switches[4]=SennheiserProfile.boolean(try await request(0x0401)) }
            try await readPeers();try check(token);onChange?()
        } catch { if generation == token { close();onClose?(error.localizedDescription) } }
    }
    var availableFeatures:[FeatureDefinition] { [FeatureDefinition("wear",4)] }
    func canQuery(_ command:UInt16) -> Bool { profile != nil && [Command.battery,Command.noise,Command.equalizer,Command.customEQ,Command.switches,Command.hosts,Command.firmware].contains(command) }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool {
        guard ready,profile?.allowsWrite(firmware:state.firmware) == true else { return false }
        let target:UInt16
        switch command {
        case Command.setNoise:target=Command.noise
        case Command.setSwitch:target=Command.switches
        case Command.setEQ:guard soundMode != 3 else { return false };target=Command.equalizer
        case Command.setCustomEQ:
            // Upstream EqualizerMinimum plus a successfully decoded live configuration.
            guard soundMode == 1,let v=state.firmware.flatMap(SennheiserProfile.version),!v.lexicographicallyPrecedes([2,12,0]) else { return false };target=Command.customEQ
        default:return false
        }
        return (reading == nil || reading == target) && state.observedQueries.contains(target)
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise),[NoiseMode.off,.anc,.transparency].contains(mode) else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        if mode == .off { _ = try await request(0x1A04,[0]) }
        else { _ = try await request(0x1A04,[1]);_ = try await request(0x1804,[mode == .transparency ? 1 : 0]) }
        for attempt in 0..<5 {
            try await readNoise();try check(token);onChange?();if state.noise == mode { return .confirmed }
            if attempt < 4 { try await Task.sleep(for:.milliseconds(200)) }
        }
        throw ProtocolError.readbackMismatch
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        let id:UInt8=id == 254 ? 1 : id
        guard canWrite(Command.setEQ),id <= 2 else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        try await readSoundMode();guard soundMode != 3 else { throw ProtocolError.unsupported }
        _ = try await request(0x0803,[0,id]);try await readSoundMode();try await readGains();try check(token);onChange?()
        guard soundMode == id else { throw ProtocolError.readbackMismatch };return .confirmed
    }
    func saveEQ(_ entry:CustomEQEntry) async throws -> WriteOutcome {
        guard canWrite(Command.setCustomEQ),[UInt8(0),254].contains(entry.id),entry.frequencies == frequencies,entry.gains.count == frequencies.count,let range=gainRange,entry.gains.allSatisfy({ (-6...6).contains($0) && range.contains(Int($0)*10) }) else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        try await readSoundMode();guard soundMode == 1 else { throw ProtocolError.unsupported }
        let target=entry.gains.map { UInt8(bitPattern:Int8(Int($0)*10)) }
        for (i,gain) in target.enumerated() { _ = try await request(0x1001,[UInt8(i),gain]);try check(token) }
        try await readSoundMode();try await readGains();try check(token);onChange?()
        guard gains == target,soundMode == 1 else { throw ProtocolError.readbackMismatch };return .confirmed
    }
    func setFeature(_ feature:FeatureDefinition,enabled:Bool) async throws -> WriteOutcome {
        guard availableFeatures.contains(feature),canWrite(Command.setSwitch),state.switches[4] != nil else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        _ = try await request(0x0400,[enabled ? 1 : 0]);let value=SennheiserProfile.boolean(try await request(0x0401));try check(token)
        state.switches[4]=value;onChange?();guard value == enabled else { throw ProtocolError.readbackMismatch };return .confirmed
    }
    func canOperateHost(_ operation:FeatureCodec.HostOperation,host:RemoteHost?) -> Bool {
        guard ready,profile == .momentum4,profile?.allowsWrite(firmware:state.firmware) == true,operation == .connect,
              let host,host.protocolIndex != nil,!host.current,!host.connected,let maximumConnections,
              state.hosts.contains(where:{ $0.current && $0.connected }),
              state.hosts.filter({ $0.connected }).count < maximumConnections else { return false }
        return state.hosts.contains { $0.id == host.id && !$0.current && !$0.connected }
    }
    func hostAction(_ operation:FeatureCodec.HostOperation,host:RemoteHost?) async throws -> WriteOutcome {
        guard canOperateHost(operation,host:host),let host,let index=host.protocolIndex else { throw ProtocolError.unsupported }
        let token=generation;try await operations.acquire();defer { operations.release() };try check(token)
        try await readPeers();guard canOperateHost(operation,host:host),state.hosts.first(where:{ $0.id == host.id })?.name == host.name else { throw ProtocolError.unsupported }
        guard let current=state.hosts.first(where:{ $0.current && $0.connected }) else { throw ProtocolError.unsupported }
        _ = try await request(0x1402,[index]) // Never disconnect/unpair (0x1403), or retry the connection write.
        for attempt in 0..<20 {
            let p=try await request(0x1404,[index]);try check(token)
            guard p.count == 2,p[0] == index,p[1] <= 1 else { throw ProtocolError.invalidPayload }
            if p[1] == 1 {
                try await readPeers();try check(token);onChange?()
                guard state.hosts.contains(where:{ $0.id == host.id && $0.name == host.name && $0.connected }),
                      state.hosts.contains(where:{ $0.id == current.id && $0.name == current.name && $0.current && $0.connected }) else { throw ProtocolError.readbackMismatch }
                return .confirmed
            }
            if attempt < 19 { try await Task.sleep(for:.milliseconds(200)) }
        }
        try await readPeers();try check(token);onChange?();throw ProtocolError.readbackMismatch
    }
    func close() { active=false;ready=false;generation=UUID();poll?.cancel();poll=nil;channel.close();state=DeviceState();gains=[];frequencies=[];gainRange=nil;soundMode=nil;maximumConnections=nil;onChange?() }
}
