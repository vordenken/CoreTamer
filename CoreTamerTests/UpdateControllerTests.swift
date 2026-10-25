import AppKit
import Foundation
import SwiftUI
import Testing

@testable import CoreTamer

final class FakeUpdater: Updater {
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var scheduledUpdateHandler: ((String?) -> Void)?
    var checks = 0
    var resets = 0

    init(checks: Bool = true, downloads: Bool = false) {
        automaticallyChecksForUpdates = checks
        automaticallyDownloadsUpdates = downloads
    }

    func checkForUpdates() { checks += 1 }
    func resetUpdateCycleAfterShortDelay() { resets += 1 }
}

@Suite(.serialized)
@MainActor
struct UpdateControllerTests {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "CoreTamerUpdateTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func mirrorsUpdaterAndStoredBetaPreference() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UpdateController.betaDefaultsKey)
        let controller = UpdateController(
            updater: FakeUpdater(checks: true, downloads: true), defaults: defaults)
        #expect(controller.automaticallyChecks)
        #expect(controller.automaticallyDownloads)
        #expect(controller.betaUpdates)
    }

    @Test func disablingChecksAlsoDisablesDownloads() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = FakeUpdater(checks: true, downloads: true)
        let controller = UpdateController(updater: updater, defaults: defaults)
        controller.automaticallyChecks = false
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(!updater.automaticallyDownloadsUpdates)
        #expect(!controller.automaticallyDownloads)
    }

    @Test func enablingDownloadsAlsoEnablesChecks() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = FakeUpdater(checks: false, downloads: false)
        let controller = UpdateController(updater: updater, defaults: defaults)
        controller.automaticallyDownloads = true
        #expect(updater.automaticallyChecksForUpdates)
        #expect(updater.automaticallyDownloadsUpdates)
        #expect(controller.automaticallyChecks)
    }

    @Test func betaToggleSelectsChannelAndRestartsUpdateCycle() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = FakeUpdater()
        let controller = UpdateController(updater: updater, defaults: defaults)
        #expect(UpdateController.allowedChannels(defaults: defaults).isEmpty)
        controller.betaUpdates = true
        #expect(defaults.bool(forKey: UpdateController.betaDefaultsKey))
        #expect(UpdateController.allowedChannels(defaults: defaults) == ["beta"])
        #expect(updater.resets == 1)
        controller.betaUpdates = false
        #expect(UpdateController.allowedChannels(defaults: defaults).isEmpty)
        #expect(updater.resets == 2)
    }

    @Test func checkNowForwardsToUpdater() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = FakeUpdater()
        UpdateController(updater: updater, defaults: defaults).checkForUpdates()
        #expect(updater.checks == 1)
    }

    @Test func scheduledUpdateReminderIsShownAndClearedAfterSparkleHandlesIt() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = FakeUpdater()
        let controller = UpdateController(updater: updater, defaults: defaults)
        var indicatorChanges: [Bool] = []
        controller.onAvailabilityChange = { indicatorChanges.append($0) }

        updater.scheduledUpdateHandler?("1.0.1")
        #expect(controller.availableUpdateVersion == "1.0.1")
        #expect(indicatorChanges == [true])
        controller.checkForUpdates()
        #expect(updater.checks == 1)
        #expect(controller.availableUpdateVersion == "1.0.1")

        updater.scheduledUpdateHandler?(nil)
        #expect(controller.availableUpdateVersion == nil)
        #expect(indicatorChanges == [true, false])
    }

    // Never started, so no network access or update UI happens in tests.
    @Test func sparkleUpdaterCanBeCreatedWithoutStarting() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sparkle = SparkleUpdater(defaults: defaults, startingUpdater: false)
        let controller = UpdateController(updater: sparkle, defaults: defaults)
        #expect(controller.automaticallyChecks == sparkle.automaticallyChecksForUpdates)
        #expect(controller.automaticallyDownloads == sparkle.automaticallyDownloadsUpdates)
        #expect(sparkle.supportsGentleScheduledUpdateReminders)
    }

    @Test func settingsShowUpdateControlsWithinFixedSize() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let updater = FakeUpdater()
        let updates = UpdateController(updater: updater, defaults: defaults)
        let host = NSHostingView(rootView: UpdateSettings(updates: updates).font(.callout))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= TamerView.size.width - 28)
        updates.betaUpdates = true
        host.layoutSubtreeIfNeeded()
        #expect(updater.resets == 1)
    }
}
