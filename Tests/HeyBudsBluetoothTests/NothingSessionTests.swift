import Foundation
import Testing
@testable import HeyBudsBluetooth
@testable import HeyBudsProtocol

/// All frames here are synthetic. This transport never opens a Bluetooth API.
@MainActor private final class NothingRadio: EarbudTransport {
    struct Request {
        var command: UInt16
        var sequence: UInt8
        var payload: [UInt8]
    }
    var onEvent: ((TransportEvent) -> Void)?
    let label = "Synthetic Nothing RFCOMM"
    let name: String
    var active = false
    var opened = 0
    var requests: [Request] = []
    var noise: UInt8 = 5
    var eq: UInt8 = 0
    var firmware = "1.0.1.50"
    var advanced: UInt8 = 0
    var applyWrites = true
    var missing: Set<UInt16> = []
    var wrongSequence = false
    var sendDelay: Duration = .zero
    var failAfterReply = false
    var collided = false
    private var sending = false
    var beforeResponse: ((Request) -> Void)?
    var replacement: ((Request) -> [UInt8]?)?
    var serialOverride: String?

    init(_ name: String = "Nothing Ear (a)") { self.name = name }
    func open() async throws { active = true; opened += 1 }
    func close() { active = false }
    static func crc(_ bytes: [UInt8]) -> UInt16 {
        var value: UInt16 = 0xFFFF
        for byte in bytes {
            value ^= UInt16(byte)
            for _ in 0..<8 { value = (value & 1 == 1) ? (value >> 1) ^ 0xA001 : value >> 1 }
        }
        return value
    }
    func emit(command: UInt16, sequence: UInt8, payload: [UInt8]) {
        var bytes: [UInt8] = [0x55,0x60,1,UInt8(truncatingIfNeeded:command),UInt8(command >> 8),
                              UInt8(truncatingIfNeeded:payload.count),UInt8(payload.count >> 8),sequence] + payload
        let crc = Self.crc(name == "CMF Buds Pro 2" ? payload : bytes)
        bytes += [UInt8(truncatingIfNeeded:crc),UInt8(crc >> 8)]
        onEvent?(.data(Data(bytes)))
    }
    func send(_ bytes: Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        if sending { collided = true; throw ProtocolError.invalidPayload }
        sending = true; defer { sending = false }
        let b = Array(bytes)
        guard b.count >= 10, b[0...2] == [0x55,0x60,1] else { throw ProtocolError.invalidPayload }
        let count = Int(b[5]) | Int(b[6]) << 8
        guard b.count == count + 10 else { throw ProtocolError.invalidPayload }
        #expect(Self.crc(Array(b.dropLast(2))) == UInt16(b[b.count-2]) | UInt16(b[b.count-1]) << 8)
        let request = Request(command:UInt16(b[3]) | UInt16(b[4]) << 8,
                              sequence:b[7],payload:Array(b[8..<(8+count)]))
        requests.append(request)
        beforeResponse?(request)
        if request.command == 0xF00F {
            if applyWrites { noise = request.payload[1] }
            // Generic success deliberately arrives before the readback.
            emit(command:0x7004,sequence:request.sequence,payload:[0])
        } else if [UInt16(0xF010),0xF01D].contains(request.command) {
            if applyWrites { eq = request.payload[0] }
            emit(command:0x7004,sequence:request.sequence,payload:[0])
        } else if !missing.contains(request.command) {
            let payload = replacement?(request) ?? defaultPayload(request)
            if let payload {
                emit(command:request.command & 0x7FFF,
                     sequence:wrongSequence ? request.sequence &+ 1 : request.sequence,payload:payload)
            }
        }
        if sendDelay != .zero { try await Task.sleep(for:sendDelay) }
        if failAfterReply { throw ProtocolError.disconnected }
    }
    func defaultPayload(_ request: Request) -> [UInt8]? {
        switch request.command {
        case 0xC01C: return Array("B172".utf8)
        case 0xC006:
            let serials = ["Nothing Ear (a)":"SH0063TEST0000", "Nothing Headphone (1)":"M3A603TEST0000",
                           "CMF Buds 2":"SH0099TEST0000", "CMF Buds Pro 2":"SH0076TEST0000"]
            return Array(("1,4," + (serialOverride ?? serials[name] ?? "UNKNOWN") + "\n").utf8)
        case 0xC042: return Array(firmware.utf8)
        case 0xC007: return name == "Nothing Headphone (1)" ? [0,0,88] : [3,2,80,3,70,4,0xFF]
        case 0xC01E: return name == "CMF Buds Pro 2" ? [2,1,0,1,noise,0] : [0,noise]
        case 0xC01F,0xC050: return [eq]
        case 0xC04C: return [advanced]
        default: return nil
        }
    }
}

@Test @MainActor func nothingFourProfilesReadFreshStateAndWriteVerifiedModes() async throws {
    for name in ["Nothing Ear (a)","Nothing Headphone (1)","CMF Buds 2","CMF Buds Pro 2"] {
        let radio = NothingRadio(name)
        let session = NothingSession(transport:radio,name:name,catalog:try ModelCatalog(),timeout:0.05)
        defer { session.close() }
        try await session.open()
        #expect(session.ready && session.model?.id == NothingProfile.named(name)?.modelID)
        #expect(session.state.batteries[.enclosure] == nil)
        #expect(session.state.batteries.count == (name == "Nothing Headphone (1)" ? 1 : 2))
        #expect(session.canWrite(Command.setNoise))
        #expect(try await session.setNoise(.transparency) == .confirmed)
        #expect(try await session.setEQ(3) == .confirmed)
        #expect(!session.canWrite(Command.setEQ,reading:Command.noise))
        #expect(!session.canQuery(Command.spatial) && !session.canWrite(Command.setBass))
        #expect(!radio.collided)
        let noiseRead = try #require(radio.requests.first { $0.command == 0xC01E })
        #expect(noiseRead.payload == (name == "CMF Buds Pro 2" ? [3] : []))
        #expect(radio.requests.contains { $0.command == (name.hasPrefix("CMF") ? 0xF01D : 0xF010) && $0.payload == [3,0] })
    }
}

@Test @MainActor func nothingExactNamesAndIdentityMismatchFailBeforeControls() async throws {
    for name in ["Nothing Ear (a) Pro", "CMF Buds 2a", "CMF Buds Pro 2 renamed", "Samsung Nothing Ear (a)"] {
        let radio = NothingRadio(name)
        let session = NothingSession(transport:radio,name:name,catalog:try ModelCatalog(),timeout:0.02)
        do { try await session.open(); Issue.record("Unlisted profile accepted") } catch { }
        #expect(radio.opened == 0 && radio.requests.isEmpty)
    }
    let radio = NothingRadio(); radio.serialOverride = "M3A603TEST0000"
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.02)
    do { try await session.open(); Issue.record("Conflicting device identity accepted") } catch { }
    #expect(!session.ready && !radio.active && radio.requests.map(\.command) == [0xC006])
}

@Test @MainActor func nothingACKCacheAndUnsolicitedEventsNeverConfirmWrites() async throws {
    let radio = NothingRadio()
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.03)
    defer { session.close() }; try await session.open()
    radio.applyWrites = false
    radio.beforeResponse = { request in
        if request.command == 0xC01E { radio.emit(command:0xE003,sequence:request.sequence,payload:[0,7]) }
    }
    do { _ = try await session.setNoise(.transparency); Issue.record("ACK or notification confirmed rejected write") }
    catch { #expect(error as? ProtocolError == .readbackMismatch) }
    #expect(session.state.noise == .off)
    radio.beforeResponse = nil
    radio.missing = [0xC01E]
    do { _ = try await session.setNoise(.off); Issue.record("Cached target confirmed absent response") } catch { }
    #expect(!session.ready && !radio.active)
}

@Test @MainActor func nothingCMF2FirmwareAndHeadphoneAdvancedModeGateOnlyEQ() async throws {
    for firmware in ["1.0.1.49","unknown","1.0.1.50"] {
        let radio = NothingRadio("CMF Buds 2"); radio.firmware = firmware
        let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.02)
        defer { session.close() }; try await session.open()
        #expect(session.canWrite(Command.setNoise))
        #expect(session.canWrite(Command.setEQ) == (firmware == "1.0.1.50"))
        if firmware != "1.0.1.50" { #expect(!radio.requests.contains { $0.command == 0xC050 }) }
    }
    let radio = NothingRadio("Nothing Headphone (1)")
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.02)
    defer { session.close() }; try await session.open()
    radio.advanced = 1
    do { _ = try await session.setEQ(3); Issue.record("Active advanced mode allowed preset write") } catch { }
    #expect(!radio.requests.contains { $0.command == 0xF010 || $0.command == 0xF04F })
    #expect(!session.canWrite(Command.setEQ) && session.canWrite(Command.setNoise))
}

@Test @MainActor func nothingMissingOptionalEQDoesNotLoseBatteryAndNoise() async throws {
    let radio = NothingRadio(); radio.missing = [0xC01F]
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.02)
    defer { session.close() }; try await session.open()
    #expect(session.ready && session.canWrite(Command.setNoise) && !session.canWrite(Command.setEQ))
    #expect(try await session.setNoise(.transparency) == .confirmed)
}

@Test @MainActor func nothingWrongSequenceAndLateTransportFailureCannotCompleteOpen() async throws {
    for scenario in 0..<3 {
        let radio = NothingRadio()
        radio.wrongSequence = scenario == 0
        radio.failAfterReply = scenario == 1
        if scenario == 2 { radio.sendDelay = .seconds(10) }
        let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.03)
        do { try await session.open(); Issue.record("Incomplete exchange succeeded") } catch { }
        #expect(!session.ready && !radio.active && radio.requests.count == 1)
    }
}

@Test @MainActor func nothingGenerationAndOperationQueueProtectReconnection() async throws {
    let radio = NothingRadio()
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.04)
    defer { session.close() }; try await session.open()
    let oldReceiver = radio.onEvent
    radio.sendDelay = .milliseconds(2)
    async let first = session.setNoise(.transparency)
    async let second = session.setEQ(3)
    #expect(try await first == .confirmed); #expect(try await second == .confirmed)
    #expect(!radio.collided)
    radio.sendDelay = .zero
    let count = radio.requests.count
    radio.missing = [0xC007]
    let refresh = Task { await session.refresh() }
    let queued = Task { try await session.setEQ(2) }
    while radio.requests.count == count { await Task.yield() }
    session.close(); await refresh.value
    do { _ = try await queued.value; Issue.record("Queued old-generation operation survived close") } catch { }
    radio.missing = []; try await session.open()
    oldReceiver?(.closed("Old channel"))
    #expect(session.ready && radio.active)
}

@Test @MainActor func nothingCancelledWriteCannotBecomeConfirmedFromEarlyReply() async throws {
    let radio = NothingRadio()
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.1)
    defer { session.close() }; try await session.open()
    radio.sendDelay = .seconds(10)
    let count = radio.requests.count
    let write = Task { try await session.setNoise(.transparency) }
    while radio.requests.count == count { await Task.yield() }
    write.cancel()
    do { _ = try await write.value; Issue.record("Cancelled write confirmed") } catch { }
    #expect(!session.ready && !radio.active)
}

@Test @MainActor func nothingMalformedReadbackAndCloseDuringNotificationNeverConfirm() async throws {
    let radio = NothingRadio()
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.05)
    defer { session.close() }; try await session.open()
    radio.replacement = { $0.command == 0xC01E ? [0] : nil }
    do { _ = try await session.setNoise(.transparency); Issue.record("Malformed setting confirmed") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(session.state.noise == nil && !session.canWrite(Command.setNoise))
    radio.replacement = nil; await session.refresh()
    session.onChange = { if session.state.noise == .off { session.close() } }
    do { _ = try await session.setNoise(.off); Issue.record("Closed generation confirmed") }
    catch { #expect(error as? ProtocolError == .disconnected) }
    #expect(!session.ready)
}

@Test @MainActor func nothingSequenceNeverWrapsWithinConnection() async throws {
    let radio = NothingRadio()
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.05)
    defer { session.close() }; try await session.open()
    for _ in 0..<90 { await session.refresh() }
    #expect(!session.ready && !radio.active)
    #expect(radio.requests.count == 250)
    #expect(Set(radio.requests.map(\.sequence)).count == 250)
}

@Test @MainActor func nothingTruncatedOptionalReplyCannotPoisonFollowingQueries() async throws {
    let radio = NothingRadio(); radio.missing = [0xC042]
    radio.beforeResponse = { request in
        if request.command == 0xC042 {
            radio.onEvent?(.data(Data([0x55,0x60,1,0x42,0x40,100,0,request.sequence])))
        }
    }
    let session = NothingSession(transport:radio,name:radio.name,catalog:try ModelCatalog(),timeout:0.03)
    defer { session.close() }; try await session.open()
    #expect(session.ready && session.state.firmware == nil && session.canWrite(Command.setNoise))
    #expect(try await session.setNoise(.transparency) == .confirmed)
}
