// Brand routing and catalog semantics ported from OppoPodsManager (GPL-3.0-or-later).
import Foundation

public enum EarbudFamily: String, Codable, CaseIterable, Sendable {
    case oppo, vivo, huawei, xiaomi, edifier, sony, samsung, google, bose, nothing, soundcore, sennheiser, jbl
    public var allowsModelOverride:Bool { [.oppo,.vivo,.huawei,.xiaomi,.edifier].contains(self) }
    public func transportKinds(for name:String) -> [String] {
        if self == .xiaomi,let profile=XiaomiProfile.named(name) { return profile.transportKinds }
        if self == .jbl { return JBLProfile.named(name)?.usesBLE == true ? ["BLE"] : ["RFCOMM"] }
        if self == .oppo { return ["RFCOMM","BLE"] }
        if self == .bose,BoseProfile.named(name)?.prefersBLE == true { return ["BLE"] }
        return ["RFCOMM"]
    }
    public static func normalize(_ name:String) -> String { name.lowercased().replacingOccurrences(of:"+",with:"plus").filter { $0.isLetter || $0.isNumber } }
    public static func detect(_ name:String) -> EarbudFamily? {
        if XiaomiProfile.named(name) != nil { return .xiaomi }
        let n=normalize(name)
        if ["oppo","enco","oneplus","realme"].contains(where:n.contains) { return .oppo }
        if n.hasPrefix("vivotws") || n.hasPrefix("iqootws") || n == "vivoheadphones" || n == "iqooheadphones" { return .vivo }
        if ["huawei","freebuds","freeclip","freearc","freelace","eyewear"].contains(where:n.hasPrefix) { return .huawei }
        if ["xiaomi","redmi","mibuds","mitrue","flipbuds","miair","air2se","air2pro"].contains(where:n.contains) { return .xiaomi }
        if ["edifier","w820nb","w200bt","漫步者"].contains(where:n.contains) { return .edifier }
        if SonyProtocol.profile(name:name) != nil { return .sony }
        if SamsungProfile.named(name) != nil { return .samsung }
        if BoseProfile.named(name) != nil { return .bose }
        if NothingProfile.named(name) != nil { return .nothing }
        if SoundcoreProfile.named(name) != nil { return .soundcore }
        if SennheiserProfile.named(name) != nil { return .sennheiser }
        if JBLProfile.named(name) != nil { return .jbl }
        if ["honorearbuds2","honorearbuds2se","honorearbuds2lite","荣耀earbuds2","荣耀earbuds2se","荣耀earbuds2lite"].contains(n) { return .huawei }
        if ["Pixel Buds Pro","Pixel Buds Pro 2"].contains(where:{n == normalize($0) || n == normalize("Google "+$0)}) { return .google }
        return nil
    }
    public var classicServiceUUIDs:[String] {
        if self == .sony { return [SonyProtocol.serviceV2,SonyProtocol.serviceV1] }
        if self == .samsung { return [SamsungProfile.service,SamsungProfile.legacyService] }
        if self == .soundcore || self == .jbl { return [] } // SPP is not brand identity; JBL uses BLE or a model-bound RACE route.
        return serviceUUID.map { [$0] } ?? []
    }
    public func serviceUUID(for name:String) -> String? {
        if self == .xiaomi,let profile=XiaomiProfile.named(name),!profile.systemBatteryOnly { return profile.services.first }
        if self == .sony { return SonyProtocol.serviceUUID(for:name) ?? serviceUUID }
        if self == .samsung { return SamsungProfile.named(name)?.serviceUUID }
        return serviceUUID
    }
    public var serviceUUID:String? {
        switch self {
        case .oppo:return "0000079A-D102-11E1-9B23-00025B00A5A5"
        case .vivo:return "00000837-D102-11E1-9B23-00025B00A5A5"
        case .huawei:return "00001101-0000-1000-8000-00805F9B34FB"
        case .xiaomi:return "00001101-0000-1000-8000-008584D01810"
        case .edifier:return "EDF00000-EDFE-DFED-FEDF-EDFEDFEDFEDF"
        case .sony:return SonyProtocol.serviceV2
        case .samsung:return SamsungProfile.service
        case .google:return GoogleMaestro.service
        case .bose:return BoseProfile.bmapServiceUUID
        case .nothing:return NothingProfile.service
        case .soundcore:return SoundcoreProfile.service
        case .sennheiser:return SennheiserProfile.service
        case .jbl:return nil
        }
    }
}
extension DeviceModel {
    static func migrated(_ entry:JSONValue) -> DeviceModel? {
        guard let id=entry["id"].text, let name=entry["name"].text, let brand=entry["brand"].text else { return nil }
        let noise=entry["noise"].elements.compactMap { node -> NoiseOption? in
            guard let key=node["mode"].text, let mode=NoiseMode(rawValue:key) else { return nil }
            let bytes=node["bytes"].elements.compactMap { $0.int.flatMap(UInt8.init(exactly:)) }
            return bytes.isEmpty ? nil : NoiseOption(mode:mode,writeBytes:bytes)
        }
        let presets=entry["presets"].elements.compactMap { node -> EQPreset? in
            guard let id=node["id"].int.flatMap(UInt8.init(exactly:)),let zh=node["zh"].text,let en=node["en"].text else { return nil }
            return EQPreset(id:id,chinese:zh,english:en,minimumFirmware:nil)
        }
        return DeviceModel(raw:entry,id:id,name:name,brand:brand,aliases:entry["children"].elements.compactMap { $0["name"].text },noiseOptions:noise,presets:presets)
    }
    public static func readOnly(name:String,family:EarbudFamily) -> DeviceModel {
        DeviceModel(raw:.object(["protocolFamily":.string(family.rawValue)]),id:family.rawValue+":unknown",name:name,brand:family.rawValue,aliases:[],noiseOptions:[],presets:[])
    }
}
