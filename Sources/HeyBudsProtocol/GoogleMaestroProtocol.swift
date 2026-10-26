// Handwritten bounded Maestro/Pigweed subset, referencing PixelBudsMacOS and
// pbpctrl (MIT). No telemetry, account, OTA or undocumented settings are exposed.
import Foundation

public enum ProtoValue:Equatable,Sendable {
    case uint(UInt64),fixed32(UInt32),fixed64(UInt64),bytes([UInt8])
}
public struct ProtoFields:Sendable {
    public let values:[Int:[ProtoValue]]
    public init(_ bytes:[UInt8]) throws {
        guard bytes.count <= 16_384 else { throw ProtocolError.invalidPayload }
        var result:[Int:[ProtoValue]]=[:],offset=0,count=0
        while offset < bytes.count {
            let key=try Self.varint(bytes,offset:&offset),field=Int(key>>3)
            guard field > 0,field <= 536_870_911,count < 256 else { throw ProtocolError.invalidPayload }
            count += 1
            let value:ProtoValue
            switch key & 7 {
            case 0:value = .uint(try Self.varint(bytes,offset:&offset))
            case 1:
                guard bytes.count-offset >= 8 else { throw ProtocolError.invalidPayload }
                var n:UInt64=0;for i in 0..<8 { n |= UInt64(bytes[offset+i]) << (i*8) };offset += 8;value = .fixed64(n)
            case 5:
                guard bytes.count-offset >= 4 else { throw ProtocolError.invalidPayload }
                var n:UInt32=0;for i in 0..<4 { n |= UInt32(bytes[offset+i]) << (i*8) };offset += 4;value = .fixed32(n)
            case 2:
                let n=try Self.varint(bytes,offset:&offset)
                guard n <= UInt64(bytes.count-offset) else { throw ProtocolError.invalidPayload }
                value = .bytes(Array(bytes[offset..<offset+Int(n)]));offset += Int(n)
            default:throw ProtocolError.invalidPayload
            }
            result[field,default:[]].append(value)
        }
        values=result
    }
    public func one(_ field:Int) -> ProtoValue? { guard values[field]?.count == 1 else { return nil };return values[field]?.first }
    public func uint(_ field:Int) -> UInt64? { if case .uint(let value)=one(field) { return value };return nil }
    public func fixed(_ field:Int) -> UInt32? { if case .fixed32(let value)=one(field) { return value };return nil }
    public func bytes(_ field:Int) -> [UInt8]? { if case .bytes(let value)=one(field) { return value };return nil }
    public func message(_ field:Int) -> ProtoFields? { bytes(field).flatMap { try? ProtoFields($0) } }
    public func present(_ field:Int) -> Bool { values[field] != nil }
    private static func varint(_ bytes:[UInt8],offset:inout Int) throws -> UInt64 {
        var result:UInt64=0
        for i in 0..<10 {
            guard offset < bytes.count else { throw ProtocolError.invalidPayload }
            let b=bytes[offset];offset += 1
            guard i < 9 || b <= 1 else { throw ProtocolError.invalidPayload }
            result |= UInt64(b & 0x7F) << (i*7)
            if b & 0x80 == 0 { return result }
        }
        throw ProtocolError.invalidPayload
    }
    public static func varint(_ value:UInt64) -> [UInt8] {
        var n=value,result:[UInt8]=[]
        repeat { let b=UInt8(n & 0x7F);n >>= 7;result.append(b | (n == 0 ? 0 : 0x80)) } while n != 0
        return result
    }
    public static func encode(_ field:Int,_ value:ProtoValue) -> [UInt8] {
        let wire:UInt64,data:[UInt8]
        switch value {
        case .uint(let v):wire=0;data=varint(v)
        case .fixed32(let v):wire=5;data=(0..<4).map { UInt8(truncatingIfNeeded:v >> ($0*8)) }
        case .fixed64(let v):wire=1;data=(0..<8).map { UInt8(truncatingIfNeeded:v >> ($0*8)) }
        case .bytes(let v):wire=2;data=varint(UInt64(v.count))+v
        }
        return varint(UInt64(field)<<3 | wire)+data
    }
}

public struct GoogleRPCFrame:Equatable,Sendable {
    public let type:UInt32,channel:UInt32,service:UInt32,method:UInt32,call:UInt32,status:UInt32
    public let payload:[UInt8]
    public init(type:UInt32=0,channel:UInt32,service:UInt32=GoogleMaestro.serviceID,method:UInt32,call:UInt32,status:UInt32=0,payload:[UInt8]=[]) {
        self.type=type;self.channel=channel;self.service=service;self.method=method;self.call=call;self.status=status;self.payload=payload
    }
    public var protobuf:[UInt8] {
        ProtoFields.encode(1,.uint(UInt64(type))) + ProtoFields.encode(2,.uint(UInt64(channel)))
        + ProtoFields.encode(3,.fixed32(service)) + ProtoFields.encode(4,.fixed32(method))
        + ProtoFields.encode(5,.bytes(payload)) + ProtoFields.encode(6,.uint(UInt64(status))) + ProtoFields.encode(7,.uint(UInt64(call)))
    }
    public static func decode(_ bytes:[UInt8]) -> Self? {
        guard let p=try? ProtoFields(bytes),let channel=p.uint(2),let call=p.uint(7),
              let service=p.fixed(3),let method=p.fixed(4),channel <= UInt32.max,call <= UInt32.max else { return nil }
        for key in [1,5,6] where p.present(key) && p.one(key) == nil { return nil }
        guard !p.present(1) || p.uint(1) != nil,!p.present(5) || p.bytes(5) != nil,!p.present(6) || p.uint(6) != nil,
              (p.uint(1) ?? 0) <= 8,(p.uint(6) ?? 0) <= UInt32.max else { return nil }
        return Self(type:UInt32(p.uint(1) ?? 0),channel:UInt32(channel),service:service,method:method,call:UInt32(call),status:UInt32(p.uint(6) ?? 0),payload:p.bytes(5) ?? [])
    }
}
public struct GoogleFrameCodec {
    private var buffer:[UInt8]=[]
    private var reading=false,escaped=false
    public init() {}
    public mutating func reset() { buffer.removeAll(keepingCapacity:true);reading=false;escaped=false }
    public static func crc32(_ bytes:[UInt8]) -> UInt32 {
        var crc:UInt32=0xFFFFFFFF
        for b in bytes { crc ^= UInt32(b);for _ in 0..<8 { crc=crc & 1 != 0 ? (crc>>1)^0xEDB88320 : crc>>1 } }
        return ~crc
    }
    public static func address(_ channel:UInt32) -> UInt32? {
        switch channel { case 19:return (10<<6)|(3<<10);case 21:return (10<<6)|(4<<10);case 24:return (13<<6)|(3<<10);case 26:return (13<<6)|(4<<10);default:return nil }
    }
    public static func encode(_ frame:GoogleRPCFrame) throws -> Data {
        guard var address=address(frame.channel),frame.payload.count <= 15_000 else { throw ProtocolError.invalidPayload }
        var raw:[UInt8]=[]
        repeat { let part=UInt8(address & 0x7F)<<1;address >>= 7;raw.append(part | (address == 0 ? 1 : 0)) } while address != 0
        raw += [3]+frame.protobuf
        let crc=crc32(raw);raw += (0..<4).map { UInt8(truncatingIfNeeded:crc >> ($0*8)) }
        var out:[UInt8]=[0x7E]
        for b in raw { if b == 0x7E || b == 0x7D { out += [0x7D,b^0x20] } else { out.append(b) } }
        return Data(out+[0x7E])
    }
    public mutating func feed(_ data:Data) -> [GoogleRPCFrame] {
        var frames:[GoogleRPCFrame]=[]
        for b in data {
            if b == 0x7E {
                if reading,!escaped,let frame=Self.decode(buffer) { frames.append(frame) }
                buffer.removeAll(keepingCapacity:true);reading=true;escaped=false;continue
            }
            guard reading else { continue }
            if escaped {
                guard b == 0x5D || b == 0x5E else { reset();continue }
                buffer.append(b^0x20);escaped=false
            } else if b == 0x7D { escaped=true } else { buffer.append(b) }
            if buffer.count > 16_384 { reset() }
        }
        return frames
    }
    private static func decode(_ bytes:[UInt8]) -> GoogleRPCFrame? {
        guard bytes.count >= 6 else { return nil }
        let end=bytes.count-4
        let crc=(0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[end+$1]) << ($1*8) }
        guard crc32(Array(bytes[..<end])) == crc else { return nil }
        var address:UInt64=0,offset=0
        for i in 0..<5 {
            guard i < end else { return nil };address |= UInt64(bytes[i]>>1) << (i*7)
            if bytes[i] & 1 == 1 { offset=i+1;break }
        }
        guard offset > 0,address <= UInt32.max,offset < end,bytes[offset] == 3 else { return nil }
        return GoogleRPCFrame.decode(Array(bytes[(offset+1)..<end]))
    }
}
public enum GoogleMaestro {
    public static let service="25E97FF7-24CE-4C4C-8951-F764A708F7B5"
    public static let candidates:[UInt32]=[19,24,21,26] // Documented logical RPC routes, not RFCOMM channel numbers.
    public static let serviceID=hash("maestro_pw.Maestro")
    public static func hash(_ name:String) -> UInt32 {
        var h=UInt32(name.utf8.count),coefficient:UInt32=65599
        for b in name.utf8 { h=h &+ coefficient &* UInt32(b);coefficient=coefficient &* 65599 };return h
    }
    public static func noise(_ bytes:[UInt8]) -> NoiseMode? {
        guard let setting=(try? ProtoFields(bytes))?.message(4),let raw=setting.uint(13) else { return nil }
        return [UInt64(1):.off,2:.anc,3:.transparency,4:.adaptive][raw]
    }
    public static func noiseWrite(_ mode:NoiseMode) throws -> [UInt8] {
        let values:[NoiseMode:UInt64]=[.off:1,.anc:2,.transparency:3,.adaptive:4]
        guard let value=values[mode] else { throw ProtocolError.unsupported }
        return ProtoFields.encode(4,.bytes(ProtoFields.encode(13,.uint(value))))
    }
    public static let presets:[[Float]]=[[0,0,0,0,0],[4,3,1,0,0],[-1,0,2,3,1],[0,0,1,3,4],[-4,-2,0,0,0]]
    public static func equalizer(_ bytes:[UInt8]) -> [Float]? {
        guard let p=(try? ProtoFields(bytes))?.message(4)?.message(16) else { return nil }
        var result:[Float]=[]
        for field in 1...5 {
            guard !p.present(field) || p.fixed(field) != nil else { return nil }
            let value=Float(bitPattern:p.fixed(field) ?? 0)
            guard value.isFinite,(-6...6).contains(value) else { return nil };result.append(value)
        }
        return result
    }
    public static func equalizerWrite(_ bands:[Float]) throws -> [UInt8] {
        guard bands.count == 5,bands.allSatisfy({$0.isFinite && (-6...6).contains($0)}) else { throw ProtocolError.invalidPayload }
        let eq=bands.enumerated().flatMap { ProtoFields.encode($0.offset+1,.fixed32($0.element.bitPattern)) }
        return ProtoFields.encode(4,.bytes(ProtoFields.encode(16,.bytes(eq))))
    }
    public static func preset(_ bands:[Float]) -> UInt8? {
        guard bands.count == 5 else { return nil }
        return presets.firstIndex { zip($0,bands).allSatisfy { abs($0-$1) < 0.05 } }.map(UInt8.init)
    }
    public static func firmware(_ bytes:[UInt8]) -> String? {
        guard let firmware=(try? ProtoFields(bytes))?.message(4) else { return nil }
        let versions=(1...3).compactMap { field -> String? in
            guard let raw=firmware.message(field)?.bytes(2),!raw.isEmpty,raw.count <= 64,
                  raw.allSatisfy({(0x20...0x7E).contains($0)}) else { return nil }
            return String(bytes:raw,encoding:.utf8)
        }
        return versions.isEmpty ? nil : Array(Set(versions)).sorted().joined(separator:" / ")
    }
    @discardableResult public static func applyRuntime(_ bytes:[UInt8],to state:inout DeviceState) -> Bool {
        guard let battery=(try? ProtoFields(bytes))?.message(6) else { return false }
        var updates:[(BatterySlot,BatteryReading?)]=[]
        for (field,slot):(Int,BatterySlot) in [(1,.enclosure),(2,.left),(3,.right)] where battery.present(field) {
            guard let item=battery.message(field),!item.present(1) || item.uint(1) != nil,!item.present(2) || item.uint(2) != nil else { return false }
            let level=item.uint(1) ?? 0,status=item.uint(2) ?? 0
            updates.append((slot,level <= 100 && (status == 1 || status == 2) ? BatteryReading(percent:Int(level),charging:status == 2) : nil))
        }
        guard !updates.isEmpty else { return false }
        // Runtime BatteryInfo is a snapshot: an omitted component is unknown,
        // not an invitation to keep an earlier case/earbud reading indefinitely.
        state.batteries=Dictionary(uniqueKeysWithValues:updates.compactMap { slot,value in value.map { (slot,$0) } })
        state.observedQueries.insert(Command.battery);return true
    }
}
