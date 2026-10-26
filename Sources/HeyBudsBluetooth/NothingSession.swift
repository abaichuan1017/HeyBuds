// GPL-3.0-or-later. Protocol references and attribution: docs/licenses/Nothing.md.
import Foundation
import HeyBudsProtocol

/// Dedicated Nothing RFCOMM session. The supplied transport must resolve the
/// selected profile's service through SDP; no numeric channel fallback is used.
@MainActor final class NothingSession: AdditionalSession {
    private(set) var state = DeviceState()
    private(set) var model: DeviceModel?
    private(set) var ready = false
    var interactive = false
    var onChange: (() -> Void)?
    var onClose: ((String?) -> Void)?
    private let profile: NothingProfile?
    private let channel: ControlChannel<NothingFrame>
    private let resetDecoder: () -> Void
    private let operations = RequestGate()
    private var generation = UUID()
    private var connected = false
    private var sequence = 0
    private var poll: Task<Void, Never>?
    private var advancedEQ: Bool?
    private var noiseAvailable = false
    private var eqAvailable = false

    init(transport: EarbudTransport, name: String, catalog: ModelCatalog, timeout: Double = 3) {
        let selected = NothingProfile.named(name)
        profile = selected
        model = selected.flatMap { p in catalog.models.first { $0.id == p.modelID } }
        var codec = NothingFrameCodec(profile: selected ?? .earA)
        resetDecoder = { codec.reset() }
        channel = ControlChannel(transport: transport, timeout: timeout,
                                 decode: { codec.feed($0) }, reset: { codec.reset() })
        // Only correlated requests update setting state. Notifications and ACKs
        // cannot establish capabilities or satisfy a setting readback.
        channel.onClose = { [weak self] reason in
            self?.close(); self?.onClose?(reason)
        }
    }

    func open() async throws {
        let token = generation
        try await operations.acquire(); defer { operations.release() }
        try check(token)
        guard let profile, model != nil, !connected else { throw ProtocolError.unsupported }
        connected = true
        do {
            try await channel.open()
            try check(token)
            let identity = try await read(profile.identityRead)
            guard profile.identityCode(identity.payload) == profile.modelCode else { throw ProtocolError.unsupported }
            state.productID = profile.modelCode
            state.observedQueries.insert(Command.product)
            // Firmware is needed for the B179 EQ gate; absence never enables it.
            if let frame = try await probe(profile.firmwareRead),
               let version = profile.parseFirmware(frame.payload) {
                state.firmware = version; state.observedQueries.insert(Command.firmware)
            }
            try check(token)
            try await readBattery()
            if let frame = try await probe(profile.noiseRead), let mode = profile.parseNoise(frame.payload) {
                state.noise = mode; noiseAvailable = true
                state.observedQueries.insert(Command.noise)
            }
            try check(token)
            if profile.allowsEQ(firmware: state.firmware) {
                do { _ = try await readEQ(probing: true); eqAvailable = true }
                catch { try check(token); clearEQ() }
            }
            try check(token)
            ready = true; onChange?(); try check(token)
        } catch {
            if generation == token { close() }
            throw error
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
    }

    /// Never reuse an operation ID in one connection: a delayed reply cannot
    /// become the readback of a later write after the one-byte ID wraps.
    private func nextSequence() throws -> UInt8 {
        guard connected else { throw ProtocolError.disconnected }
        guard sequence < 250 else {
            close(); onClose?(nil); throw ProtocolError.disconnected
        }
        sequence += 1
        return UInt8(sequence)
    }

    private func read(_ request: NothingRequest, probing: Bool = false) async throws -> NothingFrame {
        let token = generation, id = try nextSequence()
        let frame = NothingFrame(command: request.command, sequence: id, payload: request.payload)
        let response: NothingFrame
        do {
            response = try await channel.request(try NothingFrameCodec.encode(frame),
                                                 retireOnTimeout: !probing, matching: {
                $0.command == request.responseCommand && $0.sequence == id
            })
        } catch {
            // A truncated optional reply must not hold the next request behind
            // its declared length. The abandoned sequence is never reused.
            if probing, generation == token, (error as? ProtocolError) == .timeout(0) { resetDecoder() }
            throw error
        }
        try check(token)
        guard connected else { throw ProtocolError.disconnected }
        return response
    }

    private func probe(_ request: NothingRequest) async throws -> NothingFrame? {
        let token = generation
        do { return try await read(request, probing: true) }
        catch {
            try check(token)
            // Only a completed send with no reply is an optional capability miss.
            // ControlChannel retires the connection if sending itself stalled.
            if (error as? ProtocolError) == .timeout(0) { return nil }
            throw error
        }
    }

    private func send(_ request: NothingRequest) async throws {
        let token = generation, id = try nextSequence()
        try await channel.send(try NothingFrameCodec.encode(
            NothingFrame(command: request.command, sequence: id, payload: request.payload)))
        try check(token)
    }

    private func readBattery() async throws {
        guard let profile else { throw ProtocolError.unsupported }
        let frame = try await read(profile.batteryRead)
        guard let batteries = profile.parseBattery(frame.payload) else {
            state.batteries.removeAll(); state.observedQueries.remove(Command.battery)
            onChange?(); throw ProtocolError.invalidPayload
        }
        state.batteries = batteries
        state.observedQueries.insert(Command.battery); onChange?()
    }

    private func readNoise() async throws -> NoiseMode {
        guard let profile else { throw ProtocolError.unsupported }
        let frame = try await read(profile.noiseRead)
        guard let mode = profile.parseNoise(frame.payload) else {
            state.noise = nil; state.observedQueries.remove(Command.noise)
            onChange?(); throw ProtocolError.invalidPayload
        }
        state.noise = mode; state.observedQueries.insert(Command.noise)
        onChange?(); return mode
    }

    private func clearEQ() {
        state.eq = nil; advancedEQ = nil; state.observedQueries.remove(Command.equalizer)
        onChange?()
    }

    private func readEQ(probing: Bool = false) async throws -> UInt8 {
        guard let profile, profile.allowsEQ(firmware: state.firmware) else { throw ProtocolError.unsupported }
        let frame = try await read(profile.eqRead, probing: probing)
        guard let id = profile.parseEQ(frame.payload) else {
            clearEQ(); throw ProtocolError.invalidPayload
        }
        // A preset register may remain cached while advanced EQ is active.
        // Check the active mode after reading that register, before publishing
        // or confirming it. Never alter advanced mode in this bounded adapter.
        if let request = profile.advancedEQRead {
            let frame = try await read(request, probing: probing)
            guard let active = profile.parseAdvancedEQ(frame.payload), !active else {
                clearEQ(); throw ProtocolError.unsupported
            }
            advancedEQ = false
        }
        state.eq = id; state.observedQueries.insert(Command.equalizer)
        onChange?(); return id
    }

    func initialize() async {
        guard ready else { return }
        let token = generation
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(self?.interactive == true ? 8 : 30)) }
                catch { return }
                guard let self, self.ready, self.generation == token else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard ready else { return }
        let token = generation
        do {
            try await operations.acquire(); defer { operations.release() }
            try check(token)
            guard ready else { return }
            try await readBattery()
            if noiseAvailable { _ = try await readNoise() }
            if eqAvailable {
                do { _ = try await readEQ() }
                catch {
                    try check(token)
                    guard let failure = error as? ProtocolError,
                          failure == .unsupported || failure == .invalidPayload else { throw error }
                    clearEQ()
                }
            }
        } catch {
            if generation == token, !(error is CancellationError) {
                // Malformed setting replies clear their own capability; a bad
                // refresh must not leave cached state presented as current.
                close(); onClose?(error.localizedDescription)
            }
        }
    }

    func canQuery(_ command: UInt16) -> Bool {
        guard let profile, model != nil else { return false }
        switch command {
        case Command.product, Command.firmware, Command.battery, Command.noise: return true
        case Command.equalizer: return profile.allowsEQ(firmware: state.firmware)
        default: return false
        }
    }

    func canWrite(_ command: UInt16, reading: UInt16? = nil) -> Bool {
        guard ready else { return false }
        let read: UInt16
        if command == Command.setNoise, noiseAvailable { read = Command.noise }
        else if command == Command.setEQ, eqAvailable { read = Command.equalizer }
        else { return false }
        return (reading == nil || reading == read) && state.observedQueries.contains(read)
    }

    func setNoise(_ mode: NoiseMode) async throws -> WriteOutcome {
        let token = generation
        try await operations.acquire(); defer { operations.release() }
        try check(token)
        guard canWrite(Command.setNoise), let request = profile?.noiseWrite(mode) else { throw ProtocolError.unsupported }
        try await send(request)
        for attempt in 0..<6 {
            try check(token)
            let fresh = try await readNoise()
            try check(token)
            guard ready else { throw ProtocolError.disconnected }
            if fresh == mode { return .confirmed }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw ProtocolError.readbackMismatch
    }

    func setEQ(_ id: UInt8) async throws -> WriteOutcome {
        let token = generation
        try await operations.acquire(); defer { operations.release() }
        try check(token)
        guard canWrite(Command.setEQ), let request = profile?.eqWrite(id) else { throw ProtocolError.unsupported }
        _ = try await readEQ() // Fresh advanced-mode gate before changing a preset.
        try await send(request)
        for attempt in 0..<6 {
            try check(token)
            let fresh = try await readEQ()
            try check(token)
            guard ready else { throw ProtocolError.disconnected }
            if fresh == id { return .confirmed }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(150)) }
        }
        throw ProtocolError.readbackMismatch
    }

    func close() {
        ready = false; connected = false; generation = UUID(); sequence = 0
        poll?.cancel(); poll = nil; channel.close(); state = DeviceState()
        advancedEQ = nil; noiseAvailable = false; eqAvailable = false; onChange?()
    }
}
