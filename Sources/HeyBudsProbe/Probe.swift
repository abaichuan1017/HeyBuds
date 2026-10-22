import Foundation
import AppKit
import HeyBudsProtocol
import HeyBudsBluetooth

@main struct HeyBudsProbe {
    @MainActor static func main() async {
        do {
            let args=CommandLine.arguments.dropFirst()
            let catalog=try ModelCatalog()
            if args.first == "catalog" {
                let rows=catalog.models.map { model -> [String:Any] in
                    ["productID":model.id,"name":model.name,"brand":model.brand,"protocolFamily":model.family.rawValue,"aliases":model.aliases,
                     "sourceAdaptation":"imported","catalogValidation":"tested",
                     "protocolFixtureCoverage":["06C410","064014","066452","06EC10"].contains(model.id) ? "representative profile" : "catalog only",
                     "hardwareVerifiedFeatures":[String](),"noiseModes":model.noiseOptions.map { $0.mode.rawValue },
                     "eqWireIDs":model.presets.map { Int($0.id) },"spatialModes":model.spatialModes.map(Int.init),
                     "customEQBands":model.customEQFrequencies,"switches":model.features.map(\.key)]
                }
                let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
                FileHandle.standardOutput.write(data); print("")
            } else if args.first == "devices" {
                for (i,device) in await Discovery.paired(catalog:catalog).enumerated() { print("\(i+1). \(device.name) · audio=\(device.audioConnected)") }
            } else if args.first == "read" {
                let devices=await Discovery.paired(catalog:catalog)
                guard let device=devices.first(where:{$0.audioConnected}) else { throw TransportFailure.unavailable("No paired connected earbuds. Use HeyBuds.app to grant Bluetooth permission.") }
                let transport:EarbudTransport
                let family=catalog.family(name:device.name) ?? device.family ?? .oppo
                if args.contains("--ble") {
                    guard family == .oppo else { throw ProtocolError.unsupported }
                    transport=BLETransport(name:device.name)
                } else if let address=device.classicAddress,let service=family.serviceUUID {
                    transport=try RFCOMMTransport(address:address,serviceUUID:service)
                } else { throw ProtocolError.unsupported }
                let session=DeviceSession(transport:transport,name:device.name,catalog:catalog,family:family)
                defer { session.close() }
                try await session.open(); await session.initialize()
                let s=session.state
                let report:[String:Any]=["productID":s.productID ?? "unknown","model":session.model?.name ?? "unknown",
                    "transport":transport.label,"battery":Dictionary(uniqueKeysWithValues:s.batteries.map { (String($0.key.rawValue),$0.value.percent) }),
                    "noise":s.noise?.rawValue ?? "unknown","eq":s.eq.map(Int.init) ?? -1,"spatial":s.spatial.map(Int.init) ?? -1,
                    "queries":s.observedQueries.sorted().map { String(format:"%04X",$0) }]
                let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                FileHandle.standardOutput.write(data); print("")
            } else {
                print("heybuds-probe catalog | devices | read [--ble]\nRead-only hardware inspection: quit HeyBuds and other controllers first. The terminal requires Bluetooth permission.")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1)
        }
    }
}
