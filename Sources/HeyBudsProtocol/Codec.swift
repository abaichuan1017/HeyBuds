// Ported from OppoPodsManager (GPL-3.0-or-later). See THIRD_PARTY_NOTICES.md.
import Foundation

public enum ProtocolError: Error, LocalizedError, Equatable {
    case invalidPayload, unsupported, rejected(UInt8), timeout(UInt16), disconnected, readbackMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Invalid protocol payload"
        case .unsupported: return "Feature unavailable for this device"
        case .rejected(let code): return String(format: "Device rejected request (0x%02X)", code)
        case .timeout(let command): return String(format: "Device response timed out (0x%04X)", command)
        case .disconnected: return "Control channel disconnected"
        case .readbackMismatch: return "Device readback differs from the requested value"
        }
    }
}

public struct OPOFrame: Equatable, Sendable {
    public var command: UInt16
    public var sequence: UInt8
    public var payload: [UInt8]
    public init(command: UInt16, sequence: UInt8 = 0xF0, payload: [UInt8] = []) {
        self.command = command; self.sequence = sequence; self.payload = payload
    }
}

/// Short OPOv1 framing used by the GPL and MIT references. Maximum payload 248.
/// Extended/ambiguous length encodings are deliberately not guessed.
public struct OPOFrameCodec: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public static func encode(_ frame: OPOFrame) throws -> Data {
        guard frame.payload.count <= 248 else { throw ProtocolError.invalidPayload }
        return Data([0xAA, UInt8(frame.payload.count + 7), 0, 0,
                     UInt8(truncatingIfNeeded: frame.command), UInt8(frame.command >> 8),
                     frame.sequence, UInt8(frame.payload.count), 0] + frame.payload)
    }
    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
    public mutating func feed(_ data: Data) -> [OPOFrame] {
        buffer.append(contentsOf: data)
        var frames: [OPOFrame] = []
        while let start = buffer.firstIndex(of: 0xAA) {
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 9 else { return frames }
            let total = Int(buffer[1]) + 2
            let count = Int(buffer[7]) | Int(buffer[8]) << 8
            guard total >= 9, total == 9 + count, buffer[2] == 0, buffer[3] == 0 else {
                buffer.removeFirst(); continue
            }
            guard buffer.count >= total else { return frames }
            frames.append(OPOFrame(command: UInt16(buffer[4]) | UInt16(buffer[5]) << 8,
                                   sequence: buffer[6], payload: Array(buffer[9..<total])))
            buffer.removeFirst(total)
        }
        buffer.removeAll(keepingCapacity: true)
        return frames
    }
}

public enum Command {
    public static let capabilities: UInt16 = 0x0100, product: UInt16 = 0x0103, firmware: UInt16 = 0x0105
    public static let battery: UInt16 = 0x0106, gestures: UInt16 = 0x0108, wear: UInt16 = 0x0109
    public static let noise: UInt16 = 0x010C, switches: UInt16 = 0x010D, equalizer: UInt16 = 0x010F
    public static let hosts: UInt16 = 0x0112, codec: UInt16 = 0x0114, customEQ: UInt16 = 0x0122
    public static let bass: UInt16 = 0x0124, spatial: UInt16 = 0x012A, gameSound: UInt16 = 0x012B
    public static let priority: UInt16 = 0x0132
    public static let find: UInt16 = 0x0400, setGestures: UInt16 = 0x0401, setSwitch: UInt16 = 0x0403
    public static let setNoise: UInt16 = 0x0404, setEQ: UInt16 = 0x0406, setCustomEQ: UInt16 = 0x0418
    public static let setBass: UInt16 = 0x041B, setSpatial: UInt16 = 0x0422, setGameSound: UInt16 = 0x0423
    public static let operateHost: UInt16 = 0x0429
    public static let safeQueries: Set<UInt16> = [capabilities, product, firmware, battery, gestures, wear,
        noise, switches, equalizer, hosts, codec, customEQ, bass, spatial, gameSound, priority, 0x0200]
    public static let allowedWrites: Set<UInt16> = [find, setGestures, setSwitch, setNoise, setEQ,
        setCustomEQ, setBass, setSpatial, setGameSound, operateHost, 0x0201, 0x0205, 0x8500]
}

public enum CapabilityBitmap {
    public static let always: Set<UInt16> = [0x0100, 0x0101, 0x0102, 0x0103, 0x0104, 0x010B,
        0x0F00, 0x0F04, 0x010D, 0x0F03, 0x0106]
    // Melody V16, low bit first. Only mapped implemented commands are exposed.
    private static let map: [Int: [UInt16]] = [0:[0x0105],1:[0x0106],3:[0x0108,0x0401],4:[0x0109],
        5:[0x0400],7:[0x0403],8:[0x010C,0x0404],10:[0x0406,0x010F],19:[0x040D,0x0115],
        22:[0x0205],25:[0x0118,0x0411],27:[0x011C,0x0413],29:[0x0112,0x040B],
        33:[0x0121,0x0417],34:[0x0122,0x0418],38:[0x0124,0x041B],47:[0x0422,0x012A],
        49:[0x0423,0x012B],59:[0x0429,0x0132],14:[0x0409],17:[0x0114]]
    public static func decode(_ payload: [UInt8]) -> Set<UInt16>? {
        guard payload.count >= 2, payload[0] == 0 else { return nil }
        let bits = Array(payload.dropFirst())
        var commands = always
        for (bit, entries) in map where bit / 8 < bits.count && bits[bit / 8] & (1 << (bit % 8)) != 0 {
            commands.formUnion(entries)
        }
        return commands
    }
}
