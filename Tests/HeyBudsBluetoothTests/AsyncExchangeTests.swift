import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor private final class DelayedRadio:EarbudTransport {
    let base=MockTransport()
    var onEvent:((TransportEvent)->Void)? { didSet { base.onEvent=onEvent } }
    let label="Delayed mock"
    var hold=false
    var completion:CheckedContinuation<Void,Error>?
    var collisions=0
    func open() async throws { try await base.open() }
    func send(_ data:Data) async throws {
        guard completion == nil else { collisions += 1;throw ProtocolError.invalidPayload }
        try await base.send(data)
        if hold { try await withCheckedThrowingContinuation { completion=$0 } }
    }
    func complete() { let c=completion;completion=nil;c?.resume() }
    func close() { base.close();let c=completion;completion=nil;c?.resume(throwing:ProtocolError.disconnected) }
}

@Test @MainActor func fastReplyDoesNotReleaseRequestGateBeforeWriteCompletion() async throws {
    let r=DelayedRadio(),s=DeviceSession(transport:r,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();r.hold=true
    var firstFinished=false
    let first=Task { _ = try await s.query(Command.noise);firstFinished=true }
    while r.completion == nil { await Task.yield() }
    let count=r.base.commands.count
    let second=Task { try await s.query(Command.noise) }
    for _ in 0..<20 { await Task.yield() }
    #expect(!firstFinished && r.base.commands.count == count && r.collisions == 0)
    r.hold=false;r.complete()
    try await first.value;_ = try await second.value
    #expect(firstFinished && r.collisions == 0)
}

@Test @MainActor func requestTimeoutAbortsUnfinishedTransportWrite() async throws {
    let r=DelayedRadio(),s=DeviceSession(transport:r,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    try await s.open();r.hold=true
    do { _ = try await s.query(Command.noise,timeout:0.03);Issue.record("Missing write deadline") }
    catch { #expect(error as? ProtocolError == .timeout(Command.noise)) }
    #expect(!s.ready && !r.base.active && r.completion == nil)
}

@Test @MainActor func requestCancellationAbortsWriteAndRejectsLateReply() async throws {
    let r=DelayedRadio(),s=DeviceSession(transport:r,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    try await s.open();r.hold=true
    let callback=r.onEvent
    let request=Task { try await s.query(Command.noise) }
    while r.completion == nil { await Task.yield() }
    request.cancel()
    do { _ = try await request.value;Issue.record("Ignored cancellation") } catch { #expect(error is CancellationError) }
    callback?(.data(try OPOFrameCodec.encode(OPOFrame(command:0x0204,payload:[1,1,1,90]))))
    #expect(!s.ready && s.state.batteries.isEmpty && r.completion == nil)
}

@Test @MainActor func writeBeforeResponseStillWaitsForReply() async throws {
    let exchange=AsyncExchange<Int>()
    var sent=false,finished=false
    let task=Task { let value=try await exchange.run(timeout:1,timeoutError:ProtocolError.disconnected,abortSend:{Issue.record("Unexpected abort")},send:{sent=true});finished=true;return value }
    while !sent { await Task.yield() }
    #expect(!finished)
    exchange.receive(.success(7));exchange.receive(.success(9))
    #expect(try await task.value == 7)
}

@Test @MainActor func sendFailureOverridesAnEarlySuccessfulReply() async throws {
    let exchange=AsyncExchange<Int>()
    do {
        _ = try await exchange.run(timeout:1,timeoutError:ProtocolError.timeout(1),abortSend:{},send:{
            exchange.receive(.success(7))
            throw ProtocolError.disconnected
        })
        Issue.record("Confirmed a response despite a failed transport write")
    } catch { #expect(error as? ProtocolError == .disconnected) }
}

@Test @MainActor func closeCancelsActiveAndQueuedRequestsWithoutSendingQueue() async throws {
    let r=DelayedRadio(),s=DeviceSession(transport:r,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    try await s.open();r.hold=true
    let first=Task { try await s.query(Command.noise) }
    while r.completion == nil { await Task.yield() }
    let second=Task { try await s.query(Command.equalizer) }
    for _ in 0..<20 { await Task.yield() }
    let count=r.base.commands.count
    s.close()
    for task in [first,second] {
        do { _ = try await task.value;Issue.record("A request survived close") }
        catch { #expect(error as? ProtocolError == .disconnected) }
    }
    #expect(r.base.commands.count == count && r.collisions == 0)
}

@Test @MainActor func transportCallbackTimeoutAndLateCompletionAreBounded() async throws {
    let write=TransportWrite();var aborted=0
    do { try await write.wait(timeout:0.02,abort:{ _ in aborted += 1 },start:{ });Issue.record("Missing callback timeout") }
    catch { #expect(error is TransportFailure) }
    write.finish(.success(()));write.finish(.failure(ProtocolError.disconnected))
    #expect(aborted == 1)
}

@Test @MainActor func transportCallbackCancellationClosesOnlyItsOwnWrite() async throws {
    let first=TransportWrite(),second=TransportWrite();var started=false,aborted=0,secondFinished=false
    let task=Task { try await first.wait(abort:{ _ in aborted += 1 },start:{started=true}) }
    while !started { await Task.yield() }
    task.cancel()
    do { try await task.value;Issue.record("Ignored callback cancellation") } catch { #expect(error is CancellationError) }
    let next=Task { try await second.wait(abort:{ _ in Issue.record("Unexpected second abort") },start:{ });secondFinished=true }
    for _ in 0..<10 { await Task.yield() }
    first.finish(.success(()))
    #expect(!secondFinished && aborted == 1)
    second.finish(.success(()));try await next.value
}
