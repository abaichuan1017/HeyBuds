// Samsung SPP facts cross-checked against Budsy (MIT) and GalaxyBudsClient (GPLv3).
import Foundation

public struct SamsungFrame:Equatable,Sendable {
    public let command:UInt8
    public let payload:[UInt8]
    public let response:Bool
    public init(_ command:UInt8,_ payload:[UInt8]=[],response:Bool=false) {
        self.command=command;self.payload=payload;self.response=response
    }
}
public struct SamsungFrameCodec {
    private var buffer:[UInt8]=[]
    public init() {}
    public mutating func reset() { buffer.removeAll(keepingCapacity:true) }
    public static func checksum(_ bytes:[UInt8]) -> UInt16 {
        var crc:UInt16=0
        for byte in bytes {
            crc ^= UInt16(byte)<<8
            for _ in 0..<8 { crc=crc & 0x8000 != 0 ? (crc<<1)^0x1021 : crc<<1 }
        }
        return crc
    }
    public static func encode(_ frame:SamsungFrame) throws -> Data {
        guard frame.payload.count <= 1020 else { throw ProtocolError.invalidPayload }
        let length=UInt16(frame.payload.count+3) | (frame.response ? 0x1000 : 0)
        let body=[frame.command]+frame.payload,crc=checksum(body)
        return Data([0xFD,UInt8(truncatingIfNeeded:length),UInt8(length>>8)]+body+[UInt8(truncatingIfNeeded:crc),UInt8(crc>>8),0xDD])
    }
    public mutating func feed(_ data:Data) -> [SamsungFrame] {
        var result:[SamsungFrame]=[]
        for byte in data {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == 0xFD else { buffer.removeFirst();continue }
                guard buffer.count >= 3 else { break }
                let header=UInt16(buffer[1])|UInt16(buffer[2])<<8,length=Int(header & 0x3FF)
                // Fragmented firmware/SMEP/legacy messages are outside this backend.
                guard length >= 3,header & 0xEC00 == 0 else { buffer.removeFirst();continue }
                let total=length+4
                guard buffer.count >= total else { break }
                let body=Array(buffer[3..<total-3]),crc=UInt16(buffer[total-3])|UInt16(buffer[total-2])<<8
                guard buffer[total-1] == 0xDD,Self.checksum(body) == crc else { buffer.removeFirst();continue }
                result.append(SamsungFrame(body[0],Array(body.dropFirst()),response:header & 0x1000 != 0))
                buffer.removeFirst(total)
            }
        }
        return result
    }
}

public struct SamsungControlState:Equatable,Sendable {
    public let revision:UInt8
    public let touchFlags:UInt8
    public let ancLevel:Int?
    public var touchLocked:Bool { touchFlags & 0x80 == 0 }
}
public enum SamsungProfile:String,Sendable,CaseIterable {
    case buds2="Galaxy Buds2",buds2Pro="Galaxy Buds2 Pro",buds4Pro="Galaxy Buds4 Pro"
    public static let service="2E73A4AD-332D-41FC-90E2-16BEF06523F2"
    public var modelID:String { switch self { case .buds2:return "samsung:buds2";case .buds2Pro:return "samsung:buds2-pro";case .buds4Pro:return "samsung:buds4-pro" } }
    public static func named(_ name:String) -> Self? {
        let trimmed=name.trimmingCharacters(in:.whitespaces)
        // Samsung appends a short hexadecimal pairing suffix. Reject arbitrary
        // suffixes (FE/Pro/new generations), rather than matching a family prefix.
        let base=trimmed.replacingOccurrences(of:#"\s*\([0-9a-fA-F]{4}\)$"#,with:"",options:.regularExpression)
        let n=EarbudFamily.normalize(base)
        return allCases.first { n == EarbudFamily.normalize($0.rawValue) || n == EarbudFamily.normalize("Samsung "+$0.rawValue) }
    }
    public func minimumStatusLength(revision:UInt8) -> Int {
        switch self {
        case .buds2:
            return revision >= 10 ? 37 : revision >= 8 ? 36 : revision >= 7 ? 35 : revision >= 6 ? 34 : revision >= 5 ? 33 : revision >= 3 ? 29 : revision >= 2 ? 28 : 27
        case .buds2Pro:
            return revision >= 13 ? 45 : revision >= 11 ? 44 : revision >= 8 ? 43 : revision >= 3 ? 42 : revision >= 1 ? 41 : 34
        case .buds4Pro:return 25 // Verified common prefix and ANC level; no newer detail offsets assumed.
        }
    }
    public func status(_ p:[UInt8]) -> DeviceState? {
        guard let revision=p.first,p.count >= minimumStatusLength(revision:revision),p[12] <= (self == .buds4Pro ? 3 : 2) else { return nil }
        var state=DeviceState()
        let charge:UInt8?
        switch self {
        case .buds2:charge=revision >= 10 ? p[36] : nil
        case .buds2Pro:charge=revision >= 11 ? p[43] : nil
        case .buds4Pro:charge=nil // New-generation charge layout requires separate evidence.
        }
        Self.battery(p[2],slot:.left,charging:charge.map { $0 & 16 != 0 } ?? false,to:&state)
        Self.battery(p[3],slot:.right,charging:charge.map { $0 & 4 != 0 } ?? false,to:&state)
        Self.battery(p[7],slot:.enclosure,charging:charge.map { $0 & 1 != 0 } ?? false,to:&state)
        state.noise=[NoiseMode.off,.anc,.transparency,.adaptive][Int(p[12])]
        state.samsungControls=SamsungControlState(revision:revision,touchFlags:p[10],ancLevel:self == .buds4Pro && p[24] <= 4 ? Int(p[24]) : nil)
        if p[9] <= 5 { state.eq=p[9];state.observedQueries.insert(Command.equalizer) }
        state.observedQueries.formUnion([Command.battery,Command.noise])
        return state
    }
    public func touchLockPayload(_ locked:Bool,current:SamsungControlState) throws -> [UInt8] {
        // Preserve individual gesture preferences, including call gestures on
        // revisions that actually carry them. Buds4 touch settings are deferred.
        guard self != .buds4Pro else { throw ProtocolError.unsupported }
        let bits:[UInt8] = (self == .buds2 && current.revision >= 7) || (self == .buds2Pro && current.revision >= 1) ? [3,2,1,0,4,5] : [3,2,1,0]
        return [locked ? 0 : 1] + bits.map { (current.touchFlags >> $0) & 1 }
    }
    public static func battery(_ raw:UInt8,slot:BatterySlot,charging:Bool,to state:inout DeviceState) {
        state.batteries[slot]=raw <= 100 ? BatteryReading(percent:Int(raw),charging:charging) : nil
    }
    public func noiseByte(_ mode:NoiseMode) -> UInt8? {
        switch mode { case .off:return 0;case .anc:return 1;case .transparency:return 2;case .adaptive:return self == .buds4Pro ? 3 : nil;default:return nil }
    }
}
