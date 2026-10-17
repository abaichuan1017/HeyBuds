// Wire formats ported from OppoPodsManager, GPL-3.0-or-later.
import Foundation

public struct BrandFrame:Equatable,Sendable {
    public let command:UInt16
    public let payload:[UInt8]
    public let sequence:UInt8
    public let kind:UInt8
    public init(_ command:UInt16,_ payload:[UInt8]=[],sequence:UInt8=0,kind:UInt8=0xC4) {
        self.command=command;self.payload=payload;self.sequence=sequence;self.kind=kind
    }
}
public struct BrandFrameCodec:Sendable {
    public let family:EarbudFamily
    public let gaiaVersion:UInt8
    public let mbb:Bool
    private var buffer:[UInt8]=[]
    public init(family:EarbudFamily,gaiaVersion:UInt8=4,mbb:Bool=false) { self.family=family;self.gaiaVersion=gaiaVersion;self.mbb=mbb }
    public func encode(_ frame:BrandFrame) throws -> Data {
        let p=frame.payload,c=frame.command
        var bytes:[UInt8]
        switch family {
        case .vivo:
            guard p.count <= 254 else { throw ProtocolError.invalidPayload }
            let handshake=c == 0x0300
            bytes=[0xFF,handshake || c == 0x0207 || c == 0x8207 ? 4 : gaiaVersion,0,UInt8(p.count),0,handshake ? 0x0A : 0x1B,UInt8(c>>8),UInt8(truncatingIfNeeded:c)]+p
        case .huawei:
            guard p.count <= 4096 else { throw ProtocolError.invalidPayload }
            let count=p.count+3
            bytes=mbb ? [0x5A,UInt8(count>>8),UInt8(truncatingIfNeeded:count),0] : [0x5A,0,UInt8(truncatingIfNeeded:count),UInt8(count>>8)]
            bytes += [UInt8(c>>8),UInt8(truncatingIfNeeded:c)]+p
            let crc=Self.crc16(bytes);bytes += [UInt8(crc>>8),UInt8(truncatingIfNeeded:crc)]
        case .edifier:
            guard p.count <= 254, c <= 255 else { throw ProtocolError.invalidPayload }
            // Upstream's encoder allocated one byte too few. Follow its documented
            // len=command+payload and checksum over ALL preceding bytes.
            bytes=[0xAA,UInt8(p.count+1),UInt8(c)]+p
            let sum=bytes.reduce(UInt16(8217)) { $0 &+ UInt16($1) }
            bytes += [UInt8(sum>>8),UInt8(truncatingIfNeeded:sum)]
        case .xiaomi:
            guard p.count <= 4096,c <= 255 else { throw ProtocolError.invalidPayload }
            let count=p.count+1
            bytes=[0xFE,0xDC,0xBA,frame.kind,UInt8(c),UInt8(count>>8),UInt8(truncatingIfNeeded:count),frame.sequence]+p+[0xEF]
        default:throw ProtocolError.unsupported
        }
        return Data(bytes)
    }
    public mutating func feed(_ data:Data) -> [BrandFrame] {
        buffer.append(contentsOf:data)
        var frames:[BrandFrame]=[]
        while !buffer.isEmpty {
            let prefix:[UInt8]
            switch family { case .vivo:prefix=[0xFF];case .huawei:prefix=[0x5A];case .xiaomi:prefix=[0xFE,0xDC,0xBA];case .edifier:prefix=[];default:buffer=[];return [] }
            if family == .edifier {
                guard let start=buffer.firstIndex(where:{$0 == 0xBB || $0 == 0xCC}) else { buffer=[];break }
                buffer.removeFirst(start)
            } else if buffer.count < prefix.count && prefix.starts(with:buffer) {
                break
            } else if !buffer.starts(with:prefix) {
                buffer.removeFirst();continue
            }
            let header=family == .xiaomi ? 8 : family == .vivo ? 8 : family == .huawei ? 6 : 3
            guard buffer.count >= header else { break }
            let total:Int
            switch family {
            case .vivo:
                guard [UInt8(3),4].contains(buffer[1]),buffer[2] == 0,buffer[4] == 0,[UInt8(0x0A),0x1B].contains(buffer[5]),buffer[3] <= 254 else { buffer.removeFirst();continue }
                total=8+Int(buffer[3])
            case .huawei:
                let count=mbb ? Int(buffer[1])<<8 | Int(buffer[2]) : Int(buffer[2]) | Int(buffer[3])<<8
                guard count >= 3,count <= 4099,(mbb ? buffer[3] == 0 : buffer[1] == 0) else { buffer.removeFirst();continue }
                // Fragment TLV semantics are unresolved upstream. Never parse a fragment as a control state.
                total=count+5
            case .xiaomi:
                let count=Int(buffer[5])<<8 | Int(buffer[6])
                guard count >= 1,count <= 4097 else { buffer.removeFirst();continue }
                total=count+8
            case .edifier:
                guard buffer[1] >= 1 else { buffer.removeFirst();continue };total=Int(buffer[1])+4
            default:return frames
            }
            guard buffer.count >= total else { break }
            let bytes=Array(buffer.prefix(total))
            if family == .huawei {
                let crc=Self.crc16(Array(bytes.dropLast(2)))
                guard bytes[total-2] == UInt8(crc>>8),bytes[total-1] == UInt8(truncatingIfNeeded:crc) else { buffer.removeFirst();continue }
            }
            if family == .edifier {
                let sum=bytes.dropLast(2).reduce(UInt16(8217)) { $0 &+ UInt16($1) }
                guard bytes[total-2] == UInt8(sum>>8),bytes[total-1] == UInt8(truncatingIfNeeded:sum) else { buffer.removeFirst();continue }
            }
            if family == .xiaomi,bytes.last != 0xEF { buffer.removeFirst();continue }
            switch family {
            case .vivo:frames.append(BrandFrame(UInt16(bytes[6])<<8 | UInt16(bytes[7]),Array(bytes[8...])))
            case .huawei:frames.append(BrandFrame(UInt16(bytes[4])<<8 | UInt16(bytes[5]),Array(bytes[6..<total-2])))
            case .edifier:frames.append(BrandFrame(UInt16(bytes[2]),Array(bytes[3..<total-2])))
            case .xiaomi:frames.append(BrandFrame(UInt16(bytes[4]),Array(bytes[8..<total-1]),sequence:bytes[7],kind:bytes[3]))
            default:break
            }
            buffer.removeFirst(total)
        }
        if buffer.count > 8192 { buffer=[] }
        return frames
    }
    public static func crc16(_ bytes:[UInt8]) -> UInt16 {
        var crc:UInt16=0
        for byte in bytes { crc ^= UInt16(byte)<<8;for _ in 0..<8 { crc=crc & 0x8000 != 0 ? (crc &<< 1)^0x1021 : crc &<< 1 } }
        return crc
    }
    public static func tlv(_ bytes:[UInt8]) -> [UInt8:[UInt8]]? {
        var result:[UInt8:[UInt8]]=[:],index=0
        while index < bytes.count {
            guard index+2 <= bytes.count else { return nil }
            let count=Int(bytes[index+1]),end=index+2+count
            guard end <= bytes.count else { return nil }
            result[bytes[index]]=Array(bytes[index+2..<end]);index=end
        }
        return result
    }
}
