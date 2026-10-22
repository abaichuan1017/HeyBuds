// SPDX-License-Identifier: GPL-3.0-only
// X4 configuration and public frame fixtures: EncoDeck contributors.
// https://github.com/TIANLI0/EncoDeck/tree/ba5db26753eceacaa4ba48ab3b87067cc0ec7da4
import Foundation
import Testing
@testable import HeyBudsProtocol

private func x4Frame(_ text:String) throws -> OPOFrame {
    let wire=Data(text.split(separator:" ").map { UInt8($0,radix:16)! })
    var codec=OPOFrameCodec()
    return try #require(codec.feed(wire).first)
}

@Test func encoX4IdentityAliasesAndConfiguration() throws {
    let catalog=try ModelCatalog()
    let model=try #require(catalog.model(productID:"06ec10",name:"renamed earbuds"))
    #expect(model.name == "OPPO Enco X4" && model.family == .oppo)
    #expect(catalog.model(productID:nil,name:"OPPO Enco Bohr")?.id == model.id)
    #expect(catalog.model(productID:nil,name:"OPPO Enco X4")?.id == model.id)
    #expect(model.presets.map(\.id) == [0,7,2,1,3])
    #expect(model.presets.map(\.chinese) == ["丹拿原声","丹拿高解析","纯享人声","清亮高音","澎湃低音"])
    #expect(model.presets.allSatisfy { $0.available(firmware:nil) })
    #expect(model.customEQFrequencies == [31,62,125,250,500,1000,2000,4000,8000,16000])
    #expect(model.spatialModes == [0,1,2] && model.gameTypes == [3])
    #expect(model.hasMultiDevice && model.gameBlocksSpatial)
    #expect(FeatureCodec.switchQuery(model:model).contains(0x18))
}

@Test func encoX4NoiseParentWritesAndChildReadback() throws {
    let model=try #require(ModelCatalog().model(productID:"06EC10",name:""))
    let expected:[NoiseMode:[UInt8]] = [.off:[1],.transparency:[4],.smart:[0x80],.deep:[0x10],.medium:[0x20],.light:[0x40],.adaptive:[0,8]]
    #expect(model.noiseOptions.count == expected.count)
    for option in model.noiseOptions { #expect(option.writeBytes == expected[option.mode]) }
    let reports:[(Int,NoiseMode)] = [(0,.off),(3,.off),(2,.transparency),(8,.transparency),
        (1,.smart),(7,.smart),(4,.deep),(5,.medium),(6,.light),(11,.adaptive),(12,.adaptive),(13,.adaptive),(14,.adaptive)]
    for (index,mode) in reports {
        let bits=UInt16(1) << index
        var state=DeviceState()
        state.applyNoise([0,1,1,UInt8(truncatingIfNeeded:bits),UInt8(bits>>8)],t500:false,model:model)
        #expect(state.noise == mode)
    }
    #expect(model.reportedNoise(mask:0) == nil)
    #expect(model.reportedNoise(mask:3) == nil)
}

@Test func encoX4PublicCapturedFramesDecode() throws {
    let model=try #require(ModelCatalog().model(productID:"06EC10",name:""))
    var state=DeviceState()
    state.apply(try x4Frame("AA 0B 00 00 03 81 02 04 00 00 10 EC 06"),model:model)
    #expect(state.productID == "06EC10")
    state.apply(try x4Frame("AA 0F 00 00 06 81 F0 08 00 00 03 01 C6 02 C6 03 46"),model:model)
    #expect(state.batteries[.left]?.percent == 70 && state.batteries[.left]?.charging == true)
    #expect(state.batteries[.enclosure]?.percent == 70 && state.batteries[.enclosure]?.charging == false)
    state.apply(try x4Frame("AA 0C 00 00 0C 81 04 05 00 00 01 01 08 00"),model:model)
    #expect(state.noise == .off)
    state.apply(try x4Frame("AA 0C 00 00 04 02 25 05 00 03 01 01 00 20"),model:model)
    #expect(state.noise == .adaptive)
    state.apply(try x4Frame("AA 0C 00 00 04 02 26 05 00 03 04 01 40 00"),model:model)
    #expect(state.noise == .smart && state.liveNoise == .light)
    state.apply(try x4Frame("AA 0D 00 00 04 02 24 06 00 01 02 01 5A 02 5A"),model:model)
    #expect(state.batteries[.left]?.percent == 90 && state.batteries[.enclosure]?.percent == 70)
    #expect(state.noise == .smart) // A battery notification must not change noise mode.
    state.apply(try x4Frame("AA 20 00 00 05 81 07 19 00 00 03 31 2C 32 2C 31 31 36 2C 32 2C 32 2C 31 31 36 2C 33 2C 32 2C 31 30 30"),model:model)
    #expect(state.firmware == "116.116.100")
}

@Test func encoX4CapturedTenBandCustomEQ() throws {
    let frame=try x4Frame("AA 37 00 00 22 81 06 30 00 00 01 00 FA 06 04 0A E8 87 AA E5 AE 9A E4 B9 89 31 0A 1F 00 00 3E 00 00 7D 00 00 FA 00 00 F4 01 00 E8 03 00 D0 07 00 A0 0F 00 40 1F 00 80 3E 00")
    let entry=try #require(FeatureCodec.customEntries(frame.payload)?.first)
    #expect(entry.id == 4 && entry.name == "自定义1")
    #expect(entry.minimum == -6 && entry.maximum == 6)
    #expect(entry.frequencies == [31,62,125,250,500,1000,2000,4000,8000,16000])
    #expect(entry.gains == Array(repeating:0,count:10))
}
