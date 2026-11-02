import Foundation
import Testing
@testable import HeyBudsProtocol

private func xbytes(_ hex:String) -> [UInt8] {
    let text=hex.filter { !$0.isWhitespace };return stride(from:0,to:text.count,by:2).map { at in
        let start=text.index(text.startIndex,offsetBy:at),end=text.index(start,offsetBy:2)
        return UInt8(text[start..<end],radix:16)!
    }
}

@Test func xiaomiCatalogHasOnlyTheSixteenRequestedModelsAndNoInferredVariants() throws {
    let catalog=try ModelCatalog()
    #expect(XiaomiProfile.allCases.count == 16)
    for profile in XiaomiProfile.allCases {
        let model=try #require(catalog.model(productID:nil,name:profile.name))
        #expect(model.id == profile.modelID && model.family == .xiaomi)
        #expect(catalog.validOverride(profile.modelID,family:.xiaomi) == nil)
        #expect(EarbudFamily.xiaomi.transportKinds(for:profile.name) == profile.transportKinds)
        for alias in profile.aliases { #expect(catalog.model(productID:nil,name:alias)?.id == profile.modelID) }
    }
    for unknown in ["Xiaomi Buds 5 Pro Wi-Fi","Redmi Buds 6 Pro Gaming","Redmi Buds 8S","Redmi Buds 8 Pro Max","Redmi Buds 7S"] {
        #expect(XiaomiProfile.named(unknown) == nil)
    }
    #expect(XiaomiProfile.buds5pro.accepts(vendor:0x2717,product:0x50AD))
    #expect(!XiaomiProfile.buds5pro.accepts(vendor:0x2717,product:0x50AB))
    #expect(!XiaomiProfile.redmi8pro.accepts(vendor:0x2717,product:0x509E))
    for profile in [XiaomiProfile.redmi8active,.redmi6play,.clip,.redmi6,.redmi6active,.redmi4pro,.redmi3,.basicS] {
        let model=try #require(catalog.models.first { $0.id == profile.modelID })
        #expect(model.noiseOptions.isEmpty)
    }
    #expect(EarbudFamily.xiaomi.transportKinds(for:"Redmi Buds legacy") == ["RFCOMM"])
    #expect(catalog.validOverride("xiaomi:family",family:.xiaomi) == "xiaomi:family")
    #expect(EarbudFamily.oppo.transportKinds(for:"OPPO Enco X4") == ["RFCOMM","BLE"])
}

@Test func xiaomiCapturedFramesSeparateStatusSequenceAndConfiguration() throws {
    let request=xbytes("FE DC BA C0 F3 00 03 02 00 0B EF")
    let reply=xbytes("FE DC BA 00 F3 00 07 00 02 04 00 0B 01 13 EF")
    var codec=XiaomiFrameCodec()
    #expect(codec.feed(Data(request.prefix(2))).isEmpty)
    let frames=codec.feed(Data(Array(request.dropFirst(2))+reply))
    #expect(frames.count == 2)
    #expect(frames[0].isRequest && frames[0].sequence == 2 && frames[0].payload == [0,11])
    #expect(!frames[1].isRequest && frames[1].status == 0 && frames[1].sequence == 2)
    #expect(frames[1].payload == [4,0,11,1,19])
    #expect(try XiaomiFrameCodec.encode(frames[1]) == Data(reply))
    let fields=try #require(XiaomiProtocol.records(frames[1].payload,idBytes:2))
    #expect(fields[11] == [1,19] && XiaomiProtocol.noise(fields[11]!) == .anc)
    let refused=XiaomiFrame(type:0,opcode:0xF3,sequence:2,status:9)
    #expect(codec.feed(try XiaomiFrameCodec.encode(refused)).first?.status == 9)
}

@Test func xiaomiStreamHandlesEveryFragmentBoundaryAndRejectsMalformedLengths() throws {
    let frame=XiaomiFrame(type:0xC7,opcode:0xF4,sequence:31,payload:[0xEF,0xFE,0xDC,0xBA,0xEF])
    let bytes=Array(try XiaomiFrameCodec.encode(frame))
    for split in 0...bytes.count {
        var codec=XiaomiFrameCodec()
        let first=codec.feed(Data(bytes.prefix(split))),second=codec.feed(Data(bytes.dropFirst(split)))
        #expect(first+second == [frame])
    }
    var codec=XiaomiFrameCodec()
    let bad=xbytes("FE DC BA 00 F3 FF FF 00 01 EF")
    #expect(codec.feed(Data([1,2,3]+bad+bytes)) == [frame])
    #expect(XiaomiProtocol.records([4,0,11,1],idBytes:2) == nil)
    #expect(XiaomiProtocol.records([3,0,7,1,3,0,7,5],idBytes:2) == nil)
    #expect(XiaomiProtocol.records([0],idBytes:1) == nil)
}

@Test func xiaomiBatterySentinelsChargingAndFirmwareAreNotFabricated() throws {
    let batteries=try #require(XiaomiProtocol.batteries([0xE4,0,255]))
    #expect(batteries[.left]?.percent == 100 && batteries[.left]?.charging == true)
    #expect(batteries[.right]?.percent == 0 && batteries[.enclosure] == nil)
    #expect(XiaomiProtocol.batteries([100,101,255]) == nil)
    #expect(XiaomiProtocol.batteries([100,90]) == nil)
    #expect(XiaomiProtocol.firmware([0x12,0x37,0x12,0x37]) == "1.2.3.7")
    #expect(XiaomiProtocol.firmware([0x12]) == nil)
}

@Test func xiaomiMMAAuthenticationMatchesFivePublishedIndependentVectors() throws {
    let vectors=[
        ("9762e8a1836d32cc4b7b8605c553545f","f7fe2d0211bab715efe4c33ac740574d"),
        ("9ddc4d55a9f74b1c2df9d11a2762b281","ac0512878403a24c87d1b6cb974061c9"),
        ("a979ae189a0c36bf973de72297ed1595","7b09a3799fa3005472c2673c9c45e82b"),
        ("57990d37d3dad961ee7e6a092ba4f2ef","6b21b2bdd693d3147ee9e6f41e46eb87"),
        ("60c881a805416aeeaa3a1e079d879568","787748b987ecf34ab33464eaa78f44ba")]
    for (challenge,answer) in vectors { #expect(try XiaomiMMAAuth.response(xbytes(challenge)) == xbytes(answer)) }
    #expect(throws:ProtocolError.invalidPayload) { try XiaomiMMAAuth.response([0]) }
}

@Test func xiaomiMutualAuthenticationNeedsPeerCompletionAndRejectsWrongAnswers() throws {
    let challenge=xbytes("9762e8a1836d32cc4b7b8605c553545f"),answer=xbytes("f7fe2d0211bab715efe4c33ac740574d")
    var auth=try XiaomiCommandAuth(sequence:0,challenge:challenge)
    #expect(try auth.start().payload == [1]+challenge)
    _ = try auth.receive(XiaomiFrame(type:4,opcode:0x50,sequence:42,payload:[1]+answer))
    #expect(!auth.ready)
    let confirmation=try auth.receive(XiaomiFrame(type:4,opcode:0x50,sequence:0,payload:[1]+answer))
    let confirm=try #require(confirmation)
    #expect(confirm.opcode == 0x51 && confirm.payload == [1,0])
    _ = try auth.receive(XiaomiFrame(type:4,opcode:0x51,sequence:1,payload:[1]))
    #expect(!auth.ready)
    let peerResponse=try auth.receive(XiaomiFrame(type:0xC0,opcode:0x50,sequence:18,payload:[1]+challenge))
    let reply=try #require(peerResponse)
    #expect(reply.type == 4 && reply.sequence == 18 && reply.payload == [1]+answer)
    #expect(!auth.ready)
    _ = try auth.receive(XiaomiFrame(type:0xC0,opcode:0x51,sequence:19,payload:[1,0]))
    #expect(auth.ready)
    var invalid=try XiaomiCommandAuth(sequence:0,challenge:challenge);_ = try invalid.start()
    #expect(throws:ProtocolError.invalidPayload) { try invalid.receive(XiaomiFrame(type:4,opcode:0x50,sequence:0,payload:[1]+Array(repeating:0,count:16))) }
    #expect(!invalid.ready)
}

@Test func xiaomiCustomEQUsesSignedMagnitudeExactFrequenciesAndReportedBounds() throws {
    var bytes:[UInt8]=[1,10,6,6,1,0,10]
    for (i,f) in XiaomiProtocol.frequencies.enumerated() { bytes += [UInt8(f >> 8),UInt8(truncatingIfNeeded:f),i == 0 ? 0x86 : 0] }
    let entry=try #require(XiaomiProtocol.customEQ(bytes))
    #expect(entry.gains.first == -6 && entry.minimum == -6 && entry.maximum == 6)
    let write=try XiaomiProtocol.customEQWrite(entry)
    #expect(Array(write.prefix(7)) == [1,10,1,1,1,0,10] && write[9] == 0x86)
    var invalid=bytes;invalid[9]=0x87
    #expect(XiaomiProtocol.customEQ(invalid) == nil)
    invalid=bytes;invalid[7]=1
    #expect(XiaomiProtocol.customEQ(invalid) == nil)
}

@Test func xiaomiSystemBatteryOnlyUsesExactConnectedIdentityAndKeepsUnknowns() throws {
    let address=[UInt8](repeating:0x21,count:6).map { String(format:"%02X",$0) }.joined(separator:":")
    let device:[String:Any]=["device_address":address,"device_batteryLevelMain":"75%"]
    func data(_ entries:[[String:Any]],paired:[[String:Any]]=[] ) throws -> Data {
        try JSONSerialization.data(withJSONObject:["SPBluetoothDataType":[["device_connected":entries,"device_not_connected":paired]]])
    }
    let aggregate=try #require(XiaomiSystemBattery.parse(data([["Redmi Buds 6":device]]),address:address))
    #expect(aggregate.aggregate && aggregate.batteries[.left]?.percent == 75)
    #expect(aggregate.batteries[.right] == nil && aggregate.batteries[.enclosure] == nil)
    #expect(try XiaomiSystemBattery.parse(data([],paired:[["Redmi Buds 6":device]]),address:address) == nil)
    #expect(try XiaomiSystemBattery.parse(data([["A":device],["B":device]]),address:address) == nil)
    var unknown=device;unknown["device_batteryLevelMain"]="255%"
    #expect(try XiaomiSystemBattery.parse(data([["A":unknown]]),address:address)?.batteries.isEmpty == true)
    for invalid in [true,2.5,"7%5%"] as [Any] {
        unknown["device_batteryLevelMain"]=invalid
        #expect(try XiaomiSystemBattery.parse(data([["A":unknown]]),address:address)?.batteries.isEmpty == true)
    }
}
