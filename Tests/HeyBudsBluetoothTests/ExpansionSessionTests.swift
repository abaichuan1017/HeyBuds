import Foundation
import Testing
@testable import HeyBudsBluetooth
@testable import HeyBudsProtocol

@MainActor private final class ExpansionTransport:EarbudTransport {
    var onEvent:((TransportEvent) -> Void)?
    let label="Simulated expansion transport"
    var active=false
    var packets:[Data]=[]
    var responder:((Data) throws -> [Data])?
    var writeDelay:Duration = .zero
    var failAfterReply=false
    var busy=false
    var collided=false
    var completedWrites=0
    func open() async throws { active=true }
    func close() { active=false }
    func send(_ data:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        if busy { collided=true;throw TransportFailure.unavailable("Concurrent simulated control write") }
        busy=true;defer { busy=false }
        packets.append(data)
        for reply in try responder?(data) ?? [] { onEvent?(.data(reply)) }
        if writeDelay != .zero { try await Task.sleep(for:writeDelay) }
        if failAfterReply { throw TransportFailure.unavailable("Write failed after response") }
        completedWrites += 1
    }
}

@MainActor private func expansionWait(_ condition:() -> Bool) async throws {
    let deadline=ContinuousClock.now.advanced(by:.seconds(2))
    while !condition(),ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(1)) }
    try #require(condition(),"Simulated operation did not reach its expected checkpoint")
}

@MainActor private func expansionChannel(_ radio:ExpansionTransport,timeout:Double=0.15,ack:Bool=false) -> ControlChannel<UInt8> {
    ControlChannel(transport:radio,timeout:timeout,decode:{Array($0)},reset:{},
                   acknowledge:{ ack && $0 == 0xF0 ? Data([0xA0]) : nil })
}

@Test @MainActor func expansionChannelEarlyReplyWaitsForWriteAndSerializesNotificationACKs() async throws {
    let radio=ExpansionTransport();radio.writeDelay = .milliseconds(4)
    radio.responder={ data in data.first == 0xA0 ? [] : [Data([0xF0,data.first!])] }
    let channel=expansionChannel(radio,ack:true)
    defer { channel.close() };try await channel.open()
    async let first=channel.request(Data([1]),matching:{$0 == 1})
    async let second=channel.request(Data([2]),matching:{$0 == 2})
    let values=try await (first,second)
    #expect(values.0 == 1 && values.1 == 2)
    #expect(radio.packets.filter {$0 == Data([0xA0])}.count == 2)
    #expect(radio.completedWrites == 4 && !radio.busy && !radio.collided)
    #expect(radio.packets.count == 4)
    #expect(radio.packets[1] == Data([0xA0]) && radio.packets[3] == Data([0xA0]))
}

@Test @MainActor func expansionChannelEarlyReplyCannotHideLateWriteFailureOrStall() async throws {
    for stalled in [false,true] {
        let radio=ExpansionTransport();radio.responder={[$0]}
        radio.failAfterReply = !stalled
        if stalled { radio.writeDelay = .seconds(5) }
        let channel=expansionChannel(radio,timeout:0.04)
        defer { channel.close() };try await channel.open()
        do { _ = try await channel.request(Data([1]),matching:{$0 == 1});Issue.record("Early reply hid an incomplete/failed send") }
        catch { if stalled { #expect(error as? ProtocolError == .timeout(0)) } }
        #expect(!radio.active && radio.completedWrites == 0 && radio.packets.count == 1)
    }
}

@Test @MainActor func expansionChannelTimeoutRetiresChannelAndQueuedWork() async throws {
    let radio=ExpansionTransport()
    let current=expansionChannel(radio,timeout:0.04)
    defer { current.close() };try await current.open()
    let first=Task { try await current.request(Data([1]),matching:{$0 == 1}) }
    try await expansionWait { radio.packets.count == 1 }
    let second=Task { try await current.request(Data([2]),matching:{$0 == 2}) }
    do { _ = try await first.value;Issue.record("Missing response did not time out") }
    catch { #expect(error as? ProtocolError == .timeout(0)) }
    do { _ = try await second.value;Issue.record("Queued request reused retired channel") }
    catch { #expect(error as? ProtocolError == .disconnected) }
    #expect(!radio.active && radio.packets == [Data([1])])
}

@Test @MainActor func expansionChannelIDBasedProbeTimeoutCanContinueAfterCompletedWrite() async throws {
    let radio=ExpansionTransport()
    let current=expansionChannel(radio,timeout:0.03)
    defer { current.close() };try await current.open()
    do { _ = try await current.request(Data([1]),retireOnTimeout:false,matching:{$0 == 1});Issue.record("Missing probe reply accepted") }
    catch { #expect(error as? ProtocolError == .timeout(0)) }
    #expect(radio.active)
    radio.responder={ _ in [Data([1]),Data([2])] } // late previous call must not satisfy new matcher
    #expect(try await current.request(Data([2]),matching:{$0 == 2}) == 2)
    #expect(radio.active && !radio.collided)
}

@Test @MainActor func expansionChannelCancellationOfQueuedRequestDoesNotCancelActiveRead() async throws {
    let radio=ExpansionTransport()
    let current=expansionChannel(radio,timeout:0.5)
    defer { current.close() };try await current.open()
    let first=Task { try await current.request(Data([1]),matching:{$0 == 1}) }
    try await expansionWait { radio.packets.count == 1 }
    let queued=Task { try await current.request(Data([2]),matching:{$0 == 2}) }
    await Task.yield();queued.cancel()
    do { _ = try await queued.value;Issue.record("Cancelled queued request completed") }
    catch { #expect(error is CancellationError) }
    radio.onEvent?(.data(Data([1])))
    #expect(try await first.value == 1)
    #expect(radio.active && radio.packets == [Data([1])])
}

@Test @MainActor func expansionChannelCancelledInFlightWriteClosesBeforeNextRequest() async throws {
    let radio=ExpansionTransport();radio.responder={[$0]};radio.writeDelay = .seconds(5)
    let channel=expansionChannel(radio,timeout:1)
    defer { channel.close() };try await channel.open()
    let first=Task { try await channel.request(Data([1]),matching:{$0 == 1}) }
    try await expansionWait { radio.busy }
    let queued=Task { try await channel.request(Data([2]),matching:{$0 == 2}) }
    first.cancel()
    do { _ = try await first.value;Issue.record("Cancelled in-flight write completed") }
    catch { #expect(error is CancellationError) }
    do { _ = try await queued.value;Issue.record("Queued write passed cancelled exchange") }
    catch { #expect(error as? ProtocolError == .disconnected) }
    #expect(!radio.active && radio.packets.count == 1 && !radio.collided)
}

@Test @MainActor func expansionChannelDisconnectAndOldCallbacksCannotReviveReopenedConnection() async throws {
    let radio=ExpansionTransport()
    let current=expansionChannel(radio,timeout:0.5)
    defer { current.close() };try await current.open()
    let old=radio.onEvent
    let read=Task { try await current.request(Data([1]),matching:{$0 == 1}) }
    try await expansionWait { radio.packets.count == 1 }
    radio.onEvent?(.closed("Simulated disconnect"))
    do { _ = try await read.value;Issue.record("Disconnected read completed") }
    catch { #expect(error as? ProtocolError == .disconnected) }
    #expect(!radio.active)
    try await current.open()
    var received:[UInt8]=[];current.onMessage={received.append($0)}
    old?(.data(Data([9])));old?(.closed("Old connection"))
    #expect(radio.active && received.isEmpty)
    radio.responder={[$0]}
    #expect(try await current.request(Data([2]),matching:{$0 == 2}) == 2)
    #expect(received == [2])
}

@MainActor private final class SamsungExpansionFixture {
    let radio=ExpansionTransport()
    let profile:SamsungProfile
    var payload:[UInt8]
    var commands:[SamsungFrame]=[]
    var override:((SamsungFrame) -> [SamsungFrame]?)?
    init(_ profile:SamsungProfile = .buds2) {
        self.profile=profile
        let revision:UInt8=profile == .buds2 ? 10 : profile == .buds2Pro ? 13 : 0
        payload=Array(repeating:0,count:profile.minimumStatusLength(revision:revision))
        payload[0]=revision;payload[2]=70;payload[3]=60;payload[7]=50
        payload[9]=1;payload[10]=0x9A;payload[12]=1;payload[24]=2
        radio.responder={ [weak self] data in
            guard let self else { return [] }
            var codec=SamsungFrameCodec()
            let frame=try #require(codec.feed(data).first)
            self.commands.append(frame)
            let replies=self.override?(frame) ?? self.defaultReply(frame)
            return try replies.map(SamsungFrameCodec.encode)
        }
    }
    func defaultReply(_ frame:SamsungFrame) -> [SamsungFrame] {
        switch frame.command {
        case 0x61:return [SamsungFrame(0x61,payload)]
        case 0x78:payload[12]=frame.payload[0]
        case 0x86:payload[9]=frame.payload[0]
        case 0x83:payload[24]=frame.payload[0]
        case 0x90:
            let bits=[3,2,1,0,4,5]
            payload[10]=frame.payload[0] == 0 ? 0 : 0x80
            for (offset,value) in frame.payload.dropFirst().enumerated() { payload[10] |= value << bits[offset] }
        default:break
        }
        return []
    }
}

@Test @MainActor func expansionSamsungModelsUseDocumentedHandshakeACKAndReadback() async throws {
    for profile in SamsungProfile.allCases {
        let f=SamsungExpansionFixture(profile);f.radio.writeDelay = .milliseconds(2)
        let session=SamsungSession(transport:f.radio,name:profile.rawValue,catalog:try ModelCatalog())
        defer { session.close() };try await session.open()
        #expect(session.ready && session.model?.id == profile.modelID)
        #expect(Array(f.commands.prefix(3)) == [SamsungFrame(0x51,[0]),SamsungFrame(0x88,[1,1,0,1]),SamsungFrame(0x61)])
        #expect(f.commands.contains(SamsungFrame(0x51,[0x61,0])))
        #expect(session.state.batteries[.left]?.percent == 70)
        let baseline=f.commands.count
        #expect(try await session.setNoise(.transparency) == .confirmed)
        #expect(f.commands[baseline] == SamsungFrame(0x78,[2]))
        #expect(f.commands.dropFirst(baseline).contains(SamsungFrame(0x61)))
        #expect(try await session.setEQ(5) == .confirmed)
        #expect(session.state.noise == .transparency && session.state.eq == 5 && !f.radio.collided)
    }
}

@Test @MainActor func expansionSamsungMalformedFreshStatusCannotConfirmCachedTarget() async throws {
    let f=SamsungExpansionFixture()
    let session=SamsungSession(transport:f.radio,name:"Galaxy Buds2",catalog:try ModelCatalog(),timeout:0.08)
    defer { session.close() };try await session.open()
    #expect(session.state.noise == .anc && session.state.eq == 1)
    f.override={ frame in frame.command == 0x61 ? [SamsungFrame(0x61,[10,0,70])] : nil }
    do { _ = try await session.setNoise(.anc);Issue.record("Truncated sample confirmed already-cached ANC") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(session.state.noise == nil && !session.canWrite(Command.setNoise))
    f.override=nil;await session.refresh()
    #expect(session.state.eq == 1)
    f.override={ frame in frame.command == 0x61 ? [SamsungFrame(0x61,[10,0,70])] : nil }
    do { _ = try await session.setEQ(1);Issue.record("Truncated sample confirmed already-cached EQ") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(session.state.noise == nil && session.state.eq == nil && !session.canWrite(Command.setEQ))
}

@Test @MainActor func expansionSamsungGenericACKAndSetEchoCannotSubstituteForStatus() async throws {
    let f=SamsungExpansionFixture()
    let session=SamsungSession(transport:f.radio,name:"Galaxy Buds2",catalog:try ModelCatalog(),timeout:0.04)
    defer { session.close() };try await session.open()
    f.override={ frame in
        if frame.command == 0x78 || frame.command == 0x61 { return [SamsungFrame(0x51,[0x78,0]),SamsungFrame(0x77,[1])] }
        return nil
    }
    do { _ = try await session.setNoise(.anc);Issue.record("ACK/notification confirmed write without extended status") }
    catch { #expect(error as? ProtocolError == .timeout(0)) }
    #expect(!session.ready && !f.radio.active && session.state.observedQueries.isEmpty)
}

@Test @MainActor func expansionSamsungTouchLockUsesFreshFlagsAndANCLevelUsesFreshOffset24() async throws {
    for profile in [SamsungProfile.buds2,.buds2Pro] {
        let f=SamsungExpansionFixture(profile)
        let session=SamsungSession(transport:f.radio,name:profile.rawValue,catalog:try ModelCatalog())
        defer { session.close() };try await session.open()
        f.payload[10]=0xA5 // changed on device since last cached sample
        #expect(try await session.setTouchLocked(true) == .confirmed)
        let write=try #require(f.commands.first {$0.command == 0x90})
        #expect(write.payload == [0,0,1,0,1,0,1])
        #expect(session.state.samsungControls?.touchLocked == true)
        #expect(session.state.samsungControls?.touchFlags == 0x25)
    }
    let f=SamsungExpansionFixture(.buds4Pro)
    let session=SamsungSession(transport:f.radio,name:"Galaxy Buds4 Pro",catalog:try ModelCatalog())
    defer { session.close() };try await session.open()
    #expect(try await session.setANCLevel(4) == .confirmed)
    #expect(f.commands.contains(SamsungFrame(0x83,[4])) && session.state.samsungControls?.ancLevel == 4)
    let count=f.commands.count
    for level in [-1,5] {
        do { _ = try await session.setANCLevel(level);Issue.record("Out-of-range ANC level sent") }
        catch { #expect(error as? ProtocolError == .unsupported) }
    }
    do { _ = try await session.setTouchLocked(true);Issue.record("Deferred Buds4 touch operation sent") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(f.commands.count == count)
    f.override={ frame in frame.command == 0x61 ? [SamsungFrame(0x61,Array(f.payload.prefix(24)))] : nil }
    do { _ = try await session.setANCLevel(4);Issue.record("Missing p24 confirmed cached ANC level") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
}

@MainActor private final class GoogleExpansionFixture {
    let radio=ExpansionTransport()
    var commands:[GoogleRPCFrame]=[]
    var override:((GoogleRPCFrame) -> [GoogleRPCFrame]?)?
    var noise:UInt8=2
    var eq:[UInt8]=[0x22,3,0x82,1,0] // explicitly present flat EqBands
    var rejectedSettingRoutes:Set<UInt32>=[]
    init() {
        radio.responder={ [weak self] data in
            guard let self else { return [] }
            var codec=GoogleFrameCodec()
            let request=try #require(codec.feed(data).first)
            self.commands.append(request)
            let replies=self.override?(request) ?? self.defaultReply(request)
            return try replies.map(GoogleFrameCodec.encode)
        }
    }
    func response(_ request:GoogleRPCFrame,type:UInt32=1,status:UInt32=0,payload:[UInt8]=[]) -> GoogleRPCFrame {
        GoogleRPCFrame(type:type,channel:request.channel,method:request.method,call:request.call,status:status,payload:payload)
    }
    func defaultReply(_ request:GoogleRPCFrame) -> [GoogleRPCFrame] {
        switch request.method {
        case 0x7199FA44: // GetSoftwareInfo, nested firmware.right.version_string
            return [response(request,payload:[0x22,7,0x12,5,0x12,3,0x31,0x2E,0x30])]
        case 0xAED0AE51: // ReadSetting
            if rejectedSettingRoutes.contains(request.channel) { return [response(request,status:2)] }
            return [response(request,payload:request.payload == [0x20,13] ? [0x22,2,0x68,noise] : eq)]
        case 0x9E8C9A1D: // WriteSetting
            if let mode=GoogleMaestro.noise(request.payload) {
                noise=mode == .off ? 1 : mode == .anc ? 2 : 3
            } else if GoogleMaestro.equalizer(request.payload) != nil { eq=request.payload }
            return [response(request)]
        case 0xE61E8290: // SubscribeRuntimeInfo: one left battery report
            return [response(request,type:7,payload:[0x32,6,0x12,4,8,70,0x10,1])]
        case 0x2821ADF5:return [] // SubscribeToSettingsChanges
        default:return [response(request,status:12)]
        }
    }
}

@Test @MainActor func expansionGoogleBothModelsProbeReadOnlyAndConfirmSettingsByReadback() async throws {
    for name in ["Pixel Buds Pro","Google Pixel Buds Pro 2"] {
        let f=GoogleExpansionFixture(),catalog=try ModelCatalog()
        let session=GoogleSession(transport:f.radio,name:name,catalog:catalog)
        defer { session.close() };try await session.open()
        #expect(session.ready && session.state.firmware == "1.0")
        #expect(session.model?.id == (name.hasSuffix("2") ? "google:pixel-buds-pro-2" : "google:pixel-buds-pro"))
        #expect(f.commands.allSatisfy {[UInt32(0x7199FA44),0xAED0AE51].contains($0.method)})
        let count=f.commands.count
        #expect(try await session.setNoise(.transparency) == .confirmed)
        #expect(f.commands[count].method == 0x9E8C9A1D && f.commands[count].payload == [0x22,2,0x68,3])
        #expect(f.commands[count+1].method == 0xAED0AE51 && f.commands[count+1].payload == [0x20,13])
        #expect(try await session.setEQ(0) == .confirmed)
        #expect(session.state.eq == 0 && session.state.noise == .transparency)
    }
}

@Test @MainActor func expansionGoogleSoftwareInfoOnlyRouteDoesNotHideReadableAlternative() async throws {
    let f=GoogleExpansionFixture();f.rejectedSettingRoutes=[19]
    let session=GoogleSession(transport:f.radio,name:"Pixel Buds Pro 2",catalog:try ModelCatalog(),timeout:0.08)
    defer { session.close() }
    // PixelBudsMacOS ChannelResolver explicitly distinguishes software-info
    // responsiveness from setting access. Our safe fallback must only read.
    try await session.open()
    #expect(session.ready && session.canWrite(Command.setNoise))
    #expect(f.commands.contains {$0.channel != 19 && $0.method == 0xAED0AE51})
    #expect(f.commands.allSatisfy {[UInt32(0x7199FA44),0xAED0AE51].contains($0.method)})
}

@Test @MainActor func expansionGoogleMalformedReadbackCannotConfirmCachedNoiseOrFlatEQ() async throws {
    let f=GoogleExpansionFixture()
    let session=GoogleSession(transport:f.radio,name:"Pixel Buds Pro",catalog:try ModelCatalog())
    defer { session.close() };try await session.open()
    #expect(session.state.noise == .anc && session.state.eq == 0)
    for invalid in [[],[0x22,0],[0x22,1,0x68]] as [[UInt8]] {
        f.override=nil;await session.refresh()
        #expect(session.state.noise == .anc && session.state.eq == 0)
        f.override={ request in request.method == 0xAED0AE51 ? [f.response(request,payload:invalid)] : nil }
        do { _ = try await session.setNoise(.anc);Issue.record("Absent/malformed readback confirmed cached noise") }
        catch { #expect(error as? ProtocolError == .invalidPayload) }
        do { _ = try await session.setEQ(0);Issue.record("Absent/malformed readback confirmed cached flat EQ") }
        catch { #expect(error as? ProtocolError == .invalidPayload) }
    }
    #expect(session.state.noise == nil && session.state.eq == nil)
    #expect(!session.canWrite(Command.setNoise) && !session.canWrite(Command.setEQ))
}

@Test @MainActor func expansionGoogleWrongRPCIdentityAndNonzeroStatusCannotCompleteCall() async throws {
    let f=GoogleExpansionFixture()
    let session=GoogleSession(transport:f.radio,name:"Pixel Buds Pro",catalog:try ModelCatalog(),timeout:0.05)
    defer { session.close() };try await session.open()
    f.override={ request in
        guard request.method == 0x9E8C9A1D else { return nil }
        return [
            GoogleRPCFrame(type:1,channel:request.channel,service:1,method:request.method,call:request.call),
            GoogleRPCFrame(type:1,channel:request.channel,method:request.method,call:request.call+1),
            GoogleRPCFrame(type:1,channel:request.channel == 19 ? 21 : 19,method:request.method,call:request.call),
            GoogleRPCFrame(type:1,channel:request.channel,method:request.method+1,call:request.call),
            f.response(request,type:7),f.response(request,status:7)
        ]
    }
    let count=f.commands.count
    do { _ = try await session.setNoise(.anc);Issue.record("Wrong identity or RPC error confirmed write") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(f.commands.count == count+1) // explicit server error; no readback
    f.override={ request in request.method == 0x9E8C9A1D ? [GoogleRPCFrame(type:1,channel:request.channel,method:request.method,call:request.call+1)] : nil }
    do { _ = try await session.setNoise(.anc);Issue.record("Wrong call ID completed write") }
    catch { #expect(error as? ProtocolError == .timeout(0)) }
    #expect(!session.ready && !f.radio.active && session.state.observedQueries.isEmpty)
}

@Test @MainActor func expansionGoogleSubscriptionCallbacksAreScopedAndCloseClearsState() async throws {
    let f=GoogleExpansionFixture()
    let session=GoogleSession(transport:f.radio,name:"Pixel Buds Pro 2",catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.refresh()
    #expect(session.state.batteries[.left]?.percent == 70)
    let stream=try #require(f.commands.first {$0.method == 0x2821ADF5})
    let spoof=GoogleRPCFrame(type:7,channel:stream.channel,method:stream.method,call:stream.call+100,payload:[0x22,2,0x68,1])
    f.radio.onEvent?(.data(try GoogleFrameCodec.encode(spoof)))
    #expect(session.state.noise == .anc)
    f.radio.onEvent?(.data(try GoogleFrameCodec.encode(f.response(stream,type:7,payload:[0x22,2,0x68,3]))))
    #expect(session.state.noise == .transparency)
    let previous=f.radio.onEvent
    session.close()
    previous?(.data(try GoogleFrameCodec.encode(f.response(stream,type:7,payload:[0x22,2,0x68,1]))))
    #expect(!session.ready && session.state.batteries.isEmpty && session.state.noise == nil)
    #expect(!session.canWrite(Command.setNoise))
}
