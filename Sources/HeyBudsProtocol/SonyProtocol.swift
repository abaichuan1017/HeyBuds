// Handwritten MDR V2 subset. Wire references and licenses: Licenses/Sony-MIT.txt.
import Foundation

public struct SonyNoiseState:Equatable,Sendable {
    public let mode:NoiseMode
    public let ambientLevel:Int
    public let focusOnVoice:Bool
    public let settled:Bool
}

public enum SonyProtocol {
    public static let serviceV2="956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
    public static let serviceV1="96CC203E-5068-46AD-B32D-E316F5E069BA"
    public static let modelNames=["WF-1000XM5","WH-1000XM5","WH-CH720N"]
    public static func supportsModel(_ model:DeviceModel?) -> Bool {
        model?.family == .sony && model.map { modelNames.contains($0.name) } == true
    }
    /// V1 returns four bytes. Only the V2 envelope with Table 1 enabled is accepted.
    public static func validHandshake(_ p:[UInt8]) -> Bool {
        p.count == 8 && p[0] == 1 && p[1] == 0 && p[2..<6].contains(where:{$0 != 0}) && p[6] == 0 && p[7] <= 1
    }
    public static func functions(_ p:[UInt8]) -> Set<UInt8>? {
        guard p.count >= 3,p[0] == 7,p[1] == 0,p.count == 3+Int(p[2])*2 else { return nil }
        // Each function has its own priority byte; this is not a flat command list.
        let ids=(0..<Int(p[2])).map { p[3+$0*2] }
        guard Set(ids).count == ids.count else { return nil }
        return Set(ids)
    }
    public static func deviceText(_ p:[UInt8],type:UInt8) -> String? {
        guard p.count >= 3,p[0] == 5,p[1] == type,p.count == 3+Int(p[2]),p[2] > 0,
              let text=String(bytes:p.dropFirst(3),encoding:.utf8),
              !text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { return nil }
        return text
    }
    public static func batteryQueries(functions:Set<UInt8>,single:Bool) -> [UInt8] {
        let pairs:[(UInt8,UInt8,UInt8,UInt8)] = single ? [(0x28,8,0x20,0)] : [(0x29,9,0x21,1),(0x2A,10,0x22,2)]
        return pairs.compactMap { advanced,advancedQuery,basic,basicQuery in
            functions.contains(advanced) ? advancedQuery : functions.contains(basic) ? basicQuery : nil
        }
    }
    /// A valid response may explicitly clear an unknown slot; a missing slot is untouched.
    @discardableResult public static func applyBattery(_ p:[UInt8],to state:inout DeviceState) -> Bool {
        guard p.count >= 2,[UInt8(0x23),0x25].contains(p[0]) else { return false }
        let sizes:[UInt8:Int]=[0:4,1:6,2:4,8:5,9:8,10:5]
        guard sizes[p[1]] == p.count else { return false }
        let dual=p[1] == 1 || p[1] == 9
        let slots:[BatterySlot]=dual ? [.left,.right] : [p[1] == 2 || p[1] == 10 ? .enclosure : .left]
        for (index,slot) in slots.enumerated() {
            let value=p[2+index*2],charge=p[3+index*2]
            state.batteries[slot] = value <= 100 && charge <= 1 ? BatteryReading(percent:Int(value),charging:charge == 1) : nil
        }
        state.observedQueries.insert(Command.battery);return true
    }
    public static func noise(_ p:[UInt8]) -> SonyNoiseState? {
        guard p.count == 7,[UInt8(0x67),0x69].contains(p[0]),p[1] == 0x17,
              p[2] <= 1,p[3] <= 1,p[4] <= 1,p[5] <= 1,(1...20).contains(p[6]) else { return nil }
        return SonyNoiseState(mode:p[3] == 0 ? .off : p[4] == 0 ? .anc : .transparency,
                              ambientLevel:Int(p[6]),focusOnVoice:p[5] == 1,settled:p[2] == 1)
    }
    public static func noiseWrite(mode:NoiseMode,level:Int,voice:Bool) throws -> [UInt8] {
        guard [.off,.anc,.transparency].contains(mode),(1...20).contains(level) else { throw ProtocolError.unsupported }
        return [0x68,0x17,1,mode == .off ? 0 : 1,mode == .transparency ? 1 : 0,voice ? 1 : 0,UInt8(level)]
    }
}
