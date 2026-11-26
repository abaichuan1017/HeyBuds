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
public struct DeviceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let audioConnected: Bool
    public let classicAddress: String?
    public let family: EarbudFamily?
    public let controlServiceUUID:String?
    public init(id: String, name: String, audioConnected: Bool, classicAddress: String?, family:EarbudFamily?=nil,controlServiceUUID:String?=nil) {
        self.id=id; self.name=name; self.audioConnected=audioConnected; self.classicAddress=classicAddress;self.family=family;self.controlServiceUUID=controlServiceUUID
    }
    public func model(in catalog:ModelCatalog, override:String?=nil) -> DeviceModel? {
        if family == .samsung {
            return SamsungProfile.named(name,on:controlServiceUUID).flatMap { catalog.model(id:$0.modelID) }
        }
        return catalog.model(productID:nil,name:name,override:override,matching:family)
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
    public static func paired(catalog:ModelCatalog?=nil) async -> [DeviceCandidate] {
        // IOBluetooth may wait for its CoreBluetooth coordinator to initialize.
        // Keep that synchronous wait off the main actor so AppKit remains responsive.
        await Task.detached(priority:.utility) {
            let catalog=catalog ?? (try? ModelCatalog())
            return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                let name=device.name ?? "Earbuds"
                guard let address=device.addressString else { return nil }
                let services=Set(EarbudFamily.allCases.filter { family in
                    family != .huawei && family.classicServiceUUIDs.contains { device.getServiceRecord(for:uuid($0)) != nil }
                })
                let family=catalog?.routingFamily(name:name,services:services)
                guard let family else { return nil }
                let available=family.classicServiceUUIDs.filter { device.getServiceRecord(for:uuid($0)) != nil }
                let service=family.serviceUUID(for:name,among:available)
                return DeviceCandidate(id:address,name:name,audioConnected:device.isConnected(),classicAddress:address,family:family,controlServiceUUID:service)
            }.sorted { $0.audioConnected == $1.audioConnected ? $0.name < $1.name : $0.audioConnected }
        }.value
    }
}
