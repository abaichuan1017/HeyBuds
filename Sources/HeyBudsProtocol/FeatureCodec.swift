// Adapted from OppoPodsManager protocol features, GPL-3.0-or-later.
import Foundation

private struct Cursor {
    let bytes: [UInt8]
    var offset = 0
    mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset+count])
    }
    mutating func byte() -> UInt8? { take(1)?.first }
}
public enum FeatureCodec {
    public static func customEntries(_ p: [UInt8]) -> [CustomEQEntry]? {
        var c=Cursor(bytes:p)
        guard c.byte() == 0, let count=c.byte() else { return nil }
        var result: [CustomEQEntry]=[]
        for _ in 0..<count {
            guard let header=c.take(5), let text=c.take(Int(header[4])), let bandCount=c.byte() else { return nil }
            var frequencies:[UInt16]=[], gains:[Int8]=[]
            for _ in 0..<bandCount {
                guard let band=c.take(3) else { return nil }
                frequencies.append(UInt16(band[0]) | UInt16(band[1]) << 8); gains.append(Int8(bitPattern:band[2]))
            }
            let min=Int8(bitPattern:header[1]), max=Int8(bitPattern:header[2])
            guard min <= max, gains.allSatisfy({ (min...max).contains($0) }) else { return nil }
            result.append(CustomEQEntry(id:header[3],name:String(bytes:text,encoding:.utf8)?.trimmingCharacters(in:.controlCharacters) ?? "EQ",
                selected:header[0] != 0,minimum:min,maximum:max,frequencies:frequencies,gains:gains))
        }
        return result
    }
    public static func validEQName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            let v=scalar.value
            return (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v) || (0x4E00...0x9FA5).contains(v)
        }
    }
    public static func customPayload(_ entry: CustomEQEntry, delete: Bool = false) throws -> [UInt8] {
        let name=Array(entry.name.utf8)
        guard validEQName(entry.name), !entry.frequencies.isEmpty,
              entry.frequencies.count == entry.gains.count, entry.frequencies.count <= 64,
              name.count <= 128, entry.minimum <= entry.maximum,
              entry.gains.allSatisfy({ (entry.minimum...entry.maximum).contains($0) }),
              6 + name.count + entry.frequencies.count*3 <= 248 else { throw ProtocolError.invalidPayload }
        var out:[UInt8]=[delete ? 3 : (entry.id == 0 ? 1 : 2),UInt8(bitPattern:entry.minimum),UInt8(bitPattern:entry.maximum),entry.id,UInt8(name.count)]
        out += name; out.append(UInt8(entry.frequencies.count))
        for (frequency,gain) in zip(entry.frequencies,entry.gains) { out += [UInt8(truncatingIfNeeded:frequency),UInt8(frequency>>8),UInt8(bitPattern:gain)] }
        return out
    }
    public static func remoteHosts(_ p:[UInt8]) -> [RemoteHost]? {
        var c=Cursor(bytes:p)
        guard c.byte() == 0, let count=c.byte() else { return nil }
        var result:[RemoteHost]=[]
        for _ in 0..<count {
            guard let addr=c.take(6), let meta=c.take(4), let name=c.take(Int(meta[3])) else { return nil }
            // Upstream formats list addresses in reverse order, then writes their
            // canonical bytes for 0x0429. Preserve that read/write distinction.
            result.append(RemoteHost(address:Array(addr.reversed()),name:String(bytes:name,encoding:.utf8)?.trimmingCharacters(in:.controlCharacters) ?? "",
                type:meta[0],connection:meta[1],flags:meta[2]))
        }
        return result
    }
    public static func hostPriority(_ p:[UInt8]) -> (automatic:Bool,address:[UInt8]?)? {
        // MultiDevice.ApplyPriority supports both a status-prefixed reply and
        // the direct [type, policy, address...] body used by some firmware.
        let offset=p.first == 0 ? 1 : 0
        guard p.count >= offset+2, p[offset] == 1 || p[offset] == 2 else { return nil }
        if p[offset+1] == 0 { return (true,nil) }
        guard p[offset+1] == 1, p.count >= offset+8 else { return nil }
        return (false,Array(p[(offset+2)..<(offset+8)].reversed()))
    }
    public enum HostOperation: Sendable { case connect, disconnect, priority, automatic }
    public static func hostPayload(_ operation: HostOperation, address: [UInt8] = []) throws -> [UInt8] {
        if case .automatic = operation { return [4,0] }
        guard address.count == 6 else { throw ProtocolError.invalidPayload }
        switch operation {
        case .connect: return [1] + address
        case .disconnect: return [2] + address
        case .priority: return [4,1] + address
        case .automatic: return [4,0]
        }
    }
    public static func gestures(_ p:[UInt8]) -> [GestureEntry]? {
        guard p.count >= 2, p[0] == 0, p.count >= 2+Int(p[1])*4 else { return nil }
        return (0..<Int(p[1])).map { let i=2+$0*4; return GestureEntry(side:p[i],mode:p[i+1],gesture:p[i+2],action:p[i+3]) }
    }
    public static func switchQuery(model: DeviceModel?) -> [UInt8] {
        var ids:[UInt8]=[5,6,0x28]
        ids += model?.features.map(\.switchID) ?? []
        if model?.spatialModes.isEmpty == false { ids.append(0x1B) }
        if model?.function["bassEngineSupport"].enabled == true { ids.append(0x1D) }
        if model?.gameTypes.isEmpty == false { ids.append(0x27) }
        let unique=Array(Set(ids)).sorted()
        return [UInt8(unique.count)] + unique
    }
}
