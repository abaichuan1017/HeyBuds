// Sony MDR framing, based on the MIT references listed in Licenses/Sony-MIT.txt.
import Foundation

public struct SonyFrame:Equatable,Sendable {
    public let type:UInt8
    public let sequence:UInt8
    public let payload:[UInt8]
    public init(type:UInt8=0x0C,sequence:UInt8=0,payload:[UInt8]=[]) {
        self.type=type;self.sequence=sequence;self.payload=payload
    }
}

/// Bounded streaming decoder; one RFCOMM callback need not contain one frame.
public struct SonyFrameCodec {
    public static let maximumPayload=4096
    private var body:[UInt8]=[]
    private var reading=false
    private var escaped=false
    public init() {}
    public mutating func reset() { body.removeAll(keepingCapacity:true);reading=false;escaped=false }
    public static func encode(_ frame:SonyFrame) throws -> Data {
        guard frame.payload.count <= maximumPayload,frame.sequence <= 1 else { throw ProtocolError.invalidPayload }
        let length=UInt32(frame.payload.count)
        var body:[UInt8]=[frame.type,frame.sequence,UInt8(truncatingIfNeeded:length>>24),
                         UInt8(truncatingIfNeeded:length>>16),UInt8(truncatingIfNeeded:length>>8),UInt8(truncatingIfNeeded:length)]
        body += frame.payload;body.append(body.reduce(0,&+))
        var bytes:[UInt8]=[0x3E]
        for byte in body {
            if (0x3C...0x3E).contains(byte) { bytes += [0x3D,byte & 0xEF] }
            else { bytes.append(byte) }
        }
        bytes.append(0x3C);return Data(bytes)
    }
    public mutating func feed(_ bytes:Data) -> [SonyFrame] {
        var frames:[SonyFrame]=[]
        for byte in bytes {
            // An unescaped start marker also recovers from a truncated escape.
            if byte == 0x3E { body.removeAll(keepingCapacity:true);reading=true;escaped=false;continue }
            guard reading else { continue }
            if escaped {
                guard (0x2C...0x2E).contains(byte) else { reset();continue }
                body.append(byte | 0x10);escaped=false
            } else if byte == 0x3D { escaped=true }
            else if byte == 0x3C {
                if let frame=Self.decode(body) { frames.append(frame) }
                reset();continue
            } else { body.append(byte) }
            if body.count > Self.maximumPayload+7 { reset() }
            else if body.count == 6,Self.length(body) > Self.maximumPayload { reset() }
        }
        return frames
    }
    private static func length(_ bytes:[UInt8]) -> Int {
        Int(UInt32(bytes[2])<<24 | UInt32(bytes[3])<<16 | UInt32(bytes[4])<<8 | UInt32(bytes[5]))
    }
    private static func decode(_ body:[UInt8]) -> SonyFrame? {
        guard body.count >= 7,body[1] <= 1 else { return nil }
        let count=length(body)
        guard count <= maximumPayload,body.count == count+7,
              body.dropLast().reduce(UInt8(0),&+) == body.last else { return nil }
        return SonyFrame(type:body[0],sequence:body[1],payload:Array(body[6..<6+count]))
    }
}
