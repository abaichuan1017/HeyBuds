import Foundation
import HeyBudsProtocol

@MainActor public protocol NothingIdentityTransport: EarbudTransport {
    var verifiedModelCode: String? { get }
}

/// Read the standard model-ID event, close that service, then open the control
/// service. No command is ever written to Fast Pair. Neither addresses nor
/// serial numbers are read or retained by this adapter.
@MainActor public final class NothingVerifiedTransport: NothingIdentityTransport {
    public var onEvent: ((TransportEvent) -> Void)?
    public let label = "RFCOMM"
    public private(set) var verifiedModelCode: String?
    private let identity: EarbudTransport
    private let control: EarbudTransport
    private let profile: NothingProfile
    private let timeout: Double
    private var exchange: AsyncExchange<String>?
    private var generation = UUID()

    public init(identity: EarbudTransport, control: EarbudTransport, profile: NothingProfile, timeout: Double = 10) {
        self.identity = identity; self.control = control; self.profile = profile; self.timeout = timeout
    }
    public func open() async throws {
        guard !profile.fastPairIDs.isEmpty, exchange == nil, verifiedModelCode == nil else { throw ProtocolError.unsupported }
        let token = generation, request = AsyncExchange<String>()
        exchange = request
        var codec = NothingModelIDCodec()
        identity.onEvent = { event in
            switch event {
            case .data(let data):
                if let id = codec.feed(data).first { request.receive(.success(id)) }
            case .closed: request.receive(.failure(ProtocolError.disconnected))
            }
        }
        do {
            let id = try await request.run(timeout: timeout, timeoutError: ProtocolError.timeout(0),
                                           abortSend: { [identity] in identity.close() },
                                           send: { [identity] in try await identity.open() })
            identity.onEvent = nil; identity.close(); exchange = nil
            guard generation == token, profile.fastPairIDs.contains(id) else { throw ProtocolError.unsupported }
            try Task.checkCancellation()
            verifiedModelCode = profile.modelCode
            control.onEvent = { [weak self] event in
                guard let self, self.generation == token else { return }
                self.onEvent?(event)
            }
            try await control.open()
            guard generation == token else { throw ProtocolError.disconnected }
        } catch { close(); throw error }
    }
    public func send(_ bytes: Data) async throws {
        guard verifiedModelCode == profile.modelCode else { throw ProtocolError.unsupported }
        try await control.send(bytes)
    }
    public func close() {
        generation = UUID(); verifiedModelCode = nil
        let pending = exchange; exchange = nil; pending?.cancel()
        identity.onEvent = nil; identity.close(); control.onEvent = nil; control.close()
    }
}
