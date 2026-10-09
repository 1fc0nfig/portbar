import AppKit
import Observation
import Sparkle

/// Finds new portbar releases with Sparkle and installs them. The feed is the appcast on the
/// latest GitHub release. An EdDSA key, not a Developer ID, proves that an update is ours.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = Delegate()

    var checksAutomatically: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    var installsAutomatically: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = installsAutomatically }
    }
    /// A downloaded update that installs when portbar quits. `installNow()` installs it at once.
    private(set) var readyVersion: String?
    @ObservationIgnored private var installReady: (() -> Void)?

    /// False in a build from `swift build`, which has no feed and no key in its Info.plist.
    var isAvailable: Bool { controller != nil }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    init() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = bundled
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
            : nil
        checksAutomatically = controller?.updater.automaticallyChecksForUpdates ?? false
        installsAutomatically = controller?.updater.automaticallyDownloadsUpdates ?? false
        delegate.onReady = { [weak self] version, install in
            self?.readyVersion = version
            self?.installReady = install
        }
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Quits, installs the downloaded update, and starts the new version.
    func installNow() {
        installReady?()
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        var onReady: ((String, @escaping () -> Void) -> Void)?

        // portbar runs until you quit it, so an update that waits for quit can wait for days.
        // Keep the install block, so the panel can offer a restart.
        func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                     immediateInstallationBlock: @escaping () -> Void) -> Bool {
            let version = item.displayVersionString
            MainActor.assumeIsolated { onReady?(version, immediateInstallationBlock) }
            return true
        }
    }
}
