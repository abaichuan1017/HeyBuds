import Foundation
import Testing
@testable import HeyBudsBluetooth
@testable import HeyBudsProtocol

@MainActor private final class DesktopRadio:EarbudTransport {
    var onEvent:((TransportEvent)->Void)?
    let label="Synthetic desktop protocol transport"
    var active=false,opens=0,closed=0
    var sent:[Data]=[]
    var onOpen:(()->Void)?
    var answer:((Data)throws->[Data])?
    func open() async throws { active=true;opens += 1;onOpen?() }
    func close() { active=false;closed += 1 }
    func send(_ data:Data) async throws {
        guard active else { throw ProtocolError.disconnected };sent.append(data)
        for packet in try answer?(data) ?? [] { onEvent?(.data(packet)) }
    }
}

@Test @MainActor func desktopSoundcoreReadbackAndPersonalizationGuards() async throws {
    let r=DesktopRadio(),catalog=try ModelCatalog()
    var state=[UInt8](repeating:0,count:60)
    state[0]=5;state.replaceSubrange(4..<12,with:Array(repeating:120,count:8))
    state.replaceSubrange(39..<44,with:Array("01.23".utf8))
    var writes=0,ignore=false,commands:[UInt16]=[]
    r.answer={ data in
        let b=Array(data),cmd=UInt16(b[5]) << 8 | UInt16(b[6]),p=Array(b[9..<b.count-1]);commands.append(cmd)
        if cmd == 0x0101 { return [try SoundcoreFrameCodec.encode(SoundcoreFrame(0x0101,state),inbound:true)] }
        writes += 1
        if !ignore {
            if cmd == 0x0681 { state.replaceSubrange(35..<39,with:p) }
            if cmd == 0x0281 { state.replaceSubrange(2..<12,with:p) }
        }
        // A generic empty ACK cannot satisfy the following status request.
        return [try SoundcoreFrameCodec.encode(SoundcoreFrame(cmd),inbound:true)]
    }
    let session=DeviceSession(transport:r,name:"Soundcore Life Q30",catalog:catalog)
    defer { session.close() };try await session.open()
    #expect(session.ready && session.state.batteries[.left]?.percent == 100)
    #expect(try await session.setNoise(.transparency) == .confirmed)
    #expect(commands.suffix(3) == [0x0101,0x0681,0x0101])
    #expect(try await session.setEQ(1) == .confirmed)
    var entry=try #require(session.state.customEQ.first)
    entry.gains=Array(repeating:1,count:8)
    #expect(try await session.saveEQ(entry) == .confirmed)
    #expect(session.state.eq == 254)
    state[14]=1 // Fresh HearID changes after the previous UI snapshot.
    let previous=writes
    await #expect(throws:ProtocolError.unsupported) { try await session.setEQ(0) }
    #expect(writes == previous)
    state[14]=0;await session.refresh();ignore=true
    await #expect(throws:ProtocolError.readbackMismatch) { try await session.setNoise(.off) }
    #expect(session.state.noise == .transparency)
}

@MainActor private final class MomentumFixture {
    let radio=DesktopRadio()
    var firmware:[UInt8]=[0,6,0,21,0,5]
    var model="M5AEBT",anc:UInt8=1,ambient:UInt8=0,wear:UInt8=1,mode:UInt8=1
    var gains:[UInt8]=[0,0,0,0,0],ignore=false
    var commands:[SennheiserFrame]=[]
    var peers:[(String,UInt8)]=[("Test system",1)]
    var maximum:UInt8=2,connectionPolls=0,delayPolls=0
    var lieAboutConnection=false,dropCurrent=false
    init() {
        radio.answer={ [self] data in
            var codec=SennheiserFrameCodec();let f=try #require(codec.feed(data).first);commands.append(f)
            let p:[UInt8]
            switch f.command {
            case 0x1206:p=Array(model.utf8)
            case 0x1201:p=firmware
            case 0x0603:p=[80]
            case 0x0602:p=[0]
            case 0x1A05:p=[anc]
            case 0x1805:p=[ambient]
            case 0x0401:p=[wear]
            case 0x0804:p=[0,mode]
            case 0x1000:p=[5,196,60,0,0]
            case 0x100B:
                let hz:[UInt16]=[90,325,1500,6500,6500],i=Int(f.payload[0]);p=[UInt8(i),UInt8(hz[i] >> 8),UInt8(truncatingIfNeeded:hz[i])]
            case 0x1003:p=gains
            case 0x1400:p=[0,UInt8(peers.count)]
            case 0x1407:p=[0]
            case 0x1401:
                let i=Int(f.payload[0]);p=[f.payload[0],0,peers[i].1]+Array(peers[i].0.utf8)
            case 0x1409:p=[maximum]
            case 0x1402:connectionPolls=0;p=[]
            case 0x1404:
                connectionPolls += 1
                if connectionPolls > delayPolls {
                    if !lieAboutConnection { peers[Int(f.payload[0])].1=1 }
                    if dropCurrent { peers[0].1=0 }
                    p=[f.payload[0],1]
                } else { p=[f.payload[0],0] }
            case 0x1A04:if !ignore { anc=f.payload[0] };p=[]
            case 0x1804:if !ignore { ambient=f.payload[0] };p=[]
            case 0x0400:if !ignore { wear=f.payload[0] };p=[]
            case 0x0803:if !ignore { mode=f.payload[1] };p=[]
            case 0x1001:if !ignore { gains[Int(f.payload[0])]=f.payload[1] };p=[]
            default:throw ProtocolError.unsupported
            }
            return [try SennheiserFrameCodec.encode(SennheiserFrame(f.command | 0x100,p))]
        }
    }
}

@Test @MainActor func desktopMomentum5FirmwareGateAndFreshReadback() async throws {
    for permitted in [false,true] {
        let f=MomentumFixture();if !permitted { f.firmware=[0,6,0,22,0,0] }
        let s=DeviceSession(transport:f.radio,name:"MOMENTUM 5",catalog:try ModelCatalog())
        defer { s.close() };try await s.open()
        #expect(s.ready && s.state.hosts.count == 1 && s.state.hosts[0].current)
        #expect(s.canWrite(Command.setNoise) == permitted)
        if !permitted {
            let before=f.commands.count
            await #expect(throws:ProtocolError.unsupported) { try await s.setNoise(.off) }
            #expect(f.commands.count == before);continue
        }
        #expect(try await s.setNoise(.transparency) == .confirmed)
        #expect(try await s.setFeature(FeatureDefinition("wear",4),enabled:false) == .confirmed)
        var entry=try #require(s.state.customEQ.first);entry.gains=[1,0,-1,0,2]
        #expect(try await s.saveEQ(entry) == .confirmed)
        #expect(f.gains == [10,0,246,0,20] && s.state.eq == 254)
        f.ignore=true
        await #expect(throws:ProtocolError.readbackMismatch) { try await s.setNoise(.off) }
        #expect(!f.commands.contains { $0.command == 0x1403 })
    }
}

@Test @MainActor func desktopMomentumIdentityMismatchStopsBeforeSettings() async throws {
    let f=MomentumFixture();f.model="M4AEBT"
    let s=DeviceSession(transport:f.radio,name:"MOMENTUM 5",catalog:try ModelCatalog())
    defer { s.close() }
    await #expect(throws:ProtocolError.unsupported) { try await s.open() }
    #expect(f.commands.map(\.command) == [0x1206] && !f.radio.active)
}

@Test @MainActor func desktopMomentum4PeerCapacityAndFreshListConfirmation() async throws {
    for scenario in ["success","capacity","stale-name","false-status","lost-current"] {
        let f=MomentumFixture();f.model="M4AEBT";f.firmware=[0,3,0,38,0,3]
        f.peers.append(("Test peer",0))
        let s=DeviceSession(transport:f.radio,name:"MOMENTUM 4",catalog:try ModelCatalog())
        defer { s.close() };try await s.open()
        let target=try #require(s.state.hosts.last)
        #expect(s.canOperateHost(.connect,host:target))
        if scenario == "capacity" { f.maximum=1 }
        if scenario == "stale-name" { f.peers[1].0="Replacement peer" }
        if scenario == "false-status" { f.lieAboutConnection=true }
        if scenario == "lost-current" { f.dropCurrent=true }
        if scenario == "success" {
            f.delayPolls=1
            #expect(try await s.operateHost(.connect,host:target) == .confirmed)
            #expect(f.connectionPolls == 2 && s.state.hosts.allSatisfy(\.connected))
        } else if scenario == "capacity" || scenario == "stale-name" {
            await #expect(throws:ProtocolError.unsupported) { try await s.operateHost(.connect,host:target) }
            #expect(!f.commands.contains { $0.command == 0x1402 })
        } else {
            await #expect(throws:ProtocolError.readbackMismatch) { try await s.operateHost(.connect,host:target) }
        }
        #expect(f.commands.filter { $0.command == 0x1402 }.count <= 1)
        #expect(!f.commands.contains { $0.command == 0x1403 })
    }
}

@Test @MainActor func desktopJBLRaceRequiresReadbackRatherThanWriteReply() async throws {
    let r=DesktopRadio();var mode:UInt8=0,ignore=false,commands:[UInt16]=[]
    r.answer={ data in
        let b=Array(data),cmd=UInt16(b[4]) | UInt16(b[5]) << 8;commands.append(cmd)
        if cmd == 0x0E06,!ignore { mode=b.count == 8 ? 0 : b[8] }
        let payload: [UInt8]=cmd == 0x0901 ? [5,0,0,mode] : []
        return [Data([5,0x5B,UInt8(payload.count+2),0,UInt8(truncatingIfNeeded:cmd),UInt8(cmd >> 8)]+payload)]
    }
    let s=DeviceSession(transport:r,name:"JBL Tune 770NC",catalog:try ModelCatalog())
    defer { s.close() };try await s.open()
    #expect(s.ready && s.state.batteries.isEmpty)
    #expect(try await s.setNoise(.anc) == .confirmed)
    #expect(commands.suffix(2) == [0x0E06,0x0901])
    ignore=true
    await #expect(throws:ProtocolError.readbackMismatch) { try await s.setNoise(.transparency) }
    #expect(!s.canWrite(Command.setEQ))
}

@Test @MainActor func desktopNothingIdentityIsReadOnlyAndClosedBeforeControl() async throws {
    for correct in [false,true] {
        let identity=DesktopRadio(),control=DesktopRadio()
        identity.onOpen={ identity.onEvent?(.data(Data([3,1,0,3,0x56,0x3D,correct ? 0xA5 : 0]))) }
        control.onOpen={ #expect(!identity.active) }
        let transport=NothingVerifiedTransport(identity:identity,control:control,profile:.cmfHeadphonePro,timeout:0.1)
        defer { transport.close() }
        if correct {
            try await transport.open();#expect(transport.verifiedModelCode == "B175")
            try await transport.send(Data([1]));#expect(control.sent == [Data([1])])
        } else {
            await #expect(throws:ProtocolError.unsupported) { try await transport.open() }
            #expect(control.opens == 0)
        }
        #expect(identity.sent.isEmpty && !identity.active)
    }
}

@Test @MainActor func desktopNothingIdentityTimeoutCannotOpenControl() async throws {
    let identity=DesktopRadio(),control=DesktopRadio()
    let transport=NothingVerifiedTransport(identity:identity,control:control,profile:.ear1,timeout:0.02)
    defer { transport.close() }
    await #expect(throws:ProtocolError.timeout(0)) { try await transport.open() }
    #expect(!identity.active && control.opens == 0 && transport.verifiedModelCode == nil)
}

@Test @MainActor func desktopQC35UsesLegacyNoiseAndNeverTransparency() async throws {
    for profile:BoseProfile in [.qc35,.qc35II] {
        let r=DesktopRadio();var mode:UInt8=0,commands:[BoseFrame]=[],ignore=false
        r.answer={ data in
            var codec=BoseFrameCodec();let f=try #require(codec.feed(data).first);commands.append(f)
            let p:[UInt8]
            switch (f.block,f.function) {
            case (0,1):p=[1,0,0]
            case (0,5):p=Array("1.0.4".utf8)
            case (0,3):p=[UInt8(profile.productID >> 8),UInt8(truncatingIfNeeded:profile.productID),0]
            case (2,2):p=[80]
            case (1,6):
                if f.operation == .setGet,!ignore { mode=f.payload[0] }
                p=[mode,0x0B]
            default:throw ProtocolError.unsupported
            }
            return [try BoseFrameCodec.encode(BoseFrame(f.block,f.function,.status,p))]
        }
        let name=profile == .qc35 ? "Bose QC35" : "Bose QC35 II"
        let s=DeviceSession(transport:r,name:name,catalog:try ModelCatalog())
        defer { s.close() };try await s.open()
        #expect(s.state.batteries[.left]?.percent == 80 && s.state.noise == .off)
        #expect(try await s.setNoise(.anc) == .confirmed)
        #expect(mode == (profile == .qc35 ? 3 : 1))
        await #expect(throws:ProtocolError.unsupported) { try await s.setNoise(.transparency) }
        ignore=true
        await #expect(throws:ProtocolError.readbackMismatch) { try await s.setNoise(.off) }
        #expect(!commands.contains { $0.block == 31 })
    }
}

@Test @MainActor func desktopSamsungEachGenerationUsesItsOwnStatusAndCommands() async throws {
    for profile in SamsungProfile.allCases where ![.buds2,.buds2Pro,.buds4Pro].contains(profile) {
        let r=DesktopRadio();var p=[UInt8](repeating:0,count:profile.minimumStatusLength(revision:0))
        p[2]=80;p[3]=70
        if !profile.legacy { p[7]=60 }
        if profile.legacy { p[11]=5 }
        var commands:[SamsungFrame]=[]
        r.answer={ data in
            var c=SamsungFrameCodec(legacy:profile.legacy);let f=try #require(c.feed(data).first);commands.append(f)
            if f.command == 0x61 { return [try SamsungFrameCodec.encode(SamsungFrame(0x61,p),legacy:profile.legacy)] }
            switch f.command {
            case 0x80:p[profile.legacy ? 7 : 8]=f.payload[0]
            case 0x98,0x78:p[12]=f.payload[0]
            case 0x86:
                if profile.legacy { p[10]=f.payload[0];p[11]=f.payload[1] }
                else { p[profile == .budsPlus ? 11 : 9]=f.payload[0] }
            default:break
            }
            return []
        }
        let s=DeviceSession(transport:r,name:profile.rawValue,catalog:try ModelCatalog())
        defer { s.close() };try await s.open()
        #expect(s.state.batteries[.left]?.percent == 80)
        for mode in profile.noiseModes { #expect(try await s.setNoise(mode) == .confirmed) }
        #expect(try await s.setEQ(5) == .confirmed)
        #expect(s.state.eq == 5)
        #expect(commands.contains { $0.command == (profile.legacy || profile == .budsPlus ? 0x80 : profile == .budsLive ? 0x98 : 0x78) })
    }
}

@Test @MainActor func desktopJBLBLEReadbackAndAbsentBatteryClearing() async throws {
    let r=DesktopRadio();var mode:UInt8=0,withBattery=true,ignore=false
    r.answer={ data in
        let b=Array(data)
        if b[1] == 0x9B { return [] }
        if b[1] == 6 {
            let p:[UInt8]=withBattery ? [2,0,0x1A,2,0,80,0,0x1C,2,0,50] : [2,0,0x1A,2,0,70]
            return [Data([0xAA,6,UInt8(p.count),0]+p)]
        }
        if b[1] == 0x91,b[3] == 0x10 {
            if !ignore { mode=b[5] == 1 ? 1 : b[7] == 1 ? 2 : 0 }
            return [Data([0xAA,0x91,1,0])] // ACK alone is not status.
        }
        return [Data([0xAA,0x91,7,0x12,1,mode == 1 ? 1 : 0,2,mode == 2 ? 1 : 0,3,0])]
    }
    let s=JBLSession(transport:r,name:"JBL Wave Buds 2",catalog:try ModelCatalog(),timeout:0.1,minimumInterval:.zero)
    defer { s.close() };try await s.open()
    #expect(s.state.batteries[.enclosure]?.percent == 50)
    #expect(try await s.setNoise(.anc) == .confirmed)
    ignore=true
    await #expect(throws:ProtocolError.readbackMismatch) { try await s.setNoise(.transparency) }
    withBattery=false;await s.refresh()
    #expect(s.state.batteries[.enclosure] == nil && s.state.batteries[.left]?.percent == 70)
}
