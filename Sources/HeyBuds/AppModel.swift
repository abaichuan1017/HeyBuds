import AppKit
import SwiftUI
import Observation
import ServiceManagement
import UserNotifications
import CoreBluetooth
import IOBluetooth
import HeyBudsBluetooth
import HeyBudsProtocol

func L(_ chinese:String,_ english:String) -> String { UserDefaults.standard.string(forKey:"language") == "en" ? english : chinese }

@MainActor @Observable final class AppModel {
    let catalog:ModelCatalog
    var candidates:[DeviceCandidate]=[]
    var selectedID:String? { didSet { UserDefaults.standard.set(selectedID,forKey:"selectedDevice") } }
    var phase="idle"
    var error:String?
    var notice:String?
    var noiseControlHint:String?
    var operationBusy=false
    var revision=0
    var onStatusChange:(() -> Void)?
    var onDeviceConnected:((DeviceCandidate) -> Void)?
    var onPreviewConnectionTip:(() -> Void)?
    var backgroundMode=UserDefaults.standard.bool(forKey:"backgroundMode") {
        didSet { UserDefaults.standard.set(backgroundMode,forKey:"backgroundMode"); onStatusChange?() }
    }
    var connectionTips=UserDefaults.standard.object(forKey:"connectionTips") as? Bool ?? true {
        didSet { UserDefaults.standard.set(connectionTips,forKey:"connectionTips"); onStatusChange?() }
    }
    var language=UserDefaults.standard.string(forKey:"language") ?? "zh" {
        didSet { UserDefaults.standard.set(language,forKey:"language"); revision += 1; onStatusChange?() }
    }
    var menuBattery=UserDefaults.standard.bool(forKey:"menuBattery") {
        didSet { UserDefaults.standard.set(menuBattery,forKey:"menuBattery"); onStatusChange?() }
    }
    var autoReconnect=UserDefaults.standard.object(forKey:"autoReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect,forKey:"autoReconnect") }
    }
    var notifyLow=UserDefaults.standard.bool(forKey:"notifyLow") {
        didSet { UserDefaults.standard.set(notifyLow,forKey:"notifyLow") }
    }
    var lowThreshold=UserDefaults.standard.object(forKey:"lowThreshold") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(lowThreshold,forKey:"lowThreshold") }
    }
    var appearance=UserDefaults.standard.string(forKey:"appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance,forKey:"appearance") }
    }
    var launchAtLogin=false
    @ObservationIgnored private(set) var session:DeviceSession?
    @ObservationIgnored private var connectTask:Task<Void,Never>?
    @ObservationIgnored private var operationTask:Task<Void,Never>?
    @ObservationIgnored private var monitorTask:Task<Void,Never>?
    @ObservationIgnored private var scanTask:Task<Void,Never>?
    @ObservationIgnored private let connectionMonitor=BluetoothConnectionMonitor()
    @ObservationIgnored private var connectionEventTask:Task<Void,Never>?
    @ObservationIgnored private var connectionPresence=ConnectionPresence()
    @ObservationIgnored private var recognizedProductIDs:[String:String]=[:]
    @ObservationIgnored private var retryTask:Task<Void,Never>?
    @ObservationIgnored private var connectionToken=UUID()
    @ObservationIgnored private var audioCloseTask:Task<Void,Never>?
    @ObservationIgnored private var manualDisconnect=false
    @ObservationIgnored private var sleeping=false
    @ObservationIgnored private var retry=0
    @ObservationIgnored private var alertSlots:Set<BatterySlot>=[]
    @ObservationIgnored private var history:[String]=[]
    var interactive=false { didSet { session?.interactive=interactive } }

    init(catalog:ModelCatalog) { self.catalog=catalog; selectedID=UserDefaults.standard.string(forKey:"selectedDevice") }
    var candidate:DeviceCandidate? { candidates.first { $0.id == selectedID } }
    var state:DeviceState { _ = revision; return session?.state ?? DeviceState() }
    var model:DeviceModel? { _ = revision; return session?.model ?? candidate.flatMap { catalog.model(productID:nil,name:$0.name,override:overrideID) } }
    var ready:Bool { phase == "ready" && session?.ready == true }
    var connecting:Bool { phase == "connecting" }
    // The header and connection card use the macOS Bluetooth name, which may be
    // a personal nickname. The protocol model name belongs in Device info.
    var title:String { candidate?.name ?? "HeyBuds" }
    var bluetoothConnected:Bool { !sleeping && (candidate?.audioConnected == true || ready) }
    var transportLabel:String { session?.transport.label ?? "" }
    var knownConnectedDevices:[DeviceCandidate] {
        guard !sleeping else { return [] }
        return candidates.filter { device in
            device.audioConnected && ((device.id == selectedID && session?.model != nil)
                || catalog.family(name:device.name,override:UserDefaults.standard.string(forKey:"model.\(device.id)")) != nil || device.family != nil)
        }
    }
    var presets:[EQPreset] { model?.presets.filter { $0.available(firmware:state.firmwareRevision) } ?? [] }
    var features:[FeatureDefinition] { _ = revision; return session?.availableFeatures ?? model?.features ?? [] }
    var supportsSpatialAudio:Bool { _ = revision; return session?.supportsSpatialAudio == true }
    var overrideID:String? {
        get { guard let selectedID else { return nil }; return UserDefaults.standard.string(forKey:"model.\(selectedID)") }
        set {
            guard let selectedID else { return }
            UserDefaults.standard.set(newValue,forKey:"model.\(selectedID)"); session?.setModelOverride(newValue); revision += 1
            if ready { disconnect(audio:false); connect() }
        }
    }
    var status:String {
        switch phase {
        case "ready": return L("控制通道就绪","Controls ready")
        case "connecting": return L("正在建立控制通道…","Opening control channel…")
        case "sleeping": return L("电脑已睡眠","Mac is asleep")
        default:
            if candidate?.audioConnected == true { return L("音频已连接 · 控制未连接","Audio connected · Controls offline") }
            return candidates.isEmpty ? L("等待耳机","Waiting for earbuds") : L("耳机未连接","Earbuds disconnected")
        }
    }
    func start() {
        connectionMonitor.onChange = { [weak self] in
            guard let self, !self.sleeping else { return }
            self.connectionEventTask?.cancel()
            self.connectionEventTask=Task { [weak self] in
                try? await Task.sleep(for:.milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                await self.rescan()
                guard !Task.isCancelled, !self.sleeping, !self.manualDisconnect else { return }
                if self.autoReconnect, !self.ready, !self.connecting, self.retryTask == nil,
                   self.candidate?.audioConnected == true { self.connect() }
            }
        }
        monitorTask=Task { [weak self] in
            guard let self else { return }
            await self.rescan()
            guard !Task.isCancelled else { return }
            if !self.sleeping, !self.manualDisconnect, self.candidate?.audioConnected == true { self.connect() }
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(self.interactive ? 8 : 30))
                guard !Task.isCancelled else { return }
                await self.rescan()
                guard !Task.isCancelled else { return }
                if !self.ready, !self.connecting, self.autoReconnect, !self.manualDisconnect, !self.sleeping,
                   self.retryTask == nil, self.candidate?.audioConnected == true { self.scheduleReconnect() }
            }
        }
    }
    func rescan() async {
        if let scanTask { await scanTask.value; return }
        let task=Task { [weak self] in
            guard let catalog=self?.catalog else { return }
            let devices=await Discovery.paired(catalog:catalog)
            guard let self, !Task.isCancelled else { return }
            self.candidates=devices
            self.connectionMonitor.watch(devices)
            if !self.ready, !self.connecting {
                if self.candidate?.audioConnected != true,
                   let next=ConnectionPresence.preferredID(connectedIDs:self.knownConnectedDevices.map(\.id),selectedID:self.selectedID) {
                    self.selectedID=next
                } else if self.selectedID == nil || !devices.contains(where:{$0.id == self.selectedID}) {
                    self.selectedID=devices.first?.id
                }
            }
            self.updateConnectionPresence()
        }
        scanTask=task
        await task.value
        scanTask=nil
    }
    private func updateConnectionPresence() {
        let devices=knownConnectedDevices
        let added=connectionPresence.update(Set(devices.map(\.id)))
        onStatusChange?()
        for device in devices where added.contains(device.id) { onDeviceConnected?(device) }
    }
    func select(_ id:String) {
        guard id != selectedID else { return }
        disconnect(audio:false); selectedID=id; manualDisconnect=false; retry=0; connect()
    }
    func connect() {
        guard !connecting, !sleeping else { return }
        guard let candidate else { error=L("先在系统蓝牙设置中配对耳机。","Pair your earbuds in Bluetooth settings first."); return }
        let competitors=["local.buds.menubar","com.aniketbudhwani.budsbar"].contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier:$0).isEmpty
        }
        if competitors { error=L("请先退出另一个耳机控制器，再连接 HeyBuds。","Quit the other earbud controller before connecting HeyBuds."); return }
        retryTask?.cancel(); retryTask=nil; connectTask?.cancel(); session?.close(); session=nil
        let token=UUID(); connectionToken=token
        manualDisconnect=false; error=nil; notice=nil; noiseControlHint=nil; phase="connecting"; onStatusChange?()
        let override=overrideID
        connectTask=Task { [weak self] in
            guard let self else { return }
            await self.audioCloseTask?.value
            guard !Task.isCancelled, self.connectionToken == token else { return }
            if !candidate.audioConnected, let address=candidate.classicAddress {
                _ = await Task.detached { IOBluetoothDevice(addressString:address)?.openConnection() }.value
            }
            var errors:[String]=[]
            let family=self.catalog.family(name:candidate.name,override:override) ?? candidate.family ?? .oppo
            let kinds=family == .apple ? ["Advertisement"] : family == .oppo ? ["RFCOMM","BLE"] : ["RFCOMM"]
            for kind in kinds {
                guard !Task.isCancelled, self.connectionToken == token, !self.sleeping, !self.manualDisconnect else { return }
                do {
                    let transport:EarbudTransport
                    if family == .apple { transport=AppleAdvertisementTransport(name:candidate.name) }
                    else if kind == "RFCOMM",let address=candidate.classicAddress,let service=family.serviceUUID { transport=try RFCOMMTransport(address:address,serviceUUID:service) }
                    else if family == .oppo { transport=BLETransport(name:candidate.name) }
                    else { throw ProtocolError.unsupported }
                    let s=DeviceSession(transport:transport,name:candidate.name,catalog:self.catalog,overrideID:override,family:family,localHostAddress:IOBluetoothHostController.default()?.addressAsString().split(whereSeparator:{$0 == ":" || $0 == "-"}).compactMap { UInt8($0,radix:16) })
                    self.session=s
                    s.interactive=self.interactive
                    s.onChange = { [weak self,weak s] in
                        guard let self, self.session === s else { return }
                        if let id=self.selectedID, let product=s?.model?.id { self.recognizedProductIDs[id]=product }
                        self.revision += 1; self.maybeNotify(); self.updateConnectionPresence()
                    }
                    s.onClose = { [weak self,weak s] reason in
                        guard let self, self.session === s else { return }
                        self.phase="idle"; self.error=reason; self.revision += 1; self.onStatusChange?(); self.scheduleReconnect()
                    }
                    s.onDiagnostic = { [weak self] line in
                        guard let self else { return }
                        self.history.append(line); if self.history.count > 80 { self.history.removeFirst(self.history.count-80) }
                    }
                    try await s.open()
                    guard !Task.isCancelled, self.connectionToken == token else { s.close(); return }
                    self.phase="ready"; self.retry=0; self.revision += 1; self.onStatusChange?()
                    await s.initialize()
                    return
                } catch {
                    guard !Task.isCancelled, self.connectionToken == token else { return }
                    self.session?.close(); self.session=nil
                    errors.append("\(kind): \(error.localizedDescription)")
                    self.history.append("\(kind) connection: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, self.connectionToken == token else { return }
            self.phase="idle"; self.error=errors.joined(separator:"\n"); self.revision += 1; self.onStatusChange?()
            self.scheduleReconnect()
        }
    }
    private func scheduleReconnect() {
        guard autoReconnect, !manualDisconnect, !sleeping, retryTask == nil else { return }
        retry += 1
        let delay=min(60,pow(2,Double(min(retry,6))))
        retryTask=Task { [weak self] in
            try? await Task.sleep(for:.seconds(delay)); guard !Task.isCancelled, let self else { return }
            await self.rescan()
            guard !Task.isCancelled else { return }
            self.retryTask=nil
            guard self.autoReconnect, !self.sleeping, !self.manualDisconnect else { return }
            if self.candidate?.audioConnected == true { self.connect() }
        }
    }
    func disconnect(audio:Bool=true) {
        manualDisconnect=true; retryTask?.cancel(); retryTask=nil; connectTask?.cancel(); connectTask=nil
        connectionToken=UUID()
        operationTask?.cancel(); operationTask=nil; operationBusy=false
        session?.close(); session=nil; phase="idle"; revision += 1; notice=nil; noiseControlHint=nil; onStatusChange?()
        if audio, let address=candidate?.classicAddress {
            audioCloseTask=Task.detached { _ = IOBluetoothDevice(addressString:address)?.closeConnection() }
        }
    }
    func sleep() { sleeping=true; connectionEventTask?.cancel(); disconnect(audio:false); phase="sleeping"; updateConnectionPresence() }
    func wake() {
        sleeping=false; phase="idle"; Task { await rescan() }
        // Respect a manual disconnect that happened before sleep.
        if !suspendedBeforeSleep { manualDisconnect=false; scheduleReconnect() }
    }
    @ObservationIgnored private var suspendedBeforeSleep=false
    func willSleep() { suspendedBeforeSleep=manualDisconnect; sleep() }
    func stop() { monitorTask?.cancel(); scanTask?.cancel(); connectionEventTask?.cancel(); connectionMonitor.stop(); disconnect(audio:false) }
    func perform(noiseControl:Bool=false,_ operation:@escaping (DeviceSession) async throws -> WriteOutcome) {
        guard !operationBusy, ready, let session else { return }
        operationBusy=true; error=nil; notice=nil; noiseControlHint=nil
        operationTask=Task { [weak self,weak session] in
            guard let self, let session else { return }
            defer { self.operationBusy=false }
            do {
                let result=try await operation(session)
                guard self.session === session, !Task.isCancelled else { return }
                let feedback=result == .confirmed ? L("已从耳机确认","Confirmed by earbuds") : L("请求已发送，设备未提供状态回读","Request sent; device provides no readback")
                if noiseControl {
                    // The confirmed selection already conveys success. Keep any ACK-only
                    // feedback in the reserved noise caption instead of resizing the footer.
                    self.noiseControlHint=result == .confirmed ? nil : feedback
                } else { self.notice=feedback }
            } catch is CancellationError { }
            catch {
                guard self.session === session else { return }
                if noiseControl, let hint=self.noiseWearHint(for:error) {
                    self.noiseControlHint=hint
                } else {
                    self.error=L("操作未确认：","Operation unconfirmed: ")+error.localizedDescription
                }
            }
        }
    }
    // Presentation only: keep the existing request and readback behavior unchanged.
    private func noiseWearHint(for error:Error) -> String? {
        guard let issue=error as? ProtocolError else { return nil }
        switch issue { case .rejected,.readbackMismatch:break; default:return nil }
        // Only describe states whose meanings are known; T500 has a different map.
        guard model?.family == .oppo, model?.isT500 != true,
              let left=state.placement[.left], let right=state.placement[.right],
              [UInt8(1),4,5].contains(left), [UInt8(1),4,5].contains(right) else { return nil }
        return L("请佩戴耳机后使用降噪或通透。","Wear your earbuds to use noise cancellation or transparency.")
    }
    func performRefresh() {
        guard let session, ready, !operationBusy else { return }
        operationBusy=true
        operationTask=Task { [weak self] in await session.refresh(); self?.operationBusy=false }
    }
    func canWrite(_ command:UInt16, reading:UInt16?=nil) -> Bool { !operationBusy && session?.canWrite(command,reading:reading) == true }
    func setNotifications(_ enabled:Bool) {
        if !enabled { notifyLow=false; return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { [weak self] allowed,_ in
            Task { @MainActor in
                self?.notifyLow=allowed
                if !allowed { self?.error=L("通知未获授权，可在系统设置中开启。","Notifications are disabled in System Settings.") }
            }
        }
    }
    private func maybeNotify() {
        guard ready, notifyLow else { return }
        for (slot,value) in state.batteries where Date().timeIntervalSince(value.updatedAt) < 120 {
            if value.percent > lowThreshold+5 || value.charging { alertSlots.remove(slot); continue }
            guard value.percent <= lowThreshold, !alertSlots.contains(slot) else { continue }
            alertSlots.insert(slot)
            let content=UNMutableNotificationContent()
            content.title="HeyBuds"
            let part=slot == .left ? L("左耳","Left earbud") : slot == .right ? L("右耳","Right earbud") : L("充电盒","Case")
            content.body="\(part) · \(value.percent)%"; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"low-\(slot.rawValue)",content:content,trigger:nil))
        }
    }
    func setLogin(_ enabled:Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error=error.localizedDescription }
        refreshLoginStatus()
    }
    func refreshLoginStatus() { launchAtLogin=SMAppService.mainApp.status == .enabled }
    func bluetoothSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
    func exportDiagnostics() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="HeyBuds-diagnostics.json"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        let report:[String:Any]=["app":"HeyBuds", "version":"0.3.1", "os":ProcessInfo.processInfo.operatingSystemVersionString,
            "phase":phase,"transport":transportLabel,"catalogModels":catalog.models.count,
            "productID":state.productID ?? "unknown","modelID":model?.id ?? "unknown",
            "firmware":state.firmware ?? "unknown","queries":state.observedQueries.sorted().map{String(format:"%04X",$0)},
            "events":history,"note":"Addresses, device/host names and raw payloads omitted. No hardware certification implied."]
        do { let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); try data.write(to:url,options:.atomic) }
        catch { self.error=error.localizedDescription }
    }
    func diagnosticSnapshot() -> [String:Any] {
        var value:[String:Any]=["app":"HeyBuds","version":"0.3.1","phase":phase,"transport":transportLabel,
            "timestamp":ISO8601DateFormatter().string(from:Date()),"productID":state.productID ?? "unknown",
            "firmware":state.firmware ?? "unknown","noise":state.noise?.rawValue ?? "unknown",
            "eq":state.eq.map(Int.init) ?? -1,"spatial":state.spatial.map(Int.init) ?? -1,
            "queries":state.observedQueries.sorted().map { String(format:"%04X",$0) },"events":history,
            "bluetoothAuthorization":CBCentralManager.authorization.rawValue,
            "backgroundMode":backgroundMode,"connectionTips":connectionTips,"knownConnectionCount":knownConnectedDevices.count,
            "battery":Dictionary(uniqueKeysWithValues:state.batteries.map { (String($0.key.rawValue),["percent":$0.value.percent,"charging":$0.value.charging ? 1 : 0]) }),
            "note":"Read-only observation; no listening, phone synchronization or sleep/wake certification."]
        if let error { value["error"]=error }
        return value
    }
}
