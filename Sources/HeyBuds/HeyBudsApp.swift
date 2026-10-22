import SwiftUI
import AppKit
import UserNotifications
import HeyBudsProtocol
import HeyBudsBluetooth

@main struct HeyBudsApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body:some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSPopoverDelegate,UNUserNotificationCenterDelegate {
    private var model:AppModel!
    private var statusItem:NSStatusItem!
    private let popover=NSPopover()
    private var eventMonitor:Any?
    private var localMonitor:Any?
    private var observers:[NSObjectProtocol]=[]
    #if DEBUG
    private var previewWindow:NSWindow?
    #endif
    private var launchTask:Task<Void,Never>?
    private var showWhenReady=false
    private let connectionToast=ConnectionToastController()
    private var announcementTask:Task<Void,Never>?
    private var pendingAnnouncementID:String?
    private var explicitAccess=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        let otherControllers=[Bundle.main.bundleIdentifier ?? AppIdentity.bundleID,AppIdentity.legacyBundleID]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier:$0) }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard otherControllers.isEmpty else {
            if otherControllers.contains(where:{$0.bundleIdentifier == AppIdentity.legacyBundleID}) {
                let alert=NSAlert();alert.messageText=AppIdentity.name
                alert.informativeText="请先退出旧版 EncoBar，再打开 HeyBuds。 / Quit the legacy EncoBar before opening HeyBuds."
                alert.runModal()
            }
            NSApp.terminate(nil);return
        }
        AppIdentity.migrateLegacyPreferences()
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.target=self; statusItem.button?.action=#selector(togglePanel)
        let image=NSImage(systemSymbolName:EarbudIcon.enclosure,accessibilityDescription:AppIdentity.name)
        image?.isTemplate=true; statusItem.button?.image=image
        showWhenReady=CommandLine.arguments.contains("--show")
        launchTask=Task { [weak self] in
            do {
                let catalog=try await Task.detached(priority:.userInitiated) { try ModelCatalog() }.value
                guard !Task.isCancelled else { return }
                self?.finishLaunching(catalog:catalog)
            } catch {
                guard !Task.isCancelled else { return }
                let alert=NSAlert(); alert.messageText=AppIdentity.name; alert.informativeText=error.localizedDescription
                alert.runModal(); NSApp.terminate(nil)
            }
        }
    }
    private func preparePanel() {
        guard popover.contentViewController == nil else { return }
        popover.behavior = .applicationDefined; popover.animates=true; popover.delegate=self
        let hosting=NSHostingController(rootView:PanelView(app:model,onHeightChange: { [weak self] height in
            guard let self else { return }
            let size=NSSize(width:360,height:height)
            if abs(self.popover.contentSize.height-height) > 0.5 { self.popover.contentSize=size }
        }))
        hosting.sizingOptions=[.preferredContentSize]
        popover.contentViewController=hosting
    }
    private func finishLaunching(catalog:ModelCatalog) {
        model=AppModel(catalog:catalog)
        model.onStatusChange = { [weak self] in self?.updateStatus() }
        model.onDeviceConnected = { [weak self] device in self?.announceConnection(device) }
        model.onPreviewConnectionTip = { [weak self] in self?.previewConnectionTip() }
        connectionToast.onDismiss = { [weak self] in self?.explicitAccess=false; self?.updateStatus() }
        UNUserNotificationCenter.current().delegate=self
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.willSleep() }
        })
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.wake() }
        })
        updateStatus(); model.start()
        if showWhenReady { showPanel() }
        #if DEBUG
        // Developer-only native window for visual QA of a menu-bar accessory app.
        if CommandLine.arguments.contains("--window-preview") {
            NSApp.setActivationPolicy(.regular)
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:620),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="HeyBuds · Preview"; window.isReleasedWhenClosed=false
            if CommandLine.arguments.contains("--tip-preview") {
                window.setContentSize(ConnectionTipView.size)
                window.contentViewController=NSHostingController(rootView:ConnectionTipPreviewView(app:model))
            } else {
                window.contentViewController=NSHostingController(rootView:PanelView(app:model,onHeightChange: { [weak window] height in
                    window?.setContentSize(NSSize(width:360,height:height))
                }))
            }
            previewWindow=window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        }
        if let index=CommandLine.arguments.firstIndex(of:"--diagnose"), index+1 < CommandLine.arguments.count {
            let output=URL(fileURLWithPath:CommandLine.arguments[index+1])
            Task { [weak self] in
                for _ in 0..<40 {
                    try? await Task.sleep(for:.seconds(1))
                    guard let self else { return }
                    if self.model.ready, self.model.state.observedQueries.count >= 7 { break }
                }
                guard let self else { return }
                try? await Task.sleep(for:.milliseconds(500))
                if CommandLine.arguments.contains("--exercise"), self.model.ready, let session=self.model.session {
                    var checks:[[String:Any]]=[]
                    for mode in [HeyBudsProtocol.NoiseMode.transparency,.deep] {
                        do {
                            let outcome=try await session.setNoise(mode)
                            checks.append(["feature":"noise","requested":mode.rawValue,"outcome":outcome.rawValue,"observed":session.state.noise?.rawValue ?? "unknown"])
                        } catch { checks.append(["feature":"noise","requested":mode.rawValue,"error":error.localizedDescription]) }
                    }
                    if let preset=self.model.presets.first(where:{$0.id != self.model.state.eq}) {
                        do {
                            let outcome=try await session.setEQ(preset.id)
                            checks.append(["feature":"eq","requested":Int(preset.id),"outcome":outcome.rawValue,"observed":session.state.eq.map(Int.init) ?? -1])
                        } catch { checks.append(["feature":"eq","requested":Int(preset.id),"error":error.localizedDescription]) }
                    }
                    do {
                        var snapshot=self.diagnosticSnapshot(); snapshot["checks"]=checks
                        snapshot["note"]="Authorized hardware write/readback checks. No automatic restore requested. Listening, phone synchronization and sleep/wake remain unverified."
                        let data=try JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys]); try data.write(to:output,options:.atomic)
                    } catch { self.model.error=error.localizedDescription }
                } else {
                do { let data=try JSONSerialization.data(withJSONObject:self.diagnosticSnapshot(),options:[.prettyPrinted,.sortedKeys]); try data.write(to:output,options:.atomic) }
                catch { self.model.error=error.localizedDescription }
                }
                if let index=CommandLine.arguments.firstIndex(of:"--snapshot"), index+1 < CommandLine.arguments.count {
                    self.snapshot(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
                }
                if let index=CommandLine.arguments.firstIndex(of:"--tip-snapshot"), index+1 < CommandLine.arguments.count {
                    self.connectionToast.snapshot(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
                }
            }
        }
        #endif
    }
    #if DEBUG
    private func snapshot(to url:URL) {
        guard let view=previewWindow?.contentViewController?.view ?? popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        if let data=bitmap.representation(using:.png,properties:[:]) { try? data.write(to:url,options:.atomic) }
    }
    private func diagnosticSnapshot() -> [String:Any] {
        var value=model.diagnosticSnapshot()
        value["statusItemVisible"]=statusItem.isVisible
        value["connectionTipVisible"]=connectionToast.isShown
        value["connectionTipPresentationCount"]=connectionToast.presentationCount
        return value
    }
    #endif
    private func updateStatus() {
        guard let button=statusItem?.button, let model else { return }
        let connected=model.knownConnectedDevices
        if let pendingAnnouncementID, !connected.contains(where:{$0.id == pendingAnnouncementID}) {
            announcementTask?.cancel(); announcementTask=nil; self.pendingAnnouncementID=nil
        }
        if connectionToast.isShown, !connectionToast.preview,
           (!model.connectionTips || !connected.contains(where:{$0.id == connectionToast.deviceID})) { connectionToast.dismiss(animated:false) }
        statusItem.isVisible=ConnectionPresence.showsStatusItem(background:model.backgroundMode,hasConnection:!connected.isEmpty,
            explicitAccess:explicitAccess || popover.isShown || connectionToast.isShown)
        let image=NSImage(systemSymbolName:!connected.isEmpty || model.ready ? EarbudIcon.pair : EarbudIcon.enclosure,accessibilityDescription:"HeyBuds")
        image?.isTemplate=true; button.image=image
        button.appearsDisabled = connected.isEmpty && !model.ready
        if model.menuBattery, model.ready {
            button.title=model.state.batteries.sorted(by:{$0.key.rawValue < $1.key.rawValue}).map { "\($0.value.percent)%" }.joined(separator:" ")
            button.imagePosition = .imageLeading
        } else { button.title="" }
        button.toolTip="HeyBuds · \(model.status)"
        button.setAccessibilityLabel("HeyBuds · \(model.status)")
        // Explicit local QA mode: expose the real AppKit visibility, without any
        // device identifiers, so hidden/reopen behavior can be verified safely.
        #if DEBUG
        if CommandLine.arguments.contains("--live-diagnose"),
           let index=CommandLine.arguments.firstIndex(of:"--diagnose"), index+1 < CommandLine.arguments.count,
           let data=try? JSONSerialization.data(withJSONObject:diagnosticSnapshot(),options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]),options:.atomic)
        }
        #endif
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        showPanel()
    }
    private func showPanel() {
        guard model != nil else { showWhenReady=true; return }
        showWhenReady=false
        announcementTask?.cancel(); announcementTask=nil; pendingAnnouncementID=nil
        explicitAccess=true; updateStatus()
        connectionToast.dismiss(animated:false,notify:false)
        guard !popover.isShown else { return }
        DispatchQueue.main.async { [weak self] in self?.presentPanel() }
    }
    private func presentPanel() {
        guard let button=statusItem.button else { return }
        guard !popover.isShown else { return }
        preparePanel()
        Task { await model.rescan() }; model.interactive=true
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey()
        eventMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in self?.popover.performClose(nil) }
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.popover.performClose(nil); return nil }; return event
        }
    }
    func popoverDidClose(_ notification:Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor=nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor=nil
        model.interactive=false; explicitAccess=false; updateStatus()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        showPanel(); return false
    }
    private var statusAnchor:NSRect? {
        guard let button=statusItem.button, let window=button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds,to:nil))
    }
    private func announceConnection(_ device:DeviceCandidate) {
        guard model.connectionTips else { return }
        announcementTask?.cancel(); pendingAnnouncementID=device.id
        announcementTask=Task { [weak self] in
            guard let self else { return }
            // Give the initial battery response a short head start; the visible card
            // continues observing current-session data if the response arrives later.
            for _ in 0..<12 {
                try? await Task.sleep(for:.milliseconds(200))
                guard !Task.isCancelled, self.model.connectionTips,
                      self.model.knownConnectedDevices.contains(where:{$0.id == device.id}) else { return }
                if self.model.ready, self.model.selectedID == device.id, !self.model.state.batteries.isEmpty { break }
            }
            self.pendingAnnouncementID=nil
            guard !self.popover.isShown else { return }
            self.connectionToast.show(app:self.model,device:device,preview:false,anchor:self.statusAnchor,onOpen:{ [weak self] in self?.showPanel() })
            self.updateStatus()
        }
    }
    private func previewConnectionTip() {
        announcementTask?.cancel(); pendingAnnouncementID=nil
        let device=model.knownConnectedDevices.first(where:{$0.id == model.selectedID}) ?? model.knownConnectedDevices.first ?? model.candidate
        connectionToast.show(app:model,device:device,preview:true,anchor:statusAnchor,onOpen:{ [weak self] in self?.showPanel() })
        popover.performClose(nil); updateStatus()
    }
    func applicationWillTerminate(_ notification:Notification) {
        launchTask?.cancel()
        announcementTask?.cancel(); connectionToast.dismiss(animated:false,notify:false)
        model?.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.sound])
    }
}
