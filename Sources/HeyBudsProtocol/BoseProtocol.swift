// BMAP protocol facts from aaronsb/bosectl and NerdySouth/bozo (MIT),
// BLE segmentation and Ultra Earbuds 2 corrections from depau/bosectl-android
// (GPL-3.0). See Licenses/Bose-MIT.txt. No fixed RFCOMM channels are imported.
import Foundation

public enum BoseOperation: UInt8, Sendable {
    case set = 0, get, setGet, status, error, start, result, processing
}

public struct BoseFrame: Equatable, Sendable {
    public let block: UInt8
    public let function: UInt8
    public let operation: BoseOperation
    public let route: UInt8
    public let payload: [UInt8]
    public init(_ block: UInt8, _ function: UInt8, _ operation: BoseOperation = .get,
                _ payload: [UInt8] = [], route: UInt8 = 0) {
        self.block=block; self.function=function; self.operation=operation
        self.payload=payload; self.route=route
    }
    public func matches(_ block: UInt8, _ function: UInt8) -> Bool {
        self.block == block && self.function == function && route == 0
    }
}

/// Length-delimited RFCOMM stream. There is no sync byte: after corruption the
/// stream is retired, never scanned for a plausible command in arbitrary data.
public struct BoseFrameCodec: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var failed = false
    public init() {}
    public mutating func reset() { buffer.removeAll(keepingCapacity:true); failed=false }
    public static func encode(_ frame: BoseFrame) throws -> Data {
        guard frame.payload.count <= 255, frame.route & 0x0F == 0 else { throw ProtocolError.invalidPayload }
        return Data([frame.block,frame.function,frame.route | frame.operation.rawValue,UInt8(frame.payload.count)] + frame.payload)
    }
    public mutating func feed(_ bytes: Data) -> [BoseFrame] {
        guard !failed else { return [] }
        guard bytes.count <= 16_384 else { buffer.removeAll(); failed=true; return [] }
        var result: [BoseFrame] = []
        // Incremental consumption bounds retained storage to one 259-byte frame.
        for byte in bytes {
            buffer.append(byte)
            guard buffer.count >= 4 else { continue }
            guard let op=BoseOperation(rawValue:buffer[2] & 0x0F) else {
                buffer.removeAll(); failed=true; return []
            }
            let length=4 + Int(buffer[3])
            if buffer.count == length {
                result.append(BoseFrame(buffer[0],buffer[1],op,Array(buffer.dropFirst(4)),route:buffer[2] & 0xF0))
                buffer.removeAll(keepingCapacity:true)
            }
        }
        return result
    }
}

/// One call to feed per ATT notification. Do not concatenate or re-chunk ATT
/// values. Reset at every connection generation. Header nibbles are last/index.
public struct BoseGATTCodec: Sendable {
    public static let maximumMessageLength = 4_096
    private var buffer: [UInt8] = []
    private var lastIndex: UInt8?
    private var nextIndex: UInt8 = 0
    public init() {}
    public mutating func reset() { buffer.removeAll(keepingCapacity:true); lastIndex=nil; nextIndex=0 }
    public static func encode(_ bytes: Data, maximumWriteLength: Int) throws -> [Data] {
        guard !bytes.isEmpty, bytes.count <= maximumMessageLength, maximumWriteLength >= 2 else {
            throw ProtocolError.invalidPayload
        }
        let chunk=min(maximumWriteLength,512)-1
        let count=(bytes.count + chunk-1)/chunk
        guard count <= 16 else { throw ProtocolError.invalidPayload }
        let payload=Array(bytes)
        return (0..<count).map { index in
            Data([UInt8((count-1) << 4 | index)] + payload[(index*chunk)..<min((index+1)*chunk,payload.count)])
        }
    }
    public mutating func feed(_ value: Data) -> Data? {
        guard (2...512).contains(value.count), let header=value.first else { reset(); return nil }
        let last=header >> 4, index=header & 0x0F
        guard index <= last else { reset(); return nil }
        if index == 0 { reset(); lastIndex=last }
        guard lastIndex == last, index == nextIndex,
              buffer.count + value.count-1 <= Self.maximumMessageLength else { reset(); return nil }
        buffer.append(contentsOf:value.dropFirst())
        if index == last { let result=Data(buffer); reset(); return result }
        nextIndex=index+1
        return nil
    }
}

public enum BoseProfile: String, CaseIterable, Sendable {
    case qc45, ultraHeadphones2, ultraEarbuds2
    public static let bmapServiceUUID = "00000000-DECA-FADE-DECA-DEAFDECACAFF"
    public static let bleServiceUUID = "0000FEBE-0000-1000-8000-00805F9B34FB"
    public static let bleSecureCharacteristicUUID = "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8"
    public var modelID: String {
        switch self {
        case .qc45: return "bose:qc45"
        case .ultraHeadphones2: return "bose:qc-ultra-headphones-2"
        case .ultraEarbuds2: return "bose:qc-ultra-earbuds-2"
        }
    }
    /// Catalog/Modalias identity, not a fabricated BMAP ProductInfo response.
    public var productID: UInt16 {
        switch self { case .qc45: return 0x4039; case .ultraHeadphones2: return 0x4082; case .ultraEarbuds2: return 0x4062 }
    }
    public var prefersBLE: Bool { self == .ultraEarbuds2 }
    public var rfcommServiceUUIDs: [String] { [Self.bmapServiceUUID] }
    public var maximumModeCount: Int { self == .qc45 ? 4 : 11 }
    public var modeStatusLength: Int { self == .qc45 ? 47 : 48 }
    public var hasLiveCNC: Bool { self != .qc45 }
    public func isExistingMode(_ mode: BoseModeConfig) -> Bool {
        mode.configured || (!mode.editable && Int(mode.index) < (self == .qc45 ? 2 : 4))
    }
    public static func forModelID(_ id: String) -> BoseProfile? { allCases.first { $0.modelID == id } }
    public static func named(_ name: String) -> BoseProfile? {
        let name=name.lowercased().filter { $0.isLetter || $0.isNumber }
        let bare=name.hasPrefix("bose") ? String(name.dropFirst(4)) : name
        switch bare {
        case "qc45", "quietcomfort45": return .qc45
        case "qcultraheadphones2ndgen", "qcultraheadphones2ndgeneration", "qcultraheadphones2", "quietcomfortultraheadphones2", "quietcomfortultraheadphones2ndgen", "quietcomfortultraheadphones2ndgeneration": return .ultraHeadphones2
        case "qcultraearbuds2ndgen", "qcultraearbuds2ndgeneration", "qcultraearbuds2", "quietcomfortultraearbuds2", "quietcomfortultraearbuds2ndgen", "quietcomfortultraearbuds2ndgeneration": return .ultraEarbuds2
        default: return nil
        }
    }
}

/// Unknown location/charging remains unknown. In particular IDs 1 and 2 are
/// deliberately not mapped to left/right: fixed upstreams contradict each other.
public struct BoseBatteryComponent: Equatable, Sendable {
    public let id: UInt8
    public let percent: Int?
    public let reserved: [UInt8]
    public let updatedAt: Date
    public var charging: Bool? { nil }
}

public struct BoseCNCState: Equatable, Sendable {
    /// Bose's inverted scale: 0=max cancellation, 10=most ambient.
    public let level: UInt8
    public let maximum: UInt8
    public let raw: [UInt8]
}

public struct BoseModeConfig: Equatable, Sendable {
    public let index: UInt8
    public let prompt: UInt16
    public let name: String
    public let editable: Bool
    public let configured: Bool
    public let cnc: UInt8
    public let autoCNC: UInt8
    public let spatial: UInt8
    public let wind: UInt8
    public let ancToggle: UInt8?
    public let raw: [UInt8]
}

public struct BoseAudioSettings: Equatable, Sendable {
    public let raw: [UInt8]
    public var cnc: UInt8 { raw[0] }
    public var autoCNC: UInt8 { raw[1] }
    public var spatial: UInt8 { raw[2] }
    public var wind: UInt8 { raw[3] }
    public var ancToggle: UInt8 { raw[4] }
    /// Keep all other live settings. Unknown values and enabled autoCNC are not
    /// silently rewritten; the latter is rejected by the documented firmware.
    public func settingCNC(_ level: UInt8) throws -> [UInt8] {
        guard level <= 10, autoCNC == 0, spatial <= 2, wind == 0, ancToggle == 1 else {
            throw ProtocolError.unsupported
        }
        var result=raw; result[0]=level; return result
    }
}

public enum BosePayload {
    public static func battery(_ bytes: [UInt8], at date: Date = Date()) -> [BoseBatteryComponent]? {
        guard !bytes.isEmpty, bytes.count <= 32, bytes.count % 4 == 0 else { return nil }
        var seen=Set<UInt8>(), result: [BoseBatteryComponent]=[]
        for offset in stride(from:0,to:bytes.count,by:4) {
            let id=bytes[offset+3], value=bytes[offset]
            guard seen.insert(id).inserted else { return nil }
            result.append(BoseBatteryComponent(id:id,percent:value <= 100 ? Int(value) : nil,
                                               reserved:Array(bytes[(offset+1)...(offset+2)]),updatedAt:date))
        }
        return result
    }
    public static func cnc(_ bytes: [UInt8]) -> BoseCNCState? {
        guard bytes.count == 3, (1...11).contains(bytes[0]), bytes[1] < bytes[0] else { return nil }
        return BoseCNCState(level:bytes[1],maximum:bytes[0]-1,raw:bytes)
    }
    public static func modeCount(_ bytes: [UInt8], profile: BoseProfile) -> Int? {
        // Favorites GET [31.8]: count + 16-bit mask. Acknowledgement and
        // truncated/unrecognised layouts never establish a mode capability.
        guard bytes.count == 3, (2...profile.maximumModeCount).contains(Int(bytes[0])) else { return nil }
        let count=Int(bytes[0]), mask=UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        guard mask >> count == 0 else { return nil }
        return count
    }
    public static func mode(_ bytes: [UInt8], profile: BoseProfile) -> BoseModeConfig? {
        guard bytes.count == profile.modeStatusLength,
              Int(bytes[0]) < profile.maximumModeCount, bytes[3] <= 1, bytes[4] <= 1,
              bytes[42] <= 10 else { return nil }
        let rawName=bytes[6..<38].prefix { $0 != 0 }
        guard let name=String(bytes:rawName,encoding:.utf8) else { return nil }
        return BoseModeConfig(index:bytes[0],prompt:UInt16(bytes[1]) << 8 | UInt16(bytes[2]),name:name,
                              editable:bytes[3] == 1,configured:bytes[4] == 1,cnc:bytes[42],autoCNC:bytes[43],
                              spatial:bytes[44],wind:bytes[profile == .qc45 ? 46 : 45],
                              ancToggle:profile == .qc45 ? nil : bytes[47],raw:bytes)
    }
    public static func audioSettings(_ bytes: [UInt8]) -> BoseAudioSettings? {
        guard bytes.count == 5, bytes[0] <= 10 else { return nil }
        return BoseAudioSettings(raw:bytes)
    }
    public static func qc45CNCWrite(_ mode: BoseModeConfig, level: UInt8) throws -> [UInt8] {
        guard mode.raw.count == 47, (2...3).contains(mode.index), mode.editable, mode.configured,
              level <= 10, mode.autoCNC == 0, mode.spatial == 0, mode.wind == 0 else {
            // Wind block masks/resets CNC on QC45; do not disable a different
            // setting or create/switch a user profile behind the caller's back.
            throw ProtocolError.unsupported
        }
        return Array(mode.raw[0..<3]) + Array(mode.raw[6..<38]) + [level,mode.autoCNC,mode.spatial,mode.wind]
    }
    public static func noise(index: UInt8?, modes: [UInt8:BoseModeConfig]) -> NoiseMode? {
        guard let index, let mode=modes[index], !mode.editable else { return nil }
        if index == 0, mode.prompt == 1 { return .anc }
        if index == 1, mode.prompt == 2 { return .transparency }
        return nil
    }
}
