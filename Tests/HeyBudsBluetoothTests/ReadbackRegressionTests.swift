import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@Test @MainActor func truncatedOppoReadbackNeverConfirmsCachedValue() async throws {
    let radio=MockTransport()
    let s=DeviceSession(transport:radio,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    defer { s.close() };try await s.open()
    radio.handler={ frame in
        switch frame.command {
        case Command.noise:return [0,1,1,0x10,0]
        case Command.equalizer,Command.spatial,Command.gameSound:return [0,0]
        case Command.switches:return [0,1,4,1]
        default:return [0]
        }
    }
    for c in [Command.noise,Command.equalizer,Command.spatial,Command.gameSound,Command.switches] { _ = try await s.query(c) }
    radio.handler={ _ in [0] }
    let writes:[() async throws -> WriteOutcome]=[
        { try await s.setNoise(.deep) },{ try await s.setEQ(0) },
        { try await s.setSpatial(0) },{ try await s.setGameSound(0) },
        { try await s.setFeature(FeatureDefinition("wear",4),enabled:true) }
    ]
    for write in writes {
        do { _ = try await write();Issue.record("Truncated response confirmed cached state") }
        catch { #expect(error as? ProtocolError == .invalidPayload) }
    }
    #expect(s.state.noise == .deep && s.state.eq == 0 && s.state.switches[4] == true)
}

@Test @MainActor func unknownNoiseMaskCannotConfirmCachedMode() async throws {
    let radio=MockTransport()
    let session=DeviceSession(transport:radio,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    defer { session.close() };try await session.open();_ = try await session.query(Command.noise)
    radio.handler={ $0.command == Command.noise ? [0,1,1,0xFF,0xFF] : [0] }
    do { _ = try await session.setNoise(.deep);Issue.record("Unknown mask confirmed cached mode") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
}

@Test @MainActor func t500ConfirmationRequiresReportAfterWrite() async throws {
    let radio=MockTransport(),s=DeviceSession(transport:radio,name:"T500",catalog:try ModelCatalog(),overrideID:"066452",family:.oppo)
    defer { s.close() };try await s.open()
    let report=try OPOFrameCodec.encode(OPOFrame(command:0x0204,payload:[3,1,1,8]))
    radio.onEvent?(.data(report))
    #expect(s.state.noise == .deep)
    do { _ = try await s.setNoise(.deep);Issue.record("Cached T500 notification confirmed a new write") }
    catch { #expect(error as? ProtocolError == .readbackMismatch) }
    radio.handler={ frame in
        if frame.command == Command.setNoise { radio.onEvent?(.data(report)) }
        return [0]
    }
    #expect(try await s.setNoise(.deep) == .confirmed)
}

@Test @MainActor func unknownFamilyNeverOpensTransportEvenWithOverride() async throws {
    let radio=MockTransport(),s=DeviceSession(transport:radio,name:"Renamed device",catalog:try ModelCatalog(),overrideID:"06EC10")
    do { try await s.open();Issue.record("Guessed a protocol from the model override") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(!radio.active && radio.commands.isEmpty)
}
