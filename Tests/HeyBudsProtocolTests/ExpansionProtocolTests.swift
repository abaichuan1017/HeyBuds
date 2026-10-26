import Foundation
import Testing
@testable import HeyBudsProtocol

private func expansionHex(_ text:String) -> [UInt8] {
    text.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0,radix:16)! }
}

// Fixed-source evidence: Budsy SppMessage.swift / CRC16.swift and
// GalaxyBudsClient Message/Decoder/ExtendedStatusUpdateDecoder.cs.
// These wire constants were independently calculated with CRC-16/XMODEM;
// expected bytes never come from the codec under test.
@Test func expansionSamsungGoldenCommandsAndEveryStreamSplit() throws {
    let vectors:[(SamsungFrame,String)]=[
        (SamsungFrame(0x61),"FD 03 00 61 87 7C DD"),
        (SamsungFrame(0x51,[0]),"FD 04 00 51 00 8E 3D DD"),
        (SamsungFrame(0x88,[1,1,0,1]),"FD 07 00 88 01 01 00 01 58 71 DD"),
        (SamsungFrame(0x78,[1]),"FD 04 00 78 01 D1 91 DD"),
        (SamsungFrame(0x86,[5]),"FD 04 00 86 05 9B E1 DD"),
        (SamsungFrame(0x51,[0x61,0]),"FD 05 00 51 61 00 E5 51 DD"),
        (SamsungFrame(0x61,response:true),"FD 03 10 61 87 7C DD")
    ]
    #expect(SamsungFrameCodec.checksum(Array("123456789".utf8)) == 0x31C3)
    for (frame,text) in vectors {
        let wire=expansionHex(text)
        #expect(Array(try SamsungFrameCodec.encode(frame)) == wire)
        for split in 0...wire.count {
            var codec=SamsungFrameCodec()
            let first=codec.feed(Data([0,1,2]+wire.prefix(split)))
            let second=codec.feed(Data(wire.dropFirst(split))+Data(wire))
            #expect(first+second == [frame,frame])
        }
    }
}

@Test func expansionSamsungRejectsCRCFlagsLengthsAndRecoversAfterReset() throws {
    let good=expansionHex("FD 03 00 61 87 7C DD")
    let malformed:[[UInt8]]=[
        expansionHex("FD 03 00 61 86 7C DD"), // bad CRC
        expansionHex("FD 03 00 61 87 7C EE"), // legacy terminator
        expansionHex("FD 03 20 61 87 7C DD"), // firmware fragment
        expansionHex("FD 03 04 61 87 7C DD"), // reserved header bit
        expansionHex("FD 02 00 61 87 7C DD"), // no room for ID and CRC
        expansionHex("FE 00 03 61 87 7C EE")  // original legacy framing
    ]
    for bytes in malformed {
        var codec=SamsungFrameCodec()
        #expect(codec.feed(Data(bytes)+Data(good)) == [SamsungFrame(0x61)])
    }
    for count in 1..<good.count {
        var codec=SamsungFrameCodec()
        #expect(codec.feed(Data(good.prefix(count))).isEmpty)
        codec.reset()
        #expect(codec.feed(Data(good)) == [SamsungFrame(0x61)])
    }
    #expect(throws:ProtocolError.invalidPayload) {
        try SamsungFrameCodec.encode(SamsungFrame(0x61,Array(repeating:0,count:1021)))
    }
}

@Test func expansionSamsungStatusRevisionBoundsAndIndependentOffsets() throws {
    // Revision lengths and charging masks follow GalaxyBudsClient's per-model
    // decoder branches, including the optional second byte after Buds2 Pro rev13.
    let cases:[(SamsungProfile,UInt8,Int)]=[
        (.buds2,0,27),(.buds2,2,28),(.buds2,3,29),(.buds2,5,33),
        (.buds2,6,34),(.buds2,7,35),(.buds2,8,36),(.buds2,10,37),
        (.buds2Pro,0,34),(.buds2Pro,1,41),(.buds2Pro,3,42),
        (.buds2Pro,8,43),(.buds2Pro,11,44),(.buds2Pro,13,45),(.buds4Pro,0,25)
    ]
    for (profile,revision,count) in cases {
        var payload=[UInt8](repeating:0,count:count)
        payload[0]=revision;payload[2]=0;payload[3]=100;payload[7]=255
        payload[9]=3;payload[10]=0x9A;payload[12]=1
        if profile == .buds2 && revision >= 10 { payload[36]=0x14 }
        if profile == .buds2Pro && revision >= 11 { payload[43]=0x14 }
        #expect(profile.minimumStatusLength(revision:revision) == count)
        let sample=try #require(profile.status(payload))
        #expect(sample.batteries[.left]?.percent == 0)
        #expect(sample.batteries[.right]?.percent == 100)
        #expect(sample.batteries[.enclosure] == nil)
        #expect(sample.noise == .anc && sample.eq == 3)
        let charging=(profile == .buds2 && revision >= 10) || (profile == .buds2Pro && revision >= 11)
        #expect(sample.batteries[.left]?.charging == charging)
        #expect(sample.batteries[.right]?.charging == charging)
        #expect(sample.samsungControls?.touchFlags == 0x9A)
        for length in 0..<count { #expect(profile.status(Array(payload.prefix(length))) == nil) }
        payload[9]=7
        let custom=try #require(profile.status(payload))
        #expect(custom.eq == nil && !custom.observedQueries.contains(Command.equalizer))
        payload[12]=profile == .buds4Pro ? 4 : 3
        #expect(profile.status(payload) == nil)
    }
    #expect(SamsungProfile.buds4Pro.noiseByte(.adaptive) == 3)
    #expect(SamsungProfile.buds2.noiseByte(.adaptive) == nil)
    #expect(SamsungProfile.buds2Pro.noiseByte(.adaptive) == nil)
}

@Test func expansionSamsungTouchLockPreservesFlagsAndVersionGatesCallGestures() throws {
    // GalaxyBudsClient LockTouchpadEncoder and Buds2/Buds2ProDeviceSpec:
    // !LockAll, Tap, DoubleTap, TripleTap, Hold, optional CallDouble/CallHold.
    for (profile,revision,calls):(SamsungProfile,UInt8,Bool) in [
        (.buds2,6,false),(.buds2,7,true),(.buds2Pro,0,false),(.buds2Pro,1,true)
    ] {
        for flags:UInt8 in [0,0x9A,0xA5,0xBF] {
            let current=SamsungControlState(revision:revision,touchFlags:flags,ancLevel:nil)
            let gestures:[UInt8]=[(flags>>3)&1,(flags>>2)&1,(flags>>1)&1,flags&1]
            let expected=gestures+(calls ? [(flags>>4)&1,(flags>>5)&1] : [])
            #expect(try profile.touchLockPayload(true,current:current) == [0]+expected)
            #expect(try profile.touchLockPayload(false,current:current) == [1]+expected)
            #expect(current.touchLocked == (flags&0x80 == 0))
        }
    }
    #expect(throws:ProtocolError.unsupported) {
        try SamsungProfile.buds4Pro.touchLockPayload(true,current:SamsungControlState(revision:0,touchFlags:0,ancLevel:2))
    }
    var payload=[UInt8](repeating:0,count:25)
    for level:UInt8 in [0,1,2,3,4,5,255] {
        payload[24]=level
        #expect(SamsungProfile.buds4Pro.status(payload)?.samsungControls?.ancLevel == (level <= 4 ? Int(level) : nil))
    }
}

@Test func expansionCatalogKeepsOriginalRoutingAndAddsExactNewModelNames() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.models.count == 228)
    #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
    for (name,id,family) in [
        ("Galaxy Buds2","samsung:buds2","samsung"),
        ("Samsung Galaxy Buds2 (A1b2)","samsung:buds2","samsung"),
        ("Galaxy Buds2 Pro","samsung:buds2-pro","samsung"),
        ("Galaxy Buds4 Pro","samsung:buds4-pro","samsung"),
        ("Pixel Buds Pro","google:pixel-buds-pro","google"),
        ("Google Pixel Buds Pro 2","google:pixel-buds-pro-2","google"),
        ("OPPO Enco Air5 Pro","06C410","oppo")
    ] {
        #expect(catalog.model(productID:nil,name:name)?.id == id)
        #expect(catalog.family(name:name)?.rawValue == family)
    }
    for (name,family) in [("vivo TWS 4","vivo"),("FreeBuds Pro 3","huawei"),
                          ("Redmi Buds 6","xiaomi"),("W820NB Plus","edifier"),("WH-1000XM5","sony")] {
        #expect(catalog.family(name:name)?.rawValue == family)
    }
    for name in ["Galaxy Buds2 FE","Galaxy Buds2 Pro Max","Galaxy Buds4","Galaxy Buds FE",
                 "Galaxy Buds2 (test)","Pixel Buds Pro 3","Pixel Buds A-Series","Pixel Buds Pro 2 Case"] {
        #expect(catalog.model(productID:nil,name:name) == nil)
    }
    #expect(SamsungProfile.service == "2E73A4AD-332D-41FC-90E2-16BEF06523F2")
    #expect(GoogleMaestro.service == "25E97FF7-24CE-4C4C-8951-F764A708F7B5")
}

// Public upstream protocol fixture, PixelBudsMacOS CapturedFramesTests frame 5.
// Only a settings notification; no device identifier or private capture.
private let expansionGoogleNotification=expansionHex("""
7E 00 A5 03 2A 04 22 02 68 03 08 07 10 15 1D EA
71 DE 7D 5E 25 F5 AD 21 28 38 09 08 E4 5A D2 7E
""")

@Test func expansionGoogleGoldenHashRequestAndCapturedNotification() throws {
    // pbpctrl pwrpc/id.rs, protocol/addr.rs and maestro_pw.proto.
    #expect(GoogleMaestro.serviceID == 0x7EDE71EA)
    #expect(GoogleMaestro.hash("GetSoftwareInfo") == 0x7199FA44)
    #expect(GoogleMaestro.hash("SubscribeToSettingsChanges") == 0x2821ADF5)
    #expect(GoogleMaestro.hash("ReadSetting") == 0xAED0AE51)
    #expect(GoogleFrameCodec.crc32(Array("123456789".utf8)) == 0xCBF43926)
    let request=GoogleRPCFrame(channel:19,method:0xAED0AE51,call:1,payload:[0x20,0x0D])
    let wire=expansionHex("7E 00 3B 03 08 00 10 13 1D EA 71 DE 7D 5E 25 51 AE D0 AE 2A 02 20 0D 30 00 38 01 18 78 9A 6F 7E")
    #expect(Array(try GoogleFrameCodec.encode(request)) == wire)
    for split in 0...expansionGoogleNotification.count {
        var decoder=GoogleFrameCodec()
        let frames=decoder.feed(Data(expansionGoogleNotification.prefix(split)))
            + decoder.feed(Data(expansionGoogleNotification.dropFirst(split)))
        let frame=try #require(frames.first)
        #expect(frames.count == 1 && frame.type == 7 && frame.channel == 21 && frame.call == 9)
        #expect(frame.service == 0x7EDE71EA && frame.method == 0x2821ADF5)
        #expect(frame.payload == [0x22,2,0x68,3] && GoogleMaestro.noise(frame.payload) == .transparency)
    }
    #expect(GoogleMaestro.candidates == [19,24,21,26])
    for (channel,address):(UInt32,UInt32) in [(19,3712),(21,4736),(24,3904),(26,4928)] {
        #expect(GoogleFrameCodec.address(channel) == address)
    }
    #expect(throws:ProtocolError.invalidPayload) {
        try GoogleFrameCodec.encode(GoogleRPCFrame(channel:999,method:0,call:1))
    }
}

@Test func expansionGoogleRejectsCorruptionTruncationAndInvalidEscape() {
    var badCRC=expansionGoogleNotification;badCRC[badCRC.count-2] ^= 1
    let invalidEscapes:[[UInt8]]=[[0x7E,0x7D,0,0x7E],[0x7E,0x7D,0x7E]]
    for bytes in [badCRC]+invalidEscapes {
        var codec=GoogleFrameCodec()
        #expect(codec.feed(Data(bytes)).isEmpty)
        #expect(codec.feed(Data(expansionGoogleNotification)).count == 1)
    }
    for split in 1..<expansionGoogleNotification.count {
        var codec=GoogleFrameCodec()
        #expect(codec.feed(Data(expansionGoogleNotification.prefix(split))).isEmpty)
        codec.reset()
        #expect(codec.feed(Data(expansionGoogleNotification)).count == 1)
    }
    var codec=GoogleFrameCodec()
    #expect(codec.feed(Data([0x7E]+Array(repeating:0,count:16_385))).isEmpty)
    #expect(codec.feed(Data(expansionGoogleNotification)).count == 1)
}

@Test func expansionProtobufBoundsWrongWireTypesAndDuplicateSingularFields() throws {
    let bad:[[UInt8]]=[[],[0],[0x0B],[0x0F],[0x08,0x80],[0x0A,3,1],
        [0x0D,0,0,0],[0x09,0,0,0,0,0,0,0],
        [0x08]+Array(repeating:0xFF,count:9)+[2],Array(repeating:0,count:16_385)]
    for bytes in bad.dropFirst() { #expect(throws:ProtocolError.invalidPayload) { try ProtoFields(bytes) } }
    let duplicate=try ProtoFields([8,1,8,2])
    #expect(duplicate.present(1) && duplicate.one(1) == nil && duplicate.uint(1) == nil)
    #expect(throws:ProtocolError.invalidPayload) { try ProtoFields(Array(repeating:[UInt8(8),0],count:257).flatMap { $0 }) }
    let maximum=try ProtoFields([8]+Array(repeating:0xFF,count:9)+[1])
    #expect(maximum.uint(1) == UInt64.max)
    let base=expansionHex("10 13 1D EA 71 DE 7E 25 51 AE D0 AE 38 01")
    #expect(GoogleRPCFrame.decode(base)?.payload == []) // absent optional payload/status/type
    for suffix in [[8,9],[8,1,8,1],[0x2A,0,0x2A,0],[0x30,0,0x30,0],[0x0D,0,0,0,0],[0x28,0],
                   [0x10,0x13],[0x38,1],[0x30,0x80,0x80,0x80,0x80,0x10]] as [[UInt8]] {
        #expect(GoogleRPCFrame.decode(base+suffix) == nil)
    }
    #expect(GoogleRPCFrame.decode([0x10,0x13]) == nil)
}

@Test func expansionGoogleSettingPresenceAndFloatValidation() throws {
    // MagicBuds docs/protocol/notes.md confirms 22 02 68 03 on real Pro 2.
    #expect(try GoogleMaestro.noiseWrite(.transparency) == [0x22,2,0x68,3])
    for bytes in [[],[0x22,0],[0x22,2,0x68,0],[0x22,2,0x68,5],
                  [0x22,4,0x68,1,0x68,2],[0x22,3,0x6A,1,1]] as [[UInt8]] {
        #expect(GoogleMaestro.noise(bytes) == nil)
    }
    // An explicitly present empty EqBands is valid flat EQ (proto3 zero defaults).
    #expect(GoogleMaestro.equalizer([0x22,3,0x82,1,0]) == [0,0,0,0,0])
    #expect(GoogleMaestro.equalizer([]) == nil)
    #expect(GoogleMaestro.equalizer([0x22,0]) == nil)
    let bass=expansionHex("22 08 82 01 05 0D 00 00 A0 40")
    #expect(GoogleMaestro.equalizer(bass) == [5,0,0,0,0])
    for field in [[8,0],[0x0D,0,0,0xC0,0x7F],[0x0D,0,0,0x80,0x7F],
                  [0x0D,0,0,0xE0,0x40],[0x0D,0,0,0,0,0x0D,0,0,0,0]] as [[UInt8]] {
        let eq=ProtoFields.encode(4,.bytes(ProtoFields.encode(16,.bytes(field))))
        #expect(GoogleMaestro.equalizer(eq) == nil)
    }
    for bands:[Float] in [[0,0],[-7,0,0,0,0],[.nan,0,0,0,0],[.infinity,0,0,0,0]] {
        #expect(throws:ProtocolError.invalidPayload) { try GoogleMaestro.equalizerWrite(bands) }
    }
}

@Test func expansionGoogleRuntimeDistinguishesZeroUnknownAndMalformedAtomically() throws {
    // maestro_pw.proto: RuntimeInfo.battery_info=6, case/left/right=1/2/3,
    // level=1, charging state=2 (1 discharging; 2 charging; 0 unknown).
    var state=DeviceState()
    let bytes=expansionHex("32 10 0A 04 08 50 10 02 12 02 10 01 1A 04 08 64 10 01")
    #expect(GoogleMaestro.applyRuntime(bytes,to:&state))
    #expect(state.batteries[.enclosure]?.percent == 80 && state.batteries[.enclosure]?.charging == true)
    #expect(state.batteries[.left]?.percent == 0 && state.batteries[.right]?.percent == 100)
    let before=state.batteries
    #expect(!GoogleMaestro.applyRuntime(expansionHex("32 09 12 04 08 01 10 01 1A 01 08"),to:&state))
    #expect(state.batteries == before)
    #expect(GoogleMaestro.applyRuntime(expansionHex("32 0C 12 04 08 01 10 00 1A 04 08 65 10 01"),to:&state))
    #expect(state.batteries[.left] == nil && state.batteries[.right] == nil)
    #expect(!GoogleMaestro.applyRuntime([],to:&state))
}

@Test func expansionGoogleRuntimeSnapshotDoesNotKeepAnAbsentCaseForever() {
    // MagicBuds PixelBudsHeadset.ToBattery treats omitted cells as unknown;
    // docs/protocol/notes.md: the case is only reported while a bud sits in it.
    var state=DeviceState()
    #expect(GoogleMaestro.applyRuntime(expansionHex("32 06 0A 04 08 50 10 01"),to:&state))
    #expect(state.batteries[.enclosure]?.percent == 80)
    #expect(GoogleMaestro.applyRuntime(expansionHex("32 06 12 04 08 28 10 01"),to:&state))
    #expect(state.batteries[.enclosure] == nil)
    #expect(state.batteries[.left]?.percent == 40)
}
