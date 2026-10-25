import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing

@testable import CoreTamer
@testable import CoreTamerCore

@Suite(.serialized)
@MainActor
struct ModelTests {
    private func fixture() throws -> (AppModel, UserDefaults, String) {
        let name = "CoreTamerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let controller =
            ProcessInfo.processInfo.environment["CORE_TAMER_TEST_CONTROLLER"].map(
                URL.init(fileURLWithPath:))
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CoreTamerController")
        return (AppModel(defaults: defaults, controllerURL: controller), defaults, name)
    }

    @Test func preferencesAndProcessRefresh() throws {
        let (model, defaults, suite) = try fixture()
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(!model.showBackground)
        #expect(!model.restoreLimits)
        model.start()
        #expect(!model.processes.isEmpty)
        #expect(model.groupByType)
        #expect(!model.pauseListOnHover)
        #expect(model.updateSpeed == .normal)
        model.showBackground = true
        #expect(!model.sections.isEmpty)
        #expect(defaults.bool(forKey: "showBackground"))
        model.groupByType = false
        #expect(model.sections.map(\.category) == [nil])
        #expect(defaults.object(forKey: "groupByType") as? Bool == false)
        model.updateSpeed = .slow
        #expect(defaults.string(forKey: "updateSpeed") == "slow")
        model.pauseListOnHover = true
        #expect(defaults.bool(forKey: "pauseListOnHover"))
        let reloaded = AppModel(defaults: defaults)
        #expect(!reloaded.groupByType)
        #expect(reloaded.updateSpeed == .slow)
        #expect(reloaded.pauseListOnHover)
        model.query = "no-such-process-\(UUID())"
        #expect(model.sections.isEmpty)
        model.restoreLimits = true
        #expect(defaults.bool(forKey: "restoreLimits"))
        model.restoreLimits = false
        #expect(!defaults.bool(forKey: "restoreLimits"))
        #expect(model.maximumLimit >= 100)
    }

    @Test func welcomeIsShownUntilOnboardingIsCompleted() throws {
        let name = "CoreTamerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults)
        #expect(model.showsWelcome)
        #expect(AppModel(defaults: defaults).showsWelcome)
        model.completeOnboarding()
        #expect(!model.showsWelcome)
        #expect(defaults.bool(forKey: "hasCompletedOnboarding"))
        #expect(!AppModel(defaults: defaults).showsWelcome)
    }

    @Test func corruptSavedPreferencesAreReported() throws {
        let name = "CoreTamerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("bad-json".utf8), forKey: "savedLimits")
        let model = AppModel(defaults: defaults)
        #expect(model.error != nil)
    }

    @Test func applyPauseResumeRemoveAndShutdown() throws {
        let (model, defaults, suite) = try fixture()
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer {
            kill(process.processIdentifier, SIGCONT)
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        model.refresh()
        let target = try ProcessSnapshot.read(pid: process.processIdentifier)
        model.select(target)
        #expect(model.selectedProcess?.id == target.id)
        #expect(model.proposedLimit == 50)
        model.apply(target, percent: 25)
        #expect(model.limits[target.id] == 25)
        model.apply(target, percent: .nan)
        #expect(model.error != nil)
        #expect(model.limits[target.id] == 25)
        model.error = nil
        model.select(target)
        #expect(model.proposedLimit == 25)
        model.togglePause()
        #expect(model.paused)
        #expect(model.limits[target.id] == 25)
        model.apply(target, percent: 30)
        #expect(model.limits[target.id] == 30)
        model.togglePause()
        #expect(!model.paused)
        #expect(model.error == nil)
        model.remove(target)
        #expect(model.limits.isEmpty)
        model.apply(target, percent: .nan)
        #expect(model.error != nil)
        model.error = nil
        model.apply(target, percent: 40)
        #expect(model.limits[target.id] == 40)
        model.shutdown()
        #expect(try !ProcessSnapshot.read(pid: target.id.pid).stopped)
    }

    @Test func staleAndProtectedProcessesProduceErrors() throws {
        let (model, defaults, suite) = try fixture()
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        let current = try ProcessSnapshot.read(pid: getpid())
        let stale = ProcessSnapshot(
            id: ProcessIdentity(pid: current.id.pid, seconds: 0, microseconds: 0),
            uid: current.uid, name: current.name, path: current.path,
            cpuNanoseconds: current.cpuNanoseconds, stopped: false
        )
        model.apply(stale, percent: 20)
        #expect(
            model.error?.contains(String(localized: "The process restarted; select it again"))
                == true)
        #expect(model.limits.isEmpty)
        model.error = nil
        model.apply(current, percent: 20)
        #expect(model.error != nil)
    }

    @Test func sharedScopeTracksHelpersRejectsOverlapsAndSurvivesPause() throws {
        let (model, defaults, suite) = try fixture()
        let leader = Process()
        let helper = Process()
        for process in [leader, helper] {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            process.standardOutput = FileHandle.nullDevice
            try process.run()
        }
        defer {
            model.shutdown()
            for process in [leader, helper] {
                kill(process.processIdentifier, SIGCONT)
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            defaults.removePersistentDomain(forName: suite)
        }
        let root = try ProcessSnapshot.read(pid: leader.processIdentifier)
        let raw = try ProcessSnapshot.read(pid: helper.processIdentifier)
        let child = ProcessSnapshot(
            id: raw.id, uid: raw.uid, parent: root.id.pid, responsible: root.id.pid,
            name: raw.name, path: raw.path, cpuNanoseconds: raw.cpuNanoseconds, stopped: false)
        model.processes = [root, child]
        model.apps = [RunningApp(pid: root.id.pid, bundlePath: nil, regular: true)]
        model.apply(root, percent: 50, includesHelpers: true)
        #expect(model.error == nil)
        #expect(model.groupLimits == [root.id])
        model.synchronizeGroups(processes: [root, child], apps: model.apps)
        #expect(model.error == nil)
        #expect(model.coveringGroup(for: child.id) == root.id)
        #expect(model.coveringGroup(for: root.id) == nil)
        model.select(root)
        #expect(model.proposedIncludesHelpers)
        model.toggleSelection(id: root.id)
        #expect(model.selected == nil)
        model.toggleSelection(id: root.id)
        #expect(model.selected == root.id)
        model.apply(child, percent: 20)
        #expect(
            model.error?.contains(
                String(
                    localized:
                        "This process already belongs to another limit. Remove that limit first"))
                == true)
        #expect(model.limits[child.id] == nil)
        model.error = nil
        model.togglePause()
        #expect(model.coveringGroup(for: child.id) == root.id)
        model.select(child)
        try withNativeView(model) { host in
            let elements = accessibilityElements(in: host)
            #expect(
                elements.contains {
                    $0.accessibilityValue() as? String
                        == String(
                            format: String(localized: "Included in %@'s shared %.0f%% limit."),
                            locale: .current,
                            arguments: ["yes", 50.0]
                        )
                })
            #expect(
                !elements.contains { $0.accessibilityLabel() == String(localized: "Apply") })
            #expect(
                !elements.contains { $0.accessibilityLabel() == String(localized: "CPU limit") })
            #expect(
                !elements.contains { $0.accessibilityLabel() == String(localized: "Entire app") })
            let link = try #require(
                elements.first {
                    $0.accessibilityLabel()
                        == String(
                            format: String(localized: "Select %@ app group"),
                            locale: .current,
                            arguments: ["yes"]
                        )
                })
            #expect(link.accessibilityPerformPress())
            #expect(model.selected == root.id)
            #expect(model.limits[root.id] == 50)
            #expect(model.limits[child.id] == nil)
            #expect(model.proposedIncludesHelpers)
        }
        model.apply(child, percent: 20)
        #expect(
            model.error?.contains(
                String(
                    localized:
                        "This process is covered by a shared app limit. Remove that limit first"))
                == true)
        model.error = nil
        model.togglePause()
        #expect(model.groupLimits == [root.id])
        model.synchronizeGroups(processes: [root, child], apps: model.apps)
        model.apply(root, percent: 40, includesHelpers: true)
        #expect(model.error == nil)
        #expect(model.limits[root.id] == 40)
        model.remove(root)
        #expect(model.groupLimits.isEmpty)
        model.apply(child, percent: 25)
        model.apply(root, percent: 50, includesHelpers: true)
        model.synchronizeGroups(processes: [root, child], apps: model.apps)
        #expect(model.error != nil)
        #expect(model.groupLimits.isEmpty)
        #expect(model.limits[child.id] == 25)
        model.error = nil
        model.remove(child)
        model.apply(root, percent: 50, includesHelpers: true)
        let protected = ProcessSnapshot(
            id: ProcessIdentity(pid: getpid(), seconds: 0, microseconds: 0),
            uid: getuid(), parent: root.id.pid, responsible: root.id.pid, name: "CoreTamer",
            path: "/test", cpuNanoseconds: 0, stopped: false)
        model.synchronizeGroups(processes: [root, protected], apps: model.apps)
        #expect(model.error == nil)
        #expect(model.groupLimits == [root.id])
        #expect(model.limits[root.id] == 50)
        #expect(model.coveringGroup(for: protected.id) == nil)
        let stopped = ProcessSnapshot(
            id: child.id, uid: child.uid, parent: root.id.pid, responsible: root.id.pid,
            name: child.name, path: child.path, cpuNanoseconds: 0, stopped: true)
        #expect(
            model.limitableMembers(of: root.id, processes: [root, stopped], apps: model.apps).map(
                \.id)
                == [root.id])
        #expect(
            model.limitableMembers(
                of: root.id, processes: [root, stopped], apps: model.apps, current: [child.id]
            ).count == 2)
    }

    @Test func inspectorTargetsAndSettingsFollowTheSelection() throws {
        let (model, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProcessSnapshot(
            id: ProcessIdentity(pid: 10, seconds: 1, microseconds: 0),
            uid: getuid(), name: "Code", path: "/test/Code", cpuNanoseconds: 0, stopped: false)
        let helper = ProcessSnapshot(
            id: ProcessIdentity(pid: 20, seconds: 1, microseconds: 0),
            uid: getuid(), parent: app.id.pid, responsible: app.id.pid,
            name: "yes", path: "/usr/bin/yes", cpuNanoseconds: 0, stopped: false)
        let standalone = ProcessSnapshot(
            id: ProcessIdentity(pid: 30, seconds: 1, microseconds: 0),
            uid: getuid(), name: "Standalone", path: "/test/Standalone",
            cpuNanoseconds: 0, stopped: false)
        model.processes = [app, helper, standalone]
        model.apps = [RunningApp(pid: app.id.pid, bundlePath: nil, regular: true)]
        model.query = "yes"
        model.groupByType = false
        #expect(model.appGroup(containing: app.id)?.id == app.id)
        #expect(model.appGroup(containing: helper.id)?.id == app.id)
        #expect(model.appGroup(containing: standalone.id) == nil)
        model.select(helper)
        #expect(!model.proposedIncludesHelpers)
        #expect(model.inspectedProcess?.id == helper.id)
        try withNativeView(model) { host in
            @MainActor func elements() -> [AccessibleElement] {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                return accessibilityElements(in: host)
            }
            let individual = elements()
            #expect(
                individual.contains {
                    $0.accessibilityValue() as? String
                        == String(
                            format: String(localized: "Individual process · Part of %@"),
                            locale: .current,
                            arguments: ["Code"]
                        )
                })
            #expect(
                individual.contains {
                    $0.accessibilityValue() as? String
                        == String(
                            format: String(localized: "Only %@ (PID %d) will be limited."),
                            locale: .current,
                            arguments: ["yes", 20]
                        )
                })
            #expect(
                !individual.contains {
                    $0.accessibilityLabel() == String(localized: "Main process only")
                })
            #expect(
                !individual.contains { $0.accessibilityLabel() == String(localized: "Entire app") })
            let link = try #require(
                individual.first {
                    $0.accessibilityLabel()
                        == String(
                            format: String(localized: "Select %@ app group"),
                            locale: .current,
                            arguments: ["Code"]
                        )
                })
            #expect(link.accessibilityPerformPress())
            #expect(model.selected == app.id)
            #expect(model.limits.isEmpty)
            #expect(!model.proposedIncludesHelpers)
            let appControls = elements()
            #expect(
                appControls.contains {
                    $0.accessibilityLabel() == String(localized: "Main process only")
                })
            #expect(
                appControls.contains { $0.accessibilityLabel() == String(localized: "Entire app") })
            model.proposedIncludesHelpers = true
            #expect(
                elements().contains {
                    $0.accessibilityValue() as? String
                        == String(
                            format: String(
                                localized:
                                    "%.0f%% total, shared across %@ and its helper processes. Newly discovered helpers are included."
                            ),
                            locale: .current,
                            arguments: [50.0, "Code"]
                        )
                })
            let settings = try #require(
                elements().first { $0.accessibilityLabel() == String(localized: "Settings") })
            #expect(settings.accessibilityPerformPress())
            #expect(model.settingsVisible)
            #expect(model.inspectedProcess == nil)
            #expect(model.selected == app.id)
            #expect(
                !elements().contains { $0.accessibilityLabel() == String(localized: "Apply") })
            model.select(helper)
            #expect(model.inspectedProcess == nil)
            #expect(
                !elements().contains {
                    $0.accessibilityLabel()
                        == String(
                            format: String(localized: "Select %@ app group"),
                            locale: .current,
                            arguments: ["Code"]
                        )
                })
            let closeSettings = try #require(
                elements().first { $0.accessibilityLabel() == String(localized: "Settings") })
            #expect(closeSettings.accessibilityPerformPress())
            #expect(!model.settingsVisible)
            #expect(model.inspectedProcess?.id == helper.id)
            #expect(
                elements().contains {
                    $0.accessibilityLabel()
                        == String(
                            format: String(localized: "Select %@ app group"),
                            locale: .current,
                            arguments: ["Code"]
                        )
                })
            model.select(standalone)
            #expect(
                elements().contains {
                    $0.accessibilityValue() as? String == String(localized: "Individual process")
                })
            #expect(
                !elements().contains { $0.accessibilityLabel() == String(localized: "Entire app") })
            model.select(id: nil)
            #expect(model.inspectedProcess == nil)
            #expect(
                !elements().contains { $0.accessibilityLabel() == String(localized: "Apply") })
        }
        model.processes = [app]
        #expect(model.appGroup(containing: app.id)?.id == app.id)
        #expect(model.appGroup(containing: helper.id) == nil)
    }

    @Test func nativeInspectorAppliesTheDisplayedScope() throws {
        let (model, defaults, suite) = try fixture()
        let workload = Process()
        workload.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        workload.standardOutput = FileHandle.nullDevice
        try workload.run()
        defer {
            model.shutdown()
            kill(workload.processIdentifier, SIGCONT)
            if workload.isRunning { workload.terminate() }
            workload.waitUntilExit()
            defaults.removePersistentDomain(forName: suite)
        }
        let target = try ProcessSnapshot.read(pid: workload.processIdentifier)
        model.processes = [target]
        model.select(target)
        // A stale app-scope draft must never turn an individual-process action into a group limit.
        model.proposedIncludesHelpers = true
        try withNativeView(model) { host in
            @MainActor func press(_ label: String) throws {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let button = try #require(
                    accessibilityElements(in: host).first { $0.accessibilityLabel() == label })
                #expect(button.accessibilityPerformPress())
            }
            try press(String(localized: "Apply"))
            #expect(model.error == nil)
            #expect(model.limits[target.id] == 50)
            #expect(model.groupLimits.isEmpty)
            try press(String(localized: "Remove"))
            #expect(model.limits.isEmpty)
            model.apps = [RunningApp(pid: target.id.pid, bundlePath: nil, regular: true)]
            model.select(target)
            model.proposedIncludesHelpers = true
            try press(String(localized: "Apply"))
            #expect(model.error == nil)
            #expect(model.limits[target.id] == 50)
            #expect(model.groupLimits == [target.id])
            try press(String(localized: "Remove"))
            #expect(model.limits.isEmpty)
            #expect(model.groupLimits.isEmpty)
            try press(String(localized: "Deselect process"))
            #expect(model.selected == nil)
        }
    }

    @Test(arguments: [true, false], [1, 2])
    func repeatedClicksWorkInTheSwiftUITable(groupByType: Bool, clickCount: Int) throws {
        let (model, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ProcessSnapshot(
            id: ProcessIdentity(pid: 10, seconds: 1, microseconds: 0),
            uid: getuid(), name: "Alpha", path: "/test/Alpha", cpuNanoseconds: 0, stopped: false)
        let second = ProcessSnapshot(
            id: ProcessIdentity(pid: 20, seconds: 1, microseconds: 0),
            uid: getuid(), name: "Beta", path: "/test/Beta", cpuNanoseconds: 0, stopped: false)
        let helper = ProcessSnapshot(
            id: ProcessIdentity(pid: 30, seconds: 1, microseconds: 0),
            uid: getuid(), parent: first.id.pid, responsible: first.id.pid,
            name: "Helper", path: "/test/Helper", cpuNanoseconds: 0, stopped: false)
        model.processes = [first, second, helper]
        model.select(first)
        model.groupByType = groupByType
        model.apps = [
            RunningApp(pid: first.id.pid, bundlePath: nil, regular: true),
            RunningApp(pid: second.id.pid, bundlePath: nil, regular: true),
        ]
        let host = NSHostingView(rootView: TamerView(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: TamerView.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        let table = try #require(findTable(in: host))
        func findRegion(in view: NSView) -> NSView? {
            if view is RepeatedRowClick.ClickRegion { return view }
            return view.subviews.lazy.compactMap { findRegion(in: $0) }.first
        }
        let region = try #require(findRegion(in: host))
        let firstRow = groupByType ? 1 : 0
        #expect(table.numberOfRows == firstRow + 2)
        let outline = try #require(table as? NSOutlineView)
        table.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
        let disclosure = outline.frameOfOutlineCell(atRow: firstRow)
        #expect(!disclosure.isEmpty)
        let header = try #require(table.headerView)
        let preservedPoints = [
            outline.convert(NSPoint(x: disclosure.midX, y: disclosure.midY), to: nil),
            header.convert(NSPoint(x: 150, y: header.bounds.midY), to: nil),
        ]
        for point in preservedPoints {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: clickCount, pressure: 1))
            var deselected = false
            #expect(RepeatedRowClick.handle(event, in: region) { deselected = true } != nil)
            #expect(!deselected)
            #expect(table.isRowSelected(firstRow))
        }
        for row in [firstRow, firstRow + 1] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let point = table.convert(NSPoint(x: 150, y: table.rect(ofRow: row).midY), to: nil)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: clickCount, pressure: 1))
            var deselected = false
            #expect(
                RepeatedRowClick.handle(event, in: region) { deselected = true } == nil,
                "Selected native row \(row) must consume the repeated click")
            #expect(deselected)
            #expect(table.selectedRow == -1)
        }
    }

    @Test(arguments: [1, 2])
    func clickingAnAlreadySelectedNativeRowDeselectsIt(clickCount: Int) throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let window = NSWindow(
            contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        let table = NSTableView(frame: content.bounds)
        table.headerView = nil
        table.allowsEmptySelection = true
        let source = SelectionRows()
        table.dataSource = source
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name")))
        content.addSubview(table)
        table.reloadData()
        let point = table.convert(NSPoint(x: 50, y: table.rect(ofRow: 0).midY), to: nil)
        func event(_ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: clickCount, pressure: 1))
        }
        var deselected = false
        #expect(RepeatedRowClick.handle(try event(), in: content) { deselected = true } != nil)
        #expect(!deselected)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(
            RepeatedRowClick.handle(try event(.command), in: content) { deselected = true } != nil)
        #expect(table.isRowSelected(0))
        #expect(RepeatedRowClick.handle(try event(), in: content) { deselected = true } == nil)
        #expect(deselected)
        #expect(table.selectedRow == -1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORE_TAMER_TEST_WORKLOAD"] != nil))
    func restorationUsesExecutablePathAndRemoveDeletesRule() throws {
        let (model, defaults, suite) = try fixture()
        let source = try #require(ProcessInfo.processInfo.environment["CORE_TAMER_TEST_WORKLOAD"])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTamer-restoration-test-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("Workload.app/Contents/MacOS/Workload")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: executable)
        var workload: Process?
        defer {
            model.shutdown()
            if let workload {
                kill(workload.processIdentifier, SIGCONT)
                if workload.isRunning { workload.terminate() }
                workload.waitUntilExit()
            }
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = executable
            try process.run()
            return process
        }
        model.restoreLimits = true
        workload = try launch()
        let firstPID = try #require(workload?.processIdentifier)
        let first = try ProcessSnapshot.read(pid: firstPID)
        model.apply(first, percent: 50, includesHelpers: true)
        #expect(model.error == nil)
        #expect(defaults.stringArray(forKey: "savedGroupLimits") == [first.path])
        model.select(first)
        #expect(model.proposedIncludesHelpers)
        #expect(defaults.data(forKey: "savedLimits") != nil)
        model.togglePause()
        workload?.terminate()
        workload?.waitUntilExit()
        workload = nil
        model.refresh()
        model.togglePause()
        workload = try launch()
        let secondPID = try #require(workload?.processIdentifier)
        model.refresh()
        let second = try ProcessSnapshot.read(pid: secondPID)
        #expect(first.id != second.id)
        #expect(model.limits[second.id] == 50)
        #expect(model.groupLimits.contains(second.id))
        model.remove(second)
        #expect(defaults.stringArray(forKey: "savedGroupLimits") == [])
        model.refresh()
        #expect(model.limits[second.id] == nil)
        model.restoreLimits = false
        let data = try #require(defaults.data(forKey: "savedLimits"))
        #expect(try JSONDecoder().decode([String: Double].self, from: data).isEmpty)
    }

    @Test func nativeViewRendersListInspectorSettingsAndErrors() throws {
        let (model, defaults, suite) = try fixture()
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        _ = NSApplication.shared
        model.refresh()
        model.showBackground = true
        model.select(try ProcessSnapshot.read(pid: getpid()))
        model.settingsVisible = true
        model.error = "Test error"
        let updates = UpdateController(updater: FakeUpdater(), defaults: defaults)
        updates.availableUpdateVersion = "1.0.1"
        let host = NSHostingView(rootView: TamerView(model: model, updates: updates))
        host.frame = NSRect(origin: .zero, size: TamerView.size)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == TamerView.size)
        model.completeOnboarding()
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == TamerView.size)
        model.updateSpeed = .paused
        model.groupByType = false
        host.layoutSubtreeIfNeeded()
        model.query = "no-such-process-\(UUID())"
        model.paused = true
        host.layoutSubtreeIfNeeded()
        #expect(model.sections.isEmpty)
    }

    @Test func headerSortTogglesAndOrdersLimitedProcessesFirst() throws {
        let (model, defaults, suite) = try fixture()
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(model.sort == .cpu)
        model.sort(by: .name)
        #expect(model.sort == ProcessSort(column: .name, ascending: true))
        model.sort(by: .name)
        #expect(model.sort == ProcessSort(column: .name, ascending: false))
        model.sort(by: .limit)
        #expect(model.sort == .limit)
        model.showBackground = true
        model.refresh()
        #expect(!model.sections.isEmpty)
    }

    @Test func nativeTableSortHeadersMapToProcessSort() {
        #expect(
            TamerView.sort(for: KeyPathComparator(\ProcessRow.name, order: .reverse), current: .cpu)
                == .name)
        #expect(
            TamerView.sort(for: KeyPathComparator(\ProcessRow.pid, order: .forward), current: .cpu)
                == ProcessSort(column: .pid))
        #expect(
            TamerView.sort(
                for: KeyPathComparator(\ProcessRow.limitSortValue, order: .forward), current: .cpu)
                == .limit)
        #expect(
            TamerView.sort(
                for: KeyPathComparator(\ProcessRow.cpuSortValue, order: .forward), current: .cpu)
                == ProcessSort(column: .cpu, ascending: true))
        #expect(
            TamerView.sort(
                for: KeyPathComparator(\ProcessRow.cpuSortValue, order: .reverse), current: .name)
                == .cpu)
        #expect(TamerView.iconPath(for: "/A.app/Contents/MacOS/A") == "/A.app")
        #expect(TamerView.iconPath(for: "/usr/bin/yes") == "/usr/bin/yes")
        #expect(TamerView.heat(nil) == 0)
        #expect(TamerView.heat(0.5) == 0)
        #expect(TamerView.heat(50) > TamerView.heat(5))
        #expect(TamerView.heat(400) == TamerView.heat(100))
    }

    @Test func menuBarGlyphIsTemplateImage() throws {
        let image = MenuBarGlyph.make()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let updateImage = MenuBarGlyph.make(updateAvailable: true)
        #expect(updateImage.isTemplate)
        #expect(updateImage.accessibilityDescription != image.accessibilityDescription)
        let rep = try #require(image.bestRepresentation(for: .zero, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        let context = try #require(bitmap.flatMap(NSGraphicsContext.init(bitmapImageRep:)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        #expect(rep.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36)))
        NSGraphicsContext.restoreGraphicsState()
    }

    @Test func listPausesOnlyWhenHoverOptionIsOnAndSelectionDoesNotFreeze() throws {
        let (model, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ProcessSnapshot(
            id: ProcessIdentity(pid: 10, seconds: 1, microseconds: 0),
            uid: getuid(), name: "Alpha", path: "/test/Alpha", cpuNanoseconds: 0, stopped: false)
        let b = ProcessSnapshot(
            id: ProcessIdentity(pid: 20, seconds: 1, microseconds: 0),
            uid: getuid(), name: "Beta", path: "/test/Beta", cpuNanoseconds: 0, stopped: false)
        func order() -> [ProcessIdentity] { model.sections.flatMap(\.allIDs) }
        // Hover changes re-rank at the real uptime, so test times must follow it.
        let now = ProcessInfo.processInfo.systemUptime + 100
        model.showBackground = true
        model.processes = [a, b]
        model.cpu = [a.id: 80, b.id: 20]
        model.updateListOrder(at: now + 0)
        #expect(order() == [a.id, b.id])
        #expect(model.sections.map(\.category) == [.background])
        model.setListHovered(true)
        #expect(!model.isListHovered)
        model.select(id: a.id)
        #expect(model.selected == a.id)
        model.cpu = [a.id: 10, b.id: 90]
        model.updateListOrder(at: now + 1)
        #expect(order() == [b.id, a.id])
        #expect(model.updatesDisplay)
        model.pauseListOnHover = true
        model.setListHovered(true)
        #expect(model.isListPausedByHover)
        #expect(!model.updatesDisplay)
        model.cpu = [a.id: 95, b.id: 5]
        model.updateListOrder(at: now + 2)
        #expect(order() == [b.id, a.id])
        model.setSort(.cpu)
        #expect(order() == [a.id, b.id])
        model.pauseListOnHover = false
        #expect(!model.isListPausedByHover)
        #expect(model.updatesDisplay)
        model.updateSpeed = .paused
        #expect(!model.updatesDisplay)
        model.updateSpeed = .normal
        model.select(id: ProcessIdentity(pid: 99, seconds: 0, microseconds: 0))
        #expect(model.selected == nil)
        model.select(id: nil)
        #expect(model.selected == nil)
        model.processes = [b]
        model.updateListOrder(at: now + 3)
        #expect(order() == [b.id])
        model.select(a)
        model.refresh(updatingDisplay: false)
        #expect(model.processes.map(\.id) == [b.id])
        #expect(model.selected == a.id)
        model.refresh()
        #expect(model.selected == nil)
        #expect(model.processes.count > 1)
    }

    @Test func updateSpeedReschedulesRunningTimer() throws {
        let (model, defaults, suite) = try fixture()
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        model.start()
        for speed in UpdateSpeed.allCases { model.updateSpeed = speed }
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))
        #expect(!model.processes.isEmpty)
    }

    private func withNativeView(
        _ model: AppModel, body: @MainActor (NSHostingView<TamerView>) throws -> Void
    ) rethrows {
        let host = NSHostingView(rootView: TamerView(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: TamerView.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try body(host)
    }

    private func accessibilityElements(
        in element: AnyObject
    ) -> [AccessibleElement] {
        [AccessibleElement(node: element)]
            + (element.accessibilityChildren?() ?? [])
            .flatMap { accessibilityElements(in: $0 as AnyObject) }
    }

    // SwiftUI accessibility nodes expose Objective-C selectors without NSAccessibilityProtocol conformance.
    private struct AccessibleElement {
        let node: AnyObject

        func accessibilityLabel() -> String? { node.accessibilityLabel?() }
        func accessibilityValue() -> Any? { node.accessibilityValue?() }
        func accessibilityPerformPress() -> Bool { node.accessibilityPerformPress?() ?? false }
    }
}

@MainActor
private final class SelectionRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 2 }
}
