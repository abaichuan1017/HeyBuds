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
    private let legacy:Bool
    public init(legacy:Bool=false) { self.legacy=legacy }
    public mutating func reset() { buffer.removeAll(keepingCapacity:true) }
    public static func checksum(_ bytes:[UInt8]) -> UInt16 {
        var crc:UInt16=0
        for byte in bytes {
            crc ^= UInt16(byte)<<8
            for _ in 0..<8 { crc=crc & 0x8000 != 0 ? (crc<<1)^0x1021 : crc<<1 }
        }
        return crc
    }
    public static func encode(_ frame:SamsungFrame,legacy:Bool=false) throws -> Data {
        guard frame.payload.count <= (legacy ? 252 : 1020) else { throw ProtocolError.invalidPayload }
        let length=UInt16(frame.payload.count+3) | (frame.response ? 0x1000 : 0)
        let body=[frame.command]+frame.payload,crc=checksum(body)
        let header:[UInt8]=legacy ? [0xFE,frame.response ? 1 : 0,UInt8(frame.payload.count+3)] : [0xFD,UInt8(truncatingIfNeeded:length),UInt8(length>>8)]
        return Data(header+body+[UInt8(truncatingIfNeeded:crc),UInt8(crc>>8),legacy ? 0xEE : 0xDD])
    }
    public mutating func feed(_ data:Data) -> [SamsungFrame] {
        var result:[SamsungFrame]=[]
        for byte in data {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == (legacy ? 0xFE : 0xFD) else { buffer.removeFirst();continue }
                guard buffer.count >= 3 else { break }
                let header=UInt16(buffer[1])|UInt16(buffer[2])<<8,length=legacy ? Int(buffer[2]) : Int(header & 0x3FF)
                // Fragmented firmware/SMEP/legacy messages are outside this backend.
                guard length >= 3,legacy ? buffer[1] <= 1 : header & 0xEC00 == 0 else { buffer.removeFirst();continue }
                let total=length+4
                guard buffer.count >= total else { break }
                let body=Array(buffer[3..<total-3]),crc=UInt16(buffer[total-3])|UInt16(buffer[total-2])<<8
                guard buffer[total-1] == (legacy ? 0xEE : 0xDD),Self.checksum(body) == crc else { buffer.removeFirst();continue }
                result.append(SamsungFrame(body[0],Array(body.dropFirst()),response:legacy ? buffer[1] == 1 : header & 0x1000 != 0))
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
    case buds="Galaxy Buds",budsPlus="Galaxy Buds+",budsLive="Galaxy Buds Live",budsPro="Galaxy Buds Pro"
    case buds2="Galaxy Buds2",buds2Pro="Galaxy Buds2 Pro",buds4Pro="Galaxy Buds4 Pro"
    case budsFE="Galaxy Buds FE",buds3="Galaxy Buds3",buds3Pro="Galaxy Buds3 Pro",buds3FE="Galaxy Buds3 FE",budsCore="Galaxy Buds Core",buds4="Galaxy Buds4"
    public static let service="2E73A4AD-332D-41FC-90E2-16BEF06523F2"
    public static let legacyService="00001102-0000-1000-8000-00805F9B34FD"
    public var serviceUUID:String { self == .buds ? Self.legacyService : Self.service }
    public var legacy:Bool { self == .buds }
    public var supportsAdaptive:Bool { [.buds3Pro,.buds4Pro,.buds4].contains(self) }
    public var hasTouchControl:Bool { self == .buds2 || self == .buds2Pro }
    public var noiseModes:[NoiseMode] {
        if self == .buds || self == .budsPlus { return [.off,.transparency] }
        if self == .budsLive || self == .buds3 || self == .buds4 { return [.off,.anc] }
        return supportsAdaptive ? [.off,.anc,.transparency,.adaptive] : [.off,.anc,.transparency]
    }
    public var modelID:String { switch self {
    case .buds:return "samsung:buds";case .budsPlus:return "samsung:buds-plus";case .budsLive:return "samsung:buds-live";case .budsPro:return "samsung:buds-pro"
    case .budsFE:return "samsung:buds-fe";case .buds3:return "samsung:buds3";case .buds3Pro:return "samsung:buds3-pro";case .buds3FE:return "samsung:buds3-fe";case .budsCore:return "samsung:buds-core";case .buds4:return "samsung:buds4"
    case .buds2:return "samsung:buds2";case .buds2Pro:return "samsung:buds2-pro";case .buds4Pro:return "samsung:buds4-pro" } }
    public static func named(_ name:String) -> Self? {
        let trimmed=name.trimmingCharacters(in:.whitespaces)
        // Samsung appends a short hexadecimal pairing suffix. Reject arbitrary
        // suffixes (FE/Pro/new generations), rather than matching a family prefix.
        let base=trimmed.replacingOccurrences(of:#"\s*\([0-9a-fA-F]{4}\)$"#,with:"",options:.regularExpression)
        let n=EarbudFamily.normalize(base.replacingOccurrences(of:"+",with:"plus"))
        return allCases.first { n == EarbudFamily.normalize($0.rawValue.replacingOccurrences(of:"+",with:"plus")) || n == EarbudFamily.normalize("Samsung "+$0.rawValue.replacingOccurrences(of:"+",with:"plus")) }
    }
    public func minimumStatusLength(revision:UInt8) -> Int {
        switch self {
        case .buds2:
            return revision >= 10 ? 37 : revision >= 8 ? 36 : revision >= 7 ? 35 : revision >= 6 ? 34 : revision >= 5 ? 33 : revision >= 3 ? 29 : revision >= 2 ? 28 : 27
        case .buds2Pro:
            return revision >= 13 ? 45 : revision >= 11 ? 44 : revision >= 8 ? 43 : revision >= 3 ? 42 : revision >= 1 ? 41 : 34
        case .buds:return 13
        case .budsPlus:return 19
        case .budsLive:return 21
        case .budsPro:return 28
        case .budsFE,.buds3,.buds3Pro,.buds3FE,.budsCore,.buds4:return 25
        case .buds4Pro:return 25 // Verified common prefix and ANC level; no newer detail offsets assumed.
        }
    }
    public func status(_ p:[UInt8]) -> DeviceState? {
        guard let revision=p.first,p.count >= minimumStatusLength(revision:revision),p.count <= 1020 else { return nil }
        var state=DeviceState()
        let charge:UInt8?
        switch self {
        case .buds2:charge=revision >= 10 ? p[36] : nil
        case .buds2Pro:charge=revision >= 11 ? p[43] : nil
        default:charge=nil // New-generation charge layout requires separate evidence.
        }
        Self.battery(p[2],slot:.left,charging:charge.map { $0 & 16 != 0 } ?? false,to:&state)
        Self.battery(p[3],slot:.right,charging:charge.map { $0 & 4 != 0 } ?? false,to:&state)
        if !legacy { Self.battery(p[7],slot:.enclosure,charging:charge.map { $0 & 1 != 0 } ?? false,to:&state) }
        if self == .buds || self == .budsPlus {
            let raw=p[self == .buds ? 7 : 8]
            guard raw <= 1 else { return nil };state.noise=raw == 1 ? .transparency : .off
        } else {
            guard p[12] <= 3 else { return nil };let mode=[NoiseMode.off,.anc,.transparency,.adaptive][Int(p[12])]
            guard noiseModes.contains(mode) else { return nil };state.noise=mode
        }
        if hasTouchControl || self == .buds4Pro { state.samsungControls=SamsungControlState(revision:revision,touchFlags:p[10],ancLevel:self == .buds4Pro && p[24] <= 4 ? Int(p[24]) : nil) }
        let eq:UInt8? = legacy ? (p[10] == 0 ? 0 : (5...9).contains(p[11]) ? p[11]-4 : nil) : p[self == .budsPlus ? 11 : 9]
        if let eq,eq <= 5 { state.eq=eq;state.observedQueries.insert(Command.equalizer) }
        state.observedQueries.formUnion([Command.battery,Command.noise])
        return state
    }
    public func touchLockPayload(_ locked:Bool,current:SamsungControlState) throws -> [UInt8] {
        // Preserve individual gesture preferences, including call gestures on
        // revisions that actually carry them. Buds4 touch settings are deferred.
        guard hasTouchControl else { throw ProtocolError.unsupported }
        let bits:[UInt8] = (self == .buds2 && current.revision >= 7) || (self == .buds2Pro && current.revision >= 1) ? [3,2,1,0,4,5] : [3,2,1,0]
        return [locked ? 0 : 1] + bits.map { (current.touchFlags >> $0) & 1 }
    }
    public static func battery(_ raw:UInt8,slot:BatterySlot,charging:Bool,to state:inout DeviceState) {
        state.batteries[slot]=raw <= 100 ? BatteryReading(percent:Int(raw),charging:charging) : nil
    }
    public func noiseFrame(_ mode:NoiseMode) -> SamsungFrame? {
        guard let value=noiseByte(mode) else { return nil }
        if legacy || self == .budsPlus { return SamsungFrame(0x80,[mode == .transparency ? 1 : 0]) }
        if self == .budsLive { return SamsungFrame(0x98,[mode == .anc ? 1 : 0]) }
        return SamsungFrame(0x78,[value])
    }
    public func eqPayload(_ id:UInt8) -> [UInt8]? {
        guard id <= 5 else { return nil };return legacy ? [id == 0 ? 0 : 1,id == 0 ? 5 : id+4] : [id]
    }
    public func noiseByte(_ mode:NoiseMode) -> UInt8? {
        guard noiseModes.contains(mode) else { return nil }
        switch mode { case .off:return 0;case .anc:return 1;case .transparency:return 2;case .adaptive:return supportsAdaptive ? 3 : nil;default:return nil }
    }
}
