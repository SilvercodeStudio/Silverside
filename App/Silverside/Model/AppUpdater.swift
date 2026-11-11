import AppKit
import Sparkle

/// Updates through Sparkle, in a build that `make dist` made (`SilversideArchive` in Info.plist):
/// a build from source never replaces itself with a released one. Info.plist has the feed and its
/// key. The app decides when an update that is ready may relaunch it (`AppModel.postponeRelaunch`).
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    /// Nil in a build from source.
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Returns true to hold the relaunch, and then calls its argument to install.
    @ObservationIgnored private let postponeRelaunch: (@escaping () -> Void) -> Bool

    /// False in a build from source, which has no Check for Updates.
    var isAvailable: Bool { controller != nil }
    /// False while Sparkle already checks, downloads, or shows an update.
    private(set) var canCheckForUpdates = false
    /// Sparkle asks at the second launch whether to check by itself; Settings › General changes it.
    /// Sparkle keeps it in the app's defaults.
    var checksAutomatically = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != checksAutomatically
            else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init(postponeRelaunch: @escaping (@escaping () -> Void) -> Bool) {
        self.postponeRelaunch = postponeRelaunch
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SilversideArchive") as? Bool == true else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        // Sparkle changes these on the main thread.
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.checksAutomatically = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeRelaunch(installHandler)
    }
}
