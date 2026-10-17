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
    func open() async throws
    func send(_ bytes: Data) async throws
    func close()
}
public struct DeviceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let audioConnected: Bool
    public let classicAddress: String?
    public let family: EarbudFamily?
    public init(id: String, name: String, audioConnected: Bool, classicAddress: String?, family:EarbudFamily?=nil) {
        self.id=id; self.name=name; self.audioConnected=audioConnected; self.classicAddress=classicAddress;self.family=family
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
    public static func paired() async -> [DeviceCandidate] {
        // IOBluetooth may wait for its CoreBluetooth coordinator to initialize.
        // Keep that synchronous wait off the main actor so AppKit remains responsive.
        await Task.detached(priority:.utility) {
            let catalog=try? ModelCatalog()
            return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                let name=device.name ?? "Earbuds"
                guard let address=device.addressString else { return nil }
                let override=UserDefaults.standard.string(forKey:"model.\(address)")
                let family=catalog?.family(name:name,override:override) ?? EarbudFamily.allCases.first { family in
                    // Standard SPP alone does not identify Huawei.
                    family != .huawei && family.serviceUUID.map { device.getServiceRecord(for:uuid($0)) != nil } == true
                }
                guard let family else { return nil }
                return DeviceCandidate(id:address,name:name,audioConnected:device.isConnected(),classicAddress:address,family:family)
            }.sorted { $0.audioConnected == $1.audioConnected ? $0.name < $1.name : $0.audioConnected }
        }.value
    }
}
