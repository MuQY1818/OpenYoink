import AppKit
import OSLog
import Sparkle

///   "The Installer XPC Service is required for Sandboxed applications."

///   Downloader XPC Service."）

@MainActor
@Observable
final class UpdateController: NSObject {

    static let manualDownloadURL = URL(
        string: "https://github.com/MuQY1818/OpenYoink/releases/latest"
    )!

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case error(String)
    }

    private(set) var status: Status = .idle

    private let settings: SettingsStore
    private let logger = Log.make(category: "Update")

    private let updaterController: SPUStandardUpdaterController
    private let delegateBridge = DelegateBridge()
    private var didStart = false

    init(settings: SettingsStore) {
        self.settings = settings
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegateBridge,
            userDriverDelegate: nil
        )
        super.init()
        delegateBridge.owner = self
    }

    /// Read on demand; the menu item stays enabled, since Sparkle ignores a
    /// repeated request while checking.
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    /// Starts the updater (idempotent), whether or not automatic checks are on:
    /// manual checks need it too, the setting only controls scheduling. The
    /// setting is applied first; it is our own settings page's source of truth,
    /// not an override of a user preference.
    func start() {
        guard !didStart else { return }
        didStart = true
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = settings.autoUpdateCheckEnabled
        do {
            try updater.start()
            logger.info("Sparkle updater started (automaticChecks: \(updater.automaticallyChecksForUpdates))")
        } catch {
            logger.error("Sparkle updater failed to start: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    func applySettings() {
        guard didStart else { return }
        let updater = updaterController.updater
        if updater.automaticallyChecksForUpdates != settings.autoUpdateCheckEnabled {
            updater.automaticallyChecksForUpdates = settings.autoUpdateCheckEnabled
        }
    }

    /// The "Check for Updates…" menu item; works with automatic checks off.
    func checkForUpdates() {
        start()
        status = .checking
        updaterController.checkForUpdates(nil)
    }

    func openManualDownloadPage() {
        NSWorkspace.shared.open(Self.manualDownloadURL)
    }

    fileprivate func noteUpdateNotFound() {
        status = .upToDate
    }

    /// "No update available" also arrives as an abort (SUSparkleErrorDomain,
    /// SUNoUpdateError = 1001, see Sparkle/SUErrors.h). It isn't an error, so
    /// it counts as up to date (Sparkle doesn't log it either).
    private static func isNoUpdateError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
    }

    fileprivate func noteUpdateAborted(_ error: any Error) {
        guard !Self.isNoUpdateError(error) else {
            status = .upToDate
            return
        }
        status = .error(error.localizedDescription)
        logger.error("Sparkle update aborted: \(error.localizedDescription, privacy: .public)")
    }

    /// A check cycle finished (background checks included). An error is
    /// recorded; "no update" was handled by `noteUpdateNotFound`; with an update
    /// Sparkle owns the UI, so `checking` returns to idle.
    fileprivate func noteUpdateCycleFinished(error: (any Error)?) {
        if let error, !Self.isNoUpdateError(error) {
            status = .error(error.localizedDescription)
            logger.error("Sparkle update cycle failed: \(error.localizedDescription, privacy: .public)")
        } else if error != nil {
            status = .upToDate
        } else if status == .checking {
            status = .idle
        }
    }
}

private final class DelegateBridge: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdateController?

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in self.owner?.noteUpdateNotFound() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in self.owner?.noteUpdateAborted(error) }
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        Task { @MainActor in self.owner?.noteUpdateCycleFinished(error: error) }
    }
}
