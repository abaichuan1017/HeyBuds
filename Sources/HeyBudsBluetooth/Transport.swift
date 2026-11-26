import Foundation
import IOBluetooth
import CoreBluetooth
import HeyBudsProtocol

public enum TransportEvent { case data(Data), closed(String?) }
public enum TransportFailure: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let reason)=self { return reason }; return nil }
}
@MainActor public protocol EarbudTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    var label: String { get }
    /// The Bluetooth service selected for this connection, when known.
    var serviceUUID: String? { get }
    func open() async throws
    func send(_ bytes: Data) async throws
    func close()
}
public extension EarbudTransport {
    var serviceUUID: String? { nil }
}
public struct BluetoothAudioRoute: Equatable, Hashable, Sendable {
    public let uid:String
    public let objectID:UInt32
    public init(uid:String, objectID:UInt32) { self.uid=uid; self.objectID=objectID }
}
public struct DeviceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let audioConnected: Bool
    public let classicAddress: String?
    public let family: EarbudFamily?
    public let controlServiceUUID:String?
    public let protocolName:String
    public var systemAudioOnly:Bool
    public var audioRoute:BluetoothAudioRoute?
    public init(id: String, name: String, audioConnected: Bool, classicAddress: String?, family:EarbudFamily?=nil,controlServiceUUID:String?=nil,
                protocolName:String?=nil, systemAudioOnly:Bool=false, audioRoute:BluetoothAudioRoute?=nil) {
        self.id=id; self.name=name; self.audioConnected=audioConnected; self.classicAddress=classicAddress;self.family=family;self.controlServiceUUID=controlServiceUUID
        self.protocolName=protocolName ?? name; self.systemAudioOnly=systemAudioOnly; self.audioRoute=audioRoute
    }
    public func model(in catalog:ModelCatalog, override:String?=nil) -> DeviceModel? {
        guard !systemAudioOnly else { return nil }
        if family == .samsung {
            return SamsungProfile.named(protocolName,on:controlServiceUUID).flatMap { catalog.model(id:$0.modelID) }
        }
        return catalog.model(productID:nil,name:protocolName,override:override,matching:family)
    }
}
@MainActor public enum Discovery {
    public static let service = "0000079A-D102-11E1-9B23-00025B00A5A5"
    public static let write = "0100079A-D102-11E1-9B23-00025B00A5A5"
    public static let notify = "0200079A-D102-11E1-9B23-00025B00A5A5"
    public nonisolated static func uuid(_ string:String="0000079A-D102-11E1-9B23-00025B00A5A5") -> IOBluetoothSDPUUID {
        var value=UUID(uuidString:string)!.uuid
        let bytes=withUnsafeBytes(of:&value) { Array($0) }
        return IOBluetoothSDPUUID(bytes:bytes,length:16)
    }
    nonisolated static func candidate(name:String,address:String,connected:Bool,catalog:ModelCatalog,
                                      advertised:[EarbudFamily:[String]],samsungID:SamsungProfile.AdvertisedIdentity,
                                      isAudio:Bool,includingSystemAudio:Bool) -> DeviceCandidate? {
        let services=Set(advertised.keys)
        let hardwareSamsung = services.contains(.samsung) && samsungID != .absent
        let family=hardwareSamsung ? .samsung : catalog.routingFamily(name:name,services:services)
        var protocolName=name
        if hardwareSamsung, case .model(let profile)=samsungID { protocolName=profile.rawValue }
        let available=family.flatMap { advertised[$0] } ?? []
        let service=family?.serviceUUID(for:protocolName,among:available)
        var systemOnly = family == nil
        if family == .samsung {
            systemOnly = samsungID == .unknown || SamsungProfile.named(protocolName,on:service) == nil
        } else if let family, [.google,.bose,.nothing,.jbl,.sennheiser,.soundcore].contains(family) {
            systemOnly = catalog.model(productID:nil,name:protocolName,matching:family) == nil
        } else if available.isEmpty, isAudio, catalog.model(productID:nil,name:protocolName,matching:family) == nil {
            systemOnly = true
        }
        guard !systemOnly || (includingSystemAudio && (isAudio || !services.isEmpty)) else { return nil }
        return DeviceCandidate(id:address,name:name,audioConnected:connected,classicAddress:address,
                               family:systemOnly ? nil : family,controlServiceUUID:systemOnly ? nil : service,
                               protocolName:protocolName,systemAudioOnly:systemOnly)
    }
    public static func paired(catalog:ModelCatalog?=nil,includingSystemAudio:Bool=false) async -> [DeviceCandidate] {
        // IOBluetooth may wait for its CoreBluetooth coordinator to initialize.
        // Keep that synchronous wait off the main actor so AppKit remains responsive.
        await Task.detached(priority:.utility) {
            guard let catalog=catalog ?? (try? ModelCatalog()) else { return [] }
            return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                let name=device.name ?? "Earbuds"
                guard let address=device.addressString else { return nil }
                var advertised:[EarbudFamily:[String]]=[:]
                for family in EarbudFamily.allCases where family != .huawei {
                    let matches=family.classicServiceUUIDs.filter { device.getServiceRecord(for:uuid($0)) != nil }
                    if !matches.isEmpty { advertised[family]=matches }
                }
                let samsungID = advertised[.samsung] == nil ? .absent : SamsungProfile.advertisedIdentity(serviceClasses:
                    (device.services as? [IOBluetoothSDPServiceRecord] ?? []).flatMap { record in
                        (record.getAttributeDataElement(1)?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []).compactMap {
                            $0.getUUIDValue()?.getWithLength(16).map { Data(referencing:$0) }
                        }
                    })
                let audio = includingSystemAudio && (
                    (device.deviceClassMajor == kBluetoothDeviceClassMajorAudio && [1,2,5,6,7,8,10,15].contains(Int(device.deviceClassMinor))) ||
                    [UInt16(0x110B),0x1108,0x111E].contains { device.getServiceRecord(for:IOBluetoothSDPUUID(uuid16:$0)) != nil })
                if device.deviceClassMajor == kBluetoothDeviceClassMajorPeripheral && !audio && advertised.isEmpty { return nil }
                return candidate(name:name,address:address,connected:device.isConnected(),catalog:catalog,advertised:advertised,
                                 samsungID:samsungID,isAudio:audio,includingSystemAudio:includingSystemAudio)
            }.sorted { $0.audioConnected == $1.audioConnected ? $0.name < $1.name : $0.audioConnected }
        }.value
    }
}
