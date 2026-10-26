import Foundation

public enum BatterySlot: UInt8, CaseIterable, Codable, Sendable { case left = 1, right = 2, enclosure = 3 }
public struct BatteryReading: Equatable, Codable, Sendable {
    public var percent: Int
    public var charging: Bool
    public var updatedAt: Date
    public init(percent: Int, charging: Bool = false, updatedAt: Date = Date()) {
        self.percent = percent; self.charging = charging; self.updatedAt = updatedAt
    }
}
public struct CustomEQEntry: Equatable, Identifiable, Codable, Sendable {
    public var id: UInt8
    public var name: String
    public var selected: Bool
    public var minimum: Int8
    public var maximum: Int8
    public var frequencies: [UInt16]
    public var gains: [Int8]
    public init(id: UInt8 = 0, name: String, selected: Bool = false, minimum: Int8 = -6, maximum: Int8 = 6, frequencies: [UInt16], gains: [Int8]) {
        self.id=id; self.name=name; self.selected=selected; self.minimum=minimum; self.maximum=maximum; self.frequencies=frequencies; self.gains=gains
    }
}
public struct RemoteHost: Equatable, Identifiable, Sendable {
    /// Canonical address bytes, normalized from little-endian list/priority replies.
    /// Retained only in memory. Never export in diagnostics.
    public var address: [UInt8]
    public var name: String
    public var type: UInt8
    public var connection: UInt8
    public var flags: UInt8
    public var id: String { Data(address).base64EncodedString() }
    public var connected: Bool { connection == 2 }
    public var current: Bool { flags & 1 != 0 }
    public var audioActive: Bool { flags & 4 != 0 }
    public var preferred: Bool { flags & 2 != 0 }
}
public struct BassState: Equatable, Sendable {
    public var minimum: UInt8, maximum: UInt8, current: UInt8
}
public struct GestureEntry: Equatable, Identifiable, Sendable {
    public let side: UInt8, mode: UInt8, gesture: UInt8, action: UInt8
    public var id: String { "\(side)-\(mode)-\(gesture)" }
}
public struct DeviceState: Sendable {
    public var productID: String?
    public var firmware: String?
    public var firmwareRevision: Int?
    public var codec: String?
    public var batteries: [BatterySlot:BatteryReading] = [:]
    /// Some protocols identify components without an established left/right map.
    public var unassignedBatteries: [UInt8:BatteryReading] = [:]
    public var placement: [BatterySlot:UInt8] = [:]
    public var noise: NoiseMode?
    public var liveNoise: NoiseMode?
    public var sonyNoise: SonyNoiseState?
    public var samsungControls: SamsungControlState?
    public var eq: UInt8?
    public var spatial: UInt8?
    public var switches: [UInt8:Bool] = [:]
    public var customEQ: [CustomEQEntry] = []
    public var bass: BassState?
    public var gameSound: UInt8?
    public var hosts: [RemoteHost] = []
    public var automaticPriority: Bool?
    public var priorityAddress: [UInt8]?
    public var gestures: [GestureEntry] = []
    public var supportedCommands: Set<UInt16>?
    public var observedQueries: Set<UInt16> = []
    public init() {}

    /// Full responses and partial notifications both update only explicitly present slots.
    public mutating func applyBattery(_ payload: [UInt8], response: Bool, t500: Bool = false) {
        var p = payload
        if response { guard p.first == 0 else { return }; p.removeFirst() }
        guard let count = p.first else { return }
        if count == 4, p.count >= 7 {
            for (i, slot) in BatterySlot.allCases.enumerated() {
                let raw = p[1 + i*2]
                if raw <= 100 { batteries[slot] = BatteryReading(percent:Int(raw),charging:p[2+i*2] != 0) }
                else { batteries.removeValue(forKey:slot) }
            }
        } else if count <= 8, p.count >= 1 + Int(count)*2 {
            for i in 0..<Int(count) {
                guard let slot = BatterySlot(rawValue:p[1+i*2]) else { continue }
                let raw = p[2+i*2], value = raw & 0x7F
                if value <= 100 { batteries[slot] = BatteryReading(percent:Int(value),charging:!t500 && raw & 0x80 != 0) }
                else { batteries.removeValue(forKey:slot) }
            }
        }
    }

    public mutating func applyNoise(_ payload: [UInt8], t500: Bool, model:DeviceModel? = nil) {
        if t500 {
            guard payload.count >= 3, payload[0] == 1 else { return }
            noise = [UInt8(1):.off,2:.transparency,4:.light,8:.deep,0x10:.medium,0x20:.smart][payload[2]]
            return
        }
        var p = payload
        if p.first == 0 || p.first == 3 { p.removeFirst() }
        guard p.count >= 4, p[1] == 1 else { return }
        let code = UInt16(p[2]) | UInt16(p[3]) << 8
        let mode:NoiseMode?
        if let model, model.function["noiseReportModes"] != .null { mode=model.reportedNoise(mask:code) }
        else { mode = [UInt16(8):.off,2:.smart,0x80:.smart,0x40:.light,0x20:.medium,
                       0x10:.deep,0x100:.transparency,4:.transparency,0x800:.adaptive][code] }
        guard let mode else { return }
        if p[0] == 4 { noise = .smart; liveNoise = mode }
        else { noise = mode; liveNoise = nil }
    }

    public mutating func apply(_ frame: OPOFrame, t500: Bool = false, model:DeviceModel? = nil) {
        let p = frame.payload
        if frame.command & 0x8000 != 0 {
            guard validResponse(frame,t500:t500,model:model) else { return }
            observedQueries.insert(frame.command & ~0x8000)
        }
        switch frame.command {
        case 0x8100: supportedCommands = CapabilityBitmap.decode(p)
        case 0x8103:
            if p.count >= 4, p[0] == 0 { let raw = Int(p[1]) | Int(p[2]) << 8 | Int(p[3]) << 16
                let normalized = (0x100100...0x100102).contains(raw) ? 0x060414 : (0x100200...0x100202).contains(raw) ? 0x060814 : (0x108100...0x108102).contains(raw) ? 0x068414 : (0x108200...0x108202).contains(raw) ? 0x068814 : raw
                productID = String(format:"%06X",normalized) }
        case 0x8105:
            if p.count > 2, p[0] == 0, let text=String(bytes:p.dropFirst(2),encoding:.utf8)?.trimmingCharacters(in:.controlCharacters) {
                let parts=text.split(separator:",").map(String.init)
                if parts.count >= 3, parts.count % 3 == 0 {
                    var versions:[Int:Int]=[:]
                    for i in stride(from:0,to:parts.count,by:3) {
                        if let device=Int(parts[i]),let version=Int(parts[i+2]) { versions[device]=version }
                    }
                    firmware=versions.keys.sorted().compactMap { versions[$0].map(String.init) }.joined(separator:".")
                    firmwareRevision=versions.keys.sorted().first.flatMap { versions[$0] }
                } else { firmware=text; firmwareRevision=Int(text) }
            }
        case 0x8106: applyBattery(p,response:true,t500:t500)
        case 0x810C: applyNoise(p,t500:t500,model:model)
        case 0x810F: if p.count >= 2, p[0] == 0 { eq=p[1] }
        case 0x812A: if p.count >= 2, p[0] == 0 { spatial=p[1] }
        case 0x810D:
            if p.count >= 2, p[0] == 0, p.count >= 2 + Int(p[1])*2 {
                switches = Dictionary((0..<Int(p[1])).map { (p[2+$0*2],p[3+$0*2] != 0) },uniquingKeysWith: { _,new in new })
            }
        case 0x8109: applyPlacement(p,response:true,t500:t500)
        case 0x8122: if let entries = FeatureCodec.customEntries(p) { customEQ=entries }
        case 0x8124: if p.count >= 4, p[0] == 0, p[1] <= p[2], (p[1]...p[2]).contains(p[3]) { bass=BassState(minimum:p[1],maximum:p[2],current:p[3]) }
        case 0x812B: if p.count >= 2, p[0] == 0 { gameSound=p[1] }
        case 0x8112: if let value = FeatureCodec.remoteHosts(p) { hosts=value }
        case 0x8132:
            if let value=FeatureCodec.hostPriority(p) {
                automaticPriority=value.automatic
                priorityAddress=value.address
            }
        case 0x8108: if let value=FeatureCodec.gestures(p) { gestures=value }
        case 0x8114:
            if p.count >= 2, p[0] == 0 {
                let code: UInt8? = p.count == 2 ? p[1] : stride(from:2,to:p.count-1,by:2).first(where:{ p[$0+1] != 0 }).map { p[$0] }
                if let code { codec=[0:"SBC",1:"LDAC",2:"AAC",3:"LHDC",4:"LC3",5:"aptX",6:"aptX HD",7:"aptX Adaptive",8:"LHDC"][Int(code)] ?? "Codec \(code)" }
            }
        case 0x0204:
            guard let type=p.first else { return }
            let body=Array(p.dropFirst())
            switch type {
            case 1: applyBattery(body,response:false,t500:t500)
            case 2: applyPlacement(body,response:false,t500:t500)
            case 3: applyNoise(body,t500:t500,model:model)
            default: break
            }
        case 0x0504: if let v=p.last { eq=v }
        case 0x0510: if let v=p.last, v <= 2 { spatial=v }
        default: break
        }
    }
    private mutating func applyPlacement(_ payload: [UInt8], response: Bool, t500: Bool) {
        var p=payload
        if response { guard p.first == 0 else { return }; p.removeFirst() }
        guard let count=p.first, count <= 3, p.count >= 1+Int(count)*2 else { return }
        for i in 0..<Int(count) {
            if let slot=BatterySlot(rawValue:p[1+i*2]), slot != .enclosure { placement[slot]=p[2+i*2] }
        }
    }
    private func validResponse(_ frame:OPOFrame,t500:Bool,model:DeviceModel?) -> Bool {
        let p=frame.payload
        if frame.command == 0x8132 { return FeatureCodec.hostPriority(p) != nil }
        guard p.first == 0 else { return false }
        switch frame.command {
        case 0x8100:return CapabilityBitmap.decode(p) != nil
        case 0x8103:return p.count == 4
        case 0x8105:return p.count > 2
        case 0x8106:return p.count >= 2 && ((p[1] == 4 && p.count >= 8) || (p[1] > 0 && p[1] <= 8 && p.count >= 2+Int(p[1])*2))
        case 0x810C:
            var sample=DeviceState()
            sample.applyNoise(p,t500:t500,model:model)
            return sample.noise != nil
        case 0x810F,0x812B:return p.count >= 2
        case 0x812A:return p.count >= 2 && p[1] <= 2
        case 0x810D:
            guard p.count >= 2, p.count == 2+Int(p[1])*2 else { return false }
            let keys=(0..<Int(p[1])).map { p[2+$0*2] }
            return Set(keys).count == keys.count && (0..<Int(p[1])).allSatisfy { p[3+$0*2] <= 1 }
        case 0x8109:return p.count >= 4
        case 0x8122:return FeatureCodec.customEntries(p) != nil
        case 0x8124:return p.count >= 4 && p[1] <= p[2] && (p[1]...p[2]).contains(p[3])
        case 0x8112:return FeatureCodec.remoteHosts(p) != nil
        case 0x8108:return FeatureCodec.gestures(p) != nil
        case 0x8114:return p.count >= 2
        default:return false
        }
    }
}
