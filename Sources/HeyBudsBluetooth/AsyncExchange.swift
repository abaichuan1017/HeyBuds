import Foundation
import HeyBudsProtocol

/// Owns both halves of a request. A fast reply must not release the serial
/// request gate while the transport still owns an asynchronous write buffer.
@MainActor final class AsyncExchange<Reply> {
    private var continuation:CheckedContinuation<Reply,Error>?
    private var reply:Result<Reply,Error>?
    private var sent=false
    private var finished=false
    private var sender:Task<Void,Never>?
    private var deadline:Task<Void,Never>?
    private var abortSend:(() -> Void)?

    func run(timeout:Double,timeoutError:Error,abortSend:@escaping () -> Void,
             send:@escaping () async throws -> Void) async throws -> Reply {
        try Task.checkCancellation()
        self.abortSend=abortSend
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation=continuation
                deadline=Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(timeout)) } catch { return }
                    self?.cancel(timeoutError,abortSending:true)
                }
                sender=Task { [weak self] in
                    guard let self, !self.finished, !Task.isCancelled else { return }
                    do {
                        try await send()
                        self.sent=true
                        if let reply=self.reply { self.complete(reply) }
                    } catch {
                        // A failed send is terminal even when a reply arrived first.
                        self.sent=true
                        self.complete(.failure(error))
                    }
                }
            }
        },onCancel: { Task { @MainActor [weak self] in
            self?.cancel(CancellationError(),abortSending:true)
        } })
    }
    func receive(_ result:Result<Reply,Error>) {
        guard !finished, reply == nil else { return }
        reply=result
        if sent { complete(result) }
    }
    func cancel(_ error:Error=ProtocolError.disconnected,abortSending:Bool=false) {
        guard !finished else { return }
        let abort=abortSending && !sent ? abortSend : nil
        complete(.failure(error))
        // Close the channel before the resumed caller can release the gate.
        abort?()
    }
    private func complete(_ result:Result<Reply,Error>) {
        guard !finished else { return }
        finished=true
        deadline?.cancel(); deadline=nil
        sender?.cancel(); sender=nil
        abortSend=nil
        let c=continuation; continuation=nil; c?.resume(with:result)
    }
}

/// A single SDK write callback, with bounded lifetime and exactly-once completion.
@MainActor final class TransportWrite {
    private var continuation:CheckedContinuation<Void,Error>?
    private var deadline:Task<Void,Never>?
    private var finished=false
    private var abort:((Error) -> Void)?

    func wait(timeout:Double=5,abort:@escaping (Error) -> Void,
              start:() -> Void) async throws {
        try Task.checkCancellation()
        self.abort=abort
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation=continuation
                deadline=Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(timeout)) } catch { return }
                    self?.abortWrite(TransportFailure.unavailable("Bluetooth write completion timed out"))
                }
                start()
            }
        },onCancel: { Task { @MainActor [weak self] in self?.abortWrite(CancellationError()) } })
    }
    func finish(_ result:Result<Void,Error>) {
        guard !finished else { return }
        finished=true; deadline?.cancel(); deadline=nil; abort=nil
        let c=continuation; continuation=nil; c?.resume(with:result)
    }
    private func abortWrite(_ error:Error) {
        guard !finished else { return }
        let abort=abort
        finish(.failure(error))
        abort?(error)
    }
}
