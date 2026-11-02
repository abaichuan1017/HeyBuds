import Foundation

/// Standard Fast Pair message stream: group, code, big-endian payload length.
/// Only Device Information / Model ID (03 01 00 03) is returned. The six hex
/// digits identify a product variant, not a particular physical device.
public struct NothingModelIDCodec {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func feed(_ data: Data) -> [String] {
        var ids: [String] = []
        for byte in data {
            buffer.append(byte)
            while buffer.count >= 4 {
                let count = Int(buffer[2]) << 8 | Int(buffer[3])
                guard count <= 1024 else { buffer.removeFirst(); continue }
                guard buffer.count >= count + 4 else { break }
                if buffer[0] == 3, buffer[1] == 1, count == 3 {
                    ids.append(buffer[4..<7].map { String(format: "%02X", $0) }.joined())
                }
                buffer.removeFirst(count + 4)
            }
        }
        return ids
    }
}
