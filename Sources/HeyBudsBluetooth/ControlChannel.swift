import Foundation
import HeyBudsProtocol

/// Shared request lifetime, never shared wire semantics. Each backend supplies
/// its own bounded decoder, response matcher and (where needed) acknowledgements.
@MainActor final class ControlChannel<Message> {
    var onMessage:((Message) -> Void)?
    var onClose:((String?) -> Void)?
    private let transport:EarbudTransport
    private let decode:(Data) -> [Message]
    private let resetDecoder:() -> Void
    private let acknowledge:(Message) -> Data?
    private let requests=RequestGate(),writes=RequestGate()
    private var generation=UUID()
    private var active=false
    private var pending:AsyncExchange<Message?>?
    private var matches:((Message) -> Bool)?
    private var started=false
    private var acknowledgements:[Data]=[]
    private var ackTask:Task<Void,Never>?
    let timeout:Double

    init(transport:EarbudTransport,timeout:Double=3,decode:@escaping (Data) -> [Message],
         reset:@escaping () -> Void,acknowledge:@escaping (Message) -> Data?={ _ in nil }) {
        self.transport=transport;self.timeout=timeout;self.decode=decode
        resetDecoder=reset;self.acknowledge=acknowledge
    }
    func open() async throws {
        let token=generation;active=true;resetDecoder()
        transport.onEvent={ [weak self] event in
            guard let self,self.active,self.generation == token else { return }
            switch event {
            case .closed(let reason):self.fail(reason)
            case .data(let bytes):
                for message in self.decode(bytes) {
                    guard self.active,self.generation == token else { return }
                    if let ack=self.acknowledge(message) { self.queueACK(ack,token:token) }
                    self.onMessage?(message)
                    if self.started,self.matches?(message) == true { self.pending?.receive(.success(message)) }
                }
            }
        }
        do {
            try await transport.open();try Task.checkCancellation()
            guard active,generation == token else { throw ProtocolError.disconnected }
        } catch { if generation == token { close() };throw error }
    }
    func request(_ bytes:Data,timeout:Double?=nil,retireOnTimeout:Bool=true,matching:@escaping (Message) -> Bool) async throws -> Message {
        guard let message=try await perform(bytes,matching:matching,timeout:timeout,retireOnTimeout:retireOnTimeout) else { throw ProtocolError.invalidPayload }
        return message
    }
    func send(_ bytes:Data) async throws { _ = try await perform(bytes,matching:nil) }
    private func perform(_ bytes:Data,matching:((Message) -> Bool)?,timeout:Double?=nil,retireOnTimeout:Bool=true) async throws -> Message? {
        let token=generation
        try await requests.acquire();defer { requests.release() }
        try Task.checkCancellation()
        guard active,generation == token else { throw ProtocolError.disconnected }
        let exchange=AsyncExchange<Message?>()
        pending=exchange;matches=matching;started=false
        defer { if pending === exchange { pending=nil;matches=nil;started=false } }
        do {
            return try await exchange.run(timeout:timeout ?? self.timeout,timeoutError:ProtocolError.timeout(0),abortSend:{ [weak self] in
                guard let self,self.generation == token else { return };self.fail(nil)
            },send:{ [weak self] in
                guard let self else { throw ProtocolError.disconnected }
                try await self.write(bytes,token:token,beforeSend:{
                    self.started=true
                    if matching == nil { exchange.receive(.success(nil)) }
                })
            })
        } catch {
            // Protocols without request IDs cannot safely reuse a channel after
            // a timeout; even ID-based protocols retire cancelled writes.
            let safeProbeTimeout = !retireOnTimeout && (error as? ProtocolError) == .timeout(0)
            if generation == token,!safeProbeTimeout { fail(error is CancellationError ? nil : error.localizedDescription) }
            throw error
        }
    }
    private func write(_ bytes:Data?,token:UUID,beforeSend:(() -> Void)?=nil) async throws {
        try await writes.acquire();defer { writes.release() }
        try Task.checkCancellation()
        guard active,generation == token else { throw ProtocolError.disconnected }
        try await drainACKs(token)
        if let bytes { beforeSend?();try await transport.send(bytes) }
        try await drainACKs(token)
    }
    private func drainACKs(_ token:UUID) async throws {
        while !acknowledgements.isEmpty {
            try Task.checkCancellation()
            guard active,generation == token else { throw ProtocolError.disconnected }
            try await transport.send(acknowledgements.removeFirst())
        }
    }
    private func queueACK(_ bytes:Data,token:UUID) {
        guard acknowledgements.count < 128 else { fail("Control notification queue overflow");return }
        acknowledgements.append(bytes)
        guard ackTask == nil else { return }
        ackTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.ackTask=nil } }
            do { try await self.write(nil,token:token) }
            catch { if self.generation == token { self.fail(error.localizedDescription) } }
        }
    }
    func close() {
        active=false;generation=UUID();ackTask?.cancel();ackTask=nil
        pending?.cancel();pending=nil;matches=nil;started=false
        acknowledgements.removeAll();transport.onEvent=nil;transport.close();resetDecoder()
    }
    private func fail(_ reason:String?) {
        guard active else { return };close();onClose?(reason)
    }
}

/// App-facing subset for the new independent brand backends. Raw commands stay
/// inside each backend; confirmed writes must inspect a fresh response.
@MainActor protocol AdditionalSession:AnyObject {
    var state:DeviceState { get }
    var model:DeviceModel? { get }
    var ready:Bool { get }
    var interactive:Bool { get set }
    var onChange:(() -> Void)? { get set }
    var onClose:((String?) -> Void)? { get set }
    func open() async throws
    func initialize() async
    func refresh() async
    func close()
    func canQuery(_ command:UInt16) -> Bool
    func canWrite(_ command:UInt16,reading:UInt16?) -> Bool
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome
    func setEQ(_ id:UInt8) async throws -> WriteOutcome
}
