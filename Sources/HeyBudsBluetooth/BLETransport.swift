import Foundation
import CoreBluetooth
import HeyBudsProtocol

@MainActor public final class BLETransport: NSObject, EarbudTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public var onEvent: ((TransportEvent) -> Void)?
    public let label="BLE GATT"
    private let targetName: String
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var opening: CheckedContinuation<Void,Error>?
    private var writing: TransportWrite?
    private var timeout: Task<Void,Never>?
    private var closing=false
    public init(name: String) { targetName=name; super.init() }
    public func open() async throws {
        closing=false
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                opening=continuation
                central=CBCentralManager(delegate:self,queue:.main)
                timeout=Task { [weak self] in
                    try? await Task.sleep(for:.seconds(12)); guard !Task.isCancelled else { return }
                    self?.fail(TransportFailure.unavailable("BLE control service discovery timed out"))
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close() } })
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closing else { return }
        switch central.state {
        case .poweredOn:
            let connected=central.retrieveConnectedPeripherals(withServices:[CBUUID(string:Discovery.service)])
                .filter { $0.name?.caseInsensitiveCompare(targetName) == .orderedSame }
            if connected.count == 1 { attach(connected[0]) }
            else if connected.count > 1 { fail(TransportFailure.unavailable("Several BLE devices have the same name")) }
            else { central.scanForPeripherals(withServices:[CBUUID(string:Discovery.service)],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false]) }
        case .unauthorized: fail(TransportFailure.unavailable("Bluetooth permission denied. Allow HeyBuds in System Settings → Privacy & Security → Bluetooth."))
        case .poweredOff: fail(TransportFailure.unavailable("Bluetooth is turned off"))
        case .unsupported: fail(TransportFailure.unavailable("Bluetooth Low Energy is unavailable"))
        case .resetting:
            if writeCharacteristic != nil { fail(TransportFailure.unavailable("Bluetooth controller is resetting")) }
        default: break
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        let name=peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name?.caseInsensitiveCompare(targetName) == .orderedSame, self.peripheral == nil else { return }
        attach(peripheral)
    }
    private func attach(_ device: CBPeripheral) {
        guard !closing, peripheral == nil else { return }
        central.stopScan(); peripheral=device; device.delegate=self; central.connect(device)
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !closing, peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string:Discovery.service)])
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error ?? ProtocolError.disconnected)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, !closing else { return }
        fail(error ?? ProtocolError.disconnected)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closing, peripheral === self.peripheral else { return }
        guard error == nil, let service=peripheral.services?.first(where:{$0.uuid == CBUUID(string:Discovery.service)}) else {
            fail(error ?? TransportFailure.unavailable("BLE control service unavailable")); return
        }
        peripheral.discoverCharacteristics([CBUUID(string:Discovery.write),CBUUID(string:Discovery.notify)],for:service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !closing, peripheral === self.peripheral else { return }
        guard error == nil, let write=service.characteristics?.first(where:{$0.uuid == CBUUID(string:Discovery.write)}),
              let notify=service.characteristics?.first(where:{$0.uuid == CBUUID(string:Discovery.notify)}),
              write.properties.contains(.writeWithoutResponse) || write.properties.contains(.write),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            fail(error ?? TransportFailure.unavailable("BLE control characteristics unavailable")); return
        }
        writeCharacteristic=write
        peripheral.setNotifyValue(true,for:notify)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !closing, peripheral === self.peripheral else { return }
        guard error == nil, characteristic.isNotifying else { fail(error ?? ProtocolError.disconnected); return }
        timeout?.cancel(); timeout=nil
        let c=opening; opening=nil; c?.resume()
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !closing, peripheral === self.peripheral, characteristic.uuid == CBUUID(string:Discovery.notify),
              error == nil, let data=characteristic.value else { return }
        onEvent?(.data(data))
    }
    public func send(_ bytes: Data) async throws {
        guard let peripheral, let write=writeCharacteristic, !closing, peripheral.state == .connected else { throw ProtocolError.disconnected }
        guard writing == nil else { throw TransportFailure.unavailable("Concurrent BLE write") }
        let type: CBCharacteristicWriteType=write.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu=peripheral.maximumWriteValueLength(for:type)
        guard mtu > 0 else { throw ProtocolError.disconnected }
        for start in stride(from:0,to:bytes.count,by:mtu) {
            try Task.checkCancellation()
            let deadline=Date().addingTimeInterval(5)
            while type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                guard Date() < deadline, !closing else { throw ProtocolError.disconnected }
                try await Task.sleep(for:.milliseconds(20))
            }
            guard !closing,peripheral === self.peripheral,peripheral.state == .connected else { throw ProtocolError.disconnected }
            let fragment=bytes.subdata(in:start..<min(start+mtu,bytes.count))
            if type == .withoutResponse { peripheral.writeValue(fragment,for:write,type:type) }
            else {
                guard writing == nil else { throw ProtocolError.invalidPayload }
                let completion=TransportWrite()
                writing=completion
                defer { if writing === completion { writing=nil } }
                try await completion.wait(abort:{ [weak self] error in self?.fail(error) },start:{
                    peripheral.writeValue(fragment,for:write,type:type)
                })
                guard !closing,peripheral === self.peripheral else { throw ProtocolError.disconnected }
            }
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !closing,peripheral === self.peripheral,characteristic === writeCharacteristic else { return }
        if let error { writing?.finish(.failure(error)) } else { writing?.finish(.success(())) }
    }
    private func fail(_ error: Error) {
        let wasReady=opening == nil && writeCharacteristic != nil && !closing
        let o=opening; opening=nil; o?.resume(throwing:error)
        let w=writing; writing=nil; w?.finish(.failure(error))
        close()
        if wasReady { onEvent?(.closed(error.localizedDescription)) }
    }
    public func close() {
        closing=true; timeout?.cancel(); timeout=nil; central?.stopScan()
        if let peripheral { peripheral.delegate=nil; central?.cancelPeripheralConnection(peripheral) }
        peripheral=nil; writeCharacteristic=nil
        let o=opening; opening=nil; o?.resume(throwing:ProtocolError.disconnected)
        let w=writing; writing=nil; w?.finish(.failure(ProtocolError.disconnected))
    }
}
