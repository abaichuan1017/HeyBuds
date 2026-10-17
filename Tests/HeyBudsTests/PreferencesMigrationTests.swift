import Foundation
import Testing
@testable import HeyBuds

@Test func migrationPreservesRecognizedSettingsAndSkipsUnrelatedData() {
    let legacy:[String:Any]=["language":"en","appearance":"dark","backgroundMode":true,"connectionTips":false,"menuBattery":true,"autoReconnect":false,"notifyLow":true,"lowThreshold":15,"selectedDevice":"test-device","model.test-device":"vivo:112","unrelated":"private","accessToken":"must not copy"]
    let result=AppIdentity.migratedPreferences(current:[:],legacy:legacy)
    #expect(result["language"] as? String == "en")
    #expect(result["appearance"] as? String == "dark")
    #expect(result["autoReconnect"] as? Bool == false)
    #expect(result["lowThreshold"] as? Int == 15)
    #expect(result["model.test-device"] as? String == "vivo:112")
    #expect(result["unrelated"] == nil && result["accessToken"] == nil)
    #expect(result[AppIdentity.migrationKey] as? Bool == true)
}
@Test func migrationNeverOverwritesHeyBudsSettingsOrRepeats() {
    let first=AppIdentity.migratedPreferences(current:["language":"zh","lowThreshold":20],legacy:["language":"en","lowThreshold":10,"appearance":"dark"])
    #expect(first["language"] as? String == "zh" && first["lowThreshold"] as? Int == 20)
    let second=AppIdentity.migratedPreferences(current:first,legacy:["language":"en","appearance":"light","menuBattery":true])
    #expect(second["appearance"] as? String == "dark")
    #expect(second["menuBattery"] == nil)
}
@Test func migrationRejectsInvalidLegacySettingTypes() {
    let result=AppIdentity.migratedPreferences(current:[:],legacy:["language":["bad"],"lowThreshold":200,"backgroundMode":"true","model.test-device":[1,2,3]])
    #expect(result.count == 1)
    #expect(result[AppIdentity.migrationKey] as? Bool == true)
}
