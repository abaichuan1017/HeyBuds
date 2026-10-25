import Foundation
import Testing
@testable import HeyBudsProtocol

@Test func sonyEnvelopeUsesDocumentedBytesAndStreamingEscapes() throws {
    #expect(try SonyFrameCodec.encode(SonyFrame(payload:[0,0])) == Data([0x3E,0x0C,0,0,0,0,2,0,0,0x0E,0x3C]))
    let frame=SonyFrame(sequence:1,payload:[0x3C,0x3D,0x3E]),encoded=try SonyFrameCodec.encode(frame)
    #expect(encoded.contains(0x2C) && encoded.contains(0x2D) && encoded.contains(0x2E))
    for split in 0...encoded.count {
        var codec=SonyFrameCodec()
        #expect(codec.feed(encoded.prefix(split))+codec.feed(encoded.dropFirst(split)) == [frame])
    }
    var codec=SonyFrameCodec()
    #expect(codec.feed(encoded+encoded) == [frame,frame])
}

@Test func sonyParserRejectsDamageAndRecoversWithBoundedInput() throws {
    let valid=try SonyFrameCodec.encode(SonyFrame(payload:[4,1]))
    var checksum=Array(valid);checksum[8] ^= 1
    let damaged:[Data]=[Data(checksum),Data([0x3E,0x3D,0xFF,0x3C]),
        Data([0x3E,0x0C,0,0xFF,0xFF,0xFF,0xFF])+Data(repeating:0,count:20_000),
        Data([0x3E,0x0C,0,0,0,0,1,0,0,0x0D,0x3C]),Data([0x3E,0x3D])]
    for bytes in damaged {
        var codec=SonyFrameCodec()
        #expect(codec.feed(bytes).isEmpty)
        #expect(codec.feed(valid) == [SonyFrame(payload:[4,1])])
    }
    #expect(throws:ProtocolError.self) { try SonyFrameCodec.encode(SonyFrame(payload:Array(repeating:0,count:4097))) }
}

@Test func sonyHandshakeRejectsV1AndUnavailableTable() {
    #expect(SonyProtocol.validHandshake([1,0,3,0,0x30,0x18,0,0]))
    for malformed:[UInt8] in [[1,0,0,1],[1,0,3,0,0x30,0x18,1,0],[1,0,3,0,0x30,0x18,0],[1,0,0,0,0,0,0,0]] {
        #expect(!SonyProtocol.validHandshake(malformed))
    }
    #expect(SonyProtocol.functions([7,0,2,0x29,0xFF,0x6B,8]) == Set([0x29,0x6B]))
    #expect(SonyProtocol.functions([7,0,2,0x29,0xFF]) == nil)
    #expect(SonyProtocol.functions([7,0,2,0x29,0xFF,0x29,0]) == nil)
    #expect(SonyProtocol.functions([7,0,0]) == [])
}

@Test func sonyBatterySupportsThresholdsUnknownAndPartialReports() {
    var state=DeviceState()
    #expect(SonyProtocol.applyBattery([0x23,9,0,0,100,1,20,20],to:&state))
    #expect(state.batteries[.left]?.percent == 0 && state.batteries[.right]?.charging == true)
    #expect(state.batteries[.enclosure] == nil)
    #expect(SonyProtocol.applyBattery([0x25,10,52,0,30],to:&state))
    #expect(state.batteries[.enclosure]?.percent == 52 && state.batteries[.right]?.percent == 100)
    #expect(SonyProtocol.applyBattery([0x25,9,0xFF,0xFF,88,0,20,20],to:&state))
    #expect(state.batteries[.left] == nil && state.batteries[.right]?.percent == 88)
    #expect(!SonyProtocol.applyBattery([0x23,9,20,0,50,0],to:&state))
    #expect(state.batteries[.right]?.percent == 88)
    #expect(SonyProtocol.applyBattery([0x23,0,79,0],to:&state))
    #expect(state.batteries[.left]?.percent == 79)
    #expect(SonyProtocol.batteryQueries(functions:[0x20,0x28],single:true) == [8])
    #expect(SonyProtocol.batteryQueries(functions:[0x21,0x22],single:false) == [1,2])
    #expect(SonyProtocol.batteryQueries(functions:[0x29],single:false) == [9])
}

@Test func sonyNoiseDoesNotConfuseANCWithAmbientLevel() throws {
    let anc=try #require(SonyProtocol.noise([0x67,0x17,1,1,0,1,20]))
    #expect(anc.mode == .anc && anc.ambientLevel == 20 && anc.focusOnVoice)
    #expect(SonyProtocol.noise([0x69,0x17,1,1,1,0,7])?.mode == .transparency)
    #expect(SonyProtocol.noise([0x67,0x17,1,0,1,0,20])?.mode == .off)
    #expect(SonyProtocol.noise([0x67,0x17,0,1,1,0,20])?.settled == false)
    for p:[UInt8] in [[0x67,0x17],[0x67,0x17,1,1,2,0,20],[0x67,0x17,1,1,1,0,21]] { #expect(SonyProtocol.noise(p) == nil) }
    #expect(try SonyProtocol.noiseWrite(mode:.anc,level:20,voice:true) == [0x68,0x17,1,1,0,1,20])
    #expect(throws:ProtocolError.self) { try SonyProtocol.noiseWrite(mode:.deep,level:20,voice:false) }
}

@Test func sonyCatalogAddsExactlyThreeProfilesWithoutChangingOldFamilies() throws {
    let catalog=try ModelCatalog(),sony=catalog.models.filter { $0.family == .sony }
    #expect(sony.count == 3 && catalog.models.count == 212 && catalog.models.filter { $0.family != .sony }.count == 209)
    #expect(catalog.model(productID:nil,name:"Sony WF-1000XM5")?.singleBattery == false)
    #expect(catalog.model(productID:nil,name:"WH-1000XM5")?.singleBattery == true)
    #expect(catalog.model(productID:nil,name:"WH-CH720N")?.singleBattery == true)
    for name in ["Sony speaker","WH-1000XM4","WF-1000XM4","WH-1000XM6","XM5"] { #expect(catalog.family(name:name) == nil) }
    #expect(catalog.routingFamily(name:"Renamed headphones",services:[.sony]) == .sony)
    #expect(catalog.family(name:"WH-1000XM5",override:"06EC10") == .sony)
    #expect(catalog.validOverride("sony:wh-1000xm5",family:.oppo) == nil)
    #expect(catalog.validOverride("sony:wh-1000xm5",family:.sony) == nil)
    #expect(EarbudFamily.sony.serviceUUID == SonyProtocol.serviceV2)
    #expect(EarbudFamily.oppo.serviceUUID == "0000079A-D102-11E1-9B23-00025B00A5A5")
}
