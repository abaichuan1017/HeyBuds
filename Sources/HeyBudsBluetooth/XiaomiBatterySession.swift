// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HeyBudsProtocol

@MainActor protocol XiaomiBatterySource:EarbudTransport {
    func snapshot() async throws -> XiaomiSystemBattery
}

/// No private control socket is opened for a model supported only by system
/// battery reports. The subprocess is owned, bounded and never logged or saved.
@MainActor final class XiaomiSystemBatteryTransport:XiaomiBatterySource {
    var onEvent:((TransportEvent) -> Void)?
    let label="System Bluetooth"
    private let address:String
    private var active=false
    private var process:Process?
    init(address:String) { self.address=address }
    func open() async throws { try Task.checkCancellation();active=true }
    func send(_ bytes:Data) async throws { throw ProtocolError.unsupported }
    func snapshot() async throws -> XiaomiSystemBattery {
        guard active,process == nil else { throw ProtocolError.disconnected }
        let task=Process(),output=Pipe()
        task.executableURL=URL(fileURLWithPath:"/usr/sbin/system_profiler")
        task.arguments=["SPBluetoothDataType","-json"]
        task.standardOutput=output;task.standardError=FileHandle.nullDevice
        process=task
        defer { if process === task { process=nil } }
        try task.run()
        let reader=Task.detached(priority:.utility) { () -> (Data,Int32) in
            let bytes=output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit();return (bytes,task.terminationStatus)
        }
        let watchdog=Task {
            do { try await Task.sleep(for:.seconds(8)) } catch { return }
            if task.isRunning { task.terminate() }
        }
        defer { watchdog.cancel() }
        let result=await withTaskCancellationHandler(operation:{ await reader.value },onCancel:{
            Task { @MainActor in if task.isRunning { task.terminate() } }
        })
        try Task.checkCancellation()
        guard active,result.1 == 0 else { throw ProtocolError.disconnected }
        guard let snapshot=XiaomiSystemBattery.parse(result.0,address:address) else { throw ProtocolError.disconnected }
        return snapshot
    }
    func close() { active=false;if process?.isRunning == true { process?.terminate() };process=nil }
}

@MainActor final class XiaomiBatterySession:AdditionalSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel?
    private(set) var ready=false
    var interactive=false
    var onChange:(() -> Void)?
    var onClose:((String?) -> Void)?
    private let profile:XiaomiProfile?
    private let baseModel:DeviceModel?
    private let source:(any XiaomiBatterySource)?
    private let operations=RequestGate()
    private var active=false,generation=UUID()
    private var poll:Task<Void,Never>?
    init(transport:EarbudTransport,name:String,catalog:ModelCatalog) {
        let selected=XiaomiProfile.named(name);profile=selected
        baseModel=selected.flatMap { p in catalog.models.first { $0.id == p.modelID } };model=baseModel
        source=transport as? any XiaomiBatterySource
    }
    private func read() async throws {
        guard let source,let profile,let baseModel else { throw ProtocolError.unsupported }
        let token=generation,snapshot=try await source.snapshot()
        try Task.checkCancellation();guard active,generation == token else { throw ProtocolError.disconnected }
        var sample=DeviceState();sample.batteries=snapshot.batteries;sample.firmware=snapshot.firmware
        if !sample.batteries.isEmpty { sample.observedQueries.insert(Command.battery) }
        model=profile.presentationModel(baseModel,aggregateBattery:snapshot.aggregate)
        state=sample;onChange?()
    }
    func open() async throws {
        guard profile?.systemBatteryOnly == true,let source,!active else { throw ProtocolError.unsupported }
        active=true
        do { try await source.open();try await read();ready=true;onChange?() }
        catch { close();throw error }
    }
    func initialize() async {
        guard ready else { return };let token=generation
        poll=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(self?.interactive == true ? 20 : 60)) } catch { return }
                guard let self,self.ready,self.generation == token else { return };await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return };let token=generation
        do {
            try await operations.acquire();defer { operations.release() }
            guard active,generation == token else { return };try await read()
        } catch { if generation == token { close();onClose?(error.localizedDescription) } }
    }
    func canQuery(_ command:UInt16) -> Bool { command == Command.battery || command == Command.firmware }
    func canWrite(_ command:UInt16,reading:UInt16?=nil) -> Bool { false }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome { throw ProtocolError.unsupported }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome { throw ProtocolError.unsupported }
    func close() { active=false;ready=false;generation=UUID();poll?.cancel();poll=nil;source?.close();state=DeviceState();onChange?() }
}
