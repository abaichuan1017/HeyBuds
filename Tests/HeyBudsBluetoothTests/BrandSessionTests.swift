import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor private final class BrandRadio:EarbudTransport {
    var onEvent:((TransportEvent)->Void)?
    let label="Mock brand transport"
    let family:EarbudFamily
    var decoder:BrandFrameCodec
    var active=false
    var packets:[Data]=[]
    var commands:[BrandFrame]=[]
    var response:((BrandFrame)->BrandFrame?)?
    var ignore=false
    init(_ family:EarbudFamily,version:UInt8=4) { self.family=family;decoder=BrandFrameCodec(family:family,gaiaVersion:version) }
    func open() async throws { active=true }
    func close() { active=false }
    func send(_ data:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        packets.append(data)
        if ignore { return }
        // Edifier request headers differ from responses; use its documented request fields.
        let frames:[BrandFrame]
        if family == .edifier {
            let b=Array(data);frames=[BrandFrame(UInt16(b[2]),Array(b[3..<b.count-2]))]
        } else { frames=decoder.feed(data) }
        for frame in frames {
            commands.append(frame)
            let answer:BrandFrame?
            if let response { answer=response(frame) }
            else {
                switch (family,frame.command) {
                case (.vivo,0x0300):answer=BrandFrame(0x8300,[0])
                case (.vivo,0x0207):answer=BrandFrame(0x8207,[0,40,0,255,1])
                case (.vivo,0x0230):answer=BrandFrame(0x8230,[0,1,4])
                case (.vivo,0x0203):answer=BrandFrame(0x8203,[0,1])
                case (.vivo,0x0218):answer=BrandFrame(0x8218,[0,0])
                case (.vivo,0x0239):answer=BrandFrame(0x8239,[0,0,1])
                case (.vivo,0x020D):answer=BrandFrame(0x820D,[0,4])
                case (.vivo,0x0251):answer=BrandFrame(0x8251,[0,0])
                case (.vivo,0x0252):answer=BrandFrame(0x8252,[0,1])
                case (.vivo,0x021C):answer=BrandFrame(0x821C,[0,49,46,50])
                case (.vivo,0x0249):answer=BrandFrame(0x8249,[0,0])
                case (.huawei,0x0108):answer=BrandFrame(0x0108,[2,3,40,0,255])
                case (.huawei,0x2B2A):answer=BrandFrame(0x2B2A,[1,2,2,1])
                case (.huawei,0x2B4A):answer=BrandFrame(0x2B4A,[1,1,1,2,1,5])
                case (.huawei,0x2B11),(.huawei,0x2B2F):answer=BrandFrame(frame.command,[1,1,1])
                case (.huawei,0x2B6C):answer=BrandFrame(0x2B6C,[2,1,0])
                case (.huawei,0x2B31):answer=BrandFrame(0x2B31,[2,1,0])
                case (.edifier,0xD0):answer=BrandFrame(0xD0,[50])
                case (.edifier,0xCC):answer=BrandFrame(0xCC,[1])
                case (.xiaomi,2) where frame.sequence == 0x50:answer=BrandFrame(2,[1]+(try XiaomiAuth.response(Array(frame.payload.dropFirst()))),sequence:0x50)
                case (.xiaomi,2):answer=BrandFrame(2,[2,2,4,7,50,60,70],sequence:frame.sequence)
                default:answer=nil
                }
            }
            if let answer { try emit(answer) }
        }
    }
    func emit(_ frame:BrandFrame) throws {
        let data:Data
        if family == .edifier {
            var b:[UInt8]=[0xBB,UInt8(frame.payload.count+1),UInt8(frame.command)]+frame.payload
            let sum=b.reduce(UInt16(8217)) { $0 &+ UInt16($1) };b += [UInt8(sum>>8),UInt8(truncatingIfNeeded:sum)];data=Data(b)
        } else { data=try decoder.encode(frame) }
        onEvent?(.data(data))
    }
}
@Test @MainActor func vivoSessionUsesItsOwnHandshakeAndNeverOppoPackets() async throws {
    let t=BrandRadio(.vivo,version:3),c=try ModelCatalog()
    let s=DeviceSession(transport:t,name:"vivo TWS 3e",catalog:c)
    defer { s.close() };try await s.open()
    #expect(s.ready && s.model?.family == .vivo)
    #expect(s.state.batteries[.right]?.percent == 0 && s.state.batteries[.enclosure] == nil)
    #expect(t.commands.first?.command == 0x0300)
    #expect(t.commands.map(\.command) == [0x0300,0x0202,0x0203,0x0204,0x0205,0x0206,0x0207])
    #expect(t.packets.allSatisfy { $0.first == 0xFF })
    #expect(s.canWrite(Command.find))
    #expect(!s.canWrite(Command.setBass))
    #expect(!s.canQuery(Command.priority))
    s.close();#expect(!s.ready && s.state.batteries.isEmpty)
}
@Test @MainActor func huaweiReadbackSelectsItsModelSpecificNoiseLevel() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds Pro 3",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    #expect(s.state.noise == .deep)
    #expect(try await s.setNoise(.deep) == .confirmed)
    let packet=try #require(t.commands.last(where:{$0.command == 0x2B04}))
    #expect(packet.payload == [1,2,1,2])
    #expect(t.packets.allSatisfy { $0.first == 0x5A })
}
@Test @MainActor func malformedReadbackCannotConfirmEvenAnUnchangedRequestedValue() async throws {
    let t=BrandRadio(.edifier),s=DeviceSession(transport:t,name:"W820NB Plus",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    #expect(s.state.noise == .off)
    t.response={ frame in frame.command == 0xCC ? BrandFrame(0xCC,[]) : nil }
    do { _ = try await s.setNoise(.off);Issue.record("Malformed readback confirmed stale state") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(s.state.noise == .off)
}
@Test @MainActor func vivoSetEchoCannotConfirmNoiseWithoutReadback() async throws {
    let t=BrandRadio(.vivo),s=DeviceSession(transport:t,name:"vivo TWS 4",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    t.response={ frame in
        if frame.command == 0x0130 { return BrandFrame(0x8130,frame.payload) }
        if frame.command == 0x0230 { return BrandFrame(0x8230,[0,1,4]) }
        return nil
    }
    let task=Task { try await s.setNoise(.transparency) }
    try await Task.sleep(for:.milliseconds(50))
    #expect(s.state.noise == .off)
    task.cancel()
    do { _ = try await task.value;Issue.record("Cancellation ignored") } catch { #expect(error is CancellationError) }
    #expect(s.state.noise == .off)
}
@Test @MainActor func staleCallbackAndQueuedOperationsCannotRestoreClosedBrandState() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds 6i",catalog:try ModelCatalog())
    try await s.open();let callback=t.onEvent
    s.close();callback?(.data(try BrandFrameCodec(family:.huawei).encode(BrandFrame(0x0108,[2,1,90]))))
    #expect(!s.ready && s.state.batteries.isEmpty)
    #expect(!s.canWrite(Command.setNoise))
}
@Test @MainActor func unsupportedOperationsNeverEmitPacketsInOtherBrands() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds 6i",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();let before=t.packets.count
    do { _ = try await s.setBass(3);Issue.record("OPPO bass sent to Huawei") } catch { #expect(error as? ProtocolError == .unsupported) }
    do { _ = try await s.setGameSound(1);Issue.record("OPPO game sound sent to Huawei") } catch { #expect(error as? ProtocolError == .unsupported) }
    do { _ = try await s.query(Command.battery);Issue.record("Raw OPPO query sent to Huawei") } catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(t.packets.count == before)
}
@Test @MainActor func xiaomiAuthenticationAndBatteryUseSeparateRcspFields() async throws {
    let t=BrandRadio(.xiaomi),s=DeviceSession(transport:t,name:"Redmi Buds 6",catalog:try ModelCatalog())
    defer { s.close() };try await s.open()
    #expect(s.ready && s.state.batteries[.left]?.percent == 50)
    let auth=try #require(t.commands.first(where:{$0.command == 0x51}))
    #expect(auth.kind == 4 && auth.sequence == 0)
    #expect(auth.payload == [3,1])
    #expect(t.packets.allSatisfy { $0.starts(with:[0xFE,0xDC,0xBA]) })
    #expect(!s.canWrite(Command.setNoise) && s.gameFeature == nil)
}
@Test @MainActor func modelOverrideCannotConvertExistingWireProtocol() async throws {
    let t=BrandRadio(.vivo),s=DeviceSession(transport:t,name:"vivo TWS 4",catalog:try ModelCatalog())
    defer { s.close() };try await s.open()
    s.setModelOverride("huawei:FreeBudsPro3")
    #expect(s.model?.family == .vivo)
    #expect(!s.canWrite(Command.setCustomEQ))
}

@Test @MainActor func completeHuaweiHostListsProtectThisMacAndConfirmTargetOnly() async throws {
    let t=BrandRadio(.huawei),local:[UInt8]=[1,2,3,4,5,6]
    let s=DeviceSession(transport:t,name:"FreeBuds Pro",catalog:try ModelCatalog(),localHostAddress:local)
    defer { s.close() };try await s.open()
    t.response={ frame in
        if frame.command == 0x2B31 { return BrandFrame(0x2B31,[2,1,1,3,1,0,4,6,1,2,3,4,5,6,5,1,1,9,3,77,97,99]) }
        if frame.command == 0x0108 { return BrandFrame(0x0108,[2,1,80]) }
        if frame.command == 0x2B2A { return BrandFrame(0x2B2A,[1,2,0,0]) }
        if frame.command == 0x2B11 || frame.command == 0x2B2F { return BrandFrame(frame.command,[1,1,1]) }
        return nil
    }
    await s.refresh()
    let host=try #require(s.state.hosts.first)
    #expect(host.current && host.address == local)
    #expect(!s.canOperateHost(.disconnect,host:host))
    #expect(!s.canOperateHost(.automatic))
    let before=t.packets.count
    do { _ = try await s.operateHost(.disconnect,host:host);Issue.record("Current Mac was disconnected") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(t.packets.count == before)
}
@Test @MainActor func closeCancelsPendingBrandReadAndClearsAllState() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds Studio",catalog:try ModelCatalog())
    try await s.open();t.ignore=true
    let task=Task { await s.refresh() }
    try await Task.sleep(for:.milliseconds(30));s.close();await task.value
    #expect(!s.ready && s.state.batteries.isEmpty && s.state.observedQueries.isEmpty)
}
