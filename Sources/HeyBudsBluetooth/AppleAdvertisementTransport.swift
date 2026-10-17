import Foundation
import CoreBluetooth
import HeyBudsProtocol

/// Passive plaintext advertisements only. The selected paired device must match by
/// advertised name. An anonymous nearby AirPods is never assigned to this session.
@MainActor public final class AppleAdvertisementTransport:NSObject,EarbudTransport,@preconcurrency CBCentralManagerDelegate {
    public var onEvent:((TransportEvent)->Void)?
    public let label="BLE advertisement"
    private let name:String
    private var central:CBCentralManager?
    private var target:UUID?
    private var opening:CheckedContinuation<Void,Error>?
    private var timeout:Task<Void,Never>?
    private var closing=true
    public init(name:String) { self.name=name;super.init() }
    public func open() async throws {
        closing=false
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                opening=continuation;central=CBCentralManager(delegate:self,queue:.main)
                timeout=Task { [weak self] in
                    try? await Task.sleep(for:.seconds(15));guard !Task.isCancelled else { return }
                    self?.fail(TransportFailure.unavailable("未收到可确认属于此耳机的明文广播 / No identifiable plaintext advertisement from the selected earbuds"))
                }
            }
        },onCancel:{Task { @MainActor [weak self] in self?.close() }})
    }
    public func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard !closing else { return }
        switch central.state {
        case .poweredOn:central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])
        case .unauthorized:fail(TransportFailure.unavailable("Bluetooth permission denied"))
        case .poweredOff:fail(TransportFailure.unavailable("Bluetooth is turned off"))
        case .unsupported:fail(TransportFailure.unavailable("Bluetooth Low Energy is unavailable"))
        default:break
        }
    }
    public func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard !closing,let data=advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,AppleAdvertisement.parse(data) != nil else { return }
        let advertised=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        if let target { guard peripheral.identifier == target else { return } }
        else {
            guard advertised?.caseInsensitiveCompare(name) == .orderedSame else { return }
            target=peripheral.identifier
        }
        // Deliver data before completing open, so ready implies a decoded state.
        onEvent?(.data(data))
        let c=opening;opening=nil;timeout?.cancel();timeout=nil;c?.resume()
    }
    public func send(_ bytes:Data) async throws { throw ProtocolError.unsupported }
    private func fail(_ error:Error) {
        let wasReady=opening == nil && !closing
        let c=opening;opening=nil;close();c?.resume(throwing:error)
        if wasReady { onEvent?(.closed(error.localizedDescription)) }
    }
    public func close() {
        closing=true;timeout?.cancel();timeout=nil;central?.stopScan();central?.delegate=nil;central=nil;target=nil
        let c=opening;opening=nil;c?.resume(throwing:ProtocolError.disconnected)
    }
}
