import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor private final class BoseTestTransport: EarbudTransport {
    var onEvent: ((TransportEvent) -> Void)?
    let label="Bose synthetic transport"
    let profile: BoseProfile
    var active=false
    var commands: [BoseFrame]=[]
    var current: UInt8=0
    var level: UInt8=0
    var battery: [UInt8]
    var modes: [UInt8:[UInt8]]=[:]
    var live: [UInt8]=[0,0,2,0,1]
    var ignoreModeWrite=false
    var malformedReadback=false
    var ackOnlyReadback=false
    var omitStartResult=false
    var hasWrittenMode=false
    var withheld: ((BoseFrame) -> Bool)?
    var sendError: Error?
    var modeCounts: [UInt8]?
    init(_ profile: BoseProfile) {
        self.profile=profile
        battery=profile == .ultraEarbuds2 ? [19,255,255,1,72,255,255,2,40,255,255,3,19,255,255,4] : [80,255,255,0]
        for i in 0..<profile.maximumModeCount {
            var p=[UInt8](repeating:0,count:profile.modeStatusLength)
            p[0]=UInt8(i); p[2]=i < 2 ? UInt8(i+1) : 12
            p[3]=i < (profile == .qc45 ? 2 : 4) ? 0 : 1; p[4]=p[3]; p[5]=1
            let name=Array((i == 0 ? "Quiet" : i == 1 ? "Aware" : "Custom").utf8)
            p.replaceSubrange(6..<(6+name.count),with:name); p[42]=i == 1 ? 10 : 0
            if profile.hasLiveCNC { p[47]=1 }
            modes[UInt8(i)]=p
        }
    }
    func open() async throws { active=true }
    func close() { active=false }
    func emit(_ frame: BoseFrame) throws { onEvent?(.data(try BoseFrameCodec.encode(frame))) }
    func send(_ data: Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        var decoder=BoseFrameCodec()
        let frame=try #require(decoder.feed(data).first)
        commands.append(frame)
        if let sendError { throw sendError }
        if withheld?(frame) == true { return }
        let reply: BoseFrame
        switch (frame.block,frame.function,frame.operation) {
        case (0,1,.get): reply=BoseFrame(0,1,.status,[1,0,0])
        case (0,5,.get): reply=BoseFrame(0,5,.status,Array("8.2.20+test".utf8))
        case (2,2,.get): reply=BoseFrame(2,2,.status,battery)
        case (31,8,.get): reply=BoseFrame(31,8,.status,modeCounts ?? [UInt8(profile.maximumModeCount),0,3])
        case (31,6,.get): reply=BoseFrame(31,6,.status,frame.payload.first.flatMap { modes[$0] } ?? [])
        case (31,3,.get):
            if hasWrittenMode, ackOnlyReadback { reply=BoseFrame(31,3,.result,[current]) }
            else { reply=BoseFrame(31,3,.status,hasWrittenMode && malformedReadback ? [] : [current]) }
        case (31,3,.start):
            hasWrittenMode=true
            if !ignoreModeWrite { current=frame.payload[0]; level=current == 1 ? 10 : 0; live[0]=level }
            // Device can push STATUS before RESULT; a session must still wait
            // for RESULT and follow with an explicit GET.
            try emit(BoseFrame(31,3,.status,[current]))
            if omitStartResult { return }
            reply=BoseFrame(31,3,.result,[current])
        case (1,5,.get): reply=BoseFrame(1,5,.status,[11,level,3])
        case (31,10,.get): reply=BoseFrame(31,10,.status,live)
        case (31,10,.setGet):
            live=frame.payload; level=live[0]; reply=BoseFrame(31,10,.status,live)
        case (31,6,.setGet):
            let index=frame.payload[0]
            if profile == .qc45,frame.payload.count == 39 {
                modes[index]?[42]=frame.payload[35]; level=frame.payload[35]
            }
            // Short echo is not a full fresh config.
            reply=BoseFrame(31,6,.status,frame.payload)
        default: reply=BoseFrame(frame.block,frame.function,.error,[4])
        }
        try emit(reply)
    }
}

@Test @MainActor func boseSessionKeepsEarbudSidesUnassignedAndClearsSentinels() async throws {
    let radio=BoseTestTransport(.ultraEarbuds2)
    let session=BoseSession(transport:radio,profile:.ultraEarbuds2,timeout:0.1)
    defer { session.close() }
    try await session.open()
    #expect(session.ready && session.canWrite(Command.setNoise))
    #expect(session.state.batteries[.left] == nil && session.state.batteries[.right] == nil)
    #expect(session.state.unassignedBatteries[1]?.percent == 19)
    #expect(session.state.unassignedBatteries[2]?.percent == 72)
    #expect(session.state.batteries[.enclosure]?.percent == 40)
    #expect(session.batteryComponents[4]?.percent == 19)
    radio.battery=[255,255,255,1,0,255,255,2]
    await session.refresh()
    #expect(session.state.unassignedBatteries[1] == nil)
    #expect(session.state.unassignedBatteries[2]?.percent == 0)
    #expect(session.state.batteries[.enclosure] == nil)
    #expect(!session.canQuery(Command.equalizer) && !session.canWrite(Command.setEQ))
    await #expect(throws:ProtocolError.unsupported) { try await session.setEQ(0) }
    await #expect(throws:ProtocolError.unsupported) { try await session.setNoise(.off) }
    #expect(!radio.commands.contains { $0.block == 1 && $0.function == 7 })
}

@Test @MainActor func boseModeWriteWaitsForResultThenFreshReadback() async throws {
    let radio=BoseTestTransport(.ultraHeadphones2)
    let session=BoseSession(transport:radio,profile:.ultraHeadphones2,timeout:0.1)
    defer { session.close() }; try await session.open()
    #expect(try await session.setNoise(.transparency) == .confirmed)
    #expect(session.state.noise == .transparency)
    let writeIndex=try #require(radio.commands.lastIndex { $0.operation == .start })
    #expect(radio.commands[writeIndex].payload == [1,0])
    #expect(radio.commands[writeIndex+1] == BoseFrame(31,3))
}

@Test @MainActor func boseACKOrMalformedReplyCannotConfirmCachedMode() async throws {
    for ackOnly in [false,true] {
        let radio=BoseTestTransport(.ultraHeadphones2)
        let session=BoseSession(transport:radio,profile:.ultraHeadphones2,timeout:0.04)
        try await session.open()
        radio.malformedReadback = !ackOnly; radio.ackOnlyReadback=ackOnly
        do { _ = try await session.setNoise(.anc); Issue.record("ACK/cache confirmed a write") }
        catch {
            if ackOnly { #expect(error as? ProtocolError == .timeout(0)); #expect(!session.ready) }
            else { #expect(error as? ProtocolError == .invalidPayload) }
        }
        session.close()
    }
}

@Test @MainActor func bosePushWithoutResultCannotCompleteStart() async throws {
    let radio=BoseTestTransport(.ultraEarbuds2)
    let session=BoseSession(transport:radio,profile:.ultraEarbuds2,timeout:0.04)
    defer { session.close() }; try await session.open(); radio.omitStartResult=true
    await #expect(throws:ProtocolError.timeout(0)) { try await session.setNoise(.transparency) }
    #expect(!session.ready)
}

@Test @MainActor func boseCNCUsesProfileSpecificWriteAndDoubleReadback() async throws {
    for profile in [BoseProfile.qc45,.ultraHeadphones2,.ultraEarbuds2] {
        let radio=BoseTestTransport(profile)
        radio.current=profile == .qc45 ? 2 : 0
        let session=BoseSession(transport:radio,profile:profile,timeout:0.1)
        defer { session.close() }; try await session.open()
        #expect(session.canSetCNC)
        #expect(try await session.setCNC(7) == .confirmed)
        #expect(session.cnc?.level == 7)
        let command=try #require(radio.commands.first { $0.operation == .setGet })
        #expect(command.block == 31)
        if profile == .qc45 {
            #expect(command.function == 6 && command.payload.count == 39)
            #expect(command.payload[0] == 2 && command.payload[35] == 7)
            #expect(radio.commands.first == BoseFrame(0,1))
            #expect(!radio.commands.contains { $0.matches(31,10) })
        } else { #expect(command.function == 10 && command.payload == [7,0,2,0,1]) }
        #expect(!radio.commands.contains { $0.block == 1 && $0.function == 5 && $0.operation != .get })
    }
}

@Test @MainActor func boseUnsafeCNCAndUnknownModesArePreserved() async throws {
    let radio=BoseTestTransport(.ultraHeadphones2)
    radio.current=9; radio.live=[5,1,0,0,1]
    let session=BoseSession(transport:radio,profile:.ultraHeadphones2,timeout:0.1)
    defer { session.close() }; try await session.open()
    #expect(session.currentModeIndex == 9 && session.state.noise == nil)
    #expect(session.audioSettings?.autoCNC == 1 && !session.canSetCNC)
    await #expect(throws:ProtocolError.unsupported) { try await session.setCNC(5) }
    #expect(!radio.commands.contains { $0.operation == .setGet })
}

@Test @MainActor func boseWrongLayoutDisablesWritesWithoutFabricatingQuiet() async throws {
    let radio=BoseTestTransport(.ultraHeadphones2)
    radio.modes[0]=Array(radio.modes[0]!.dropLast())
    let session=BoseSession(transport:radio,profile:.ultraHeadphones2,timeout:0.1)
    defer { session.close() }; try await session.open()
    #expect(session.ready && session.state.batteries[.left]?.percent == 80)
    #expect(session.state.noise == nil && !session.canWrite(Command.setNoise))
    #expect(session.unknownModePayloads[0]?.count == 47)
    #expect(!session.canSetCNC)
}

@Test @MainActor func boseCloseAndCancellationRetireGenerations() async throws {
    let radio=BoseTestTransport(.ultraHeadphones2)
    let session=BoseSession(transport:radio,profile:.ultraHeadphones2,timeout:1)
    try await session.open()
    let oldCallback=radio.onEvent
    radio.withheld={ $0.matches(31,3) && $0.operation == .start }
    let task=Task { try await session.setNoise(.transparency) }
    for _ in 0..<100 {
        if radio.commands.contains(where:{$0.operation == .start}) { break }
        await Task.yield()
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled Bose command completed") } catch { }
    #expect(!session.ready)
    radio.withheld=nil; try await session.open()
    oldCallback?(.data(try BoseFrameCodec.encode(BoseFrame(31,3,.status,[1]))))
    #expect(session.state.noise == .anc)
    session.close()
    #expect(session.state.batteries.isEmpty && session.state.unassignedBatteries.isEmpty)
    #expect(session.cnc == nil && session.currentModeIndex == nil && session.modes.isEmpty)
}
