import AppKit
import Observation
import Sparkle

/// Created on demand so opening HeyBuds never starts a network update check.
@MainActor @Observable final class NativeUpdater:NSObject,@preconcurrency SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates=true
    @ObservationIgnored var onWillPresentUI:(() -> Void)?
    @ObservationIgnored private var controller:SPUStandardUpdaterController?
    @ObservationIgnored private var observation:NSKeyValueObservation?

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSWorkspace.shared.open(AppIdentity.releasesURL)
            return
        }
        onWillPresentUI?()
        if controller == nil {
            let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:self)
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

    func standardUserDriverWillShowModalAlert() {
        onWillPresentUI?()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate:Bool,forUpdate update:SUAppcastItem,state:SPUUserUpdateState) {
        if handleShowingUpdate { onWillPresentUI?() }
    }
}
