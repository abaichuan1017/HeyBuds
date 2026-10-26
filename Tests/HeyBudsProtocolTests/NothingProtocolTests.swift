import Foundation
import Testing
@testable import HeyBudsProtocol

// Synthetic RX builder, separate from the production encoder and CRC routine.
// Only literals explicitly labelled below are upstream wire evidence.
private func nothingRX(_ command: UInt16, _ payload: [UInt8], sequence: UInt8 = 9,
                       payloadCRC: Bool = false, event: Bool = false) -> Data {
    var bytes: [UInt8] = [0x55, event ? 0 : 0x60, 1,
                          UInt8(truncatingIfNeeded: command), UInt8(command >> 8),
                          UInt8(truncatingIfNeeded: payload.count), UInt8(payload.count >> 8), sequence] + payload
    if !event {
        var crc = 65535
        for byte in payloadCRC ? payload : bytes {
            crc ^= Int(byte)
            for _ in 0..<8 {
                let remainder = crc % 2
                crc /= 2
                if remainder == 1 { crc ^= 40961 }
            }
        }
        bytes += [UInt8(crc % 256), UInt8(crc / 256)]
    }
    return Data(bytes)
}

@Test func nothingExactProfilesNeverMatchOtherGenerationsOrSuffixes() {
    let ids = ["nothing:ear-a", "nothing:headphone-1", "nothing:cmf-buds-2", "nothing:cmf-buds-pro-2"]
    #expect(NothingProfile.allCases.map(\.modelID) == ids)
    #expect(NothingProfile.allCases.map(\.modelCode) == ["B162", "B170", "B179", "B172"])
    for profile in NothingProfile.allCases {
        #expect(profile.service == "AEAC4A03-DFF5-498F-843A-34487CF133EB")
        #expect(profile.serviceUUID == NothingProfile.service)
        #expect(profile.writeUUID == nil && profile.notifyUUID == nil)
        for alias in profile.aliases {
            #expect(NothingProfile.named(alias) == profile)
            #expect(NothingProfile.matching(name: " \(alias.uppercased())\n") == profile)
            #expect(NothingProfile.named(alias + " Pro") == nil)
        }
    }
    for unknown in ["Nothing", "Ear", "B162", "Ear (1)", "Nothing Ear (2024)", "Nothing Ear (a) 2",
                    "Nothing Headphone (1) Pro", "CMF Buds 2a", "CMF Buds 2 Plus", "CMF Buds Pro",
                    "my CMF Buds Pro 2", "CMF Buds Pro 2 (1234)", "CMF-Buds-2"] {
        #expect(NothingProfile.named(unknown) == nil)
    }
}

@Test func nothingRequestDescriptorsAreModelSpecificAndNeverACKConfirmation() throws {
    for profile in NothingProfile.allCases {
        #expect(profile.batteryRead == NothingRequest(command: 0xC007, responseCommand: 0x4007))
        #expect(profile.firmwareRead == NothingRequest(command: 0xC042, responseCommand: 0x4042))
        #expect(profile.noiseRead.command == 0xC01E && profile.noiseRead.responseCommand == 0x401E)
        let write = try #require(profile.noiseWrite(.transparency))
        #expect(write.command == 0xF00F && write.payload == [1, 7, 0] && write.responseCommand == nil)
        #expect(!write.matches(NothingFrame(command: 0x700F, sequence: 9, payload: [0]), sequence: 9))
        #expect(profile.noiseWrite(.smart) == nil && profile.noiseWrite(.deep) == nil)
    }
    #expect(NothingProfile.earA.identityRead.command == 0xC006)
    #expect(NothingProfile.cmfBudsPro2.identityRead == NothingRequest(command: 0xC01C, responseCommand: 0x401C))
    #expect(NothingProfile.cmfBudsPro2.noiseRead.payload == [3])
    #expect(NothingProfile.cmfBuds2.noiseRead.payload.isEmpty)
    #expect(NothingProfile.earA.eqRead == NothingRequest(command: 0xC01F, responseCommand: 0x401F))
    #expect(NothingProfile.cmfBudsPro2.eqRead == NothingRequest(command: 0xC050, responseCommand: 0x4050))
    #expect(NothingProfile.cmfBuds2.eqRead == NothingProfile.cmfBudsPro2.eqRead)
    let request = NothingProfile.earA.batteryRead
    #expect(request.matches(NothingFrame(command: 0x4007, sequence: 8), sequence: 8))
    #expect(!request.matches(NothingFrame(command: 0x4007, sequence: 7), sequence: 8))
    #expect(!request.matches(NothingFrame(command: 0xE001, sequence: 8), sequence: 8))
}

@Test func nothingEncoderMatchesFixedWireFactsAndLengthBounds() throws {
    // SwiftNothingEar battery request fixture; openNothing captured ANC request.
    #expect(try NothingFrameCodec.encode(NothingProfile.earA.batteryRead.frame(sequence: 1))
            == Data([0x55,0x60,1,7,0xC0,0,0,1,0xAC,0xDF]))
    #expect(try NothingFrameCodec.encode(NothingProfile.cmfBudsPro2.noiseRead.frame(sequence: 13))
            == Data([0x55,0x60,1,0x1E,0xC0,1,0,13,3,0x99,0x89]))
    let transparency = try #require(NothingProfile.earA.noiseWrite(.transparency))
    #expect(try NothingFrameCodec.encode(transparency.frame(sequence: 0xCB))
            == Data([0x55,0x60,1,0x0F,0xF0,3,0,0xCB,1,7,0,0xC5,0xAF]))
    #expect(NothingFrameCodec.checksum(Array("123456789".utf8)) == 0x4B37)
    let maximum = NothingFrame(command: 0xC006, sequence: 1, payload: .init(repeating: 0, count: 1024))
    let encoded = try NothingFrameCodec.encode(maximum)
    #expect(encoded.count == 1034 && encoded[5] == 0 && encoded[6] == 4)
    #expect(throws: ProtocolError.self) {
        try NothingFrameCodec.encode(NothingFrame(command: 0xC006, sequence: 1, payload: .init(repeating: 0, count: 1025)))
    }
    #expect(throws: ProtocolError.self) { try NothingFrameCodec(profile: .earA, maximumPayloadLength: 10).encode(maximum) }
}

@Test func nothingFullFrameCRCReplaysCMF2CaptureAtEverySplit() {
    // ncr/omarchy-headphones docs/captures/nothing-cmf-buds-2.txt, battery/ANC.
    // Non-identifying wire bytes copied as protocol facts, not generated by encode.
    let battery = Data([0x55,0x60,1,7,0x40,5,0,1,2,2,100,3,100,0x32,0x89])
    let noise = Data([0x55,0x60,1,0x1E,0x40,6,0,1,1,5,0,2,1,0,0xB6,0x2A])
    let expected = [NothingFrame(command: 0x4007, sequence: 1, payload: [2,2,100,3,100]),
                    NothingFrame(command: 0x401E, sequence: 1, payload: [1,5,0,2,1,0])]
    let stream = battery + noise
    for split in 0...stream.count {
        var codec = NothingFrameCodec(profile: .cmfBuds2)
        #expect(codec.feed(stream.prefix(split)) + codec.feed(stream.dropFirst(split)) == expected)
        #expect(codec.bufferedByteCount == 0)
    }
    var codec = NothingFrameCodec(profile: .cmfBuds2)
    #expect(stream.flatMap { codec.feed(Data([$0])) } == expected)
}

@Test func nothingDirectionalCRCDoesNotTryAnotherScopeOrTrustEchoedRequests() throws {
    let payload: [UInt8] = [2,2,71,3,82]
    let full = nothingRX(0x4007, payload), partial = nothingRX(0x4007, payload, payloadCRC: true)
    for profile in [NothingProfile.earA, .headphone1, .cmfBuds2] {
        var codec = NothingFrameCodec(profile: profile)
        #expect(codec.feed(partial).isEmpty)
        #expect(codec.feed(full) == [NothingFrame(command: 0x4007, sequence: 9, payload: payload)])
    }
    var codec = NothingFrameCodec(profile: .cmfBudsPro2)
    #expect(codec.feed(full).isEmpty)
    #expect(codec.feed(partial) == [NothingFrame(command: 0x4007, sequence: 9, payload: payload)])
    #expect(codec.feed(try NothingFrameCodec.encode(NothingProfile.cmfBudsPro2.batteryRead.frame(sequence: 9))).isEmpty)
    let wrongResponse = nothingRX(0x401F, [1], payloadCRC: true)
    #expect(codec.feed(wrongResponse).isEmpty) // B172 uses 4050, not 401F.
}

@Test func nothingCRCFreeEventsHaveOneExplicitProfileAndCannotSatisfyReads() {
    // openNothing tests/protocol/test_golden.py: real B172 ANC event.
    let event = Data([0x55,0,1,3,0xE0,3,0,0,1,7,0])
    for profile in [NothingProfile.earA, .headphone1, .cmfBuds2] {
        var codec = NothingFrameCodec(profile: profile)
        #expect(codec.feed(event).isEmpty)
    }
    var codec = NothingFrameCodec(profile: .cmfBudsPro2)
    let frames = codec.feed(event)
    #expect(frames == [NothingFrame(command: 0xE003, sequence: 0, payload: [1,7,0])])
    #expect(frames.allSatisfy { !NothingProfile.cmfBudsPro2.noiseRead.matches($0, sequence: 1) })
    #expect(codec.feed(nothingRX(0x401E, [1,7,0], sequence: 0, event: true)).isEmpty)
    #expect(codec.feed(nothingRX(0xE003, [1,7,0], sequence: 1, event: true)).isEmpty)
    #expect(codec.feed(nothingRX(0xE002, [0], sequence: 0, event: true)).isEmpty)
}

@Test func nothingCorruptionOversizedLengthsAndUnknownControlsRecoverBoundedly() {
    let valid = nothingRX(0x4007, [1,2,0])
    var corrupt = Array(valid); corrupt[10] ^= 1
    let bad: [Data] = [Data(corrupt), Data([0x55,0x60,1,7,0x40,0xFF,0xFF,1]),
                       Data([0x55,0x61,1,7,0x40,0,0,1]), Data([0x55,0x60,2,7,0x40,0,0,1]),
                       Data(repeating: 0x55, count: 20_000), Data(repeating: 0, count: 20_000)]
    for data in bad {
        var codec = NothingFrameCodec(profile: .earA)
        #expect(codec.feed(data).isEmpty)
        #expect(codec.bufferedByteCount <= 1034)
        #expect(codec.feed(valid) == [NothingFrame(command: 0x4007, sequence: 9, payload: [1,2,0])])
    }
    var truncated = NothingFrameCodec(profile: .earA)
    #expect(truncated.feed(valid.dropLast()).isEmpty) // CRC is mandatory, even at a notification boundary.
    truncated.reset()
    #expect(truncated.bufferedByteCount == 0)
    #expect(truncated.feed(valid).count == 1)
    let long = nothingRX(0x4042, .init(repeating: 49, count: 256))
    #expect(truncated.feed(long).first?.payload.count == 256) // 16-bit little-endian length.
    var bounded = NothingFrameCodec(profile: .earA, maximumPayloadLength: 16)
    #expect(bounded.feed(long).isEmpty && bounded.bufferedByteCount <= 26)
}

@Test func nothingBatteryDistinguishesZeroUnknownAbsentAndMalformed() throws {
    let profile = NothingProfile.earA, now = Date(timeIntervalSince1970: 100)
    let reading = try #require(profile.parseBattery([3,2,0,3,0xE4,4,0xFF], updatedAt: now))
    #expect(reading[.left]?.percent == 0 && reading[.left]?.charging == false)
    #expect(reading[.right]?.percent == 100 && reading[.right]?.charging == true)
    #expect(reading[.right]?.updatedAt == now && reading[.enclosure] == nil)
    #expect(profile.parseBattery([0])?.isEmpty == true)
    #expect(profile.parseBattery([1,4,0x7F])?.isEmpty == true)
    for malformed: [UInt8] in [[], [1], [1,2], [1,2,50,0], [2,2,1,2,2], [1,6,70], [4,2,1,3,2,4,3,4,4]] {
        #expect(profile.parseBattery(malformed) == nil)
    }
    let headset = NothingProfile.headphone1
    #expect(headset.parseBattery([0,0,0xD8])?[.left]?.percent == 88)
    #expect(headset.parseBattery([1,6,0])?[.left]?.percent == 0)
    #expect(headset.parseBattery([0,0,0xFF])?.isEmpty == true)
    #expect(headset.parseBattery([1,2,50]) == nil)
    #expect(headset.parseBattery([0,0,50,0]) == nil)
    for caseID: UInt8 in [4,5] {
        let b172 = try #require(NothingProfile.cmfBudsPro2.parseBattery([3,2,65,3,70,caseID,90]))
        #expect(b172.count == 2 && b172[.left]?.percent == 65 && b172[.right]?.percent == 70)
        #expect(b172[.enclosure] == nil)
        #expect(NothingProfile.cmfBudsPro2.parseBattery([2,caseID,1,caseID,2]) == nil)
    }
    #expect(NothingProfile.cmfBudsPro2.parseBattery([1,6,50]) == nil)
}

@Test func nothingNoiseUsesModeGroupRatherThanANCLevelAndRejectsWrongLayouts() {
    #expect(NothingProfile.cmfBudsPro2.parseNoise([2,1,0,1,5,0]) == .off)
    #expect(NothingProfile.cmfBuds2.parseNoise([1,7,0,2,1,0]) == .transparency)
    #expect(NothingProfile.earA.parseNoise([1,7,0]) == .transparency)
    #expect(NothingProfile.headphone1.parseNoise([0,1]) == .anc)
    #expect(NothingProfile.headphone1.parseNoise([1,1,0]) == nil)
    #expect(NothingProfile.cmfBudsPro2.parseNoise([0,1]) == nil)
    let modes: [(UInt8, NoiseMode)] = [(1,.anc),(2,.medium),(3,.light),(4,.adaptive),(5,.off),(7,.transparency)]
    for (value, mode) in modes {
        #expect(NothingProfile.earA.parseNoise([0,value]) == mode)
        #expect(NothingProfile.earA.noiseWrite(mode)?.payload == [1,value,0])
    }
    for malformed: [UInt8] in [[], [1], [0,0], [0,6], [1,5,1], [1,5,0,1,7,0], [3,5,0], [2,5,0], [1,5,0,0]] {
        #expect(NothingProfile.cmfBudsPro2.parseNoise(malformed) == nil)
    }
}

@Test func nothingPresetsAndAdvancedGuardExposeNoCustomOrSpatialWrites() {
    for profile in NothingProfile.allCases {
        for id in profile.presetIDs {
            #expect(profile.parseEQ([id]) == id)
            #expect(profile.eqWrite(id)?.payload == [id,0])
            #expect(profile.presetLabel(id) != nil)
        }
        for id: UInt8 in [6,7,8,0xFF] {
            #expect(profile.parseEQ([id]) == nil && profile.eqWrite(id) == nil)
        }
        #expect(profile.parseEQ([]) == nil && profile.parseEQ([0,1]) == nil)
    }
    #expect(NothingProfile.earA.presetIDs.map { NothingProfile.earA.presetLabel($0)! }
            == ["Balanced", "Voice", "More Treble", "More Bass"])
    #expect(NothingProfile.cmfBuds2.presetIDs.map { NothingProfile.cmfBuds2.presetLabel($0)! }
            == ["Balanced", "Rock", "Electronic", "Pop", "Enhance Vocals", "Classical"])
    #expect(NothingProfile.headphone1.advancedEQRead == NothingRequest(command: 0xC04C, responseCommand: 0x404C))
    #expect(NothingProfile.headphone1.parseAdvancedEQ([0]) == false)
    #expect(NothingProfile.headphone1.parseAdvancedEQ([1]) == true)
    for malformed: [UInt8] in [[], [2], [0,0], [1,0]] { #expect(NothingProfile.headphone1.parseAdvancedEQ(malformed) == nil) }
    #expect(NothingProfile.earA.advancedEQRead == nil && NothingProfile.earA.parseAdvancedEQ([0]) == nil)
}

@Test func nothingFirmwareGateIsNumericStrictAndNeverAssumesMissingVersion() {
    let profile = NothingProfile.cmfBuds2
    for version in ["1.0.1.50", "1.0.1.100", "1.0.2.0", "2.0.0.0"] { #expect(profile.allowsEQ(firmware: version)) }
    for version: String? in [nil, "", "1.0.1.9", "1.0.1.49", "1.0.1", "1.0.1.50-beta", "1.0.1.50.1", "+1.0.1.50", "1.0.1.65536"] {
        #expect(!profile.allowsEQ(firmware: version))
    }
    #expect(profile.parseFirmware(Array("1.0.1.50".utf8) + [0,0]) == "1.0.1.50")
    #expect(profile.parseFirmware(Array("2.4.5".utf8)) == "2.4.5")
    for malformed in [Array("1..50".utf8), Array("1.0\u{0}1.50".utf8), [0xFF], Array("release 1.0.1.50".utf8), Array(repeating: UInt8(49), count: 33)] {
        #expect(profile.parseFirmware(malformed) == nil)
    }
    #expect(NothingProfile.earA.allowsEQ(firmware: nil))
}

@Test func nothingIdentityReturnsOnlyAllowlistedModelCodeWithoutNameFallback() {
    // Deliberately synthetic SKU-bearing values, never an actual device identity.
    let examples = [("SH0063TEST0000", "B162"), ("SH0073TEST0000", "B162"),
                    ("M3A603TEST0000", "B170"), ("M3A606TEST0000", "B170"),
                    ("SH0099TEST0000", "B179"), ("130098TEST0000", "B179"), ("SH0076TEST0000", "B172")]
    for (serial, code) in examples {
        let payload = Array("2,4,\(serial)\n3,4,\(serial)\n6,6,000000000000\n".utf8)
        #expect(NothingProfile.earA.identityCode(payload) == code)
        #expect(NothingProfile.earA.identityCode([4] + payload) == code)
    }
    #expect(NothingProfile.cmfBudsPro2.identityCode(Array("B172".utf8) + [0]) == "B172")
    #expect(NothingProfile.cmfBudsPro2.identityCode(Array("B179".utf8)) == "B179") // Session must compare against its selected profile.
    #expect(NothingProfile.cmfBudsPro2.identityCode(Array("unknown B172".utf8)) == nil)
    for text in ["", "2,4,UNKNOWN0000\n", "2,4,SH0084TEST0000\n", "2,4,SH0063TEST0000\n3,4,M3A603TEST0000\n",
                 "6,6,000000000000\n", "2,4,SH0063TEST0000,extra\n", "2,4,SH0063TEST0000\nmalformed\n"] {
        #expect(NothingProfile.earA.identityCode(Array(text.utf8)) == nil)
    }
    #expect(NothingProfile.earA.identityCode(.init(repeating: 65, count: 1025)) == nil)
}
