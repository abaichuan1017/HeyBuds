// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreFoundation

public struct XiaomiSystemBattery:Sendable {
    public let batteries:[BatterySlot:BatteryReading]
    public let aggregate:Bool
    public let firmware:String?
    public init(batteries:[BatterySlot:BatteryReading],aggregate:Bool,firmware:String?=nil) {
        self.batteries=batteries;self.aggregate=aggregate;self.firmware=firmware
    }
    /// Consume only the exact connected device's system-reported values. Paired
    /// and historical entries, similarly named devices and invalid levels are ignored.
    public static func parse(_ data:Data,address:String) -> Self? {
        func normalized(_ address:String) -> String { address.lowercased().filter { $0.isHexDigit } }
        let key=normalized(address)
        guard key.count == 12,data.count <= 2_000_000,
              let root=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let controllers=root["SPBluetoothDataType"] as? [[String:Any]] else { return nil }
        var matches:[[String:Any]]=[]
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String:Any]] ?? [] {
                for info in entry.values {
                    guard let fields=info as? [String:Any],let raw=fields["device_address"] as? String,
                          normalized(raw) == key else { continue }
                    matches.append(fields)
                }
            }
        }
        guard matches.count == 1,let fields=matches.first else { return nil }
        func percent(_ name:String) -> BatteryReading? {
            let value:Int?
            if let text=fields[name] as? String {
                var digits=text.trimmingCharacters(in:.whitespacesAndNewlines)
                if digits.hasSuffix("%") { digits.removeLast() }
                value=digits.allSatisfy(\.isNumber) ? Int(digits) : nil
            } else if let number=fields[name] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
                      (0...100).contains(number.doubleValue),number.doubleValue.rounded(.towardZero) == number.doubleValue {
                value=number.intValue
            } else { value=nil }
            guard let value,(0...100).contains(value) else { return nil }
            return BatteryReading(percent:value)
        }
        var batteries:[BatterySlot:BatteryReading]=[:]
        for (name,slot) in [("device_batteryLevelLeft",BatterySlot.left),("device_batteryLevelRight",.right),("device_batteryLevelCase",.enclosure)] {
            if let value=percent(name) { batteries[slot]=value }
        }
        let aggregate=batteries.isEmpty
        if aggregate,let value=percent("device_batteryLevelMain") { batteries[.left]=value }
        let firmware=(fields["device_firmwareVersion"] as? String).flatMap { text in
            !text.isEmpty && text.count <= 80 && !text.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) ? text : nil
        }
        return Self(batteries:batteries,aggregate:aggregate,firmware:firmware)
    }
}
