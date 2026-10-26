import Foundation
import Testing
@testable import HeyBudsProtocol

@Test func sonyExpansionProfilesAreExactAndGenerationServicesStaySeparate() {
    #expect(SonyProtocol.allProfiles.count == 7)
    for name in ["WH-1000XM3","Sony WH-1000XM4"] {
        let p=SonyProtocol.profile(name:name)
        #expect(p?.generation == .v1 && p?.serviceUUID == SonyProtocol.serviceV1)
    }
    #expect(SonyProtocol.profile(name:"WH-XB910N") == .whXB910n)
    #expect(SonyProtocol.profile(name:"WH-ULT900N") == .ultWear)
    #expect(SonyProtocol.profile(name:"ULT WEAR") == .ultWear)
    #expect(SonyProtocol.serviceUUID(for:"ULT WEAR") == SonyProtocol.serviceV2)
    #expect(SonyProfile.ultWear.ambientLevelRange == nil)
    #expect(SonyProfile.ultWear.supportsFocusOnVoice)
    for name in ["XM4","WF-1000XM4","WH-XB900N","WH-1000XM6","WH-1000XM3 clone","ULT"] {
        #expect(SonyProtocol.profile(name:name) == nil)
    }
}

@Test func sonyExpansionV1UsesFlatFunctionsAndNeverV2BatteryOpcode() {
    #expect(SonyProtocol.generation(fromHandshake:[1,0,0,1]) == .v1)
    #expect(SonyProtocol.generation(fromHandshake:[1,0,2,0,0,1,0,0]) == .v2)
    for bytes:[UInt8] in [[1,0,0,0],[1,1,0,1],[1,0,0,1,0],[1,0,2,0,0,1,1,0]] {
        #expect(SonyProtocol.generation(fromHandshake:bytes) == nil)
    }
    #expect(SonyProtocol.functions([7,0,2,0x11,0x62],generation:.v1) == [0x11,0x62])
    #expect(SonyProtocol.functions([7,0,2,0x11,0xFF,0x62,0xFF],generation:.v1) == nil)
    #expect(SonyProtocol.functions([7,0,2,0x11,0x11],generation:.v1) == nil)
    #expect(SonyProtocol.functions([7,0,2,0x11,0x62],generation:.v2) == nil)
    #expect(SonyProtocol.batteryQueries(functions:[0x11,0x20,0x28],single:true,generation:.v1) == [0])
    #expect(SonyProtocol.batteryQueries(functions:[0x20,0x28],single:true,generation:.v1).isEmpty)
    #expect(SonyProtocol.batteryQueries(functions:[0x11],single:false,generation:.v1).isEmpty)
    #expect(SonyProtocol.batteryRequest(subtype:0,generation:.v1) == [0x10,0])
    #expect(SonyProtocol.batteryRequest(subtype:8,generation:.v1) == nil)
    var state=DeviceState()
    #expect(SonyProtocol.applyBattery([0x11,0,80,1],generation:.v1,to:&state))
    #expect(state.batteries[.left]?.percent == 80)
    #expect(!SonyProtocol.applyBattery([0x23,0,10,0],generation:.v1,to:&state))
    #expect(state.batteries[.left]?.percent == 80)
    #expect(SonyProtocol.applyBattery([0x13,0,0xFF,0xFF],generation:.v1,to:&state))
    #expect(state.batteries[.left] == nil)
    #expect(!SonyProtocol.applyBattery([0x11,0,70],generation:.v1,to:&state))
}

@Test func sonyExpansionV1NoiseDoesNotUseV2OffsetsOrTransitionFlags() throws {
    for profile:SonyProfile in [.wh1000xm3,.wh1000xm4] {
        #expect(SonyProtocol.noise([0x67,2,1,1,2,1,0,0],profile:profile)?.mode == .anc)
        let ambient=try #require(SonyProtocol.noise([0x69,2,1,1,0,1,1,7],profile:profile))
        #expect(ambient.mode == .transparency && ambient.ambientLevel == 7 && ambient.focusOnVoice && ambient.settled)
        let off=try #require(SonyProtocol.noise([0x67,2,0,1,2,1,0,0],profile:profile))
        #expect(off.mode == .off && off.settled)
        #expect(SonyProtocol.noise([0x67,2,0x10,1,0,1,0,8],profile:profile)?.settled == false)
        #expect(SonyProtocol.noise([0x67,2,0x11,1,0,1,0,8],profile:profile)?.settled == true)
        #expect(try SonyProtocol.noiseWrite(mode:.anc,level:20,voice:false,profile:profile) == [0x68,2,1,1,2,1,0,0])
        #expect(try SonyProtocol.noiseWrite(mode:.off,level:20,voice:false,profile:profile) == [0x68,2,0,1,0,1,0,0])
        #expect(try SonyProtocol.noiseWrite(mode:.transparency,level:7,voice:true,profile:profile) == [0x68,2,1,1,0,1,1,7])
        for p:[UInt8] in [[0x67,2,1,1,0,1,1],[0x67,2,2,1,0,1,1,7],[0x67,2,1,0,0,1,1,7],[0x67,2,1,1,0,1,1,21],[0x67,0x17,1,1,1,0,7]] {
            #expect(SonyProtocol.noise(p,profile:profile) == nil)
        }
    }
}

@Test func sonyExpansionXBAndULTHaveDistinctEightByteProfiles() throws {
    let xb=try #require(SonyProtocol.noise([0x67,0x16,1,1,1,2,1,9],profile:.whXB910n))
    #expect(xb.mode == .transparency && xb.ambientLevel == 9 && xb.focusOnVoice)
    #expect(try SonyProtocol.noiseWrite(mode:.transparency,level:9,voice:true,profile:.whXB910n) == [0x68,0x16,1,1,1,2,1,9])
    let ult=try #require(SonyProtocol.noise([0x69,0x17,1,1,1,2,1,0],profile:.ultWear))
    #expect(ult.mode == .transparency && ult.ambientLevel == nil && ult.focusOnVoice)
    #expect(try SonyProtocol.noiseWrite(mode:.transparency,level:nil,voice:true,profile:.ultWear) == [0x68,0x17,1,1,1,2,1,0])
    #expect(try SonyProtocol.noiseWrite(mode:.anc,level:nil,voice:true,profile:.ultWear) == [0x68,0x17,1,1,0,2,0,0])
    #expect(throws:ProtocolError.self) { try SonyProtocol.noiseWrite(mode:.transparency,level:5,voice:false,profile:.ultWear) }
    for level in [0,21,255] {
        #expect(SonyProtocol.noise([0x67,0x16,1,1,1,2,0,UInt8(level)],profile:.whXB910n) == nil)
        #expect(throws:ProtocolError.self) { try SonyProtocol.noiseWrite(mode:.transparency,level:level,voice:false,profile:.whXB910n) }
    }
    for p:[UInt8] in [[0x67,0x17,1,1,1,0,7],[0x67,0x17,1,1,1,2,0,1],[0x67,0x17,1,1,1,1,0,0],[0x67,0x16,1,1,1,2,0,7]] {
        #expect(SonyProtocol.noise(p,profile:.ultWear) == nil)
    }
    #expect(SonyProtocol.noise([0x67,0x17,1,1,1,2,0,0],profile:.wh1000xm5) == nil)
}

@Test func sonyExpansionOriginalThreeProfilesRemainByteIdentical() throws {
    for profile:SonyProfile in [.wf1000xm5,.wh1000xm5,.whCH720n] {
        for mode:NoiseMode in [.off,.anc,.transparency] {
            let payload=try SonyProtocol.noiseWrite(mode:mode,level:7,voice:true,profile:profile)
            let expected:[UInt8]=[0x68,0x17,1,mode == .off ? 0 : 1,mode == .transparency ? 1 : 0,1,7]
            #expect(payload == expected)
            let reply=[UInt8(0x67)]+payload.dropFirst()
            let noise=try #require(SonyProtocol.noise(reply,profile:profile))
            #expect(noise.mode == mode && noise.ambientLevel == 7 && noise.focusOnVoice)
            #expect(SonyProtocol.noiseReadbackMatches(noise,mode:mode,level:7,voice:true,profile:profile))
        }
        #expect(SonyProtocol.batteryQueries(functions:[0x28,0x29,0x2A],single:profile.singleBattery) == (profile.singleBattery ? [8] : [9,10]))
    }
}
