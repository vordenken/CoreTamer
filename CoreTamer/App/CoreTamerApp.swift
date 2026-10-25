import AppKit
import CoreTamerCore
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import os

@main
struct CoreTamerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let model = AppModel()
    private var updates: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
            // The shared scheme sets this while the app hosts unit tests: tests create their own
            // models, so the host must not show a menu bar item or re-apply the user's saved limits.
            if ProcessInfo.processInfo.environment["CORE_TAMER_UNIT_TESTING"] == "1" { return }
        #endif
        let sparkleUpdater = SparkleUpdater(startingUpdater: false)
        let updates = UpdateController(updater: sparkleUpdater)
        self.updates = updates
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        updates.onAvailabilityChange = { [weak self] updateAvailable in
            self?.updateMenuBarImage(updateAvailable: updateAvailable)
        }
        updateMenuBarImage(updateAvailable: updates.availableUpdateVersion != nil)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: TamerView.size.width, height: TamerView.size.height)
        popover.contentViewController = NSHostingController(
            rootView: TamerView(model: model, updates: updates))
        model.start()
        sparkleUpdater.startUpdater()
        #if DEBUG
            // Simulates a gentle reminder so the banner and menu bar dot can be reviewed
            // without publishing a newer release to the appcast.
            if CommandLine.arguments.contains("--preview-update-reminder") {
                updates.availableUpdateVersion = "9.9.9"
            }
        #endif
        // A menu-bar-only app shows no window on launch, so the first launch opens the
        // popover to make the app and its welcome options discoverable.
        if model.showsWelcome || CommandLine.arguments.contains("--show") { toggle() }
    }

    private func updateMenuBarImage(updateAvailable: Bool) {
        item?.button?.image = MenuBarGlyph.make(updateAvailable: updateAvailable)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item?.button {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        if !popover.isShown { toggle() }
        return false
    }
}

@Observable
final class AppModel: NSObject {
    var processes: [ProcessSnapshot] = []
    var cpu: [ProcessIdentity: Double] = [:]
    var limits: [ProcessIdentity: Double] = [:]
    var apps: [RunningApp] = []
    var query = ""
    var sort = ProcessSort.cpu
    var selected: ProcessIdentity?
    var proposedLimit = 50.0
    var proposedIncludesHelpers = false
    private(set) var groupLimits: Set<ProcessIdentity> = []
    var paused = false
    var error: String?
    var settingsVisible = false
    private(set) var isListHovered = false
    var showBackground: Bool {
        didSet { defaults.set(showBackground, forKey: "showBackground") }
    }
    var groupByType: Bool {
        didSet { defaults.set(groupByType, forKey: "groupByType") }
    }
    var pauseListOnHover: Bool {
        didSet {
            defaults.set(pauseListOnHover, forKey: "pauseListOnHover")
            if !pauseListOnHover { setListHovered(false) }
        }
    }
    var updateSpeed: UpdateSpeed {
        didSet {
            defaults.set(updateSpeed.rawValue, forKey: "updateSpeed")
            if timer != nil { scheduleTimer() }
        }
    }
    var restoreLimits: Bool {
        didSet {
            defaults.set(restoreLimits, forKey: "restoreLimits")
            if !restoreLimits { savedLimits = [:] }
            persistRules()
        }
    }
    private(set) var showsWelcome: Bool
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    private let defaults: UserDefaults
    private let controllerURL: URL
    private let logger = Logger(subsystem: "com.vd.CoreTamer", category: "controller")
    private var sampler = CPUSampler()
    private var displaySmoother = CPUDisplaySmoother()
    private var listOrder = ProcessListOrder()
    private var controllers: [ProcessIdentity: Limiter] = [:]
    private var savedLimits: [String: Double] = [:]
    private var savedGroupLimits: Set<String> = []
    private var restorationAttempts: Set<ProcessIdentity> = []
    private var timer: Timer?

    init(
        defaults: UserDefaults = .standard,
        controllerURL: URL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/CoreTamerController")
    ) {
        self.defaults = defaults
        self.controllerURL = controllerURL
        showBackground = defaults.bool(forKey: "showBackground")
        restoreLimits = defaults.bool(forKey: "restoreLimits")
        groupByType = defaults.object(forKey: "groupByType") as? Bool ?? true
        pauseListOnHover = defaults.bool(forKey: "pauseListOnHover")
        updateSpeed = defaults.string(forKey: "updateSpeed").flatMap(UpdateSpeed.init) ?? .normal
        showsWelcome = !defaults.bool(forKey: "hasCompletedOnboarding")
        super.init()
        savedGroupLimits = Set(defaults.stringArray(forKey: "savedGroupLimits") ?? [])
        if let data = defaults.data(forKey: "savedLimits") {
            do {
                savedLimits = try JSONDecoder().decode([String: Double].self, from: data)
            } catch { present(error) }
        }
    }

    var sections: [ProcessSection] {
        let ranks = Dictionary(uniqueKeysWithValues: listOrder.ids.enumerated().map { ($1, $0) })
        return groupedProcesses(
            processes, apps: apps, query: query, showBackground: showBackground,
            groupByType: groupByType, sort: sort, cpu: cpu, limits: limits
        ).ranked(by: ranks)
    }

    var isListPausedByHover: Bool { pauseListOnHover && isListHovered }

    func toggleSelection(id: ProcessIdentity) {
        if selected == id { deselect() } else { select(id: id) }
    }

    func sort(by column: ProcessSortColumn) {
        setSort(sort.selecting(column))
    }

    func setSort(_ sort: ProcessSort) {
        self.sort = sort
        updateListOrder(at: ProcessInfo.processInfo.systemUptime, force: true)
    }

    func setListHovered(_ hovered: Bool) {
        isListHovered = hovered && pauseListOnHover
        if !isListHovered { updateListOrder(at: ProcessInfo.processInfo.systemUptime) }
    }

    func deselect() { selected = nil }

    /// Selects by row ID, as the native table reports it.
    func select(id: ProcessIdentity?) {
        if let process = processes.first(where: { $0.id == id }) {
            select(process)
        } else {
            deselect()
        }
    }

    func updateListOrder(at time: TimeInterval, force: Bool = false) {
        let sorted = groupedProcesses(
            processes, apps: apps, query: "", showBackground: true, groupByType: groupByType,
            sort: sort, cpu: cpu, limits: limits)
        // Without a hover pause every refresh re-sorts, like Task Manager; grouping keeps moves local.
        listOrder.update(
            sorted.flatMap(\.allIDs), at: time, frozen: isListPausedByHover, force: force,
            interval: 0)
    }

    var selectedProcess: ProcessSnapshot? { processes.first { $0.id == selected } }
    var inspectedProcess: ProcessSnapshot? { settingsVisible ? nil : selectedProcess }
    var maximumLimit: Double { Double(ProcessInfo.processInfo.activeProcessorCount * 100) }

    /// Uses the full grouping, so a helper search cannot change the inspector's target.
    func appGroup(containing id: ProcessIdentity) -> ProcessRow? {
        groupedProcesses(
            processes, apps: apps, query: "", showBackground: true, groupByType: false,
            sort: .name, cpu: [:]
        ).flatMap(\.rows).first { row in
            (row.id == id || row.helpers?.contains(where: { $0.id == id }) == true)
                && (row.helpers != nil || apps.contains(where: { $0.pid == row.pid })
                    || groupLimits.contains(row.id))
        }
    }

    func start() {
        refresh()
        scheduleTimer()
    }

    /// Limits are maintained every two seconds even while the display is paused.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: updateSpeed.interval ?? 2, target: self, selector: #selector(tick),
            userInfo: nil, repeats: true)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// Hover pause and the Paused speed freeze values and order; limits are still maintained.
    var updatesDisplay: Bool { updateSpeed != .paused && !isListPausedByHover }

    @objc private func tick() { refresh(updatingDisplay: updatesDisplay) }

    /// Reads all processes and maintains limits; `updatingDisplay: false` keeps the list frozen.
    func refresh(updatingDisplay: Bool = true) {
        do {
            let current = try ProcessSnapshot.all()
            let time = ProcessInfo.processInfo.systemUptime
            let live = Set(current.map(\.id))
            let runningApps = NSWorkspace.shared.runningApplications.map {
                RunningApp(
                    pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path,
                    regular: $0.activationPolicy == .regular)
            }
            if updatingDisplay {
                processes = current
                cpu = displaySmoother.sample(sampler.sample(current, at: time), at: time)
                apps = runningApps
                if let selected, !live.contains(selected) { self.selected = nil }
            }
            restorationAttempts.formIntersection(live)
            for id in Array(limits.keys) where !live.contains(id) {
                if let detail = controllers.removeValue(forKey: id)?.stop() { present(detail) }
                limits.removeValue(forKey: id)
                groupLimits.remove(id)
            }
            for (id, controller) in controllers where !controller.isRunning {
                if let detail = controller.failure() { present(detail) }
                controllers.removeValue(forKey: id)
                limits.removeValue(forKey: id)
                groupLimits.remove(id)
            }
            synchronizeGroups(processes: current, apps: runningApps)
            if restoreLimits && !paused {
                for process in current where process.canControl && limits[process.id] == nil {
                    if let value = savedLimits[process.path],
                        process.path.contains(".app/Contents/MacOS/"),
                        !restorationAttempts.contains(process.id)
                    {
                        restorationAttempts.insert(process.id)
                        apply(
                            process, percent: value, save: false,
                            includesHelpers: savedGroupLimits.contains(process.path))
                    }
                }
            }
            if updatingDisplay { updateListOrder(at: time) }
        } catch { present(error) }
    }

    func select(_ process: ProcessSnapshot) {
        selected = process.id
        proposedLimit = limits[process.id] ?? 50
        proposedIncludesHelpers = groupLimits.contains(process.id)
    }

    func groupMembers(
        of id: ProcessIdentity, processes: [ProcessSnapshot], apps: [RunningApp]
    ) -> [ProcessSnapshot] {
        let rows = groupedProcesses(
            processes, apps: apps, query: "", showBackground: true, groupByType: false,
            sort: .name, cpu: [:]
        ).flatMap(\.rows)
        guard let row = rows.first(where: { $0.id == id }) else {
            return processes.filter { $0.id == id }
        }
        return [row.process] + (row.helpers ?? []).map(\.process)
    }

    /// Group members the shared budget can control. Protected, foreign or externally stopped helpers
    /// are skipped so one of them cannot end the whole app limit; current members stay tracked
    /// because the controller itself stops them.
    func limitableMembers(
        of id: ProcessIdentity, processes: [ProcessSnapshot], apps: [RunningApp],
        current: Set<ProcessIdentity> = []
    ) -> [ProcessSnapshot] {
        groupMembers(of: id, processes: processes, apps: apps).filter {
            $0.id == id || $0.canControl || current.contains($0.id)
        }
    }

    func synchronizeGroups(processes: [ProcessSnapshot], apps: [RunningApp]) {
        for id in Array(groupLimits) {
            guard let controller = controllers[id] else { continue }
            do {
                let members = limitableMembers(
                    of: id, processes: processes, apps: apps, current: controller.memberIDs)
                try validateOverlap(members: members, replacing: id)
                try controller.updateMembers(members)
            } catch {
                if let detail = controllers.removeValue(forKey: id)?.stop() { present(detail) }
                limits.removeValue(forKey: id)
                groupLimits.remove(id)
                present(error)
            }
        }
    }

    private func validateOverlap(members: [ProcessSnapshot], replacing id: ProcessIdentity) throws {
        let ids = Set(members.map(\.id))
        for (other, controller) in controllers where other != id {
            if !controller.memberIDs.isDisjoint(with: ids) {
                throw ProcessFailure(
                    operation:
                        String(
                            localized:
                                "This process already belongs to another limit. Remove that limit first"
                        ),
                    code: EBUSY)
            }
        }
        if limits.keys.contains(where: { $0 != id && ids.contains($0) }) {
            throw ProcessFailure(
                operation:
                    String(
                        localized:
                            "A helper already has an individual limit. Remove it before applying a group limit"
                    ),
                code: EBUSY)
        }
        for group in groupLimits where group != id {
            let covered = Set(groupMembers(of: group, processes: processes, apps: apps).map(\.id))
            if !ids.isDisjoint(with: covered) {
                throw ProcessFailure(
                    operation:
                        String(
                            localized:
                                "This process is covered by a shared app limit. Remove that limit first"
                        ),
                    code: EBUSY)
            }
        }
    }

    func coveringGroup(for id: ProcessIdentity) -> ProcessIdentity? {
        groupLimits.first { group in
            guard group != id else { return false }
            if let controller = controllers[group] { return controller.memberIDs.contains(id) }
            return groupMembers(of: group, processes: processes, apps: apps).contains {
                $0.id == id
            }
        }
    }

    func apply(
        _ process: ProcessSnapshot, percent: Double, save: Bool = true,
        includesHelpers: Bool = false
    ) {
        do {
            try Limiter.validatePercent(percent)
            let current = try ProcessSnapshot.all()
            let runningApps = NSWorkspace.shared.runningApplications.map {
                RunningApp(
                    pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path,
                    regular: $0.activationPolicy == .regular)
            }
            let members =
                includesHelpers
                ? limitableMembers(
                    of: process.id, processes: current, apps: runningApps,
                    current: controllers[process.id]?.memberIDs ?? [])
                : current.filter { $0.id == process.id }
            try validateOverlap(members: members, replacing: process.id)
            if let detail = controllers.removeValue(forKey: process.id)?.stop() {
                throw NSError(
                    domain: "CoreTamer", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            limits.removeValue(forKey: process.id)
            groupLimits.remove(process.id)
            let fresh = try ProcessSnapshot.read(pid: process.id.pid)
            guard fresh.id == process.id else {
                throw ProcessFailure(
                    operation: String(localized: "The process restarted; select it again"),
                    code: ESRCH)
            }
            try Limiter.validate(target: fresh, percent: percent)
            // The old limiter may have stopped helpers in the snapshot taken before stop().
            let refreshed = includesHelpers ? try ProcessSnapshot.all() : [fresh]
            let freshMembers =
                includesHelpers
                ? limitableMembers(of: fresh.id, processes: refreshed, apps: runningApps) : [fresh]
            for member in freshMembers { try Limiter.validate(target: member, percent: percent) }
            if !paused {
                controllers[process.id] = try Limiter(
                    target: fresh, percent: percent, executable: controllerURL,
                    includesHelpers: includesHelpers,
                    members: includesHelpers ? freshMembers.filter { $0.id != fresh.id } : [])
            }
            limits[process.id] = percent
            if includesHelpers { groupLimits.insert(process.id) }
            if save && restoreLimits && process.path.contains(".app/Contents/MacOS/") {
                savedLimits[process.path] = percent
                if includesHelpers {
                    savedGroupLimits.insert(process.path)
                } else {
                    savedGroupLimits.remove(process.path)
                }
                persistRules()
            }
        } catch { present(error) }
    }

    func remove(_ process: ProcessSnapshot) {
        if let detail = controllers.removeValue(forKey: process.id)?.stop() { present(detail) }
        limits.removeValue(forKey: process.id)
        groupLimits.remove(process.id)
        savedLimits.removeValue(forKey: process.path)
        savedGroupLimits.remove(process.path)
        persistRules()
    }

    func togglePause() {
        paused.toggle()
        if paused {
            for controller in controllers.values {
                if let detail = controller.stop() { present(detail) }
            }
            controllers.removeAll()
        } else {
            for process in processes {
                if let value = limits[process.id] {
                    apply(
                        process, percent: value, save: false,
                        includesHelpers: groupLimits.contains(process.id))
                }
            }
        }
    }

    func completeOnboarding() {
        showsWelcome = false
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        } catch { present(error) }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        for controller in controllers.values {
            if let detail = controller.stop() { logger.error("\(detail, privacy: .public)") }
        }
        controllers.removeAll()
    }

    private func persistRules() {
        if !restoreLimits { savedGroupLimits.removeAll() }
        defaults.set(Array(savedGroupLimits).sorted(), forKey: "savedGroupLimits")
        do { defaults.set(try JSONEncoder().encode(savedLimits), forKey: "savedLimits") } catch {
            present(error)
        }
    }

    private func present(_ failure: any Error) { present(failure.localizedDescription) }
    private func present(_ detail: String) {
        error = detail
        logger.error("\(detail, privacy: .public)")
    }
}
