import Foundation
import Observation
import Sparkle

/// The part of Sparkle's updater that CoreTamer's settings use; tests substitute a fake.
protocol Updater: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var scheduledUpdateHandler: ((String?) -> Void)? { get set }
    func checkForUpdates()
    func resetUpdateCycleAfterShortDelay()
}

/// Update preferences shown in the settings panel, mirrored from the updater so SwiftUI observes them.
@Observable
final class UpdateController {
    static let betaDefaultsKey = "BetaUpdatesEnabled"

    @ObservationIgnored private let updater: any Updater
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onAvailabilityChange: ((Bool) -> Void)?

    var availableUpdateVersion: String? {
        didSet {
            guard oldValue != availableUpdateVersion else { return }
            onAvailabilityChange?(availableUpdateVersion != nil)
        }
    }

    var automaticallyChecks: Bool {
        didSet {
            updater.automaticallyChecksForUpdates = automaticallyChecks
            // Downloading without checking is impossible, so turning checks off also stops downloads.
            if !automaticallyChecks && automaticallyDownloads { automaticallyDownloads = false }
        }
    }

    var automaticallyDownloads: Bool {
        didSet {
            if automaticallyDownloads && !automaticallyChecks { automaticallyChecks = true }
            updater.automaticallyDownloadsUpdates = automaticallyDownloads
        }
    }

    var betaUpdates: Bool {
        didSet {
            defaults.set(betaUpdates, forKey: Self.betaDefaultsKey)
            updater.resetUpdateCycleAfterShortDelay()
        }
    }

    init(updater: any Updater, defaults: UserDefaults = .standard) {
        self.updater = updater
        self.defaults = defaults
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        betaUpdates = defaults.bool(forKey: Self.betaDefaultsKey)
        updater.scheduledUpdateHandler = { [weak self] version in
            self?.availableUpdateVersion = version
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    static func allowedChannels(defaults: UserDefaults) -> Set<String> {
        defaults.bool(forKey: betaDefaultsKey) ? ["beta"] : []
    }
}

/// Sparkle-backed updater. The feed URL and public EdDSA key come from Info.plist.
final class SparkleUpdater: NSObject, Updater, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?

    var scheduledUpdateHandler: ((String?) -> Void)?

    init(defaults: UserDefaults = .standard, startingUpdater: Bool = true) {
        self.defaults = defaults
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: self, userDriverDelegate: self)
    }

    private var updater: SPUUpdater? { controller?.updater }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func startUpdater() {
        controller?.startUpdater()
    }

    func resetUpdateCycleAfterShortDelay() {
        updater?.resetUpdateCycleAfterShortDelay()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateController.allowedChannels(defaults: defaults)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        scheduledUpdateHandler?(handleShowingUpdate ? nil : update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        scheduledUpdateHandler?(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        scheduledUpdateHandler?(nil)
    }
}
