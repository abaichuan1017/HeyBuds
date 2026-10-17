import Foundation

/// Audio/Bluetooth presence is independent of the OPO control session.
struct ConnectionPresence {
    private(set) var connectedIDs:Set<String>=[]
    mutating func update(_ ids:Set<String>) -> Set<String> {
        let added=ids.subtracting(connectedIDs)
        connectedIDs=ids
        return added
    }
    static func showsStatusItem(background:Bool,hasConnection:Bool,explicitAccess:Bool) -> Bool {
        !background || hasConnection || explicitAccess
    }
    static func preferredID(connectedIDs:[String],selectedID:String?) -> String? {
        if let selectedID, connectedIDs.contains(selectedID) { return selectedID }
        return connectedIDs.first
    }
}
