import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor final class MockTransport:EarbudTransport {
    var onEvent:((TransportEvent) -> Void)?
    let label="Mock"
    var active=false
    var handler:((OPOFrame) -> [UInt8]?)?
    var commands:[OPOFrame]=[]
    var wrongSequence=false
    func open() async throws { active=true }
    func close() { active=false }
    func send(_ bytes:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        var codec=OPOFrameCodec()
        for frame in codec.feed(bytes) {
            commands.append(frame)
            let payload:[UInt8]?
            if let handler { payload=handler(frame) }
            else {
                switch frame.command {
                case Command.product:payload=[0,0x10,0xC4,6]
                case Command.capabilities:payload=[0]+Array(repeating:255,count:9)
                case Command.battery:payload=[0,3,1,70,2,80,3,20]
                case Command.noise:payload=[0,1,1,0x10,0]
                default:payload=[0]
                }
            }
            if let payload {
                if wrongSequence { onEvent?(.data(try OPOFrameCodec.encode(OPOFrame(command:frame.command | 0x8000,sequence:frame.sequence &+ 1,payload:[0,1,1,1,0])))) }
                onEvent?(.data(try OPOFrameCodec.encode(OPOFrame(command:frame.command | 0x8000,sequence:frame.sequence,payload:payload))))
            }
        }
    }
}
@MainActor private func opened() async throws -> (DeviceSession,MockTransport) {
    let radio=MockTransport()
    let session=DeviceSession(transport:radio,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog())
    try await session.open()
    return (session,radio)
}
@Test @MainActor func sessionReadsIdentityAndBattery() async throws {
    let (s,_)=try await opened(); defer { s.close() }
    #expect(s.ready)
    #expect(s.model?.id == "06C410")
    #expect(s.state.batteries[.left]?.percent == 70)
}
@Test @MainActor func manualRefreshReadsNewCaseBatteryWithoutWaitingForPolling() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    #expect(s.state.batteries[.enclosure]?.percent == 20)
    t.handler = { frame in
        frame.command == Command.battery ? [0,3,1,69,2,79,3,63] : [0]
    }
    let before=t.commands.count
    await s.refresh()
    #expect(s.state.batteries[.enclosure]?.percent == 63)
    #expect(s.state.batteries[.left]?.percent == 69)
    #expect(t.commands.dropFirst(before).filter { $0.command == Command.battery }.count == 1)
    s.close()
    let disconnectedCount=t.commands.count
    await s.refresh()
    #expect(t.commands.count == disconnectedCount)
}
@Test @MainActor func genericAckDoesNotConfirmNoiseChange() async throws {
    let (s,_)=try await opened(); defer { s.close() }
    _ = try await s.query(Command.noise,payload:[1,1])
    do { _ = try await s.setNoise(.off); Issue.record("ACK incorrectly confirmed a setting") }
    catch { #expect(error as? ProtocolError == .readbackMismatch) }
    #expect(s.state.noise == .deep)
}
@Test @MainActor func successfulWriteUsesReadback() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    var mode:UInt8=0x10
    t.handler = { f in
        if f.command == Command.setNoise { mode=f.payload.last == 1 ? 8 : f.payload.last!; return [0] }
        if f.command == Command.noise { return [0,1,1,mode,0] }
        return [0]
    }
    _ = try await s.query(Command.noise,payload:[1,1])
    #expect(try await s.setNoise(.off) == .confirmed)
    #expect(t.commands.suffix(2).map(\.command) == [Command.setNoise,Command.noise])
}
@Test @MainActor func timeoutAndCancellationAreBounded() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    t.handler = { _ in nil }
    do { _ = try await s.query(Command.noise,timeout:0.02); Issue.record("Missing timeout") }
    catch { #expect(error as? ProtocolError == .timeout(Command.noise)) }
    let task=Task { try await s.query(Command.noise,timeout:3) }
    try await Task.sleep(for:.milliseconds(10)); task.cancel()
    do { _ = try await task.value; Issue.record("Missing cancellation") }
    catch { #expect(error is CancellationError) }
}
@Test @MainActor func disconnectCancelsOutstandingAndQueuedRequests() async throws {
    let (s,t)=try await opened(); t.handler = { _ in nil }
    let first=Task { try await s.query(Command.noise) }
    let second=Task { try await s.query(Command.equalizer) }
    try await Task.sleep(for:.milliseconds(10)); s.close()
    for task in [first,second] {
        do { _ = try await task.value; Issue.record("Request survived disconnect") }
        catch { #expect(error as? ProtocolError == .disconnected) }
    }
    #expect(!s.ready && s.state.batteries.isEmpty)
}
@Test @MainActor func wrongSequenceReplyCannotCompleteRequest() async throws {
    let (s,t)=try await opened(); defer { s.close() }; t.wrongSequence=true
    _ = try await s.query(Command.noise,payload:[1,1])
    #expect(s.state.noise == .deep)
}
@Test @MainActor func unknownModelIsReadOnly() async throws {
    let t=MockTransport()
    t.handler = { frame in frame.command == Command.product ? [0,0xFF,0xFF,0xFF] : frame.command == Command.capabilities ? [0,255,255] : [0,1,1,50] }
    let s=DeviceSession(transport:t,name:"Unknown buds",catalog:try ModelCatalog()); defer { s.close() }
    try await s.open()
    #expect(s.model == nil)
    #expect(!s.canWrite(Command.setNoise))
}
@Test @MainActor func firmwareAndDestructiveCommandsHaveNoRawQueryAccess() async throws {
    let (s,_)=try await opened(); defer { s.close() }
    do { _ = try await s.query(0xEF01); Issue.record("Unimplemented firmware command was accepted") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    do { _ = try await s.query(Command.operateHost,payload:[3,0,0,0,0,0,0]); Issue.record("Raw host write accepted") }
    catch { #expect(error as? ProtocolError == .unsupported) }
}
@Test @MainActor func enablingGameSoundFirstDisablesConflictingSpatialSound() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    var spatial:UInt8=1, game:UInt8=0
    t.handler = { f in
        switch f.command {
        case Command.spatial:return [0,spatial]
        case Command.gameSound:return [0,game]
        case Command.setSpatial:spatial=f.payload[0]; return [0]
        case Command.setGameSound:game=f.payload[0]; return [0]
        default:return [0]
        }
    }
    _ = try await s.query(Command.spatial)
    _ = try await s.query(Command.gameSound)
    let type=try #require(s.model?.gameTypes.first)
    #expect(try await s.setGameSound(type) == .confirmed)
    let writes=t.commands.filter { $0.command == Command.setSpatial || $0.command == Command.setGameSound }
    #expect(writes.map(\.command) == [Command.setSpatial,Command.setGameSound])
    #expect(s.state.spatial == 0 && s.state.gameSound == type)
}
@Test @MainActor func registeredNotificationAndLateOldResponseAreSeparated() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    t.onEvent?(.data(try OPOFrameCodec.encode(OPOFrame(command:0x8202,payload:[0,1,1,1,42]))))
    #expect(s.state.batteries[.left]?.percent == 42)
    t.onEvent?(.data(try OPOFrameCodec.encode(OPOFrame(command:0x8106,sequence:99,payload:[0,1,1,9]))))
    #expect(s.state.batteries[.left]?.percent == 42)
}
@Test @MainActor func olderSpatialProtocolUsesReportedFeatureSwitch() async throws {
    let t=MockTransport()
    t.handler = { f in
        switch f.command {
        case Command.product:return [0,0x10,0xC4,6]
        case Command.capabilities:return [0,0x80]
        case Command.battery:return [0,1,1,50]
        case Command.switches:return [0,1,0x1B,1]
        default:return [0]
        }
    }
    let s=DeviceSession(transport:t,name:"OPPO Enco Air5 Pro",catalog:try ModelCatalog()); defer { s.close() }
    try await s.open()
    _ = try await s.query(Command.switches,payload:FeatureCodec.switchQuery(model:s.model))
    #expect(!s.supportsSpatialAudio)
    #expect(s.availableFeatures.contains(FeatureDefinition("spatialSound",0x1B)))
    #expect(s.canWrite(Command.setSwitch,reading:Command.switches))
    #expect(FeatureCodec.switchQuery(model:s.model).contains(0x1B))
}
@Test @MainActor func gameSoundResetsConflictingEqualizerBeforeActivation() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    var eq:UInt8=2, game:UInt8=0
    t.handler = { f in
        switch f.command {
        case Command.equalizer:return [0,eq]
        case Command.gameSound:return [0,game]
        case Command.setEQ:eq=f.payload[0];return [0]
        case Command.setGameSound:game=f.payload[0];return [0]
        default:return [0]
        }
    }
    _ = try await s.query(Command.equalizer)
    _ = try await s.query(Command.gameSound)
    let type=try #require(s.model?.gameTypes.first)
    #expect(try await s.setGameSound(type) == .confirmed)
    let writes=t.commands.filter { $0.command == Command.setEQ || $0.command == Command.setGameSound }
    #expect(writes.map(\.command) == [Command.setEQ,Command.setGameSound])
    #expect(s.state.eq == 0 && s.state.gameSound == type)
}
@Test @MainActor func publicOperationsRejectInventedSwitchesAndPresetSlots() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    t.handler = { f in
        if f.command == Command.switches { return [0,1,4,1] }
        if f.command == Command.customEQ { return [0,0] }
        return [0]
    }
    _ = try await s.query(Command.switches)
    _ = try await s.query(Command.customEQ)
    do { _ = try await s.setFeature(FeatureDefinition("game",4),enabled:false); Issue.record("Invented switch accepted") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    let frequencies=try #require(s.model?.customEQFrequencies)
    let entry=CustomEQEntry(id:99,name:"Unknown",frequencies:frequencies,gains:Array(repeating:0,count:frequencies.count))
    do { _ = try await s.saveEQ(entry); Issue.record("Unknown preset slot accepted") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(!t.commands.contains(where:{$0.command == Command.setSwitch || $0.command == Command.setCustomEQ}))
}

@Test @MainActor func hostConnectionWaitsForSettledReadbackAndWritesCanonicalAddressOnce() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    let wire:[UInt8]=[1,2,3,4,5,6]
    var wrote=false, readsAfterWrite=0
    t.handler = { f in
        if f.command == Command.operateHost { wrote=true; return [0] }
        if f.command == Command.priority { return [0,1,0] }
        if f.command == Command.hosts {
            if wrote { readsAfterWrite += 1 }
            return [0,1]+wire+[0,wrote && readsAfterWrite >= 3 ? 2 : 1,0,0]
        }
        return [0]
    }
    _ = try await s.query(Command.hosts)
    let host=try #require(s.state.hosts.first)
    #expect(try await s.operateHost(.connect,host:host) == .confirmed)
    let writes=t.commands.filter {$0.command == Command.operateHost}
    #expect(writes.count == 1 && writes.first?.payload == [1]+Array(wire.reversed()))
    #expect(readsAfterWrite == 3 && s.state.hosts.first?.connected == true)
}

@Test @MainActor func hostPriorityAndAutomaticModesUseVerifiedReadback() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    let wire:[UInt8]=[1,2,3,4,5,6]
    var automatic=true
    t.handler = { f in
        switch f.command {
        case Command.hosts:return [0,1]+wire+[0,2,0,0]
        case Command.priority:return automatic ? [1,0] : [2,1]+wire
        case Command.operateHost:automatic=f.payload == [4,0]; return [0]
        default:return [0]
        }
    }
    _ = try await s.query(Command.hosts)
    _ = try await s.query(Command.priority)
    let host=try #require(s.state.hosts.first)
    #expect(try await s.operateHost(.priority,host:host) == .confirmed)
    #expect(s.state.priorityAddress == host.address && s.state.automaticPriority == false)
    #expect(try await s.operateHost(.automatic) == .confirmed)
    #expect(s.state.automaticPriority == true)
    #expect(t.commands.filter {$0.command == Command.operateHost}.map(\.payload) == [[4,1]+Array(wire.reversed()),[4,0]])
}

@Test @MainActor func hostAvailabilityUsesLatestStateAndProtectsCurrentMac() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    var connected=true
    t.handler = { f in
        if f.command == Command.priority { return [0,1,0] }
        if f.command == Command.hosts { return [0,2,1,2,3,4,5,6,0,2,1,0,7,8,9,10,11,12,0,connected ? 2 : 1,0,0] }
        return [0]
    }
    _ = try await s.query(Command.hosts)
    let current=s.state.hosts[0], remote=s.state.hosts[1]
    #expect(!s.canOperateHost(.disconnect,host:current))
    #expect(!s.canOperateHost(.connect,host:current))
    #expect(s.canOperateHost(.disconnect,host:remote))
    #expect(!s.canOperateHost(.priority,host:remote))
    _ = try await s.query(Command.priority)
    #expect(s.canOperateHost(.priority,host:remote))
    connected=false
    _ = try await s.query(Command.hosts)
    #expect(!s.canOperateHost(.disconnect,host:remote))
    #expect(s.canOperateHost(.connect,host:remote))
    do { _ = try await s.operateHost(.disconnect,host:current); Issue.record("Current host was disconnected") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(!t.commands.contains {$0.command == Command.operateHost})
}

@Test @MainActor func hostRefusalAndUnchangedReadbackNeverReportSuccess() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    let wire:[UInt8]=[1,2,3,4,5,6]
    var refuse=true
    t.handler = { f in
        if f.command == Command.hosts { return [0,1]+wire+[0,1,0,0] }
        if f.command == Command.operateHost { return refuse ? [5] : [0] }
        return [0]
    }
    _ = try await s.query(Command.hosts)
    let host=try #require(s.state.hosts.first)
    do { _ = try await s.operateHost(.connect,host:host); Issue.record("Refusal accepted") }
    catch { #expect(error as? ProtocolError == .rejected(5)) }
    refuse=false
    do { _ = try await s.operateHost(.connect,host:host); Issue.record("Unchanged state accepted") }
    catch { #expect(error as? ProtocolError == .readbackMismatch) }
    #expect(t.commands.filter {$0.command == Command.operateHost}.count == 2)
}

@Test @MainActor func cancellingHostReadbackDoesNotRepeatWrite() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    t.handler = { f in f.command == Command.hosts ? [0,1,1,2,3,4,5,6,0,1,0,0] : [0] }
    _ = try await s.query(Command.hosts)
    let host=try #require(s.state.hosts.first)
    let task=Task { try await s.operateHost(.connect,host:host) }
    try await Task.sleep(for:.milliseconds(20)); task.cancel()
    do { _ = try await task.value; Issue.record("Cancellation ignored") }
    catch { #expect(error is CancellationError) }
    #expect(t.commands.filter {$0.command == Command.operateHost}.count == 1)
}

@Test @MainActor func hearingControlAvailabilityMatchesItsDedicatedCapabilityRequirements() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    t.handler = { f in f.command == Command.capabilities ? [0,0x80] : f.command == Command.switches ? [0,1,0x0B,0] : [0] }
    _ = try await s.query(Command.capabilities)
    _ = try await s.query(Command.switches)
    let hearing=FeatureDefinition("hearing",0x0B)
    #expect(!s.canSetFeature(hearing))
    do { _ = try await s.setFeature(hearing,enabled:true); Issue.record("Incomplete hearing capabilities accepted") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(!t.commands.contains {$0.command == Command.setSwitch})
}

@Test @MainActor func malformedPriorityReadbackCannotConfirmCachedAutomaticState() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    var wrote=false
    t.handler = { f in
        if f.command == Command.priority { return wrote ? [0,1,1] : [0,1,0] }
        if f.command == Command.operateHost { wrote=true }
        return [0]
    }
    _ = try await s.query(Command.priority)
    do { _ = try await s.operateHost(.automatic); Issue.record("Malformed reply confirmed cached priority") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
}

@Test @MainActor func disconnectCanBeConfirmedWhenCompleteListDropsTheHost() async throws {
    let (s,t)=try await opened(); defer { s.close() }
    var wrote=false
    t.handler = { f in
        if f.command == Command.hosts { return wrote ? [0,0] : [0,1,1,2,3,4,5,6,0,2,0,0] }
        if f.command == Command.operateHost { wrote=true }
        if f.command == Command.priority { return [0,1,0] }
        return [0]
    }
    _ = try await s.query(Command.hosts)
    let host=try #require(s.state.hosts.first)
    #expect(try await s.operateHost(.disconnect,host:host) == .confirmed)
    #expect(s.state.hosts.isEmpty)
}
