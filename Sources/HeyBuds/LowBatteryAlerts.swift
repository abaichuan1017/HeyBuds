import Foundation
import HeyBudsProtocol

struct LowBatteryAlerts {
    private struct Key:Hashable { let device:String; let slot:BatterySlot }
    private var alerted:Set<Key>=[]
    private var identifiers:[Key:String]=[:]

    mutating func notificationID(device:String,slot:BatterySlot,reading:BatteryReading,threshold:Int,now:Date=Date()) -> String? {
        guard now.timeIntervalSince(reading.updatedAt) < 120 else { return nil }
        let key=Key(device:device,slot:slot)
        if reading.charging || reading.percent > threshold+5 {
            alerted.remove(key);return nil
        }
        guard reading.percent <= threshold,alerted.insert(key).inserted else { return nil }
        // Notification identifiers must not contain device addresses or names.
        let id=identifiers[key] ?? UUID().uuidString
        identifiers[key]=id
        return id
    }
}
