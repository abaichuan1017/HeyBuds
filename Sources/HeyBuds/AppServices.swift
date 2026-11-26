import AppKit
import IOBluetooth
import HeyBudsBluetooth
import HeyBudsProtocol

/// System boundaries are injectable so lifecycle tests never discover or open radios.
@MainActor struct AppServices {
    var discover:(ModelCatalog) async -> [DeviceCandidate] = { [inventory=SystemAudio.Inventory()] catalog in
        let paired=await Discovery.paired(catalog:catalog,includingSystemAudio:true)
        return await inventory.devices(paired:paired)
    }
    var monitor:BluetoothConnectionMonitor? = BluetoothConnectionMonitor()
    var observeOutputs:((@escaping () -> Void) -> (() -> Void))? = SystemAudio.observeOutputs
    var volume=SystemAudio.VolumeService()
    var makeSession:(DeviceCandidate,EarbudFamily,String,String?,ModelCatalog) throws -> DeviceSession = { device,family,kind,override,catalog in
        let transport=try ControlTransportFactory.make(device:device,family:family,kind:kind)
        let local=IOBluetoothHostController.default()?.addressAsString().split(whereSeparator:{$0 == ":" || $0 == "-"}).compactMap { UInt8($0,radix:16) }
        return DeviceSession(transport:transport,name:device.protocolName,catalog:catalog,overrideID:override,family:family,localHostAddress:local)
    }
    var openAudio:(String) async -> Void = { address in
        _ = await Task.detached { IOBluetoothDevice(addressString:address)?.openConnection() }.value
    }
    var closeAudio:(String) async -> Void = { address in
        _ = await Task.detached { IOBluetoothDevice(addressString:address)?.closeConnection() }.value
    }
    var hasCompetitor:() -> Bool = {
        ["local.buds.menubar","com.aniketbudhwani.budsbar"].contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier:$0).isEmpty
        }
    }
    var delay:(Duration) async throws -> Void = { try await Task.sleep(for:$0) }
}
