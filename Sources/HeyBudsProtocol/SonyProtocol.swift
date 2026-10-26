// Handwritten MDR V1/V2 subset; GPL-3.0-or-later like HeyBuds.
// Protocol references: mos9527/SonyHeadphonesClient (MIT), commit
// 8f4808cb635f5a176df0b7b5aea959818be5129e, libmdr/include/mdr/ProtocolV{1,2}T1.hpp
// and libmdr/src/HeadphonesV1.cpp. MIT attribution: Licenses/Sony-MIT.txt.
// XB910N wire facts only: DaanHessen/sonyctl docs/protocol.md at
// 2c24bf362a3539465c112f18ef5e7e2698af4dde. No AGPL implementation copied.
// ULT payload reference: Leonard013/sony-ult-ctl SonyULTMenu.swift at
// 546099de1e1ff35a0d28dae24ba3ed09d8918085. Its MIT notice follows:
// Copyright (c) 2026 Leonard013
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import Foundation

public enum SonyGeneration:Sendable { case v1,v2 }

/// Explicit allowlist, independent of catalog display names and aliases.
public enum SonyProfile:String,CaseIterable,Sendable {
    case wf1000xm5="sony:wf-1000xm5",wh1000xm5="sony:wh-1000xm5",whCH720n="sony:wh-ch720n"
    case wh1000xm3="sony:wh-1000xm3",wh1000xm4="sony:wh-1000xm4"
    case whXB910n="sony:wh-xb910n",ultWear="sony:ult-wear"
    public var modelID:String { rawValue }
    public var generation:SonyGeneration { self == .wh1000xm3 || self == .wh1000xm4 ? .v1 : .v2 }
    public var serviceUUID:String { generation == .v1 ? SonyProtocol.serviceV1 : SonyProtocol.serviceV2 }
    public var supportsAmbientLevel:Bool { self != .ultWear }
    public var supportsFocusOnVoice:Bool { true }
    public var ambientLevelRange:ClosedRange<Int>? { supportsAmbientLevel ? 1...20 : nil }
    public var singleBattery:Bool { self != .wf1000xm5 }
    public var noiseSubtype:UInt8 { generation == .v1 ? 2 : self == .whXB910n ? 0x16 : 0x17 }
    public var noiseFunction:UInt8 { generation == .v1 ? 0x62 : self == .whXB910n ? 0x6A : 0x6B }
    /// XB910N documents model identity on Table 2; feature commands stay on Table 1.
    public var identityFrameType:UInt8 { self == .whXB910n ? 0x0E : 0x0C }
}

public struct SonyNoiseState:Equatable,Sendable {
    public let mode:NoiseMode
    /// ULT's trailing byte is not a verified level. Never manufacture a UI value.
    public let ambientLevel:Int?
    public let focusOnVoice:Bool
    public let settled:Bool
}

public enum SonyProtocol {
    public static let serviceV2="956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
    public static let serviceV1="96CC203E-5068-46AD-B32D-E316F5E069BA"
    /// Compatibility baseline; allProfiles includes the four explicit extensions.
    public static let modelNames=["WF-1000XM5","WH-1000XM5","WH-CH720N"]
    public static let allProfiles=SonyProfile.allCases
    public static func profile(name:String) -> SonyProfile? {
        var name=name.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        if name.hasPrefix("SONY ") { name=String(name.dropFirst(5)) }
        switch name {
        case "WF-1000XM5":return .wf1000xm5
        case "WH-1000XM5":return .wh1000xm5
        case "WH-CH720N":return .whCH720n
        case "WH-1000XM3":return .wh1000xm3
        case "WH-1000XM4":return .wh1000xm4
        case "WH-XB910N":return .whXB910n
        case "ULT WEAR","WH-ULT900N":return .ultWear
        default:return nil
        }
    }
    public static func profile(model:DeviceModel?) -> SonyProfile? {
        guard let model,model.family == .sony,let profile=SonyProfile(rawValue:model.id),
              self.profile(name:model.name) == profile else { return nil }
        return profile
    }
    public static func serviceUUID(for name:String) -> String? { profile(name:name)?.serviceUUID }
    public static func supportsModel(_ model:DeviceModel?) -> Bool { profile(model:model) != nil }
    public static func generation(serviceUUID:String) -> SonyGeneration? {
        switch serviceUUID.uppercased() { case serviceV1:return .v1;case serviceV2:return .v2;default:return nil }
    }
    public static func generation(fromHandshake p:[UInt8]) -> SonyGeneration? {
        if p.count == 4,p[0] == 1,p[1] == 0,(p[2] != 0 || p[3] != 0) { return .v1 }
        return validHandshake(p) ? .v2 : nil
    }
    /// Legacy overload intentionally accepts only the original V2 Table 1 envelope.
    public static func validHandshake(_ p:[UInt8]) -> Bool {
        p.count == 8 && p[0] == 1 && p[1] == 0 && p[2..<6].contains(where:{$0 != 0}) && p[6] == 0 && p[7] <= 1
    }
    public static func functions(_ p:[UInt8],generation:SonyGeneration = .v2) -> Set<UInt8>? {
        let stride=generation == .v1 ? 1 : 2
        guard p.count >= 3,p[0] == 7,p[1] == 0,p.count == 3+Int(p[2])*stride else { return nil }
        let ids=(0..<Int(p[2])).map { p[3+$0*stride] }
        guard Set(ids).count == ids.count else { return nil }
        return Set(ids)
    }
    public static func deviceText(_ p:[UInt8],type:UInt8) -> String? {
        guard p.count >= 3,p[0] == 5,p[1] == type,p.count == 3+Int(p[2]),p[2] > 0,
              let text=String(bytes:p.dropFirst(3),encoding:.utf8),
              !text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { return nil }
        return text
    }
    public static func batteryQueries(functions:Set<UInt8>,single:Bool,generation:SonyGeneration = .v2) -> [UInt8] {
        if generation == .v1 {
            // This port deliberately covers only the two single-battery V1 profiles.
            return single && functions.contains(0x11) ? [0] : []
        }
        let pairs:[(UInt8,UInt8,UInt8,UInt8)] = single ? [(0x28,8,0x20,0)] : [(0x29,9,0x21,1),(0x2A,10,0x22,2)]
        return pairs.compactMap { advanced,advancedQuery,basic,basicQuery in
            functions.contains(advanced) ? advancedQuery : functions.contains(basic) ? basicQuery : nil
        }
    }
    public static func batteryRequest(subtype:UInt8,generation:SonyGeneration) -> [UInt8]? {
        guard (generation == .v1 ? [UInt8(0)] : [0,1,2,8,9,10]).contains(subtype) else { return nil }
        return [generation == .v1 ? 0x10 : 0x22,subtype]
    }
    public static func batteryReply(generation:SonyGeneration) -> UInt8 { generation == .v1 ? 0x11 : 0x23 }
    public static func batteryNotification(generation:SonyGeneration) -> UInt8 { generation == .v1 ? 0x13 : 0x25 }
    /// A valid response may explicitly clear an unknown slot; a missing slot is untouched.
    @discardableResult public static func applyBattery(_ p:[UInt8],generation:SonyGeneration = .v2,to state:inout DeviceState) -> Bool {
        guard p.count >= 2,[batteryReply(generation:generation),batteryNotification(generation:generation)].contains(p[0]) else { return false }
        let sizes:[UInt8:Int]=generation == .v1 ? [0:4] : [0:4,1:6,2:4,8:5,9:8,10:5]
        guard sizes[p[1]] == p.count else { return false }
        let dual=p[1] == 1 || p[1] == 9
        let slots:[BatterySlot]=dual ? [.left,.right] : [p[1] == 2 || p[1] == 10 ? .enclosure : .left]
        for (index,slot) in slots.enumerated() {
            let value=p[2+index*2],charge=p[3+index*2]
            state.batteries[slot] = value <= 100 && charge <= 1 ? BatteryReading(percent:Int(value),charging:charge == 1) : nil
        }
        state.observedQueries.insert(Command.battery);return true
    }
    public static func noise(_ p:[UInt8],profile:SonyProfile = .wh1000xm5) -> SonyNoiseState? {
        guard p.count >= 2,[UInt8(0x67),0x69].contains(p[0]),p[1] == profile.noiseSubtype else { return nil }
        if profile.generation == .v1 {
            // V1: effect, NC setting type/value, ASM setting type/id/value.
            guard p.count == 8,[UInt8(0),1,0x10,0x11].contains(p[2]),[UInt8(1),2].contains(p[3]),
                  p[4] <= 2,p[5] == 1,p[6] <= 1,p[7] <= 20 else { return nil }
            return SonyNoiseState(mode:p[2] == 0 ? .off : p[4] > 0 ? .anc : .transparency,
                                  ambientLevel:Int(p[7]),focusOnVoice:p[6] == 1,settled:p[2] != 0x10)
        }
        if profile == .whXB910n || profile == .ultWear {
            guard p.count == 8,p[2] <= 1,p[3] <= 1,p[4] <= 1,p[5] == 2,p[6] <= 1 else { return nil }
            if profile == .whXB910n { guard (1...20).contains(p[7]) else { return nil } }
            else { guard p[7] == 0 else { return nil } } // Only the documented ULT parameter group is supported.
            return SonyNoiseState(mode:p[3] == 0 ? .off : p[4] == 0 ? .anc : .transparency,
                                  ambientLevel:profile == .ultWear ? nil : Int(p[7]),focusOnVoice:p[6] == 1,settled:p[2] == 1)
        }
        guard p.count == 7,p[2] <= 1,p[3] <= 1,p[4] <= 1,p[5] <= 1,(1...20).contains(p[6]) else { return nil }
        return SonyNoiseState(mode:p[3] == 0 ? .off : p[4] == 0 ? .anc : .transparency,
                              ambientLevel:Int(p[6]),focusOnVoice:p[5] == 1,settled:p[2] == 1)
    }
    public static func noiseWrite(mode:NoiseMode,level:Int?,voice:Bool,profile:SonyProfile = .wh1000xm5) throws -> [UInt8] {
        guard [.off,.anc,.transparency].contains(mode) else { throw ProtocolError.unsupported }
        if profile == .ultWear {
            guard level == nil else { throw ProtocolError.unsupported }
            return [0x68,0x17,1,mode == .off ? 0 : 1,mode == .transparency ? 1 : 0,2,mode == .transparency && voice ? 1 : 0,0]
        }
        guard let level,(1...20).contains(level) else { throw ProtocolError.unsupported }
        if profile.generation == .v1 {
            return [0x68,2,mode == .off ? 0 : 1,1,mode == .anc ? 2 : 0,1,voice ? 1 : 0,mode == .transparency ? UInt8(level) : 0]
        }
        if profile == .whXB910n {
            return [0x68,0x16,1,mode == .off ? 0 : 1,mode == .transparency ? 1 : 0,2,mode == .transparency && voice ? 1 : 0,UInt8(level)]
        }
        return [0x68,0x17,1,mode == .off ? 0 : 1,mode == .transparency ? 1 : 0,voice ? 1 : 0,UInt8(level)]
    }
    public static func noiseReadbackMatches(_ state:SonyNoiseState,mode:NoiseMode,level:Int?,voice:Bool,profile:SonyProfile) -> Bool {
        guard state.settled,state.mode == mode else { return false }
        if profile.generation == .v1 || profile == .whXB910n || profile == .ultWear {
            // These profiles ignore/reset ambient parameters outside ambient mode.
            guard mode == .transparency else { return true }
        }
        return state.ambientLevel == level && state.focusOnVoice == voice
    }
}
