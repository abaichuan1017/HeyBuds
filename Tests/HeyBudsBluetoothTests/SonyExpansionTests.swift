import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

/// A wire fixture, not a hardware compatibility claim. Payloads are intentionally
/// literal and do not call the production encoder for their semantic fields.
@MainActor private final class SonyExpansionRadio:EarbudTransport {
    var onEvent:((TransportEvent) -> Void)?
    var label:String { "Sony expansion fixture" }
    var active=false
    var name:String
    var handshake:[UInt8]
    var functions:[UInt8]
    var noise:[UInt8]
    var v1:Bool
    var commands:[SonyFrame]=[]
    var acks:[SonyFrame]=[]
    var ackFirst=true,acknowledge=true,duplicates=false,collided=false,busy=false
    var delay:Duration = .zero
    var failSend=false
    var responseOverride:((SonyFrame) -> [UInt8]?)?
    var beforeReply:((SonyFrame) -> Void)?
    var responseType:UInt8?
    private var rxSequence:UInt8=0
    init(_ profile:SonyProfile) {
        v1=profile == .wh1000xm3 || profile == .wh1000xm4
        switch profile {
        case .wh1000xm3:name="WH-1000XM3"
        case .wh1000xm4:name="WH-1000XM4"
        case .whXB910n:name="WH-XB910N"
        case .ultWear:name="WH-ULT900N"
        case .wf1000xm5:name="WF-1000XM5"
        case .wh1000xm5:name="WH-1000XM5"
        case .whCH720n:name="WH-CH720N"
        }
        handshake=v1 ? [1,0,0,1] : [1,0,3,0,0x30,0x18,0,0]
        if v1 { functions=[0x11,0x62];noise=[0x67,2,1,1,2,1,0,0] }
        else if profile == .whXB910n { functions=[0x20,0x6A];noise=[0x67,0x16,1,1,0,2,0,20] }
        else if profile == .ultWear { functions=[0x20,0x6B];noise=[0x67,0x17,1,1,0,2,0,0] }
        else { functions=profile == .wf1000xm5 ? [0x29,0x2A,0x6B] : [0x28,0x6B];noise=[0x67,0x17,1,1,0,0,20] }
    }
    func open() async throws { active=true }
    func close() { active=false }
    func emit(_ payload:[UInt8],type:UInt8=0x0C) {
        let frame=SonyFrame(type:type,sequence:rxSequence,payload:payload);rxSequence ^= 1
        let bytes=try! SonyFrameCodec.encode(frame)
        onEvent?(.data(bytes));if duplicates { onEvent?(.data(bytes)) }
    }
    func send(_ bytes:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        if busy { collided=true;throw ProtocolError.invalidPayload }
        busy=true;defer { busy=false }
        var decoder=SonyFrameCodec()
        let frame=try #require(decoder.feed(bytes).first)
        if frame.type == 1 { acks.append(frame);return }
        commands.append(frame);beforeReply?(frame)
        func ack() {
            if acknowledge { onEvent?(.data(try! SonyFrameCodec.encode(SonyFrame(type:1,sequence:frame.sequence ^ 1)))) }
        }
        let response=responseOverride.map { $0(frame) } ?? defaultReply(frame)
        if ackFirst { ack() }
        if let response { emit(response,type:responseType ?? frame.type) }
        if !ackFirst { ack() }
        if delay != .zero { try await Task.sleep(for:delay) }
        if failSend { throw ProtocolError.disconnected }
    }
    func defaultReply(_ frame:SonyFrame) -> [UInt8]? {
        let p=frame.payload
        switch p[0] {
        case 0:return handshake
        case 4:
            let bytes=Array((p[1] == 1 ? name : "1.0.0").utf8)
            return [5,p[1],UInt8(bytes.count)]+bytes
        case 6:return [7,0,UInt8(functions.count)]+(v1 ? functions : functions.flatMap { [$0,0xFF] })
        case 0x10:return v1 && p == [0x10,0] ? [0x11,0,81,0] : nil
        case 0x22:
            guard !v1 else { Issue.record("V2 battery/power-off opcode sent to V1");return nil }
            switch p[1] {
            case 0:return [0x23,0,81,0]
            case 8:return [0x23,8,81,0,20]
            case 9:return [0x23,9,70,0,65,1,20,20]
            case 10:return [0x23,10,52,0,20]
            default:return nil
            }
        case 0x66:return noise
        case 0x68:noise=[0x67]+p.dropFirst();return nil
        default:return nil
        }
    }
}

@Test @MainActor func sonyExpansionAllProfilesHandshakeBatteryAndConfirmedControls() async throws {
    for profile in SonyProfile.allCases {
        let radio=SonyExpansionRadio(profile)
        let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog(),serviceUUID:profile.serviceUUID)
        defer { s.close() }
        let backend:any AdditionalSession=s
        try await backend.open();await backend.refresh()
        #expect(s.ready && s.profile == profile && s.model?.id == profile.modelID && s.state.noise == .anc)
        #expect(s.state.batteries[.left]?.percent == (profile == .wf1000xm5 ? 70 : 81))
        #expect(s.supportsAmbientLevel == (profile != .ultWear))
        let battery=radio.commands.filter { [UInt8(0x10),0x22].contains($0.payload.first ?? 0xFF) }
        #expect(battery.allSatisfy { $0.payload[0] == (profile.generation == .v1 ? 0x10 : 0x22) })
        if profile == .whXB910n {
            #expect(radio.commands.first(where:{$0.payload == [4,1]})?.type == 0x0E)
            #expect(s.state.firmware == nil)
        } else { #expect(s.state.firmware == "1.0.0") }
        #expect(try await s.setNoise(.transparency) == .confirmed)
        if profile == .ultWear {
            #expect(s.state.sonyNoise?.ambientLevel == nil)
            #expect(try await s.setFocusOnVoice(true) == .confirmed)
            do { _ = try await s.setAmbient(level:7,focusOnVoice:true);Issue.record("ULT level invented") }
            catch { #expect(error as? ProtocolError == .unsupported) }
        } else {
            #expect(try await s.setAmbient(level:7,focusOnVoice:true) == .confirmed)
            #expect(s.state.sonyNoise?.ambientLevel == 7)
        }
        #expect(s.state.sonyNoise?.focusOnVoice == true)
        #expect(try await s.setNoise(.off) == .confirmed)
        #expect(s.state.noise == .off && !radio.collided)
        #expect(!s.canWrite(Command.setEQ))
        do { _ = try await backend.setEQ(0);Issue.record("Sony EQ enabled") }
        catch { #expect(error as? ProtocolError == .unsupported) }
    }
}

@Test @MainActor func sonyExpansionServiceHandshakeAndIdentityMustAgreeBeforeFeatures() async throws {
    for scenario in 0..<5 {
        let radio=SonyExpansionRadio(.wh1000xm4)
        var service=SonyProtocol.serviceV1
        if scenario == 0 { service=SonyProtocol.serviceV2 }
        if scenario == 1 { radio.name="WH-1000XM5" }
        if scenario == 2 { radio.handshake=[1,0,0,0] }
        if scenario == 3 { radio.name="WF-1000XM4" }
        if scenario == 4 { radio.functions=[0x20,0x28,0x6B] }
        let s=SonySession(transport:radio,name:"WH-1000XM4",catalog:try ModelCatalog(),serviceUUID:service)
        defer { s.close() }
        if scenario == 4 {
            try await s.open();await s.refresh()
            #expect(!s.canQuery(Command.battery) && !s.canWrite(Command.setNoise))
        } else {
            do { try await s.open();Issue.record("Version/identity mismatch accepted") }
            catch { #expect(error as? ProtocolError == .unsupported) }
            #expect(!s.ready && !radio.active)
        }
        #expect(!radio.commands.contains { [UInt8(0x10),0x22,0x66,0x68].contains($0.payload.first ?? 0xFF) })
    }
}

@Test @MainActor func sonyExpansionACKOrderDuplicatesAndWriteCompletionRemainSerialized() async throws {
    for profile:SonyProfile in [.wh1000xm4,.whXB910n,.ultWear,.wh1000xm5] {
        for first in [true,false] {
            let radio=SonyExpansionRadio(profile);radio.ackFirst=first;radio.duplicates=true;radio.delay = .milliseconds(2)
            let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog())
            defer { s.close() };try await s.open();await s.refresh()
            async let a=s.refresh();async let b=s.refresh();_ = await (a,b)
            #expect(s.ready && !radio.collided)
            #expect(radio.commands.enumerated().allSatisfy { $0.element.sequence == UInt8($0.offset%2) })
            #expect(radio.acks.count >= radio.commands.filter { $0.payload.first != 0x68 }.count*2)
        }
    }
}

@Test @MainActor func sonyExpansionNoACKNoResponseWrongTableOrIncompleteSendCannotOpen() async throws {
    for scenario in 0..<6 {
        let radio=SonyExpansionRadio(.wh1000xm4)
        if scenario == 0 { radio.acknowledge=false }
        if scenario == 1 { radio.responseOverride={ _ in nil } }
        if scenario == 2 { radio.responseType=0x0E }
        if scenario == 3 { radio.delay = .seconds(20) }
        if scenario == 4 { radio.failSend=true }
        if scenario == 5 {
            radio.acknowledge=false
            radio.beforeReply={ frame in radio.onEvent?(.data(try! SonyFrameCodec.encode(SonyFrame(type:1,sequence:frame.sequence)))) }
        }
        let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.05)
        do { try await s.open();Issue.record("Incomplete exchange opened") } catch { }
        #expect(!s.ready && !radio.active && radio.commands.count == 1)
    }
}

@Test @MainActor func sonyExpansionFreshReadbackRejectsCacheNotificationsAndMalformedLayout() async throws {
    for profile:SonyProfile in [.wh1000xm3,.wh1000xm4,.whXB910n,.ultWear] {
        let radio=SonyExpansionRadio(profile)
        let s=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.05)
        defer { s.close() };try await s.open();await s.refresh()
        let before=radio.noise
        radio.responseOverride={ frame in
            if frame.payload.first == 0x66 { return [0x67,before[1]] }
            return radio.defaultReply(frame)
        }
        do { _ = try await s.setNoise(.transparency);Issue.record("Malformed readback confirmed") }
        catch { #expect(error as? ProtocolError == .invalidPayload) }
        radio.responseOverride=nil;await s.refresh()
        // The cached and notified state already says ambient, but no GET answer arrives.
        radio.responseOverride={ frame in frame.payload.first == 0x66 ? nil : radio.defaultReply(frame) }
        radio.beforeReply={ frame in
            if frame.payload.first == 0x66 { radio.emit([0x69]+radio.noise.dropFirst()) }
        }
        do { _ = try await s.setNoise(.transparency);Issue.record("Notification/cache completed GET") } catch { }
        #expect(!s.ready && !radio.active)
    }
}

@Test @MainActor func sonyExpansionSettledReadbackAndAvailabilityAreProfileSpecific() async throws {
    for profile:SonyProfile in [.wh1000xm4,.whXB910n,.ultWear] {
        let radio=SonyExpansionRadio(profile)
        let session=SonySession(transport:radio,name:radio.name,catalog:try ModelCatalog())
        defer { session.close() };try await session.open();await session.refresh()
        var reads=0
        radio.responseOverride={ frame in
            if frame.payload.first == 0x66 {
                reads += 1
                var bytes=radio.noise
                if reads == 1 { bytes[2]=profile.generation == .v1 ? 0x10 : 0 }
                return bytes
            }
            return radio.defaultReply(frame)
        }
        #expect(try await session.setNoise(.transparency) == .confirmed)
        #expect(reads == 2 && radio.commands.filter { $0.payload.first == 0x68 }.count == 1)
        radio.emit([0x65,profile.noiseSubtype,1]);#expect(!session.canWrite(Command.setNoise))
        radio.emit([0x65,profile.noiseSubtype,0]);#expect(session.canWrite(Command.setNoise))
    }
}

@Test @MainActor func sonyExpansionCancellationQueuedRequestsAndOldCallbacksAreRetired() async throws {
    for profile:SonyProfile in [.wh1000xm3,.whXB910n,.ultWear] {
        let radio=SonyExpansionRadio(profile),catalog=try ModelCatalog()
        let s=SonySession(transport:radio,name:radio.name,catalog:catalog)
        defer { s.close() };try await s.open();await s.refresh()
        let receiver=radio.onEvent,count=radio.commands.count
        radio.responseOverride={ _ in nil }
        let a=Task { await s.refresh() },b=Task { await s.refresh() }
        while radio.commands.count == count { await Task.yield() }
        a.cancel();await a.value;await b.value
        #expect(!s.ready && !radio.active && radio.commands.count == count+1)
        radio.responseOverride=nil;try await s.open();await s.refresh()
        receiver?(.closed("Previous generation"))
        receiver?(.data(try SonyFrameCodec.encode(SonyFrame(payload:profile.generation == .v1 ? [0x13,0,1,0] : [0x25,0,1,0]))))
        #expect(s.ready && radio.active && s.state.batteries[.left]?.percent == 81)
    }
}
