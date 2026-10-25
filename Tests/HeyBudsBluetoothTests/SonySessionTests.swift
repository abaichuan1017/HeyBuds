import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor final class SonyRadio:EarbudTransport {
    var onEvent:((TransportEvent) -> Void)?
    var label:String { "Simulated Sony RFCOMM" }
    var active=false
    var name="WH-1000XM5"
    var handshake:[UInt8]=[1,0,3,0,0x30,0x18,0,0]
    var functions:[UInt8]=[0x20,0x6B]
    var noise:[UInt8]=[0x67,0x17,1,1,0,0,20]
    var commandFrames:[SonyFrame]=[]
    var hostACKs:[SonyFrame]=[]
    var ackFirst=true
    var acknowledge=true
    var duplicateReplies=false
    var writeDelay:Duration = .zero
    var failAfterReply=false
    var handler:((SonyFrame) -> [UInt8]?)?
    var beforeReply:((SonyFrame) -> Void)?
    var busy=false
    var collided=false
    var sequence:UInt8=0
    func open() async throws { active=true }
    func close() { active=false }
    func emit(_ payload:[UInt8],duplicate:Bool=false) {
        let frame=SonyFrame(sequence:sequence,payload:payload);sequence ^= 1
        let data=try! SonyFrameCodec.encode(frame)
        onEvent?(.data(data));if duplicate { onEvent?(.data(data)) }
    }
    func send(_ bytes:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        if busy { collided=true;throw TransportFailure.unavailable("Concurrent simulated write") }
        busy=true;defer { busy=false }
        var codec=SonyFrameCodec()
        let frame=try #require(codec.feed(bytes).first)
        if frame.type == 1 { hostACKs.append(frame);return }
        commandFrames.append(frame);beforeReply?(frame)
        let response=handler.map { $0(frame) } ?? defaultReply(frame.payload)
        func ack() { if acknowledge { onEvent?(.data(try! SonyFrameCodec.encode(SonyFrame(type:1,sequence:frame.sequence ^ 1)))) } }
        if ackFirst { ack() }
        if let response { emit(response,duplicate:duplicateReplies) }
        if !ackFirst { ack() }
        if writeDelay != .zero { try await Task.sleep(for:writeDelay) }
        if failAfterReply { throw TransportFailure.unavailable("Simulated write completion failure") }
    }
    func defaultReply(_ p:[UInt8]) -> [UInt8]? {
        switch p[0] {
        case 0:return handshake
        case 4:
            let text=Array((p[1] == 1 ? name : "1.0.0").utf8)
            return [5,p[1],UInt8(text.count)]+text
        case 6:return [7,0,UInt8(functions.count)]+functions.flatMap { [$0,0xFF] }
        case 0x22:
            switch p[1] { case 0:return [0x23,0,81,0];case 8:return [0x23,8,81,0,20];case 9:return [0x23,9,70,0,65,1,20,20];case 10:return [0x23,10,0xFF,0xFF,20];default:return nil }
        case 0x66:return noise
        case 0x68:noise=[0x67]+p.dropFirst();return nil
        default:return nil
        }
    }
}

@Test @MainActor func sonyAllThreeModelsUseIndependentV2HandshakeAndBatteryShape() async throws {
    for name in SonyProtocol.modelNames {
        let radio=SonyRadio();radio.name=name
        radio.functions=name.hasPrefix("WF-") ? [0x29,0x2A,0x6B] : [0x28,0x6B]
        let s=DeviceSession(transport:radio,name:"Renamed headphones",catalog:try ModelCatalog(),family:.sony)
        defer { s.close() };try await s.open();await s.initialize()
        #expect(s.ready && s.model?.name == name)
        #expect(s.state.firmware == "1.0.0" && s.state.noise == .anc)
        #expect(radio.commandFrames.prefix(4).map(\.payload) == [[0,0],[4,1],[4,2],[6,0]])
        let queries=radio.commandFrames.filter { $0.payload.first == 0x22 }.map { $0.payload[1] }
        #expect(queries == (name.hasPrefix("WF-") ? [9,10] : [8]))
        #expect(s.state.batteries[.enclosure] == nil)
        #expect((s.state.batteries[.right] != nil) == name.hasPrefix("WF-"))
        #expect(try await s.setNoise(.transparency) == .confirmed)
        #expect(try await s.setSonyAmbient(level:7,focusOnVoice:true) == .confirmed)
        #expect(s.state.sonyNoise?.ambientLevel == 7 && s.state.sonyNoise?.focusOnVoice == true)
        #expect(!s.canWrite(Command.setEQ) && !s.supportsSpatialAudio && s.availableFeatures.isEmpty)
        do { _ = try await s.query(Command.battery);Issue.record("OPO query reached Sony") }
        catch { #expect(error as? ProtocolError == .unsupported) }
        #expect(!radio.collided)
    }
}

@Test @MainActor func sonyV1MalformedHandshakeAndUnknownIdentityNeverReachFeatureCommands() async throws {
    for scenario in 0..<3 {
        let radio=SonyRadio()
        if scenario == 0 { radio.handshake=[1,0,0,1] }
        if scenario == 1 { radio.handshake=[1,0,3,0,0,1,1,0] }
        if scenario == 2 { radio.name="WH-1000XM4" }
        let s=SonySession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog())
        do { try await s.open();Issue.record("Unsupported protocol or identity accepted") }
        catch { #expect(error as? ProtocolError == .unsupported) }
        #expect(!radio.active && !s.ready)
        #expect(!radio.commandFrames.contains { $0.payload.first == 0x22 || $0.payload.first == 0x68 })
    }
}

@Test @MainActor func sonyWaitsForACKResponseAndWriteCompletionInEitherOrder() async throws {
    for ackFirst in [true,false] {
        let radio=SonyRadio();radio.ackFirst=ackFirst;radio.duplicateReplies=true;radio.writeDelay = .milliseconds(4)
        let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog())
        defer { s.close() };try await s.open();await s.initialize()
        async let first=s.refresh();async let second=s.refresh();_ = await (first,second)
        #expect(s.ready && !radio.collided)
        #expect(radio.hostACKs.count >= radio.commandFrames.count)
        #expect(radio.commandFrames.enumerated().allSatisfy { $0.element.sequence == UInt8($0.offset%2) })
    }
}

@Test @MainActor func sonyNotificationsAreACKedAndDoNotCompleteUnrelatedRequest() async throws {
    let radio=SonyRadio(),s=SonySession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.initialize()
    radio.beforeReply={ frame in
        if frame.payload.first == 0x66 { radio.emit([0x25,0,42,0],duplicate:true) }
    }
    #expect(try await s.setNoise(.off) == .confirmed)
    #expect(s.state.batteries[.left]?.percent == 42 && s.state.noise == .off && !radio.collided)
    radio.emit([0x65,0x17,1]);#expect(!s.canWrite(Command.setNoise))
    radio.emit([0x65,0x17,0]);#expect(s.canWrite(Command.setNoise))
}

@Test @MainActor func sonyRequiresFreshCompleteSettledReadback() async throws {
    let radio=SonyRadio(),s=SonySession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.initialize()
    for payload:[UInt8] in [[0x67,0x17],[0x67,0x17,0,1,0,0,20],[0x67,0x17,1,0,0,0,20]] {
        radio.handler={ frame in frame.payload.first == 0x66 ? payload : radio.defaultReply(frame.payload) }
        do { _ = try await s.setNoise(.anc);Issue.record("Cached or changing readback confirmed write") }
        catch { #expect(error as? ProtocolError == .invalidPayload || error as? ProtocolError == .readbackMismatch) }
        radio.handler=nil;await s.refresh()
    }
}

@Test @MainActor func sonyMissingACKAndTimeoutCloseChannelBeforeLateReplies() async throws {
    for missingACK in [true,false] {
        let radio=SonyRadio();radio.acknowledge = !missingACK
        if !missingACK { radio.handler={ _ in nil } }
        let s=SonySession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog(),timeout:0.06)
        let receiver:((TransportEvent) -> Void)?
        let open=Task { try await s.open() }
        while radio.commandFrames.isEmpty { await Task.yield() };receiver=radio.onEvent
        do { try await open.value;Issue.record("Incomplete exchange succeeded") } catch { }
        #expect(!radio.active && !s.ready)
        receiver?(.data(try SonyFrameCodec.encode(SonyFrame(payload:radio.handshake))))
        #expect(!s.ready && radio.commandFrames.count == 1)
    }
}

@Test @MainActor func sonyWrongACKAndCancellationCannotAdvanceQueue() async throws {
    let radio=SonyRadio();radio.acknowledge=false
    radio.beforeReply={ frame in radio.onEvent?(.data(try! SonyFrameCodec.encode(SonyFrame(type:1,sequence:frame.sequence)))) }
    let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.2)
    let opening=Task { try await s.open() }
    while radio.commandFrames.isEmpty { await Task.yield() }
    opening.cancel()
    do { try await opening.value;Issue.record("Cancelled open completed") } catch { }
    #expect(!s.ready && !radio.active && radio.commandFrames.count == 1)
}

@Test @MainActor func sonyAbsentCapabilitiesNeverOpenControlsOrProbeBattery() async throws {
    let radio=SonyRadio();radio.functions=[]
    let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.initialize()
    #expect(s.ready && s.state.noise == nil && s.state.batteries.isEmpty)
    #expect(!s.canWrite(Command.setNoise) && !s.canQuery(Command.battery))
    #expect(radio.commandFrames.count == 4)
}

@Test @MainActor func sonyLateWriteFailureAndMissingWriteCompletionNeverConfirmHandshake() async throws {
    for stalled in [false,true] {
        let radio=SonyRadio();radio.failAfterReply = !stalled
        if stalled { radio.writeDelay = .seconds(20) }
        let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.06)
        do { try await s.open();Issue.record("Early ACK and response hid incomplete write") } catch { }
        #expect(!s.ready && !radio.active && radio.commandFrames.count == 1 && !radio.collided)
    }
}

@Test @MainActor func sonyDisconnectCancelsQueuedRequestsAndIgnoresPreviousConnection() async throws {
    let radio=SonyRadio(),s=SonySession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.initialize()
    let receiver=radio.onEvent,count=radio.commandFrames.count
    radio.handler={ _ in nil }
    let first=Task { await s.refresh() },second=Task { await s.refresh() }
    while radio.commandFrames.count == count { await Task.yield() }
    s.close();await first.value;await second.value
    #expect(radio.commandFrames.count == count+1 && !s.ready)
    radio.handler=nil
    try await s.open();await s.initialize()
    receiver?(.data(try SonyFrameCodec.encode(SonyFrame(payload:[0x25,0,1,0]))))
    receiver?(.closed("Old channel closed"))
    #expect(s.ready && radio.active && s.state.batteries[.left]?.percent == 81 && !radio.collided)
}

@Test @MainActor func sonyMalformedIdentityCannotBeRescuedByAdvertisedModel() async throws {
    for identity:[UInt8] in [[5,1,3,65],[5,1,1,0xFF],[5,1,1,0],[5,1,0]] {
        let radio=SonyRadio()
        radio.handler={ frame in frame.payload == [4,1] ? identity : radio.defaultReply(frame.payload) }
        let s=DeviceSession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog(),overrideID:"06EC10",family:.sony)
        do { try await s.open();Issue.record("Malformed identity accepted") } catch { }
        #expect(!s.ready && !radio.active && radio.commandFrames.map(\.payload) == [[0,0],[4,1]])
    }
}

@Test @MainActor func sonyWaitsForFreshSettledTransitionWithoutRepeatingWrite() async throws {
    let radio=SonyRadio(),s=SonySession(transport:radio,name:"WH-1000XM5",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.initialize()
    var reads=0
    radio.handler={ frame in
        if frame.payload.first == 0x66 {
            reads += 1
            if reads == 1 { return [0x67,0x17,0,1,0,0,20] }
        }
        return radio.defaultReply(frame.payload)
    }
    #expect(try await s.setNoise(.transparency) == .confirmed)
    #expect(reads == 2 && radio.commandFrames.filter { $0.payload.first == 0x68 }.count == 1)
    #expect(s.state.sonyNoise?.settled == true && s.state.noise == .transparency)
}
