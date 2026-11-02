import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor private final class XiaomiRadio:EarbudTransport {
    var onEvent:((TransportEvent) -> Void)?
    let label="Mock Xiaomi MMA"
    let profile:XiaomiProfile
    var codec=XiaomiFrameCodec()
    var active=false,applyWrites=true,corruptIdentity=false,corruptReadback=false,wrongTarget=false
    var corruptOtherGesture=false,wrongAuthentication=false,holdAuthentication=false
    var commands:[XiaomiFrame]=[]
    var config:[UInt16:[UInt8]]=[11:[1,19],7:[0],4:[1],47:[0],12:[0],29:[5],2:[4,8,1,1,2,3,2,3,2,3,0,6,99,200,201]]
    var wear=true
    init(_ profile:XiaomiProfile) {
        self.profile=profile
        var eq:[UInt8]=[1,10,6,6,1,0,10]
        for f in XiaomiProtocol.frequencies { eq += [UInt8(f >> 8),UInt8(truncatingIfNeeded:f),0] }
        config[55]=eq
    }
    func open() async throws { active=true }
    func close() { active=false }
    func emit(_ frame:XiaomiFrame) throws { onEvent?(.data(try XiaomiFrameCodec.encode(frame))) }
    func send(_ data:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        for frame in codec.feed(data) {
            commands.append(frame)
            if !frame.isRequest {
                if frame.opcode == 0x50 { try emit(XiaomiFrame(type:0xC0,opcode:0x51,sequence:202,payload:[1,0])) }
                continue
            }
            switch frame.opcode {
            case 0x50:
                if holdAuthentication { continue }
                let answer=wrongAuthentication ? Array(repeating:UInt8(0),count:16) : try XiaomiMMAAuth.response(Array(frame.payload.dropFirst()))
                try emit(frame.reply([1]+answer,type:frame.type & 7))
            case 0x51:
                try emit(frame.reply([1],type:frame.type & 7))
                try emit(XiaomiFrame(type:0xC0,opcode:0x50,sequence:201,payload:[1]+Array(repeating:7,count:16)))
            case 2:
                let pid=corruptIdentity ? UInt16(0xFFFF) : profile.productIDs.sorted().first ?? 0x50F8
                let payload:[UInt8]=[5,3,0x27,0x17,UInt8(pid >> 8),UInt8(truncatingIfNeeded:pid),5,1,0x12,0x37,0x12,0x37,4,7,0xE4,90,255]
                try emit(frame.reply(payload,type:wrongTarget ? 4 : frame.type & 7))
            case 9:
                try emit(frame.reply([2,10,wear ? 0 : 1],type:frame.type & 7))
            case 0xF3:
                guard frame.payload.count == 2 else { throw ProtocolError.invalidPayload }
                let id=UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
                if let value=config[id] {
                    let payload=corruptReadback ? [UInt8(10),0,UInt8(truncatingIfNeeded:id),0] : try XiaomiProtocol.config(id,value)
                    try emit(frame.reply(payload,type:frame.type & 7))
                } else { try emit(frame.reply(type:frame.type & 7,status:9)) }
            case 8:
                if applyWrites,frame.payload.count == 3 {
                    if frame.payload[1] == 4 {
                        config[11]=[frame.payload[2],19]
                        if profile == .redmi6lite { try emit(XiaomiFrame(type:0xC7,opcode:0xF4,sequence:101,payload:XiaomiProtocol.config(11,config[11]!))) }
                    } else if frame.payload[1] == 6 { wear=frame.payload[2] == 0 }
                }
                try emit(frame.reply(type:frame.type & 7))
            case 0xF2:
                guard let records=XiaomiProtocol.records(frame.payload,idBytes:2) else { throw ProtocolError.invalidPayload }
                if applyWrites {
                    for (id,value) in records {
                        if id == 2,let old=config[2],var rows=XiaomiProtocol.gestures(old),value.count == 3,var pair=rows[value[0]] {
                            for i in 0..<2 where value[i+1] != 255 { pair[i]=value[i+1] }
                            if corruptOtherGesture { pair[1] &+= 1 }
                            rows[value[0]]=pair
                            config[id]=rows.sorted { $0.key < $1.key }.flatMap { [$0.key]+$0.value }
                        } else if id == 55 {
                            var reply=value;reply[2]=6;reply[3]=6;config[id]=reply
                        } else { config[id]=value }
                    }
                }
                try emit(frame.reply(type:frame.type & 7))
            default:throw ProtocolError.unsupported
            }
        }
    }
}

@Test @MainActor func xiaomiExplicitProfileRoutesToNewSessionAndUsesCapturedState() async throws {
    let radio=XiaomiRadio(.redmi8pro),session=DeviceSession(transport:radio,name:"REDMI Buds 8 Pro",catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.initialize()
    #expect(session.model?.id == "xiaomi:redmi8pro" && session.ready)
    #expect(session.state.firmware == "1.2.3.7" && session.state.batteries[.left]?.charging == true)
    #expect(session.state.batteries[.enclosure] == nil)
    #expect(session.state.noise == .anc && session.canWrite(Command.setNoise))
    #expect(radio.commands.filter(\.isRequest).allSatisfy { $0.type == 0xC0 })
    #expect(!radio.commands.contains { $0.opcode == 0x50 })
    #expect(try await session.setNoise(.transparency) == .confirmed)
    #expect(radio.commands.contains { $0.opcode == 0xF2 && $0.payload == [4,0,11,2,0] })
    #expect(session.state.noise == .transparency)
    #expect(try await session.setNoise(.anc) == .confirmed)
    #expect(radio.config[11] == [1,19])
}

@Test(arguments:XiaomiProfile.allCases.filter { !$0.systemBatteryOnly }) @MainActor
func xiaomiEachPrivateProfileUsesItsOwnIdentityAndCapabilities(_ profile:XiaomiProfile) async throws {
    let radio=XiaomiRadio(profile),session=DeviceSession(transport:radio,name:profile.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.initialize()
    #expect(session.model?.id == profile.modelID && session.ready)
    #expect(radio.commands.contains { $0.opcode == 0x50 } == profile.requiresAuthentication)
    #expect(session.state.batteries[.left]?.percent == 100)
    if !profile.controls {
        #expect(!session.canWrite(Command.setNoise) && !session.canWrite(Command.setEQ))
        #expect(radio.commands.allSatisfy { $0.opcode == 2 })
    } else if session.model?.noiseOptions.isEmpty == false {
        #expect(try await session.setNoise(.transparency) == .confirmed)
    }
}

@Test @MainActor func xiaomiGenericACKOrMalformedReadCannotConfirmNoiseWrite() async throws {
    let radio=XiaomiRadio(.redmi8pro),session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog(),timeout:0.1)
    defer { session.close() };try await session.open();await session.refresh()
    radio.applyWrites=false
    do { _ = try await session.setNoise(.transparency);Issue.record("Generic ACK confirmed a setting") }
    catch { #expect(error as? ProtocolError == .readbackMismatch) }
    #expect(session.state.noise == .anc)
    radio.corruptReadback=true
    do { _ = try await session.setNoise(.anc);Issue.record("Malformed fresh read confirmed cached state") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(!session.canWrite(Command.setNoise))
}

@Test @MainActor func xiaomiWrongProductCannotEnableAnyControlOrQuerySettings() async throws {
    let radio=XiaomiRadio(.redmi8pro);radio.corruptIdentity=true
    let session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    do { try await session.open();Issue.record("Wrong product accepted") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(!session.ready && session.state.batteries.isEmpty)
    #expect(radio.commands.map(\.opcode) == [2])
}

@Test @MainActor func xiaomiWrongEndpointRoleCannotSatisfyDeviceIdentity() async throws {
    let radio=XiaomiRadio(.redmi8pro);radio.wrongTarget=true
    let session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog(),timeout:0.1)
    do { try await session.open();Issue.record("Wrong response endpoint accepted") } catch {}
    #expect(!session.ready && session.state.batteries.isEmpty && !radio.active)
}

@Test @MainActor func xiaomiNonANCModelNeverProbesOrSendsNoiseCommands() async throws {
    let radio=XiaomiRadio(.redmi8active),session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.refresh()
    #expect(session.ready && !session.canWrite(Command.setNoise) && session.state.noise == nil)
    let count=radio.commands.count
    do { _ = try await session.setNoise(.anc);Issue.record("ANC enabled on Active model") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(radio.commands.count == count)
    #expect(!radio.commands.contains { $0.opcode == 0xF3 && $0.payload == [0,11] })
}

@Test @MainActor func xiaomiSixPlayCompletesMutualAuthBeforeNormalControlAndLatencyReadback() async throws {
    let radio=XiaomiRadio(.redmi6play),session=DeviceSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.initialize()
    #expect(session.ready && session.gameFeature == FeatureDefinition("game",6))
    let authIndex=try #require(radio.commands.firstIndex { !$0.isRequest && $0.opcode == 0x51 })
    let infoIndex=try #require(radio.commands.firstIndex { $0.isRequest && $0.opcode == 2 })
    #expect(authIndex < infoIndex)
    #expect(try await session.setFeature(FeatureDefinition("game",6),enabled:true) == .confirmed)
    #expect(session.state.switches[6] == true)
    #expect(!session.canWrite(Command.setNoise))
    #expect(try await session.setEQ(5) == .confirmed && session.state.eq == 5)
}

@Test @MainActor func xiaomiAuthenticationFailureNeverFallsBackToUnauthenticatedControl() async throws {
    let radio=XiaomiRadio(.redmi6play);radio.wrongAuthentication=true
    let session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog(),timeout:0.1,authTimeout:0.1)
    do { try await session.open();Issue.record("Bad authentication accepted") } catch {}
    #expect(!session.ready && !radio.active && session.state.batteries.isEmpty)
    #expect(radio.commands.allSatisfy { [UInt8(0x50),0x51].contains($0.opcode) })
}

@Test @MainActor func xiaomiSixLiteUsesFreshNoiseNotificationInsteadOfUnsupportedQuery() async throws {
    let radio=XiaomiRadio(.redmi6lite),session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open()
    #expect(try await session.setNoise(.transparency) == .confirmed)
    #expect(session.state.noise == .transparency)
    #expect(!radio.commands.contains { $0.opcode == 0x50 || $0.opcode == 9 })
    #expect(radio.commands.contains { !$0.isRequest && $0.opcode == 0xF4 })
}

@Test @MainActor func xiaomiGestureWritePreservesOtherEarAndUnknownRecords() async throws {
    let radio=XiaomiRadio(.redmi6play),session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.refresh()
    let entry=try #require(session.state.gestures.first { $0.side == 1 && $0.gesture == 1 })
    #expect(session.gestureActions(entry).contains(6))
    #expect(try await session.setGesture(entry,action:6) == .confirmed)
    #expect(radio.commands.contains { $0.opcode == 0xF2 && $0.payload == [5,0,2,4,3,255] })
    #expect(XiaomiProtocol.gestures(radio.config[2]!)?[99] == [200,201])
    radio.corruptOtherGesture=true
    do { _ = try await session.setGesture(entry,action:5);Issue.record("Opposite ear changed but write was confirmed") }
    catch { #expect(error as? ProtocolError == .readbackMismatch) }
}

@Test @MainActor func xiaomiSpatialWritePreservesPreferenceBitsAndCustomEQNeedsSelectedPreset() async throws {
    let radio=XiaomiRadio(.redmi8pro),session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open();await session.refresh()
    #expect(try await session.setSpatial(2) == .confirmed && radio.config[29] == [13])
    #expect(!session.canWrite(Command.setCustomEQ))
    #expect(try await session.setEQ(10) == .confirmed)
    var entry=try #require(session.state.customEQ.first);entry.gains[0] = -6
    #expect(try await session.saveEQ(entry) == .confirmed)
    #expect(session.state.customEQ.first?.gains.first == -6)
}

@Test @MainActor func xiaomiFindRequiresFreshOutOfEarStatusAndCloseRejectsStaleNotifications() async throws {
    let radio=XiaomiRadio(.redmi8pro),session=XiaomiSession(transport:radio,name:radio.profile.name,catalog:try ModelCatalog())
    try await session.open();await session.refresh();radio.config[12]=[8]
    do { _ = try await session.find(true);Issue.record("Find sound sent while worn") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(!radio.commands.contains { $0.opcode == 0xF2 && $0.payload == [4,0,9,1,3] })
    radio.corruptReadback=true
    do { _ = try await session.find(true);Issue.record("Find started without valid fresh wear state") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(session.canWrite(Command.find))
    #expect(try await session.find(false) == .sent)
    #expect(radio.commands.contains { $0.opcode == 0xF2 && $0.payload == [4,0,9,0,3] })
    let callback=radio.onEvent;session.close()
    callback?(.data(try XiaomiFrameCodec.encode(XiaomiFrame(type:0xC7,opcode:0xF4,sequence:1,payload:[4,0,11,2,0]))))
    #expect(!session.ready && session.state.batteries.isEmpty && session.state.noise == nil)
}

@MainActor private final class XiaomiBatteryRadio:XiaomiBatterySource {
    let label="Mock system battery"
    var onEvent:((TransportEvent) -> Void)?
    var active=false,frames=0
    var value=XiaomiSystemBattery(batteries:[.left:BatteryReading(percent:65)],aggregate:true)
    func open() async throws { active=true }
    func close() { active=false }
    func send(_ bytes:Data) async throws { frames+=1;throw ProtocolError.unsupported }
    func snapshot() async throws -> XiaomiSystemBattery { value }
}

@Test @MainActor func xiaomiSystemBatteryProfilesNeverOpenMMAOrExposeSettings() async throws {
    let radio=XiaomiBatteryRadio(),session=DeviceSession(transport:radio,name:XiaomiProfile.basicS.name,catalog:try ModelCatalog())
    defer { session.close() };try await session.open()
    #expect(session.ready && session.model?.id == "xiaomi:basicS" && session.model?.singleBattery == true)
    #expect(session.state.batteries[.left]?.percent == 65 && session.state.batteries[.right] == nil)
    #expect(!session.canWrite(Command.setNoise) && !session.canWrite(Command.setSwitch))
    radio.value=XiaomiSystemBattery(batteries:[:],aggregate:true);await session.refresh()
    #expect(session.state.batteries.isEmpty && radio.frames == 0)
}
