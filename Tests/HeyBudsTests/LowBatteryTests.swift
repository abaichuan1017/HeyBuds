import Foundation
import Testing
import HeyBudsProtocol
@testable import HeyBuds

@Test func batteryAlertsAreIndependentPerDeviceAndSlot() {
    var alerts=LowBatteryAlerts()
    let reading=BatteryReading(percent:10)
    let first=alerts.notificationID(device:"fixture-a",slot:.left,reading:reading,threshold:20)
    let second=alerts.notificationID(device:"fixture-b",slot:.left,reading:reading,threshold:20)
    #expect(first != nil && second != nil && first != second)
    #expect(alerts.notificationID(device:"fixture-a",slot:.right,reading:reading,threshold:20) != nil)
    #expect(alerts.notificationID(device:"fixture-a",slot:.left,reading:reading,threshold:20) == nil)
    #expect(first?.contains("fixture-a") == false)
}

@Test func batteryAlertsRearmOnlyAfterRecoveryOrCharging() {
    var alerts=LowBatteryAlerts()
    func sample(_ percent:Int,_ charging:Bool=false) -> BatteryReading { BatteryReading(percent:percent,charging:charging) }
    let id=alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(10),threshold:20)
    #expect(id != nil)
    #expect(alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(25),threshold:20) == nil)
    #expect(alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(10),threshold:20) == nil)
    _=alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(26),threshold:20)
    #expect(alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(10),threshold:20) == id)
    _=alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(10,true),threshold:20)
    #expect(alerts.notificationID(device:"fixture-a",slot:.left,reading:sample(10),threshold:20) == id)
}

@Test func staleBatteryCannotTriggerOrRearmAnAlert() {
    var alerts=LowBatteryAlerts()
    let now=Date(),stale=now.addingTimeInterval(-121)
    #expect(alerts.notificationID(device:"fixture",slot:.left,reading:BatteryReading(percent:0,updatedAt:stale),threshold:20,now:now) == nil)
    #expect(alerts.notificationID(device:"fixture",slot:.left,reading:BatteryReading(percent:0,updatedAt:now),threshold:20,now:now) != nil)
    _=alerts.notificationID(device:"fixture",slot:.left,reading:BatteryReading(percent:90,updatedAt:stale),threshold:20,now:now)
    #expect(alerts.notificationID(device:"fixture",slot:.left,reading:BatteryReading(percent:0,updatedAt:now),threshold:20,now:now) == nil)
}
