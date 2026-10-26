import Foundation
import Testing
@testable import HeyBudsProtocol

private func boseModeFixture(_ profile: BoseProfile, index: UInt8, cnc: UInt8=0) -> [UInt8] {
    // Synthetic layout fixture, not a hardware capture. Presets can have the
    // userConfigured flag clear; this does not mean Quiet/Aware are absent.
    var p=[UInt8](repeating:0,count:profile.modeStatusLength)
    p[0]=index; p[2]=index < 2 ? index+1 : 12
    p[3]=index < (profile == .qc45 ? 2 : 4) ? 0 : 1; p[4]=p[3]; p[5]=1
    let name=Array((index == 0 ? "Quiet" : index == 1 ? "Aware" : "Custom").utf8)
    p.replaceSubrange(6..<(6+name.count),with:name); p[42]=cnc
    if profile != .qc45 { p[47]=1 }
    return p
}

@Test func boseStreamSplitsEveryBoundaryAndKeepsRouteBits() throws {
    let frames=[BoseFrame(2,2,.status,[80,255,255,0]),BoseFrame(31,3,.result,[1]),BoseFrame(31,3,.status,[7],route:0x50)]
    let bytes=try frames.reduce(into:Data()) { $0.append(try BoseFrameCodec.encode($1)) }
    for split in 0...bytes.count {
        var codec=BoseFrameCodec()
        let actual=codec.feed(bytes.prefix(split)) + codec.feed(bytes.dropFirst(split))
        #expect(actual == frames)
    }
    #expect(!frames[2].matches(31,3))
    #expect(throws:ProtocolError.invalidPayload) { try BoseFrameCodec.encode(BoseFrame(2,2,.get,[UInt8](repeating:0,count:256))) }
}

@Test func boseCorruptStreamIsNotResynchronizedAndResetClearsPartialGeneration() throws {
    var codec=BoseFrameCodec()
    #expect(codec.feed(Data([2,2,15,0])).isEmpty)
    #expect(codec.failed)
    let valid=try BoseFrameCodec.encode(BoseFrame(31,3,.status,[0]))
    #expect(codec.feed(valid).isEmpty)
    codec.reset(); #expect(codec.feed(valid).count == 1)
    #expect(codec.feed(Data([31,3,3,1])).isEmpty)
    codec.reset(); #expect(codec.feed(valid).count == 1)
    #expect(codec.feed(Data(repeating:0,count:16_385)).isEmpty && codec.failed)
}

@Test func boseGATTUsesNibbleSegmentsAndBounds() throws {
    let body=Data((0..<259).map { UInt8(truncatingIfNeeded:$0) })
    let segments=try BoseGATTCodec.encode(body,maximumWriteLength:20)
    #expect(segments.count == 14)
    #expect(segments.first?.first == 0xD0 && segments.last?.first == 0xDD)
    #expect(segments.allSatisfy { $0.count <= 20 })
    var decoder=BoseGATTCodec()
    let messages=segments.compactMap { decoder.feed($0) }
    #expect(messages == [body])
    #expect(try BoseGATTCodec.encode(Data([31,3,1,0]),maximumWriteLength:20) == [Data([0,31,3,1,0])])
    #expect(throws:ProtocolError.invalidPayload) { try BoseGATTCodec.encode(body,maximumWriteLength:2) }
    #expect(throws:ProtocolError.invalidPayload) { try BoseGATTCodec.encode(Data(repeating:0,count:4097),maximumWriteLength:512) }
    #expect(throws:ProtocolError.invalidPayload) { try BoseGATTCodec.encode(Data(),maximumWriteLength:20) }
}

@Test func boseGATTRejectsDroppedDuplicatedChangedLastAndOversizedNotifications() throws {
    var codec=BoseGATTCodec()
    #expect(codec.feed(Data([0x20,1])) == nil)
    #expect(codec.feed(Data([0x22,3])) == nil) // missing index1
    #expect(codec.feed(Data([0x11,2])) == nil) // orphan tail
    #expect(codec.feed(Data([0x20,1])) == nil)
    #expect(codec.feed(Data([0x11,2])) == nil) // changed last index
    #expect(codec.feed(Data([0x10,1])) == nil)
    #expect(codec.feed(Data([0x00,9])) == Data([9])) // new message discards old partial
    #expect(codec.feed(Data([0x01,1])) == nil) // index > last
    #expect(codec.feed(Data(repeating:0,count:513)) == nil)
    #expect(codec.feed(Data([0])) == nil)
    #expect(codec.feed(Data([0x10,1])) == nil); codec.reset()
    #expect(codec.feed(Data([0x11,2])) == nil)
    // Repeated full-sized segments cannot grow beyond the documented cap.
    for i in 0..<16 { #expect(codec.feed(Data([UInt8(0xF0+i)]) + Data(repeating:1,count:511)) == nil) }
    #expect(codec.feed(Data([0,2])) == Data([2]))
}

@Test func boseBatteryKeepsComponentIDsAndUnknownValues() throws {
    let samples=try #require(BosePayload.battery([19,255,255,1,72,255,255,2,255,255,255,3,64,255,255,4]))
    #expect(samples.map(\.id) == [1,2,3,4])
    #expect(samples.map(\.percent) == [19,72,nil,64])
    #expect(samples.allSatisfy { $0.charging == nil })
    #expect(BosePayload.battery([1,255,255,1,2,255,255,1]) == nil)
    #expect(BosePayload.battery([80,255,255]) == nil)
    #expect(BosePayload.battery([]) == nil)
}

@Test func boseLayoutsDoNotConfuseStatusAndSetEchoOrOtherGenerations() throws {
    let qc=boseModeFixture(.qc45,index:2,cnc:5)
    let ultra=boseModeFixture(.ultraHeadphones2,index:4,cnc:5)
    #expect(BosePayload.mode(qc,profile:.ultraHeadphones2) == nil)
    #expect(BosePayload.mode(ultra,profile:.qc45) == nil)
    let mode=try #require(BosePayload.mode(qc,profile:.qc45))
    let write=try BosePayload.qc45CNCWrite(mode,level:7)
    #expect(write.count == 39 && write[35] == 7)
    #expect(Array(write[0..<3]) == Array(qc[0..<3]))
    #expect(Array(write[3..<35]) == Array(qc[6..<38]))
    #expect(BosePayload.mode(write,profile:.qc45) == nil)
    var windy=qc; windy[46]=1
    #expect(throws:ProtocolError.unsupported) { try BosePayload.qc45CNCWrite(try #require(BosePayload.mode(windy,profile:.qc45)),level:3) }
    #expect(throws:ProtocolError.unsupported) { try BosePayload.qc45CNCWrite(try #require(BosePayload.mode(boseModeFixture(.qc45,index:0),profile:.qc45)),level:3) }
}

@Test func boseUnknownModesRemainUnknownAndCNCDoesNotInventSettings() throws {
    let quiet=try #require(BosePayload.mode(boseModeFixture(.qc45,index:0),profile:.qc45))
    #expect(!quiet.configured)
    #expect(BosePayload.noise(index:0,modes:[0:quiet]) == .anc)
    #expect(BosePayload.noise(index:9,modes:[0:quiet]) == nil)
    #expect(BosePayload.modeCount([4,0,3],profile:.qc45) == 4)
    #expect(BosePayload.modeCount([11,0,3],profile:.qc45) == nil)
    #expect(BosePayload.modeCount([4,1,0],profile:.qc45) == nil)
    #expect(BosePayload.cnc([11,5,3])?.maximum == 10)
    #expect(BosePayload.cnc([0,0,3]) == nil)
    #expect(BosePayload.cnc([11,11,3]) == nil)
    let settings=try #require(BosePayload.audioSettings([5,0,2,0,1]))
    #expect(try settings.settingCNC(7) == [7,0,2,0,1])
    for p: [UInt8] in [[5,1,2,0,1],[5,0,7,0,1],[5,0,2,1,1],[5,0,2,0,0]] {
        let unknown=try #require(BosePayload.audioSettings(p))
        #expect(throws:ProtocolError.unsupported) { try unknown.settingCNC(7) }
    }
    #expect(BoseProfile.named("Bose QuietComfort Ultra Earbuds") == nil)
    #expect(BoseProfile.named("Bose QuietComfort Ultra Earbuds (2nd Gen)") == .ultraEarbuds2)
    #expect(BoseProfile.named("Bose QC Ultra Headphones 2nd Gen") == .ultraHeadphones2)
    #expect(BoseProfile.named("Bose QC Ultra Earbuds 2nd Gen") == .ultraEarbuds2)
    #expect(BoseProfile.forModelID("bose:qc45") == .qc45)
}
