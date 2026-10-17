import Testing
@testable import HeyBuds

@Test func connectionRefreshesAndControlRetriesDoNotRepeatAnnouncements() {
    var presence=ConnectionPresence()
    #expect(presence.update([]).isEmpty)
    #expect(presence.update(["earbuds-a"]) == ["earbuds-a"])
    for _ in 0..<10 { #expect(presence.update(["earbuds-a"]).isEmpty) }
    #expect(presence.update([]).isEmpty)
    #expect(presence.update(["earbuds-a"]) == ["earbuds-a"])
}
@Test func secondDeviceAndDisconnectHaveSeparatePresence() {
    var presence=ConnectionPresence()
    _=presence.update(["earbuds-a"])
    #expect(presence.update(["earbuds-a","earbuds-b"]) == ["earbuds-b"])
    #expect(presence.update(["earbuds-b"]).isEmpty)
    #expect(presence.connectedIDs == ["earbuds-b"])
}
@Test func hiddenMenuItemCanAlwaysBeRevealedByExplicitAccess() {
    #expect(!ConnectionPresence.showsStatusItem(background:true,hasConnection:false,explicitAccess:false))
    #expect(ConnectionPresence.showsStatusItem(background:true,hasConnection:false,explicitAccess:true))
    #expect(ConnectionPresence.showsStatusItem(background:true,hasConnection:true,explicitAccess:false))
    #expect(ConnectionPresence.showsStatusItem(background:false,hasConnection:false,explicitAccess:false))
}
@Test func connectedDeviceIsPreferredOverDisconnectedSelection() {
    #expect(ConnectionPresence.preferredID(connectedIDs:["earbuds-b"],selectedID:"earbuds-a") == "earbuds-b")
    #expect(ConnectionPresence.preferredID(connectedIDs:["earbuds-b","earbuds-a"],selectedID:"earbuds-a") == "earbuds-a")
    #expect(ConnectionPresence.preferredID(connectedIDs:[],selectedID:"earbuds-a") == nil)
}
