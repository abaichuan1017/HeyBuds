// IOBluetooth lifecycle informed by Realme TWS Mac Controller (MIT).
// Rewritten to own asynchronous buffers through write completion and cancel sessions.
import Foundation
import IOBluetooth
import HeyBudsProtocol

@MainActor public final class RFCOMMTransport: NSObject, EarbudTransport, @preconcurrency IOBluetoothRFCOMMChannelDelegate, @preconcurrency IOBluetoothDeviceAsyncCallbacks {
    public var onEvent: ((TransportEvent) -> Void)?
    public let label="RFCOMM"
    private let device: IOBluetoothDevice
    public let serviceUUID:String
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void,Error>?
    private var writing: TransportWrite?
    private var writeSequence:UInt=0
    private var writeRefcon:UnsafeMutableRawPointer?
    private var writeBuffer: NSData?
    private var timeout: Task<Void,Never>?
    private var sdpPoll:Task<Void,Never>?
    private var channelOpening=false
    private var isClosing=false

    public init(address: String,serviceUUID:String="0000079A-D102-11E1-9B23-00025B00A5A5") throws {
        guard let device=IOBluetoothDevice(addressString:address) else { throw ProtocolError.disconnected }
        self.device=device
        self.serviceUUID=serviceUUID
        super.init()
    }
    public func open() async throws {
        guard opening == nil, channel == nil else { throw TransportFailure.unavailable("Control channel already opening") }
        isClosing=false
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                opening=continuation
                timeout=Task { [weak self] in
                    try? await Task.sleep(for:.seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.failOpen(TransportFailure.unavailable("Control service connection timed out"))
                }
                // Cached records alone are insufficient on some firmware. Refresh using the SDK callback.
                let result=device.performSDPQuery(self)
                if result != kIOReturnSuccess { failOpen(TransportFailure.unavailable("SDP query failed (\(result))")) }
                else {
                    // Some macOS releases refresh the cache without delivering the SDP
                    // callback. Match the same service UUID in that cache, never a bare port.
                    sdpPoll=Task { [weak self] in
                        for _ in 0..<40 {
                            try? await Task.sleep(for:.milliseconds(50))
                            guard !Task.isCancelled, let self, self.opening != nil, !self.isClosing else { return }
                            if let record=self.device.getServiceRecord(for:Discovery.uuid(self.serviceUUID)) { self.openRecord(record); return }
                        }
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close() } })
    }
    @objc public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard opening != nil, !isClosing, !channelOpening else { return }
        guard status == kIOReturnSuccess,
              let record=self.device.getServiceRecord(for:Discovery.uuid(serviceUUID)) else {
            failOpen(TransportFailure.unavailable("Earbud control service not found")); return
        }
        openRecord(record)
    }
    @objc public func remoteNameRequestComplete(_ device:IOBluetoothDevice!,status:IOReturn) { }
    @objc public func connectionComplete(_ device:IOBluetoothDevice!,status:IOReturn) { }
    private func openRecord(_ record:IOBluetoothSDPServiceRecord) {
        guard !channelOpening, opening != nil, !isClosing else { return }
        channelOpening=true
        var id: BluetoothRFCOMMChannelID=0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess, id > 0 else {
            failOpen(TransportFailure.unavailable("Control service has no RFCOMM channel")); return
        }
        // Channel is accepted only from this specific service record, never guessed.
        var opened: IOBluetoothRFCOMMChannel?
        let result=self.device.openRFCOMMChannelAsync(&opened,withChannelID:id,delegate:self)
        if result == kIOReturnSuccess { channel=opened }
        else { failOpen(TransportFailure.unavailable("RFCOMM open failed (\(result))")) }
    }
    public func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard !isClosing, opening != nil else { channel?.close(); return }
        guard error == kIOReturnSuccess else { failOpen(TransportFailure.unavailable("RFCOMM connection failed (\(error))")); return }
        self.channel=channel; timeout?.cancel(); timeout=nil; sdpPoll?.cancel(); sdpPoll=nil
        let c=opening; opening=nil; c?.resume()
    }
    private func failOpen(_ error: Error) {
        let c=opening; opening=nil; timeout?.cancel(); timeout=nil; sdpPoll?.cancel(); sdpPoll=nil; channelOpening=false
        channel?.setDelegate(nil); channel?.close(); channel=nil
        c?.resume(throwing:error)
    }
    public func send(_ bytes: Data) async throws {
        guard let channel, channel.isOpen(), !isClosing else { throw ProtocolError.disconnected }
        guard writing == nil else { throw TransportFailure.unavailable("Concurrent RFCOMM write") }
        let mtu=max(1,Int(channel.getMTU()))
        for start in stride(from:0,to:bytes.count,by:mtu) {
            try Task.checkCancellation()
            let fragment=bytes.subdata(in:start..<min(bytes.count,start+mtu)) as NSData
            let write=TransportWrite()
            writeSequence = writeSequence == UInt.max ? 1 : writeSequence+1
            let refcon=UnsafeMutableRawPointer(bitPattern:writeSequence)
            writing=write;writeBuffer=fragment;writeRefcon=refcon
            defer { if writing === write { writing=nil;writeBuffer=nil;writeRefcon=nil } }
            try await write.wait(abort:{ [weak self] error in
                self?.close();self?.onEvent?(.closed(error.localizedDescription))
            },start:{
                let result=channel.writeAsync(UnsafeMutableRawPointer(mutating:fragment.bytes),length:UInt16(fragment.length),refcon:refcon)
                if result != kIOReturnSuccess {
                    write.finish(.failure(TransportFailure.unavailable("RFCOMM write failed (\(result))")))
                }
            })
            guard !isClosing, channel === self.channel else { throw ProtocolError.disconnected }
        }
    }
    public func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard !isClosing,channel === self.channel,refcon == writeRefcon else { return }
        if error == kIOReturnSuccess { writing?.finish(.success(())) }
        else { writing?.finish(.failure(TransportFailure.unavailable("RFCOMM write completion failed (\(error))"))) }
    }
    public func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard !isClosing, channel === self.channel, let pointer, length > 0 else { return }
        onEvent?(.data(Data(bytes:pointer,count:length)))
    }
    public func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard channel === self.channel else { return }
        close(); onEvent?(.closed(nil))
    }
    public func close() {
        isClosing=true; timeout?.cancel(); timeout=nil; sdpPoll?.cancel(); sdpPoll=nil; channelOpening=false
        channel?.setDelegate(nil); channel?.close(); channel=nil
        let o=opening; opening=nil; o?.resume(throwing:ProtocolError.disconnected)
        let w=writing; writing=nil; w?.finish(.failure(ProtocolError.disconnected))
        writeBuffer=nil;writeRefcon=nil
    }
}
