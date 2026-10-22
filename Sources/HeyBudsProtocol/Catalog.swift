// Model semantics ported from OppoPodsManager, GPL-3.0-or-later.
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let d) = self { return d[key] ?? .null }; return .null }
    public var text: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .number(let n) = self, n.isFinite, n >= Double(Int.min), n < Double(Int.max) { return Int(n) }; return nil }
    public var elements: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    public var enabled: Bool { if case .bool(let b) = self { return b }; return (int ?? 0) > 0 }
}

public enum NoiseMode: String, CaseIterable, Codable, Sendable {
    case off, transparency, anc, smart, deep, medium, light, adaptive
    public var group: NoiseMode { [.smart,.deep,.medium,.light].contains(self) ? .anc : self }
    public static func from(type: Int) -> NoiseMode? {
        [1:.off,2:.transparency,3:.light,4:.deep,5:.anc,6:.smart,7:.smart,8:.medium,10:.adaptive][type]
    }
}
public struct NoiseOption: Identifiable, Equatable, Sendable {
    public let mode: NoiseMode
    public let writeBytes: [UInt8]
    public var payload: [UInt8] { [1,1] + writeBytes }
    public var id: NoiseMode { mode }
}
public struct EQPreset: Identifiable, Equatable, Sendable {
    public let id: UInt8
    public let chinese: String
    public let english: String
    public let minimumFirmware: Int?
    public func available(firmware:Int?) -> Bool { minimumFirmware.map { minimum in firmware.map { $0 >= minimum } ?? false } ?? true }
}
public struct FeatureDefinition: Identifiable, Equatable, Sendable {
    public let key: String
    public let switchID: UInt8
    public var id: String { key }
    public init(_ key: String, _ switchID: UInt8) { self.key = key; self.switchID = switchID }
}

public struct DeviceModel: Identifiable, Sendable {
    public let raw: JSONValue
    public let id: String
    public let name: String
    public let brand: String
    public let aliases: [String]
    public let noiseOptions: [NoiseOption]
    public let presets: [EQPreset]
    public var function: JSONValue { raw["function"] }
    public var family: EarbudFamily { EarbudFamily(rawValue:raw["protocolFamily"].text ?? "oppo") ?? .oppo }
    public var singleBattery: Bool { function["singleBattery"].enabled }
    public var customEQMinimum: Int8 { Int8(exactly:function["customEqMinimum"].int ?? -6) ?? -6 }
    public var customEQMaximum: Int8 { Int8(exactly:function["customEqMaximum"].int ?? 6) ?? 6 }
    public var isT500: Bool { id == "066452" }
    public var spatialModes: [UInt8] { function["spatialTypes"].elements.compactMap { $0.int.flatMap(UInt8.init(exactly:)) } }
    public var customEQFrequencies: [UInt16] {
        let f = function["customEqFrequency"].elements.compactMap { $0.int.flatMap(UInt16.init(exactly:)) }
        return f.isEmpty && function["customEqualizer"].enabled ? [62,250,1000,4000,8000,16000] : f
    }
    public var customEQMax: Int { function["customEqMax"].int ?? 3 }
    public var hasMultiDevice: Bool { function["multiDevicesConnect"].enabled || !function["multiConnectFunctions"].elements.isEmpty }
    public func hostOperationAvailable(_ functionType:String,firmware:Int?) -> Bool {
        let entries=function["multiConnectFunctions"].elements
        guard !entries.isEmpty else { return hasMultiDevice }
        guard let entry=entries.first(where:{$0["functionType"].text == functionType}) else { return false }
        let minimum=entry["minFirmVersion"].int ?? 0
        return minimum == 0 || firmware.map { $0 >= minimum } == true
    }
    public var gameTypes: [UInt8] { function["gameSoundList"].elements.compactMap { $0["type"].int.flatMap(UInt8.init(exactly:)) }.filter { $0 > 0 } }
    public var gameBlocksSpatial: Bool { function["gameSoundMutexes"].elements.contains { $0.int == 1 } }
    public var gameBlocksEQ: Bool { function["gameSoundMutexes"].elements.contains { $0.int == 2 } }
    public var supportsGame: Bool { function["gameMode"].enabled || !gameTypes.isEmpty || function["gameEqualizer"].enabled }
    public var hasSpatialSound: Bool { spatialModes.isEmpty && function["dolbyAtmos"].enabled }
    public var features: [FeatureDefinition] {
        let list: [(String,String,UInt8)] = [("wearDetection","wear",4),("vocalEnhance","voice",9),
            ("hearingEnhancement","hearing",0x0B),("multiDevicesConnect","dual",0x11),
            ("longPowerMode","longBattery",0x17),("spineHealth","posture",0x22)]
        var result = list.filter { function[$0.0].enabled }.map { FeatureDefinition($0.1,$0.2) }
        if hasSpatialSound { result.append(FeatureDefinition("spatialSound",0x1B)) }
        return result
    }
}

public struct ModelCatalog: Sendable {
    public let models: [DeviceModel]
    private let byID: [String: DeviceModel]
    private let byProductID: [String: DeviceModel]
    private let byName: [String: DeviceModel]
    private struct NameMatch: Sendable {
        let model: DeviceModel
        let name: String
        let aliases: [String]
        let tokens: Set<String>
    }
    private let fallbackNames: [NameMatch]
    public init() throws {
        let resourceBundle = Bundle.main.url(forResource:"HeyBuds_HeyBudsProtocol",withExtension:"bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let file = resourceBundle.url(forResource: "DeviceModels", withExtension: "json"),
              let zhFile = resourceBundle.url(forResource: "EqModeNames", withExtension: "json"),
              let enFile = resourceBundle.url(forResource: "EqModeNames.en", withExtension: "json") else { throw ProtocolError.invalidPayload }
        let decoder = JSONDecoder()
        let raw = try decoder.decode(JSONValue.self, from: Data(contentsOf: file))
        let zh = try decoder.decode(JSONValue.self, from: Data(contentsOf: zhFile))["mapping"]
        let en = try decoder.decode(JSONValue.self, from: Data(contentsOf: enFile))["mapping"]
        var imported = raw["whiteList"].elements.compactMap { entry -> DeviceModel? in
            guard let id = entry["id"].text, let name = entry["name"].text else { return nil }
            var noise: [NoiseOption] = []
            if id == "066452" {
                // MIT reference's T500 Pro captures, not the OPPO family's read/write mapping.
                let values:[(NoiseMode,UInt8)] = [(.off,1),(.transparency,2),(.smart,0x20),(.deep,8),(.medium,0x10),(.light,4)]
                noise = values.map { NoiseOption(mode:$0.0,writeBytes:[$0.1]) }
            } else {
                for parent in entry["function"]["noiseReductionMode"].elements {
                    guard let type = parent["modeType"].int, let mode = NoiseMode.from(type:type) else { continue }
                    let children = parent["childrenMode"].elements
                    let nodes = children.count > 1 ? children : [parent]
                    for node in nodes {
                        guard let index = node["protocolIndex"].int, (0...15).contains(index),
                              let kind = node["modeType"].int, let leaf = NoiseMode.from(type:kind) else { continue }
                        // Upstream catalog holds bit indices, not bytes to write.
                        var bits = [UInt8](repeating:0,count:1 + index/8)
                        bits[index/8] = 1 << UInt8(index%8)
                        if !noise.contains(where: { $0.mode == leaf }) { noise.append(NoiseOption(mode:leaf,writeBytes:bits)) }
                    }
                    if nodes.isEmpty, mode != .anc { continue }
                }
            }
            let eqNodes=["equalizerMode","equalizerModeCompat","equalizerModeByVersion"].flatMap { entry["function"][$0].elements }
            var eqSeen:Set<UInt8>=[]
            let presets = eqNodes.compactMap { item -> EQPreset? in
                guard let number = item["protocolIndex"].int, let wire = UInt8(exactly:number), let type = item["modeType"].int else { return nil }
                // Retain mobile version conditions in raw JSON; don't claim a source baseline newer than Melody 16.8.1.
                if let required=item["minAppVersion"].int, required > 16_008_001 { return nil }
                guard eqSeen.insert(wire).inserted else { return nil }
                return EQPreset(id:wire,chinese:zh[String(type)].text ?? "EQ \(wire)",english:en[String(type)].text ?? "EQ \(wire)",minimumFirmware:item["minFirmVersion"].int)
            }
            return DeviceModel(raw:entry,id:id,name:name,brand:entry["brand"].text ?? "OPPO",
                aliases:entry["children"].elements.compactMap { $0["name"].text },noiseOptions:noise,presets:presets)
        }
        guard let migratedFile=resourceBundle.url(forResource:"MigratedModels",withExtension:"json") else { throw ProtocolError.invalidPayload }
        let migrated=try decoder.decode(JSONValue.self,from:Data(contentsOf:migratedFile))
        for entry in migrated["models"].elements {
            guard let model=DeviceModel.migrated(entry) else { throw ProtocolError.invalidPayload }
            imported.append(model)
        }
        models=imported
        guard Set(models.map(\.id)).count == models.count else { throw ProtocolError.invalidPayload }
        byID=Dictionary(uniqueKeysWithValues:models.map { ($0.id,$0) })
        var products:[String:DeviceModel]=[:]
        var names:[String:DeviceModel]=[:]
        for model in models {
            if products[model.id.lowercased()] == nil { products[model.id.lowercased()]=model }
            for name in [model.name]+model.aliases {
                let key=EarbudFamily.normalize(name)
                if names[key] == nil { names[key]=model }
            }
        }
        byProductID=products; byName=names
        fallbackNames=models.sorted { $0.name.count > $1.name.count }.compactMap { model in
            guard [.vivo,.huawei,.apple,.edifier].contains(model.family) else { return nil }
            return NameMatch(model:model,name:EarbudFamily.normalize(model.name),
                aliases:model.aliases.map(EarbudFamily.normalize),tokens:Set(model.aliases.map { $0.lowercased() }))
        }
    }
    public func model(productID: String?, name: String, override: String? = nil) -> DeviceModel? {
        if let override, let model=byID[override] { return model }
        if let productID, let model=byProductID[productID.lowercased()] { return model }
        // Match longest names first: FreeBuds Pro must not capture Pro 2/3/4/5.
        let normalized=EarbudFamily.normalize(name)
        if let exact=byName[normalized] { return exact }
        let tokens=Set(name.lowercased().split(whereSeparator:{ !$0.isLetter && !$0.isNumber }).map(String.init))
        return fallbackNames.first { match in
            switch match.model.family {
            case .vivo:
                return !tokens.isDisjoint(with:match.tokens) || normalized.contains(match.name)
            case .huawei: return ([match.name]+match.aliases).contains(where:normalized.hasPrefix)
            case .apple,.edifier: return normalized.contains(match.name)
            default:return false
            }
        }?.model
    }
    public func family(name:String, override:String?=nil) -> EarbudFamily? {
        model(productID:nil,name:name,override:override)?.family ?? EarbudFamily.detect(name)
    }
}
