import AppKit
import Observation
import Sparkle

/// Created on demand so opening HeyBuds never starts a network update check.
@MainActor @Observable final class NativeUpdater {
    private(set) var canCheckForUpdates=true
    @ObservationIgnored private var controller:SPUStandardUpdaterController?
    @ObservationIgnored private var observation:NSKeyValueObservation?

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSWorkspace.shared.open(AppIdentity.releasesURL)
            return
        }
        if controller == nil {
            let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
            self.controller=controller
            observation=controller.updater.observe(\.canCheckForUpdates,options:[.initial,.new]) { [weak self] updater,_ in
                let available=updater.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates=available }
            }
            controller.startUpdater()
        }
        NSApp.activate(ignoringOtherApps:true)
        controller?.checkForUpdates(nil)
    }
}
