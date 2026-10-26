// GPL-3.0-or-later. Independent implementation of the bounded protocol facts
// attributed in docs/licenses/Nothing.md. No upstream application code copied.
import Foundation

public struct NothingFrame: Equatable, Sendable {
    public let command: UInt16
    public let sequence: UInt8
    public let payload: [UInt8]
    public init(command: UInt16, sequence: UInt8, payload: [UInt8] = []) {
        self.command = command; self.sequence = sequence; self.payload = payload
    }
}

/// A nil responseCommand denotes a write: an ACK must never confirm the setting.
/// Issue a new read with a different sequence and validate its parsed state.
public struct NothingRequest: Equatable, Sendable {
    public let command: UInt16
    public let payload: [UInt8]
    public let responseCommand: UInt16?
    public init(command: UInt16, payload: [UInt8] = [], responseCommand: UInt16? = nil) {
        self.command = command; self.payload = payload; self.responseCommand = responseCommand
    }
    public func frame(sequence: UInt8) -> NothingFrame {
        NothingFrame(command: command, sequence: sequence, payload: payload)
    }
    public func matches(_ frame: NothingFrame, sequence: UInt8) -> Bool {
        responseCommand == frame.command && frame.sequence == sequence
    }
}

public enum NothingTransport: Sendable { case rfcomm }
public enum NothingCRCRegion: Sendable { case headerAndPayload, payload }

/// Only these exact, independently selected RFCOMM profiles are supported.
/// Name matching selects a candidate; identityRead must still agree before use.
public struct NothingProfile: Equatable, Sendable, CaseIterable {
    private enum Model: CaseIterable, Sendable { case earA, headphone1, cmfBuds2, cmfBudsPro2 }
    private let model: Model
    private init(_ model: Model) { self.model = model }
    public static let earA = Self(.earA)
    public static let headphone1 = Self(.headphone1)
    public static let cmfBuds2 = Self(.cmfBuds2)
    public static let cmfBudsPro2 = Self(.cmfBudsPro2)
    public static let allCases: [Self] = [.earA, .headphone1, .cmfBuds2, .cmfBudsPro2]

    public static let service = "AEAC4A03-DFF5-498F-843A-34487CF133EB"
    public var service: String { Self.service }
    public var serviceUUID: String { Self.service }
    public var transport: NothingTransport { .rfcomm }
    // No BLE route or characteristic discovery fallback is implemented.
    public var writeUUID: String? { nil }
    public var notifyUUID: String? { nil }
    public var singleBattery: Bool { model == .headphone1 }
    public var modelID: String {
        switch model {
        case .earA: return "nothing:ear-a"
        case .headphone1: return "nothing:headphone-1"
        case .cmfBuds2: return "nothing:cmf-buds-2"
        case .cmfBudsPro2: return "nothing:cmf-buds-pro-2"
        }
    }
    public var modelCode: String {
        switch model {
        case .earA: return "B162"
        case .headphone1: return "B170"
        case .cmfBuds2: return "B179"
        case .cmfBudsPro2: return "B172"
        }
    }
    public var aliases: [String] {
        switch model {
        case .earA: return ["Nothing Ear (a)", "Nothing Ear(a)", "Nothing Ear a", "Ear (a)"]
        case .headphone1: return ["Nothing Headphone (1)", "Nothing Headphone(1)", "Nothing Headphone 1", "Headphone (1)"]
        case .cmfBuds2: return ["CMF Buds 2", "CMF Buds2"]
        case .cmfBudsPro2: return ["CMF Buds Pro 2", "CMF Buds Pro2"]
        }
    }
    public static func named(_ name: String) -> Self? { matching(name: name) }
    public static func matching(name: String) -> Self? {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.aliases.contains { $0.lowercased() == candidate } }
    }

    /// Fixed receive policy, never a trial of both CRC regions. B170's full-frame
    /// policy is source-level evidence only; it must be checked on real hardware.
    public var receiveCRC: NothingCRCRegion {
        model == .cmfBudsPro2 ? .payload : .headerAndPayload
    }
    public var identityRead: NothingRequest {
        model == .cmfBudsPro2
            ? NothingRequest(command: 0xC01C, responseCommand: 0x401C)
            : NothingRequest(command: 0xC006, responseCommand: 0x4006)
    }
    public var firmwareRead: NothingRequest { NothingRequest(command: 0xC042, responseCommand: 0x4042) }
    public var batteryRead: NothingRequest { NothingRequest(command: 0xC007, responseCommand: 0x4007) }
    public var noiseRead: NothingRequest {
        NothingRequest(command: 0xC01E, payload: model == .cmfBudsPro2 ? [3] : [], responseCommand: 0x401E)
    }
    public var eqRead: NothingRequest {
        genrePresets ? NothingRequest(command: 0xC050, responseCommand: 0x4050)
                     : NothingRequest(command: 0xC01F, responseCommand: 0x401F)
    }
    public var advancedEQRead: NothingRequest? {
        model == .headphone1 ? NothingRequest(command: 0xC04C, responseCommand: 0x404C) : nil
    }
    private var genrePresets: Bool { model == .cmfBuds2 || model == .cmfBudsPro2 }
    public var presetIDs: [UInt8] { genrePresets ? [0, 1, 2, 3, 4, 5] : [0, 1, 2, 3] }
    public func presetLabel(_ id: UInt8) -> String? {
        let labels = genrePresets
            ? ["Balanced", "Rock", "Electronic", "Pop", "Enhance Vocals", "Classical"]
            : ["Balanced", "Voice", "More Treble", "More Bass"]
        return Int(id) < labels.count ? labels[Int(id)] : nil
    }
    public func noiseWrite(_ mode: NoiseMode) -> NothingRequest? {
        let value: UInt8
        switch mode {
        case .anc: value = 1
        case .medium: value = 2
        case .light: value = 3
        case .adaptive: value = 4
        case .off: value = 5
        case .transparency: value = 7
        default: return nil
        }
        return NothingRequest(command: 0xF00F, payload: [1, value, 0])
    }
    /// B170 requires fresh Advanced EQ == false both before and after this write.
    /// B179 additionally requires allowsEQ(firmware:) before using this descriptor.
    public func eqWrite(_ id: UInt8) -> NothingRequest? {
        guard presetIDs.contains(id) else { return nil }
        return NothingRequest(command: genrePresets ? 0xF01D : 0xF010, payload: [id, 0])
    }

    /// A complete battery report replaces the previous report. Missing and
    /// unavailable components are omitted; an actual 0% remains a reading.
    public func parseBattery(_ payload: [UInt8], updatedAt: Date = Date()) -> [BatterySlot: BatteryReading]? {
        func reading(_ raw: UInt8) -> BatteryReading? {
            let percent = Int(raw & 0x7F)
            return percent <= 100 ? BatteryReading(percent: percent, charging: raw & 0x80 != 0, updatedAt: updatedAt) : nil
        }
        if singleBattery {
            // Swift fixture [0,0,value]; RFCOMM profile [count=1,id=6,value].
            guard payload.count == 3,
                  (payload[0] == 0 && payload[1] == 0) || (payload[0] == 1 && payload[1] == 6) else { return nil }
            return reading(payload[2]).map { [.left: $0] } ?? [:]
        }
        guard let count = payload.first, count <= 3, payload.count == 1 + Int(count) * 2 else { return nil }
        var result: [BatterySlot: BatteryReading] = [:]
        var seen = Set<UInt8>()
        for offset in stride(from: 1, to: payload.count, by: 2) {
            let id = payload[offset], slot: BatterySlot
            guard seen.insert(id).inserted else { return nil }
            // B172's BLE fixture uses case ID 4, whereas the RFCOMM
            // reference names ID 5. Its actual capture contains only buds.
            // Preserve verified bud readings without guessing a case mapping.
            if model == .cmfBudsPro2, id == 4 || id == 5 { continue }
            switch id {
            case 2: slot = .left
            case 3: slot = .right
            case 4: slot = .enclosure
            default: return nil
            }
            result[slot] = reading(payload[offset + 1])
        }
        return result
    }

    public func parseNoise(_ payload: [UInt8]) -> NoiseMode? {
        let value: UInt8
        if payload.count == 2, model != .cmfBudsPro2 {
            guard payload[0] == 0 else { return nil }
            value = payload[1]
        } else {
            // Groups are (kind,value,reserved): kind 1 is mode, 2 is ANC level.
            // B172 capture places kind 2 first; using payload[1] is incorrect.
            // B170 currently has only compact status evidence.
            guard model != .headphone1 else { return nil }
            guard payload.count == 3 || payload.count == 6 else { return nil }
            var mode: UInt8?, seen = Set<UInt8>()
            for offset in stride(from: 0, to: payload.count, by: 3) {
                let kind = payload[offset], setting = payload[offset + 1]
                guard payload[offset + 2] == 0, seen.insert(kind).inserted else { return nil }
                switch kind {
                case 1: mode = setting
                case 2: guard (1...4).contains(setting) else { return nil }
                default: return nil
                }
            }
            guard let mode else { return nil }
            value = mode
        }
        switch value {
        case 1: return .anc
        case 2: return .medium
        case 3: return .light
        case 4: return .adaptive
        case 5: return .off
        case 7: return .transparency
        default: return nil
        }
    }
    public func parseEQ(_ payload: [UInt8]) -> UInt8? {
        // All four model fixtures use one byte. Do not import the upstream
        // generic parser's unverified "second byte when longer" fallback.
        guard payload.count == 1 else { return nil }
        let value = payload[0]
        return presetIDs.contains(value) ? value : nil
    }
    public func parseAdvancedEQ(_ payload: [UInt8]) -> Bool? {
        guard advancedEQRead != nil, payload.count == 1, payload[0] <= 1 else { return nil }
        return payload[0] == 1
    }
    public func parseFirmware(_ payload: [UInt8]) -> String? {
        guard !payload.isEmpty, payload.count <= 32 else { return nil }
        let bytes = payload.prefix { $0 != 0 }
        guard payload.dropFirst(bytes.count).allSatisfy({ $0 == 0 }),
              let version = String(bytes: bytes, encoding: .ascii), Self.versionParts(version) != nil else { return nil }
        return version
    }
    private static func versionParts(_ version: String) -> [UInt16]? {
        guard version.utf8.count <= 31 else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        var result: [UInt16] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.count <= 5,
                  part.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(part) else { return nil }
            result.append(value)
        }
        return result
    }
    public func allowsEQ(firmware: String?) -> Bool {
        guard model == .cmfBuds2 else { return true }
        guard let firmware, let parts = Self.versionParts(firmware), parts.count == 4 else { return false }
        return !parts.lexicographicallyPrecedes([1, 0, 1, 50])
    }
    public func firmwareAllowsControl(_ firmware: String?) -> Bool { allowsEQ(firmware: firmware) }

    /// Discards serial/address fields immediately; no raw identity is retained
    /// or returned. Conflicting/unknown SKU entries fail closed, never use a name.
    public func identityCode(_ payload: [UInt8]) -> String? {
        guard !payload.isEmpty, payload.count <= 1024 else { return nil }
        if model == .cmfBudsPro2 {
            let bytes = payload.prefix { $0 != 0 }
            guard bytes.count == 4, payload.dropFirst(4).allSatisfy({ $0 == 0 }),
                  let code = String(bytes: bytes, encoding: .ascii), Self.allCases.contains(where: { $0.modelCode == code }) else { return nil }
            return code
        }
        // Config text may have a one-byte record-count prefix (B179 capture).
        var bytes = payload[...]
        if let first = bytes.first, (1...16).contains(first), first != 10 && first != 13 { bytes = bytes.dropFirst() }
        if bytes.last == 0 { bytes = bytes.dropLast() }
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { return nil }
        var code: String?
        for line in bytes.split(separator: 10, omittingEmptySubsequences: true) {
            let trimmed = line.last == 13 ? line.dropLast() : line[...]
            let fields = trimmed.split(separator: 44, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty,
                  fields[0].allSatisfy({ (48...57).contains($0) }), fields[1].allSatisfy({ (48...57).contains($0) }) else { return nil }
            guard fields[1].elementsEqual([52]) else { continue } // type 4 = serial/SKU
            guard let found = Self.codeFromSKU(fields[2]), code == nil || code == found else { return nil }
            code = found
        }
        return code
    }
    private static func codeFromSKU(_ bytes: ArraySlice<UInt8>) -> String? {
        guard (8...64).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        let prefix = bytes.prefix(2)
        if prefix.elementsEqual([77, 51]) { // M3, three-digit SKU at offset 3
            let sku = Array(bytes.dropFirst(3).prefix(3))
            return sku == [54, 48, 51] || sku == [54, 48, 54] ? "B170" : nil
        }
        guard prefix.elementsEqual([83, 72]) || prefix.elementsEqual([49, 51]) else { return nil }
        let skuBytes = Array(bytes.dropFirst(4).prefix(2))
        guard skuBytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let sku = Int(skuBytes[0] - 48) * 10 + Int(skuBytes[1] - 48)
        switch sku {
        case 63...68, 71...73: return "B162"
        case 76...83: return "B172"
        case 98, 99: return "B179"
        default: return nil
        }
    }

    fileprivate func accepts(_ command: UInt16) -> Bool {
        let reads = [identityRead, firmwareRead, batteryRead, noiseRead, eqRead] + (advancedEQRead.map { [$0] } ?? [])
        return reads.contains { $0.responseCommand == command }
            || [UInt16(0xE001), 0xE003, 0x700F, genrePresets ? 0x701D : 0x7010].contains(command)
    }
    fileprivate func crcFreeEvent(_ command: UInt16, sequence: UInt8) -> Bool {
        model == .cmfBudsPro2 && sequence == 0 && (command == 0xE001 || command == 0xE003)
    }
}

/// Streaming receiver with at most maximumPayloadLength + 10 retained bytes.
/// Partial frames wait for more bytes; reset at a session boundary/timeout.
/// Does not guess a different transport, CRC region, or absent checksum.
public struct NothingFrameCodec {
    public static let maximumPayloadLength = 1024
    public let maximumPayloadLength: Int
    public let profile: NothingProfile
    private var buffer: [UInt8] = []
    public var bufferedByteCount: Int { buffer.count }
    public init(profile: NothingProfile, maximumPayloadLength: Int = 1024) {
        self.profile = profile
        self.maximumPayloadLength = min(max(0, maximumPayloadLength), Self.maximumPayloadLength)
    }
    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        // Reflected CRC-16, polynomial A001, initial FFFF, no final XOR.
        var value: UInt16 = 0xFFFF
        for byte in bytes {
            value ^= UInt16(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xA001 }
        }
        return value
    }
    public static func encode(_ frame: NothingFrame) throws -> Data {
        guard frame.payload.count <= maximumPayloadLength else { throw ProtocolError.invalidPayload }
        let length = UInt16(frame.payload.count)
        var bytes: [UInt8] = [0x55, 0x60, 1, UInt8(truncatingIfNeeded: frame.command), UInt8(frame.command >> 8),
                              UInt8(truncatingIfNeeded: length), UInt8(length >> 8), frame.sequence]
        bytes += frame.payload
        let crc = checksum(bytes)
        bytes += [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
        return Data(bytes)
    }
    public func encode(_ frame: NothingFrame) throws -> Data {
        guard frame.payload.count <= maximumPayloadLength else { throw ProtocolError.invalidPayload }
        return try Self.encode(frame)
    }
    public mutating func feed(_ data: Data) -> [NothingFrame] {
        var result: [NothingFrame] = []
        for byte in data {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == 0x55 else { buffer.removeFirst(); continue }
                guard buffer.count >= 8 else { break }
                let command = UInt16(buffer[3]) | UInt16(buffer[4]) << 8
                let length = Int(buffer[5]) | Int(buffer[6]) << 8
                let noCRC = buffer[1] == 0 && buffer[2] == 1
                    && profile.crcFreeEvent(command, sequence: buffer[7])
                guard length <= maximumPayloadLength, profile.accepts(command),
                      noCRC || (buffer[1] == 0x60 && buffer[2] == 1) else { buffer.removeFirst(); continue }
                let end = 8 + length, total = end + (noCRC ? 0 : 2)
                guard buffer.count >= total else { break }
                if !noCRC {
                    let start = profile.receiveCRC == .payload ? 8 : 0
                    let expected = UInt16(buffer[end]) | UInt16(buffer[end + 1]) << 8
                    guard Self.checksum(Array(buffer[start..<end])) == expected else { buffer.removeFirst(); continue }
                }
                result.append(NothingFrame(command: command, sequence: buffer[7], payload: Array(buffer[8..<end])))
                buffer.removeFirst(total)
            }
        }
        return result
    }
}
