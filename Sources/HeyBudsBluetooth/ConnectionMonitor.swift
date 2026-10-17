import Foundation
import IOBluetooth

/// Register after the first background paired-device query has initialized IOBluetooth.
@MainActor public final class BluetoothConnectionMonitor:NSObject {
    public var onChange:(() -> Void)?
    private var connection:IOBluetoothUserNotification?
    private var disconnections:[String:IOBluetoothUserNotification]=[:]
    public func watch(_ devices:[DeviceCandidate]) {
        if connection == nil {
            connection=IOBluetoothDevice.register(forConnectNotifications:self,selector:#selector(changed(_:device:)))
        }
        let wanted=Set(devices.filter(\.audioConnected).map(\.id))
        for id in Array(disconnections.keys) where !wanted.contains(id) {
            disconnections.removeValue(forKey:id)?.unregister()
        }
        for device in devices where device.audioConnected && disconnections[device.id] == nil {
            if let address=device.classicAddress {
                disconnections[device.id]=IOBluetoothDevice(addressString:address)?.register(forDisconnectNotification:self,selector:#selector(changed(_:device:)))
            }
        }
    }
    @objc nonisolated private func changed(_ notification:IOBluetoothUserNotification!,device:IOBluetoothDevice!) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    public func stop() {
        connection?.unregister(); connection=nil
        for notification in disconnections.values { notification.unregister() }
        disconnections.removeAll()
    }
}
