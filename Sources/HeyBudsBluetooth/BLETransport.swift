import Foundation
import CoreBluetooth
import HeyBudsProtocol

/// Exact control endpoints only. Fast Pair, OTA and arbitrary writable services
/// are never candidates for a control session.
public struct BLEControlProfile:Sendable {
    public let service:String
    public let write:String
    public let notify:String
    public let bmapSegmentation:Bool
    public static let oppo=BLEControlProfile(service:"0000079A-D102-11E1-9B23-00025B00A5A5",write:"0100079A-D102-11E1-9B23-00025B00A5A5",notify:"0200079A-D102-11E1-9B23-00025B00A5A5",bmapSegmentation:false)
    public static let bose=BLEControlProfile(service:"0000FEBE-0000-1000-8000-00805F9B34FB",write:"C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8",notify:"C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8",bmapSegmentation:true)
}

@MainActor public final class BLETransport: NSObject, EarbudTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public var onEvent: ((TransportEvent) -> Void)?
    public let label="BLE GATT"
    private let targetName: String
    private let profile:BLEControlProfile
    private var bmapCodec=BoseGATTCodec()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var opening: CheckedContinuation<Void,Error>?
    private var writing: TransportWrite?
    private var timeout: Task<Void,Never>?
    private var closing=false
    public init(name: String,profile:BLEControlProfile = .oppo) { targetName=name;self.profile=profile;super.init() }
    public func open() async throws {
        closing=false;bmapCodec.reset()
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
        guard !closing,central === self.central else { return }
        switch central.state {
        case .poweredOn:
            let connected=central.retrieveConnectedPeripherals(withServices:[CBUUID(string:profile.service)])
                .filter { $0.name?.caseInsensitiveCompare(targetName) == .orderedSame }
            if connected.count == 1 { attach(connected[0]) }
            else if connected.count > 1 { fail(TransportFailure.unavailable("Several BLE devices have the same name")) }
            else { central.scanForPeripherals(withServices:[CBUUID(string:profile.service)],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false]) }
        case .unauthorized: fail(TransportFailure.unavailable("Bluetooth permission denied. Allow HeyBuds in System Settings → Privacy & Security → Bluetooth."))
        case .poweredOff: fail(TransportFailure.unavailable("Bluetooth is turned off"))
        case .unsupported: fail(TransportFailure.unavailable("Bluetooth Low Energy is unavailable"))
        case .resetting:
            if writeCharacteristic != nil { fail(TransportFailure.unavailable("Bluetooth controller is resetting")) }
        default: break
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard !closing,central === self.central else { return }
        let name=peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name?.caseInsensitiveCompare(targetName) == .orderedSame, self.peripheral == nil else { return }
        attach(peripheral)
    }
    private func attach(_ device: CBPeripheral) {
        guard !closing, peripheral == nil else { return }
        central.stopScan(); peripheral=device; device.delegate=self; central.connect(device)
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !closing,central === self.central, peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string:profile.service)])
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard !closing,central === self.central,peripheral === self.peripheral else { return }
        fail(error ?? ProtocolError.disconnected)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central,peripheral === self.peripheral, !closing else { return }
        fail(error ?? ProtocolError.disconnected)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closing, peripheral === self.peripheral else { return }
        guard error == nil, let service=peripheral.services?.first(where:{$0.uuid == CBUUID(string:profile.service)}) else {
            fail(error ?? TransportFailure.unavailable("BLE control service unavailable")); return
        }
        peripheral.discoverCharacteristics([CBUUID(string:profile.write),CBUUID(string:profile.notify)],for:service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !closing, peripheral === self.peripheral else { return }
        guard error == nil, let write=service.characteristics?.first(where:{$0.uuid == CBUUID(string:profile.write)}),
              let notify=service.characteristics?.first(where:{$0.uuid == CBUUID(string:profile.notify)}),
              write.properties.contains(.writeWithoutResponse) || write.properties.contains(.write),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            fail(error ?? TransportFailure.unavailable("BLE control characteristics unavailable")); return
        }
        writeCharacteristic=write
        peripheral.setNotifyValue(true,for:notify)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !closing, peripheral === self.peripheral else { return }
        guard characteristic.uuid == CBUUID(string:profile.notify) else { return }
        guard error == nil, characteristic.isNotifying else { fail(error ?? ProtocolError.disconnected); return }
        timeout?.cancel(); timeout=nil
        let c=opening; opening=nil; c?.resume()
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !closing, peripheral === self.peripheral, characteristic.uuid == CBUUID(string:profile.notify),
              error == nil, let data=characteristic.value else { return }
        if profile.bmapSegmentation { if let frame=bmapCodec.feed(data) { onEvent?(.data(frame)) } }
        else { onEvent?(.data(data)) }
    }
    public func send(_ bytes: Data) async throws {
        guard let peripheral, let write=writeCharacteristic, !closing, peripheral.state == .connected else { throw ProtocolError.disconnected }
        guard writing == nil else { throw TransportFailure.unavailable("Concurrent BLE write") }
        let type: CBCharacteristicWriteType=write.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu=peripheral.maximumWriteValueLength(for:type)
        guard mtu > 0 else { throw ProtocolError.disconnected }
        let fragments:[Data]
        if profile.bmapSegmentation { fragments=try BoseGATTCodec.encode(bytes,maximumWriteLength:mtu) }
        else { fragments=stride(from:0,to:bytes.count,by:mtu).map { bytes.subdata(in:$0..<min($0+mtu,bytes.count)) } }
        for fragment in fragments {
            try Task.checkCancellation()
            let deadline=Date().addingTimeInterval(5)
            while type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                guard Date() < deadline, !closing else { throw ProtocolError.disconnected }
                try await Task.sleep(for:.milliseconds(20))
            }
            guard !closing,peripheral === self.peripheral,peripheral.state == .connected else { throw ProtocolError.disconnected }
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
        peripheral=nil; writeCharacteristic=nil;bmapCodec.reset()
        let o=opening; opening=nil; o?.resume(throwing:ProtocolError.disconnected)
        let w=writing; writing=nil; w?.finish(.failure(ProtocolError.disconnected))
    }
}
