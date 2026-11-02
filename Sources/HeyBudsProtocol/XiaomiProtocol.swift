// SPDX-License-Identifier: GPL-3.0-or-later
// MMA interoperability facts: BudsLink, buds-ctl and redmi-buds-bar.
import Foundation

/// Explicitly requested models only. A family-name match never enables this backend.
public enum XiaomiProfile:String,CaseIterable,Sendable {
    case buds5pro,redmi8pro,redmi8lite,redmi8,redmi8active
    case redmi6pro,redmi6lite,redmi6play,redmi5pro,redmi5
    case clip,redmi6,redmi6active,redmi4pro,redmi3,basicS

    public var modelID:String { "xiaomi:"+rawValue }
    public var name:String {
        switch self {
        case .buds5pro:return "Xiaomi Buds 5 Pro"
        case .clip:return "Xiaomi 耳夹式耳机"
        case .basicS:return "Mi True Wireless Earbuds Basic S"
        default:
            let suffix=rawValue.replacingOccurrences(of:"redmi",with:"")
                .replacingOccurrences(of:"pro",with:" Pro").replacingOccurrences(of:"lite",with:" Lite")
                .replacingOccurrences(of:"active",with:" Active").replacingOccurrences(of:"play",with:" Play")
            return "Redmi Buds "+suffix
        }
    }
    public var aliases:[String] {
        switch self {
        case .buds5pro:return ["Xiaomi Buds 5 Pro M2437E1"]
        case .clip:return ["Xiaomi Clip-on Earbuds","M2529E1","Xiaomi 耳夹式耳机 M2529E1"]
        case .basicS:return ["Mi True Wireless EBs Basic S","Mi TW Earphones Basic S","TWSEJ05LS"]
        default:return []
        }
    }
    public static func named(_ name:String) -> Self? {
        let value=EarbudFamily.normalize(name)
        return allCases.first { ([ $0.name ]+$0.aliases).contains { EarbudFamily.normalize($0) == value } }
    }
    public var systemBatteryOnly:Bool { [.redmi6,.redmi6active,.redmi4pro,.redmi3,.basicS].contains(self) }
    public var controls:Bool { !systemBatteryOnly && self != .clip }
    public var transportKinds:[String] { systemBatteryOnly ? ["System"] : [.buds5pro,.clip].contains(self) ? ["BLE"] : ["RFCOMM"] }
    public var requestType:UInt8 { self == .redmi8pro ? 0xC0 : 0xC4 }
    public var requiresAuthentication:Bool { !systemBatteryOnly && ![.clip,.redmi8pro,.redmi6lite].contains(self) }
    public static let service="0000FD2D-0000-1000-8000-00805F9B34FB"
    public static let miwearService="DF21FE2C-2515-4FDB-8886-F12C4D67927C"
    public static let bleService="0000AF00-0000-1000-8000-00805F9B34FB"
    public static let bleWrite="0000AF07-0000-1000-8000-00805F9B34FB"
    public static let bleNotify="0000AF08-0000-1000-8000-00805F9B34FB"
    public var services:[String] {
        if self == .redmi8pro || self == .redmi6play { return [Self.service] }
        let legacy="00001101-0000-1000-8000-008584D01810"
        return self == .redmi8 ? [Self.miwearService,Self.service,legacy] : [Self.service,legacy]
    }
    public var productIDs:Set<UInt16> {
        switch self {
        case .buds5pro:return [0x50AD,0x50B4] // Wi-Fi variant is outside this change.
        case .redmi8pro:return [0x50E3,0x50E5]
        case .redmi8lite:return [0x50EE,0x50EF]
        case .redmi8:return [0x50F2,0x50F3]
        case .redmi8active:return [0x50E1,0x50E2]
        case .redmi6pro:return [0x509D,0x509E] // Gaming edition is not inferred.
        case .redmi6lite:return [0x508A,0x508B]
        case .redmi6play:return [0x509B]
        case .redmi5pro:return [0x506C,0x506D,0x506F]
        case .redmi5:return [0x506A,0x506B,0x5075]
        default:return []
        }
    }
    public func accepts(vendor:UInt16,product:UInt16) -> Bool {
        vendor == 0x2717 && (self == .clip || productIDs.contains(product))
    }
    public func presentationModel(_ model:DeviceModel,aggregateBattery:Bool) -> DeviceModel {
        guard systemBatteryOnly,case .object(var raw)=model.raw,
              case .object(var function)=raw["function"] else { return model }
        function["singleBattery"] = .bool(aggregateBattery);raw["function"] = .object(function)
        return DeviceModel.migrated(.object(raw)) ?? model
    }
}

public struct XiaomiFrame:Equatable,Sendable {
    public let type:UInt8,opcode:UInt8,sequence:UInt8
    public let payload:[UInt8]
    public let status:UInt8
    public var isRequest:Bool { type & 0x80 != 0 }
    public var needsReply:Bool { isRequest && type & 0x40 != 0 }
    public init(type:UInt8=0xC4,opcode:UInt8,sequence:UInt8,payload:[UInt8]=[],status:UInt8=0) {
        self.type=type;self.opcode=opcode;self.sequence=sequence;self.payload=payload;self.status=status
    }
    public func reply(_ bytes:[UInt8]=[],type:UInt8?=nil,status:UInt8=0) -> Self {
        Self(type:type ?? (self.type & 7),opcode:opcode,sequence:sequence,payload:bytes,status:status)
    }
}

/// Responses have a status byte BEFORE their sequence. Embedded EF/header bytes
/// are data; complete lengths, bounds and the final trailer determine a frame.
public struct XiaomiFrameCodec:Sendable {
    private var buffer:[UInt8]=[]
    public init() {}
    public mutating func reset() { buffer=[] }
    public static func encode(_ frame:XiaomiFrame) throws -> Data {
        guard frame.payload.count <= 4096,[UInt8(0),4,7].contains(frame.type & 7) else { throw ProtocolError.invalidPayload }
        let body=(frame.isRequest ? [] : [frame.status])+[frame.sequence]+frame.payload
        return Data([0xFE,0xDC,0xBA,frame.type,frame.opcode,UInt8(body.count >> 8),UInt8(truncatingIfNeeded:body.count)]+body+[0xEF])
    }
    public mutating func feed(_ bytes:Data) -> [XiaomiFrame] {
        buffer.append(contentsOf:bytes);var result:[XiaomiFrame]=[]
        let prefix:[UInt8]=[0xFE,0xDC,0xBA]
        while !buffer.isEmpty {
            if buffer.count < 3,prefix.starts(with:buffer) { break }
            guard buffer.starts(with:prefix) else { buffer.removeFirst();continue }
            guard buffer.count >= 7 else { break }
            let length=Int(buffer[5]) << 8 | Int(buffer[6]),request=buffer[3] & 0x80 != 0
            let minimum=request ? 1 : 2
            guard (minimum...4098).contains(length),[UInt8(0),4,7].contains(buffer[3] & 7) else { buffer.removeFirst();continue }
            let count=length+8
            guard buffer.count >= count else { break }
            guard buffer[count-1] == 0xEF else { buffer.removeFirst();continue }
            let index=request ? 7 : 8
            result.append(XiaomiFrame(type:buffer[3],opcode:buffer[4],sequence:buffer[index],payload:Array(buffer[(index+1)..<(count-1)]),status:request ? 0 : buffer[7]))
            buffer.removeFirst(count)
        }
        if buffer.count > 8192 { buffer=[] }
        return result
    }
}

public enum XiaomiProtocol {
    public static let frequencies:[UInt16]=[62,125,250,500,1000,2000,4000,8000,12000,16000]
    /// Both TLV layouts count the ID bytes inside their length. Duplicate IDs
    /// and partial tails are rejected before any state is published.
    public static func records(_ bytes:[UInt8],idBytes:Int) -> [UInt16:[UInt8]]? {
        guard idBytes == 1 || idBytes == 2 else { return nil }
        var offset=0,result:[UInt16:[UInt8]]=[:]
        while offset < bytes.count {
            let length=Int(bytes[offset]),end=offset+length+1
            guard length >= idBytes,end <= bytes.count else { return nil }
            let id=idBytes == 1 ? UInt16(bytes[offset+1]) : UInt16(bytes[offset+1]) << 8 | UInt16(bytes[offset+2])
            guard result[id] == nil else { return nil }
            result[id]=Array(bytes[(offset+1+idBytes)..<end]);offset=end
        }
        return result
    }
    public static func config(_ id:UInt16,_ value:[UInt8]) throws -> [UInt8] {
        guard value.count <= 252 else { throw ProtocolError.invalidPayload }
        return [UInt8(value.count+2),UInt8(id >> 8),UInt8(truncatingIfNeeded:id)]+value
    }
    public static func batteries(_ bytes:[UInt8]) -> [BatterySlot:BatteryReading]? {
        guard bytes.count == 3 else { return nil }
        var result:[BatterySlot:BatteryReading]=[:]
        for (index,slot) in BatterySlot.allCases.enumerated() {
            let value=bytes[index]
            if value == 0xFF { continue }
            guard value & 0x7F <= 100 else { return nil }
            result[slot]=BatteryReading(percent:Int(value & 0x7F),charging:value & 0x80 != 0)
        }
        return result
    }
    public static func identity(_ records:[UInt16:[UInt8]]) -> (vendor:UInt16,product:UInt16)? {
        guard let bytes=records[3],bytes.count == 4 else { return nil }
        return (UInt16(bytes[0]) << 8 | UInt16(bytes[1]),UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
    }
    public static func firmware(_ bytes:[UInt8]) -> String? {
        guard bytes.count == 2 || bytes.count == 4 else { return nil }
        func version(_ offset:Int) -> String { [bytes[offset] >> 4,bytes[offset] & 15,bytes[offset+1] >> 4,bytes[offset+1] & 15].map(String.init).joined(separator:".") }
        let first=version(0)
        return bytes.count == 4 && Array(bytes.prefix(2)) != Array(bytes.suffix(2)) ? first+" / "+version(2) : first
    }
    public static func noise(_ value:[UInt8]) -> NoiseMode? {
        guard value.count == 2 else { return nil }
        return [UInt8(0):NoiseMode.off,1:.anc,2:.transparency][value[0]]
    }
    public static func gestures(_ value:[UInt8]) -> [UInt8:[UInt8]]? {
        guard !value.isEmpty,value.count % 3 == 0 else { return nil }
        var result:[UInt8:[UInt8]]=[:]
        for offset in stride(from:0,to:value.count,by:3) {
            guard result[value[offset]] == nil else { return nil }
            result[value[offset]]=Array(value[(offset+1)...(offset+2)])
        }
        return result
    }
    public static func gestureType(_ common:UInt8) -> UInt8? { [UInt8(1):4,2:1,3:2,4:3,5:5][common] }
    public static func commonGesture(_ wire:UInt8) -> UInt8? { [UInt8(4):1,1:2,2:3,3:4,5:5][wire] }
    // Shared UI actions are deliberately distinct from Xiaomi wire values.
    public static let actionToWire:[UInt8:UInt8]=[0:8,1:1,3:0,5:2,6:3,7:11,17:7,0x30:4,0x31:5,0x32:6]
    public static func commonAction(_ wire:UInt8) -> UInt8? { actionToWire.first { $0.value == wire }?.key }
    public static func gestureEntries(_ value:[UInt8],model:DeviceModel) -> [GestureEntry] {
        guard let rows=gestures(value) else { return [] }
        return rows.sorted { $0.key < $1.key }.flatMap { wire,pair -> [GestureEntry] in
            guard let gesture=commonGesture(wire),!model.function["xiaomiGestureActions"][String(wire)].elements.isEmpty else { return [] }
            return pair.enumerated().compactMap { index,action in
                guard let common=commonAction(action) else { return nil }
                return GestureEntry(side:UInt8(index+1),mode:1,gesture:gesture,action:common)
            }
        }
    }
    public static func customEQ(_ bytes:[UInt8]) -> CustomEQEntry? {
        guard bytes.count >= 8,bytes[0] == 1,bytes[1] <= 15,bytes[2] <= 24,bytes[3] <= 24 else { return nil }
        let nameCount=Int(bytes[5]),start=6+nameCount
        guard start < bytes.count,let name=String(bytes:bytes[6..<start],encoding:.utf8) else { return nil }
        let count=Int(bytes[start]);guard count == 10,bytes.count == start+1+count*3 else { return nil }
        let upper=bytes[2] == 0 ? UInt8(10) : bytes[2]
        var frequencies:[UInt16]=[],gains:[Int8]=[]
        for i in 0..<count {
            let at=start+1+i*3,raw=bytes[at+2],magnitude=raw & 0x7F
            guard magnitude <= (raw & 0x80 != 0 ? bytes[3] : upper) else { return nil }
            frequencies.append(UInt16(bytes[at]) << 8 | UInt16(bytes[at+1]))
            gains.append(raw & 0x80 != 0 ? -Int8(magnitude) : Int8(magnitude))
        }
        guard frequencies == Self.frequencies else { return nil }
        return CustomEQEntry(id:10,name:name.isEmpty ? "Custom" : name,selected:false,minimum:-Int8(bytes[3]),maximum:Int8(upper),frequencies:frequencies,gains:gains)
    }
    public static func customEQWrite(_ entry:CustomEQEntry) throws -> [UInt8] {
        guard entry.id == 10,entry.frequencies == frequencies,entry.gains.count == 10,
              entry.gains.allSatisfy({ entry.minimum <= $0 && $0 <= entry.maximum }) else { throw ProtocolError.invalidPayload }
        var bytes:[UInt8]=[1,10,1,1,1,0,10]
        for (frequency,gain) in zip(entry.frequencies,entry.gains) {
            bytes += [UInt8(frequency >> 8),UInt8(truncatingIfNeeded:frequency),gain < 0 ? UInt8(-Int(gain)) | 0x80 : UInt8(gain)]
        }
        return bytes
    }
}
