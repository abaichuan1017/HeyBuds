import Foundation
import HeyBudsBluetooth

/// Audio/Bluetooth presence is independent of the OPO control session.
struct ConnectionPresence {
    private var previous:[DeviceCandidate]=[]
    mutating func update(_ devices:[DeviceCandidate]) -> (added:[DeviceCandidate],removed:[DeviceCandidate]) {
        let before=Set(previous.map(\.id)), after=Set(devices.map(\.id))
        let removed=previous.filter { !after.contains($0.id) }
        previous=devices
        return (devices.filter { !before.contains($0.id) },removed)
    }
    static func showsStatusItem(background:Bool,hasConnection:Bool,explicitAccess:Bool) -> Bool {
        !background || hasConnection || explicitAccess
    }
}
