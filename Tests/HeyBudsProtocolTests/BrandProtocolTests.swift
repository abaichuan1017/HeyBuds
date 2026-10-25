import Foundation
import Testing
@testable import HeyBudsProtocol

private func hex(_ string:String) -> [UInt8] { string.split(separator:" ").map { UInt8($0,radix:16)! } }
@Test func catalogIndexesPreserveLookupPrecedenceAndAliasOrder() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.model(productID:"06c410",name:"FreeBuds Pro 3")?.id == "06C410")
    #expect(catalog.model(productID:"06C410",name:"AirPods Pro",override:"066452")?.id == "066452")
    #expect(catalog.model(productID:"missing",name:"OPPO Enco Air5 Pro",override:"missing")?.id == "06C410")
    for model in catalog.models {
        for name in [model.name]+model.aliases {
            let key=EarbudFamily.normalize(name)
            let first=catalog.models.first { candidate in
                ([candidate.name]+candidate.aliases).contains { EarbudFamily.normalize($0) == key }
            }
            #expect(catalog.model(productID:nil,name:name)?.id == first?.id)
        }
    }
}
@Test func migratedCatalogCoversSourceFamiliesAndDisambiguatesNames() throws {
    let c=try ModelCatalog()
    #expect(c.models.filter { $0.family != .sony }.count == 209)
    #expect(c.models.filter { $0.family == .vivo }.count == 43)
    #expect(c.models.filter { $0.family == .huawei }.count == 24)
    #expect(c.models.filter { $0.family == .vivo }.reduce(0) { $0+$1.raw["sourceEntries"].elements.count } == 87)
    for n in ["FreeBuds Pro 2","FreeBuds Pro 3","FreeBuds Pro 4","FreeBuds Pro 5"] {
        #expect(c.model(productID:nil,name:n+" (test)")?.name == "HUAWEI "+n)
    }
    #expect(c.family(name:"DPD2321A LE") == .vivo)
    #expect(c.family(name:"my Redmi Buds") == .xiaomi)
    #expect(c.family(name:"W820NB Plus") == .edifier)
    #expect(c.family(name:"AirPods Pro") == nil)
    #expect(c.family(name:"Beats Fit Pro") == nil)
    #expect(!c.models.contains { $0.id.hasPrefix("apple:") })
    #expect(c.family(name:"Soundcore Liberty Air") == nil)
    #expect(c.family(name:"Keyboard") == nil)
    let tws3e=try #require(c.model(productID:nil,name:"vivo TWS 3e"))
    #expect(!tws3e.hasMultiDevice)
    #expect(tws3e.function["findDevice"].enabled && tws3e.function["wearDetection"].enabled)
    #expect(!tws3e.supportsGame)
    #expect(tws3e.raw["noiseSuffix"].elements.compactMap(\.int) == [3])
}
@Test func goldenBrandFramesAndEveryStreamSplit() throws {
    let fixtures:[(EarbudFamily,UInt8,Bool,BrandFrame,[UInt8])]=[
        (.vivo,3,false,BrandFrame(0x0300),hex("FF 04 00 00 00 0A 03 00")),
        (.vivo,3,false,BrandFrame(0x0207),hex("FF 04 00 00 00 1B 02 07")),
        (.vivo,3,false,BrandFrame(0x0130,[2,4,0]),hex("FF 03 00 03 00 1B 01 30 02 04 00")),
        (.huawei,4,false,BrandFrame(0x0108,[1,0,2,0,3,0]),hex("5A 00 09 00 01 08 01 00 02 00 03 00 FB B9")),
        (.huawei,4,false,BrandFrame(0x2B2A,[1,0]),hex("5A 00 05 00 2B 2A 01 00 42 7E")),
        (.huawei,4,true,BrandFrame(0x2B49,[1,1,5,2,2,0x10,0x20]),hex("5A 00 0A 00 2B 49 01 01 05 02 02 10 20 B9 D4")),
        (.xiaomi,4,false,BrandFrame(2,[255,255,255,255],sequence:0x0B),hex("FE DC BA C4 02 00 05 0B FF FF FF FF EF")),
        (.xiaomi,4,false,BrandFrame(0xF2,[3,0,47,1],sequence:0x90),hex("FE DC BA C4 F2 00 05 90 03 00 2F 01 EF")),
        (.xiaomi,4,false,BrandFrame(0x51,[3,1],sequence:0,kind:4),hex("FE DC BA 04 51 00 03 00 03 01 EF"))]
    for (family,version,mbb,frame,wire) in fixtures {
        let c=BrandFrameCodec(family:family,gaiaVersion:version,mbb:mbb)
        #expect(Array(try c.encode(frame)) == wire)
        for split in 0...wire.count {
            var decoder=c
            let a=decoder.feed(Data([0,1,2])+Data(wire.prefix(split)))
            let b=decoder.feed(Data(wire.dropFirst(split))+Data(wire))
            #expect((a+b).map(\.command) == [frame.command,frame.command])
            #expect((a+b).map(\.payload) == [frame.payload,frame.payload])
        }
    }
}
@Test func edifierFrameRetainsCommandAndLastPayloadByte() throws {
    let codec=BrandFrameCodec(family:.edifier)
    let bytes=Array(try codec.encode(BrandFrame(0xC1,[3])))
    #expect(bytes == hex("AA 02 C1 03 21 89"))
    var response:[UInt8]=[0xBB,2,0xCC,3]
    let sum=response.reduce(UInt16(8217)) { $0 &+ UInt16($1) };response += [UInt8(sum>>8),UInt8(truncatingIfNeeded:sum)]
    for split in 0...response.count {
        var c=codec
        let a=c.feed(Data(response.prefix(split))),b=c.feed(Data(response.dropFirst(split)))
        #expect(a+b == [BrandFrame(0xCC,[3])])
    }
}
@Test func brandFramesRejectCorruptionAndRecover() throws {
    let frame=BrandFrame(0x2B2A,[1,2,3,1]),codec=BrandFrameCodec(family:.huawei)
    let good=try codec.encode(frame);var bad=Array(good);bad[bad.count-1] ^= 1
    var decoder=codec
    #expect(decoder.feed(Data(bad)+good) == [frame])
    #expect(BrandFrameCodec.tlv([1,4,2]) == nil)
    #expect(throws:ProtocolError.invalidPayload) { try BrandFrameCodec(family:.vivo).encode(BrandFrame(1,Array(repeating:0,count:255))) }
    #expect(throws:ProtocolError.invalidPayload) { try BrandFrameCodec(family:.edifier).encode(BrandFrame(1,Array(repeating:0,count:255))) }
}
@Test func brandBatteryUnknownZeroAndWearStatesStayDistinct() throws {
    let catalog=try ModelCatalog(),v=try #require(catalog.model(productID:nil,name:"vivo TWS 4")),h=try #require(catalog.model(productID:nil,name:"FreeBuds Studio"))
    var state=DeviceState()
    #expect(BrandState.apply(BrandFrame(0x8207,[0,0,255,80,5]),model:v,to:&state))
    #expect(state.batteries[.left]?.percent == 0 && state.batteries[.left]?.charging == true)
    #expect(state.batteries[.right] == nil)
    #expect(state.batteries[.enclosure]?.percent == 80)
    #expect(!BrandState.apply(BrandFrame(0x8207,[1,50,50,50,0]),model:v,to:&state))
    #expect(BrandState.apply(BrandFrame(0x820D,[0,6]),model:v,to:&state))
    #expect(state.placement[.left] == 3 && state.placement[.right] == 4)
    #expect(BrandState.apply(BrandFrame(0x0108,[2,1,75,3,1,1]),model:h,to:&state))
    #expect(state.batteries[.left]?.percent == 75 && state.batteries[.left]?.charging == true)
    #expect(state.batteries[.right] == nil && state.batteries[.enclosure] == nil)
}
@Test func modelSpecificNoiseAndEQAreNotInterchangeable() throws {
    let c=try ModelCatalog(),pro=try #require(c.model(productID:nil,name:"FreeBuds Pro 3")),air=try #require(c.model(productID:nil,name:"vivo TWS Air3 Pro"))
    #expect(pro.presets.map(\.id) == [5,1,2,9])
    #expect(pro.noiseOptions.first(where:{$0.mode == .deep})?.writeBytes == [1,2])
    #expect(air.raw["gaiaVersion"].int == 3)
    #expect(air.raw["noiseSuffix"].elements.compactMap(\.int) == [4,0])
    var state=DeviceState()
    #expect(BrandState.apply(BrandFrame(0x2B2A,[1,2,2,1]),model:pro,to:&state))
    #expect(state.noise == .deep)
    // A SET echo must not become verified state.
    #expect(!BrandState.apply(BrandFrame(0x8130,[2,4,0]),model:air,to:&state))
    #expect(state.noise == .deep)
    #expect(BrandState.apply(BrandFrame(0x8230,[0,2,1]),model:air,to:&state))
    #expect(state.noise == .transparency)
}
@Test func remoteListsRequireCompleteRowsAndCorrectAddressOrder() {
    let payload:[UInt8]=[0,1,6,5,4,3,2,1,0,0,0,2,3,77,97,99]
    #expect(BrandState.vivoHosts(payload)?.first?.address == [1,2,3,4,5,6])
    #expect(BrandState.vivoHosts(Array(payload.dropLast())) == nil)
    #expect(BrandState.vivoHosts([0,0]) == [])
    let row:[UInt8]=[2,1,1,3,1,0,4,6,1,2,3,4,5,6,5,1,9,7,1,1,9,3,77,97,99]
    let host=BrandState.huaweiHost(row)?.host
    #expect(host?.address == [1,2,3,4,5,6] && host?.preferred == true && host?.audioActive == true)
}
@Test func xiaomiAuthMatchesIndependentUpstreamRoundFunctionVectors() throws {
    #expect(try XiaomiAuth.response([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]) == [224, 205, 103, 156, 132, 213, 183, 32, 79, 23, 165, 217, 35, 67, 90, 104])
    #expect(try XiaomiAuth.response([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) == [215, 170, 85, 59, 84, 215, 123, 176, 201, 219, 112, 252, 201, 89, 164, 5])
    #expect(try XiaomiAuth.response([255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255]) == [149, 177, 97, 196, 26, 182, 62, 95, 90, 132, 6, 21, 75, 9, 249, 76])
    #expect(throws:ProtocolError.invalidPayload) { try XiaomiAuth.response([0]) }
}
