import Foundation
import Testing
@testable import HeyBudsProtocol

private func bytes(_ string:String) -> [UInt8] { string.split(separator:" ").map { UInt8($0,radix:16)! } }

@Test func capturedBatteryAndEverySplitBoundary() throws {
    // Real T500 frame from the MIT reference's captured self-check fixture.
    let wire=bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
    for split in 0...wire.count {
        var codec=OPOFrameCodec()
        let a=codec.feed(Data(wire.prefix(split)))
        let b=codec.feed(Data(wire.dropFirst(split)))
        #expect(a+b == [OPOFrame(command:0x0204,sequence:0x0C,payload:[1,3,1,100,2,100,3,80])])
    }
}
@Test func framingRejectsMalformedAndResynchronizes() throws {
    let frame=OPOFrame(command:Command.battery,sequence:9,payload:[])
    let valid=try OPOFrameCodec.encode(frame)
    var codec=OPOFrameCodec()
    let malformed=Data([0xAA,7,0,0,6,1,0,200,0])
    #expect(codec.feed(Data([0,9,4])+malformed+valid+valid) == [frame,frame])
    #expect(throws:ProtocolError.invalidPayload) { try OPOFrameCodec.encode(OPOFrame(command:1,payload:Array(repeating:0,count:249))) }
}
@Test func zeroPartialChargingAndInvalidBatteryAreDifferent() {
    var state=DeviceState()
    state.apply(OPOFrame(command:0x8106,payload:[0,3,1,0,2,0xB2,3,25]))
    #expect(state.batteries[.left]?.percent == 0)
    #expect(state.batteries[.right]?.percent == 50)
    #expect(state.batteries[.right]?.charging == true)
    state.apply(OPOFrame(command:0x0204,payload:[1,1,1,70]))
    #expect(state.batteries[.left]?.percent == 70)
    #expect(state.batteries[.right]?.percent == 50)
    state.apply(OPOFrame(command:0x0204,payload:[1,1,3,0x7F]))
    #expect(state.batteries[.enclosure] == nil)
}
@Test func entire137ModelCatalogAndOriginalIDs() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.models.filter { $0.family == .oppo }.count == 137)
    #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
    for model in catalog.models {
        #expect(!model.name.isEmpty)
        #expect(catalog.model(productID:model.id,name:"")?.id == model.id)
        for option in model.noiseOptions { #expect(!option.writeBytes.isEmpty && option.writeBytes.count <= 2) }
        for alias in model.aliases { #expect(catalog.model(productID:nil,name:alias) != nil) }
    }
}
@Test func eqPreservesNonSequentialWireIDs() throws {
    let catalog=try ModelCatalog()
    let air=try #require(catalog.model(productID:"06C410",name:""))
    #expect(air.presets.map(\.id) == [0,2,1])
    let pro=try #require(catalog.model(productID:"064014",name:""))
    #expect(pro.presets.map(\.id) == [0,1,2,3,7])
    #expect(pro.spatialModes == [0,1,2])
}
@Test func modelSpecificNoiseReadAndWriteMappings() throws {
    let c=try ModelCatalog()
    let air=try #require(c.model(productID:"06C410",name:""))
    let realme=try #require(c.model(productID:"066452",name:""))
    #expect(air.noiseOptions.first(where:{$0.mode == .transparency})?.payload == [1,1,4])
    #expect(realme.noiseOptions.first(where:{$0.mode == .transparency})?.payload == [1,1,2])
    var state=DeviceState()
    state.applyNoise([0,1,1,0,1],t500:false)
    #expect(state.noise == .transparency)
    state.applyNoise([0,4,1,0x10,0],t500:false)
    #expect(state.noise == .smart && state.liveNoise == .deep)
    state.applyNoise([1,1,2],t500:true)
    #expect(state.noise == .transparency)
    state.applyNoise([4,1,8],t500:true)
    #expect(state.noise == .transparency) // live smart level is not a main-mode event
}
@Test func productIdentityIsLittleEndianAndLegacyNormalized() {
    var state=DeviceState()
    state.apply(OPOFrame(command:0x8103,payload:[0,0x10,0xC4,6]))
    #expect(state.productID == "06C410")
    state.apply(OPOFrame(command:0x8103,payload:[0,1,1,0x10]))
    #expect(state.productID == "060414")
}
@Test func capabilityBitsDoNotEnableUnreportedCommands() {
    #expect(CapabilityBitmap.decode([0,0])?.contains(Command.setNoise) == false)
    #expect(CapabilityBitmap.decode([0,0,1])?.contains(Command.setNoise) == true)
    #expect(CapabilityBitmap.decode([2,255]) == nil)
}
@Test func customEQRangesUTF8AndTruncation() throws {
    let entry=CustomEQEntry(id:2,name:"低音A",frequencies:[62,1000],gains:[-3,6])
    let payload=try FeatureCodec.customPayload(entry)
    let response:[UInt8]=[0,1,0]+Array(payload.dropFirst())
    let decoded=try #require(FeatureCodec.customEntries(response))
    #expect(decoded.first?.gains == [-3,6])
    #expect(decoded.first?.name == "低音A")
    #expect(FeatureCodec.customEntries(Array(response.dropLast())) == nil)
    #expect(!FeatureCodec.validEQName("bad name"))
    let invalid=CustomEQEntry(name:"Test",frequencies:[62],gains:[20])
    #expect(throws:ProtocolError.invalidPayload) { try FeatureCodec.customPayload(invalid) }
}
@Test func hostAddressRoundTripAndNoUnpairSurface() throws {
    let wire:[UInt8]=[1,2,3,4,5,6]
    let payload:[UInt8]=[0,1]+wire+[1,2,1,5]+Array("Phone".utf8)
    let host=try #require(FeatureCodec.remoteHosts(payload)?.first)
    #expect(host.name == "Phone" && host.connected && host.current)
    let canonical=Array(wire.reversed())
    #expect(host.address == canonical)
    #expect(try FeatureCodec.hostPayload(.priority,address:host.address) == [4,1]+canonical)
    #expect(try FeatureCodec.hostPayload(.connect,address:host.address) == [1]+canonical)
    #expect(try FeatureCodec.hostPayload(.disconnect,address:host.address) == [2]+canonical)
    #expect(try FeatureCodec.hostPayload(.automatic) == [4,0])
    #expect(FeatureCodec.remoteHosts(Array(payload.dropLast())) == nil)
    let pairedOnly:[UInt8]=[0,1]+wire+[1,1,0,0]
    #expect(FeatureCodec.remoteHosts(pairedOnly)?.first?.connected == false)
}
@Test func priorityReadbackRequiresCompleteValidAddressAndMatchesHostList() throws {
    let wire:[UInt8]=[1,2,3,4,5,6]
    var state=DeviceState()
    state.apply(OPOFrame(command:0x8132,payload:[0,1,1]))
    #expect(!state.observedQueries.contains(Command.priority))
    #expect(state.automaticPriority == nil)
    state.apply(OPOFrame(command:0x8132,payload:[0,2,1]+wire))
    #expect(state.automaticPriority == false)
    #expect(state.priorityAddress == Array(wire.reversed()))
    let host=try #require(FeatureCodec.remoteHosts([0,1]+wire+[0,2,6,0])?.first)
    #expect(host.address == state.priorityAddress && host.audioActive && host.preferred)
    state.apply(OPOFrame(command:0x8132,payload:[0,1,0]))
    #expect(state.automaticPriority == true && state.priorityAddress == nil)
    state.apply(OPOFrame(command:0x8132,payload:[2,1]+wire))
    #expect(state.automaticPriority == false && state.priorityAddress == Array(wire.reversed()))
    state.apply(OPOFrame(command:0x8132,payload:[1,0]))
    #expect(state.automaticPriority == true && state.priorityAddress == nil)
    #expect(FeatureCodec.hostPriority([0,1]) == nil)
    #expect(FeatureCodec.hostPriority([1,1]) == nil)
    #expect(FeatureCodec.hostPriority([0,5,0]) == nil)
}
@Test func unsupportedModelRemainsUnknown() throws {
    #expect(try ModelCatalog().model(productID:"FFFFFF",name:"OPPO mystery") == nil)
}
@Test func firmwareConstraintsAndFormattingArePreserved() throws {
    let c=try ModelCatalog()
    let pro2=try #require(c.models.first(where:{$0.name == "OnePlus Buds Pro 2"}))
    let guarded=try #require(pro2.presets.first(where:{$0.id == 7}))
    #expect(!guarded.available(firmware:nil))
    #expect(!guarded.available(firmware:164))
    #expect(guarded.available(firmware:165))
    var state=DeviceState()
    state.apply(OPOFrame(command:0x8105,payload:[0,0]+Array("1,2,158,2,2,158,3,1,01,3,2,105".utf8)))
    #expect(state.firmware == "158.158.105")
    #expect(state.firmwareRevision == 158)
}
@Test func malformedReplyDoesNotEnableAWrite() {
    var state=DeviceState()
    state.apply(OPOFrame(command:0x810C,payload:[0]))
    #expect(!state.observedQueries.contains(Command.noise))
}
