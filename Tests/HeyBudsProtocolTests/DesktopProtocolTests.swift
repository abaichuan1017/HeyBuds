import Foundation
import Testing
@testable import HeyBudsProtocol

private func desktopHex(_ text:String) -> [UInt8] { text.split(separator:" ").map { UInt8($0,radix:16)! } }

@Test func desktopCatalogRoutesAll39ModelsWithoutAliasCollisions() throws {
    let c=try ModelCatalog()
    #expect(c.models.count == 283)
    for m in c.models where [.soundcore,.sennheiser,.jbl,.samsung,.nothing,.sony,.bose].contains(m.family) || m.id.hasPrefix("honor:") {
        for name in [m.name]+m.aliases {
            #expect(c.model(productID:nil,name:name)?.id == m.id)
            #expect(c.family(name:name) == m.family)
        }
    }
    #expect(c.model(productID:nil,name:"Galaxy Buds+")?.id == "samsung:buds-plus")
    #expect(c.model(productID:nil,name:"Galaxy Buds")?.id == "samsung:buds")
    #expect(c.model(productID:nil,name:"Galaxy Buds3 FE (AB12)")?.id == "samsung:buds3-fe")
    #expect(c.model(productID:nil,name:"JBL Wave Buds 2-LE")?.id == "jbl:wave-buds-2")
    for name in ["HONOR Earbuds 2 Pro","Soundcore Liberty 5 Pro","MOMENTUM 6","JBL Tune 770NC Max","Nothing Ear (4)"] {
        #expect(c.model(productID:nil,name:name) == nil)
    }
    #expect(c.routingFamily(name:"Personal headphones",services:[.soundcore,.huawei]) == nil)
    #expect(EarbudFamily.samsung.serviceUUID(for:"Galaxy Buds") == SamsungProfile.legacyService)
    #expect(EarbudFamily.jbl.transportKinds(for:"JBL Wave Buds 2") == ["BLE"])
    #expect(EarbudFamily.jbl.transportKinds(for:"JBL Tune 770NC") == ["RFCOMM"])
    let h=try #require(c.model(productID:nil,name:"HONOR Earbuds 2 SE"))
    #expect(h.family == .huawei && h.raw["route"].text == "FreeBuds4I")
}

@Test func desktopSoundcoreGoldenFrameAndBoundedFragmentRecovery() throws {
    #expect(Array(try SoundcoreFrameCodec.encode(SoundcoreFrame(0x0101))) == desktopHex("08 EE 00 00 00 01 01 0A 00 02"))
    let wire=desktopHex("09 FF 00 00 01 01 01 0C 00 05 00 1C")
    for split in 0...wire.count {
        var c=SoundcoreFrameCodec()
        #expect(c.feed(Data(wire.prefix(split)))+c.feed(Data(wire.dropFirst(split))) == [SoundcoreFrame(0x0101,[5,0])])
    }
    var c=SoundcoreFrameCodec(),bad=wire;bad[11] ^= 1
    #expect(c.feed(Data(bad)).isEmpty)
    c.reset();#expect(c.feed(Data(wire)).count == 1)
    #expect(SoundcoreProfile.isVendorService(Data(desktopHex("0C F1 2D 31 FA C3 45 53 BD 80 D6 83 2E 7A BC DE"))))
    #expect(!SoundcoreProfile.isVendorService(Data(desktopHex("0C F1 2D 31 FA C3 45 53 BD 80 D6 83 2E 6A BC DE"))))
}

@Test func desktopSoundcoreLayoutsUseModelSpecificBatteryAndProtectHearID() throws {
    // Synthetic, independently specified offsets from each upstream state parser.
    // The serial ranges are zeros, never real identifiers.
    let layouts:[(SoundcoreProfile,Int,Int,Int,Int,Int)]=[
        (.q30,60,39,2,14,35),(.q35,61,39,2,14,35),(.q45,135,2,23,77,49),
        (.spaceOnePro,87,2,23,37,69),(.liberty4NC,150,6,37,60,118),
        (.liberty4Pro,165,6,44,67,125),(.liberty5,154,6,38,61,119)]
    for (profile,count,fw,eq,hear,noise) in layouts {
        var p=[UInt8](repeating:0,count:count)
        p.replaceSubrange(fw..<fw+5,with:Array("01.23".utf8))
        let bands=profile.oldEQ ? 8 : 10,channels=profile.singleBattery ? 1 : 2
        p.replaceSubrange(eq+2..<eq+2+bands*channels,with:Array(repeating:120,count:bands*channels))
        p[noise]=2
        if profile.singleBattery { p[0]=profile == .spaceOnePro ? 9 : 5 }
        else { p[2]=profile == .liberty4Pro ? 100 : profile == .liberty5 ? 9 : 5;p[3]=p[2];p[profile == .liberty4NC ? 131 : 37]=profile == .liberty4NC ? 5 : 9 }
        let snapshot=try #require(profile.snapshot(p))
        #expect(snapshot.state.batteries[.left]?.percent == 100)
        #expect(snapshot.state.noise == .off && snapshot.state.firmware == "01.23" && snapshot.eqWritable)
        for length in 0..<count { #expect(profile.snapshot(Array(p.prefix(length))) == nil) }
        let write=try profile.noiseWrite(.anc,snapshot:snapshot)
        #expect(write.command == 0x0681 && write.payload.first == 0)
        #expect(Array(write.payload.dropFirst()) == Array(snapshot.noise.dropFirst()))
        let flat=Array(repeating:UInt8(120),count:bands)
        #expect(try profile.equalizerWrite(id:0xFEFE,curve:flat,snapshot:snapshot).command == (profile.oldEQ ? 0x0281 : 0x0387))
        p[hear]=1
        let personalized=try #require(profile.snapshot(p))
        #expect(!personalized.eqWritable)
        #expect(throws:ProtocolError.unsupported) { try profile.equalizerWrite(id:0,curve:flat,snapshot:personalized) }
    }
}

@Test func desktopSennheiserFramingFirmwareAndPeerIdentity() throws {
    let wire=desktopHex("FF 03 00 01 04 95 1A 04 01")
    #expect(Array(try SennheiserFrameCodec.encode(SennheiserFrame(0x1A04,[1]))) == wire)
    for split in 0...wire.count {
        var c=SennheiserFrameCodec()
        #expect(c.feed(Data(wire.prefix(split)))+c.feed(Data(wire.dropFirst(split))) == [SennheiserFrame(0x1A04,[1])])
    }
    var c=SennheiserFrameCodec()
    #expect(c.feed(Data([255,3,1,1,4,0x95,0x13,1,0,0])).isEmpty)
    #expect(SennheiserProfile.firmware([0,6,0,21,0,5]) == "6.21.5")
    #expect(SennheiserProfile.momentum5.allowsWrite(firmware:"6.21.5"))
    for fw in [nil,"6.21.4","6.22.0","unknown"] { #expect(!SennheiserProfile.momentum5.allowsWrite(firmware:fw)) }
    #expect(!SennheiserProfile.momentum4.matchesIdentity(Array("M5AEBT".utf8)))
    let peer=try #require(SennheiserProfile.peer([2,0,1]+Array("Test peer".utf8),index:2,current:0))
    #expect(peer.id == "peer-index:2" && peer.address.isEmpty && peer.connected && !peer.current)
    #expect(SennheiserProfile.peer([3,0,1,65],index:2,current:0) == nil)
}

@Test func desktopJBLProfilesFramesAndPartialInformation() throws {
    #expect(Array(try JBLFrameCodec.encode(JBLProfile.tune230.noiseRead,profile:.tune230)) == desktopHex("AA 91 01 11"))
    #expect(Array(try JBLFrameCodec.encode(JBLProfile.tune770.noiseRead,profile:.tune770)) == desktopHex("05 5A 04 00 01 09 05 00"))
    #expect(try JBLFrameCodec.encode(JBLProfile.tune770.noiseWrite(.anc)!,profile:.tune770) == Data(desktopHex("05 5A 05 00 06 0E 00 0A 01")))
    let packet=desktopHex("AA 91 07 12 01 00 02 01 03 00")
    for split in 0...packet.count {
        var c=JBLFrameCodec(profile:.waveBuds2)
        let frames=c.feed(Data(packet.prefix(split)))+c.feed(Data(packet.dropFirst(split)))
        #expect(frames.count == 1 && frames.first.flatMap(JBLProfile.waveBuds2.noise) == .transparency)
    }
    #expect(JBLProfile.waveBuds2.noise(JBLFrame(0x91,[0x12,1,1,2,1,3,0])) == nil)
    #expect(JBLProfile.waveBuds2.noise(JBLFrame(0x91,[0x12,1,0,2,0,3,1])) == nil)
    // Source fixture's non-identifying firmware and battery TLVs only.
    let p=desktopHex("02 00 05 03 00 03 04 00 1A 02 00 50 00 1B 02 01 5A 00 1C 02 00 FF")
    let info=try #require(JBLProfile.waveBuds2.information(p))
    #expect(info.firmware == "0.3.4" && info.batteries[.left]?.percent == 80 && info.batteries[.right]?.charging == true)
    #expect(info.batteries[.enclosure] == nil)
    #expect(JBLProfile.waveBuds2.information(Array(p.dropLast())) == nil)
    #expect(JBLProfile.tune230.information(p) == nil)
}

@Test func desktopSamsungLegacyHasSeparateFramesEQAndNoiseCommands() throws {
    #expect(Array(try SamsungFrameCodec.encode(SamsungFrame(0x61),legacy:true)) == desktopHex("FE 00 03 61 87 7C EE"))
    var legacy=SamsungFrameCodec(legacy:true),modern=SamsungFrameCodec()
    let wire=Data(desktopHex("FE 00 03 61 87 7C EE"))
    #expect(legacy.feed(wire) == [SamsungFrame(0x61)] && modern.feed(wire).isEmpty)
    #expect(SamsungProfile.buds.noiseFrame(.anc) == nil)
    #expect(SamsungProfile.buds.noiseFrame(.transparency) == SamsungFrame(0x80,[1]))
    #expect(SamsungProfile.budsLive.noiseFrame(.anc) == SamsungFrame(0x98,[1]))
    #expect(SamsungProfile.buds.eqPayload(0) == [0,5] && SamsungProfile.buds.eqPayload(5) == [1,9])
    var p=[UInt8](repeating:0,count:13);p[2]=80;p[3]=70;p[7]=1;p[10]=1;p[11]=9
    let state=try #require(SamsungProfile.buds.status(p))
    #expect(state.noise == .transparency && state.eq == 5 && state.batteries[.enclosure] == nil)
    #expect(SamsungProfile.budsPlus.status(p) == nil)
}

@Test func desktopSonyFirmwareGatesAndAdaptationArePreserved() throws {
    #expect(!SonyProfile.wfC700n.allowsNoiseWrite(firmware:"2.0.5"))
    #expect(!SonyProfile.wfC700n.allowsNoiseWrite(firmware:nil))
    #expect(SonyProfile.wfC700n.allowsNoiseWrite(firmware:"2.0.7"))
    let current=try #require(SonyProtocol.noise([0x67,0x19,1,1,0,0,20,1,2],profile:.wh1000xm6))
    #expect(current.adaptation == [1,2])
    let write=try SonyProtocol.noiseWrite(mode:.transparency,level:9,voice:true,profile:.wh1000xm6,current:current)
    #expect(write == [0x68,0x19,1,1,1,1,9,1,2])
    #expect(SonyProtocol.noise([0x67,0x19,1,1,0,0,20,1,2],profile:.wh1000xm5) == nil)
}

@Test func desktopNothingModelIDUsesOnlyProductEvents() {
    let packet=desktopHex("03 01 00 03 56 3D A5")
    for split in 0...packet.count {
        var c=NothingModelIDCodec()
        #expect(c.feed(Data(packet.prefix(split)))+c.feed(Data(packet.dropFirst(split))) == ["563DA5"])
    }
    var c=NothingModelIDCodec()
    #expect(c.feed(Data(desktopHex("03 02 00 03 56 3D A5"))).isEmpty)
    #expect(NothingProfile.cmfHeadphonePro.fastPairIDs.contains("563DA5"))
    #expect(NothingProfile.earStick.noiseWrite(.anc) == nil && !NothingProfile.earStick.supportsNoise)
    #expect(NothingProfile.cmfHeadphonePro.singleBattery)
    #expect(NothingProfile.ear2.advancedEQRead != nil)
    #expect(NothingProfile.cmfBuds.eqWrite(2)?.command == 0xF01D)
    #expect(NothingProfile.cmfBudsPro.eqWrite(2)?.command == 0xF010)
}

@Test func desktopLiberty4NCMatchesUpstreamNonIdentifyingEqualizerVector() throws {
    // OpenSCQ30 a3947/packets/set_equalizer_configuration.rs, known-good
    // settings vector. No serial, address or personal calibration capture.
    let curve:[UInt8]=[180,120,120,120,120,120,120,60,120,120]
    let hearing:[UInt8]=[112,117,140,148,150,142,134,131,60,60]
    let base=[UInt8(0)]+hearing+hearing+[104,100,34,64,2]+hearing+hearing
    let snapshot=SoundcoreSnapshot(state:DeviceState(),noise:[0,0,0,0,0,0,0],equalizerID:0,curves:curve+curve,hear:base+[6,0],eqWritable:true)
    let packet=try SoundcoreProfile.liberty4NC.equalizerWrite(id:0xFEFE,curve:curve,snapshot:snapshot)
    let drc:[UInt8]=[128,116,121,119,121,119,124,111,120,0]
    let expected=[UInt8(254),254,6,0]+curve+curve+[0,0]+base+drc+drc+[0]
    #expect(packet.command == 0x0387 && packet.payload == expected)
    let wire=try SoundcoreFrameCodec.encode(packet)
    #expect(wire.count == 103 && wire.last == 143)
}
