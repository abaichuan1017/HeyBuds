import Foundation
import Testing
import HeyBudsBluetooth
import HeyBudsProtocol
@testable import HeyBuds

@MainActor private final class Latch {
    var continuation:CheckedContinuation<Void,Never>?
    var entered:Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation=$0 } }
    func release() { let c=continuation;continuation=nil;c?.resume() }
}

@MainActor private final class AppRadio:EarbudTransport {
    var onEvent:((TransportEvent)->Void)?
    let label="App lifecycle mock"
    var active=false
    var lastCommand:UInt16?
    var delayBattery:Latch?
    func open() async throws { active=true }
    func close() { active=false }
    func send(_ bytes:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        var codec=OPOFrameCodec()
        for frame in codec.feed(bytes) {
            lastCommand=frame.command
            if frame.command == Command.battery,let delayBattery { await delayBattery.wait() }
            guard active else { throw ProtocolError.disconnected }
            let payload:[UInt8]
            switch frame.command {
            case Command.capabilities:payload=[0]+Array(repeating:255,count:9)
            case Command.product:payload=[0,0x10,0xC4,6]
            case Command.battery:payload=[0,1,1,70]
            default:payload=[0]
            }
            onEvent?(.data(try OPOFrameCodec.encode(OPOFrame(command:frame.command | 0x8000,sequence:frame.sequence,payload:payload))))
        }
    }
}

@MainActor private func eventually(_ predicate:() -> Bool) async throws {
    let until=Date().addingTimeInterval(3)
    while !predicate(),Date() < until { try await Task.sleep(for:.milliseconds(1)) }
    try #require(predicate())
}

@MainActor private final class AppFixture {
    let suite="HeyBuds-lifecycle-tests-"+UUID().uuidString
    let defaults:UserDefaults
    var app:AppModel!
    var radios:[AppRadio]=[]
    let retry=Latch()
    let devices=[DeviceCandidate(id:"fixture-a",name:"OPPO Enco Air5 Pro",audioConnected:true,classicAddress:nil,family:.oppo),
                 DeviceCandidate(id:"fixture-b",name:"OPPO Enco Air5 Pro",audioConnected:true,classicAddress:nil,family:.oppo)]
    init() throws {
        defaults=try #require(UserDefaults(suiteName:suite))
        defaults.set(false,forKey:"autoReconnect")
        defaults.set(false,forKey:"notifyLow")
        var services=AppServices()
        services.monitor=nil
        services.discover={ [devices] _ in devices }
        services.hasCompetitor={ false }
        services.openAudio={ _ in Issue.record("Unexpected real audio connection") }
        services.closeAudio={ _ in Issue.record("Unexpected real audio disconnect") }
        services.delay={ [retry] _ in await retry.wait() }
        services.makeSession={ [weak self] device,family,_,override,catalog in
            let radio=AppRadio();self?.radios.append(radio)
            return DeviceSession(transport:radio,name:device.name,catalog:catalog,overrideID:override,family:family)
        }
        app=AppModel(catalog:try ModelCatalog(),defaults:defaults,services:services)
        app.candidates=devices;app.selectedID=devices[0].id
    }
    func open() async throws {
        app.connect()
        try await eventually { self.app.ready && self.radios.last?.lastCommand == Command.gestures }
    }
    func cleanup() {
        app.stop();retry.release()
        for radio in radios { radio.delayBattery?.release() }
        defaults.removePersistentDomain(forName:suite)
    }
}

@Test @MainActor func oldOperationCannotFinishOrOverwriteNewDeviceOperation() async throws {
    let f=try AppFixture();defer { f.cleanup() };try await f.open()
    let old=Latch(),current=Latch()
    f.app.perform { _ in await old.wait();throw ProtocolError.rejected(1) }
    try await eventually { old.entered }
    f.app.select("fixture-b")
    try await eventually { f.app.ready && f.radios.last?.lastCommand == Command.gestures }
    f.app.perform { _ in await current.wait();return .confirmed }
    try await eventually { current.entered }
    old.release()
    for _ in 0..<30 { await Task.yield() }
    #expect(f.app.operationBusy && f.app.error == nil && f.app.notice == nil)
    current.release();try await eventually { !f.app.operationBusy }
    #expect(f.app.notice != nil)
}

@Test @MainActor func oldRefreshCannotClearNewSessionBusyState() async throws {
    let f=try AppFixture();defer { f.cleanup() };try await f.open()
    let old=Latch(),current=Latch()
    f.radios[0].delayBattery=old
    f.app.performRefresh();try await eventually { old.entered }
    f.app.select("fixture-b")
    try await eventually { f.app.ready && f.radios.last?.lastCommand == Command.gestures }
    f.app.perform { _ in await current.wait();return .confirmed }
    try await eventually { current.entered }
    old.release()
    for _ in 0..<30 { await Task.yield() }
    #expect(f.app.operationBusy)
    current.release();try await eventually { !f.app.operationBusy }
}

@Test @MainActor func lateReconnectCannotReplaceHealthyNewSession() async throws {
    let f=try AppFixture();defer { f.cleanup() };try await f.open();f.app.autoReconnect=true
    // Let the connection task finish initialization before simulating link loss.
    for _ in 0..<30 { await Task.yield() }
    f.radios[0].onEvent?(.closed(nil))
    try await eventually { f.retry.entered }
    try await f.open()
    let count=f.radios.count,identity=f.app.sessionID
    f.retry.release()
    for _ in 0..<30 { await Task.yield() }
    #expect(f.app.ready && f.radios.count == count && f.app.sessionID == identity)
}

@Test @MainActor func sleepWakePreservesManualDisconnectAndInvalidatesEditor() async throws {
    let f=try AppFixture();defer { f.cleanup() };try await f.open()
    let editor=EQEditingContext(app:f.app,entry:CustomEQEntry(name:"Test",frequencies:[100],gains:[0]))
    #expect(editor.isCurrent(in:f.app))
    f.app.disconnect(audio:false);f.app.autoReconnect=true
    f.app.willSleep();f.app.wake()
    for _ in 0..<30 { await Task.yield() }
    #expect(!f.app.ready && f.radios.count == 1 && !f.retry.entered && !editor.isCurrent(in:f.app))
    try await f.open()
    #expect(!editor.isCurrent(in:f.app))
}

@Test @MainActor func automaticWakeReconnectsUsingFreshSession() async throws {
    let f=try AppFixture();defer { f.cleanup() };try await f.open();f.app.autoReconnect=true
    let before=f.app.sessionID
    f.app.willSleep();f.app.wake()
    try await eventually { f.retry.entered };f.retry.release()
    try await eventually { f.app.ready }
    #expect(f.app.sessionID != before && f.radios.count == 2)
}

@Test @MainActor func storedCrossFamilyOverrideShowsWarningAndDoesNotRouteConnection() async throws {
    let f=try AppFixture();defer { f.cleanup() }
    f.defaults.set("huawei:FreeBudsPro3",forKey:"model.fixture-a")
    #expect(f.app.overrideID == nil && f.app.overrideWarning != nil && f.app.connectionFamily == .oppo)
    #expect(f.app.overrideModels.allSatisfy { $0.family == .oppo })
    try await f.open()
    #expect(f.app.session?.model?.family == .oppo)
    f.app.overrideID="06EC10"
    try await eventually { f.app.ready && f.app.session?.model?.id == "06EC10" }
    #expect(f.app.overrideWarning == nil)
    f.app.overrideID="huawei:FreeBudsPro3"
    #expect(f.app.overrideID == "06EC10" && f.app.error != nil)
}
