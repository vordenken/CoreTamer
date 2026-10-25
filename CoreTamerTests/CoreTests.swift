import Darwin
import Foundation
import ProcessControl
import Testing

@testable import CoreTamerCore

private func snapshot(
    pid: Int32 = 12345, seconds: UInt64 = 1, name: String = "Test",
    uid: UInt32 = getuid(), parent: Int32 = 1, responsible: Int32? = nil, path: String? = nil,
    cpu: UInt64 = 0, stopped: Bool = false
) -> ProcessSnapshot {
    ProcessSnapshot(
        id: ProcessIdentity(pid: pid, seconds: seconds, microseconds: 0),
        uid: uid, parent: parent, responsible: responsible, name: name,
        path: path ?? "/test/\(name)",
        cpuNanoseconds: cpu,
        stopped: stopped
    )
}

private func flat(
    _ processes: [ProcessSnapshot], query: String = "", showBackground: Bool = true,
    apps: [RunningApp] = [], sort: ProcessSort, cpu: [ProcessIdentity: Double] = [:],
    limits: [ProcessIdentity: Double] = [:]
) -> [ProcessIdentity] {
    groupedProcesses(
        processes, apps: apps, query: query, showBackground: showBackground, groupByType: false,
        sort: sort, cpu: cpu, limits: limits
    ).flatMap(\.allIDs)
}

@Test func samplingUsesOneCorePercentAndMonotonicDeltas() {
    var sampler = CPUSampler()
    let first = snapshot(cpu: 1_000_000_000)
    #expect(sampler.sample([first], at: 1).isEmpty)
    let second = snapshot(cpu: 1_500_000_000)
    #expect(sampler.sample([second], at: 2)[second.id] == 50)
    let third = snapshot(cpu: 3_500_000_000)
    #expect(sampler.sample([third], at: 3)[third.id] == 200)
    #expect(sampler.sample([third], at: 3).isEmpty)
    #expect(sampler.sample([snapshot(cpu: 1)], at: 4).isEmpty)
    #expect(sampler.sample([snapshot(seconds: 2, cpu: 2)], at: 5).isEmpty)
    #expect(sampler.sample([], at: 6).isEmpty)
}

@Test func germanLocalizationCoversCategoriesAndFormattedInspectorText() {
    let german = Locale(identifier: "de")
    #expect(String(localized: "Process list", locale: german) == "Prozessliste")
    #expect(String(localized: "General", locale: german) == "Allgemein")
    #expect(String(localized: "Updates", locale: german) == "Updates")
    #expect(
        String(localized: "Background processes", locale: german) == "Hintergrundprozesse")
    #expect(
        String(localized: "System & other users", locale: german) == "System und andere Benutzer")
    #expect(String(localized: "Fast (1 s)", locale: german) == "Schnell (1 s)")
    #expect(
        String(
            format: String(localized: "%.0f%%", locale: german),
            locale: german,
            arguments: [50.0]
        ) == "50 %")
    #expect(Bundle.main.localizations.contains("en"))
    #expect(Bundle.main.localizations.contains("de"))

    let format = String(
        localized: "Included in %@'s shared %.0f%% limit.",
        locale: german
    )
    #expect(
        String(format: format, locale: german, arguments: ["Browser", 50.0])
            == "Im gemeinsamen Limit von Browser (50 %) enthalten.")
}

@Test(arguments: [ProcessSort.cpu, .name, .limit, ProcessSort(column: .pid, ascending: true)])
func sortingAndFiltering(sort: ProcessSort) {
    let a = snapshot(pid: 30, name: "Zebra")
    let b = snapshot(pid: 20, name: "Alpha")
    let all = [a, b]
    #expect(flat(all, sort: sort, cpu: [b.id: 40], limits: [b.id: 25]) == [b.id, a.id])
    let reversed = ProcessSort(column: sort.column, ascending: !sort.ascending)
    #expect(flat(all, sort: reversed, cpu: [b.id: 40], limits: [b.id: 25]) == [a.id, b.id])
    #expect(flat(all, query: "zEb", sort: sort) == [a.id])
    #expect(flat(all, query: "20", sort: sort) == [b.id])
    #expect(
        flat(
            all, showBackground: false, apps: [RunningApp(pid: 30, bundlePath: nil, regular: true)],
            sort: sort) == [a.id])
    #expect(flat(all, query: "none", sort: sort).isEmpty)
    let tied = [snapshot(pid: 30, name: "same"), snapshot(pid: 20, name: "same")]
    #expect(
        flat(tied, sort: ProcessSort(column: sort.column == .pid ? .name : sort.column)).map(\.pid)
            == [20, 30])
}

@Test func processesAreGroupedByTypeWithHelpersUnderTheirApp() {
    let browser = snapshot(
        pid: 100, name: "Browser", path: "/Apps/Browser.app/Contents/MacOS/Browser")
    let renderer = snapshot(
        pid: 101, name: "Browser Helper",
        path: "/Apps/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Browser Helper")
    let terminal = snapshot(pid: 200, name: "Terminal", path: "/Apps/Terminal.app/T")
    let shell = snapshot(pid: 201, name: "zsh", parent: 200, path: "/bin/zsh")
    let tool = snapshot(pid: 202, name: "make", parent: 201, path: "/usr/bin/make")
    let menuBar = snapshot(pid: 300, name: "MenuTool", path: "/Apps/MenuTool.app/M")
    let agent = snapshot(pid: 400, name: "agent")
    let orphan = snapshot(pid: 401, name: "orphan", parent: 9999)
    let root = snapshot(pid: 500, name: "kernel_task", uid: 0)
    let otherUser = snapshot(pid: 501, name: "other", uid: getuid() + 1, parent: 200)
    let apps = [
        RunningApp(pid: 100, bundlePath: "/Apps/Browser.app", regular: true),
        RunningApp(pid: 200, bundlePath: "/Apps/Terminal.app/", regular: true),
        RunningApp(pid: 300, bundlePath: "/Apps/MenuTool.app", regular: false),
        RunningApp(pid: 999, bundlePath: "/Apps/Gone.app", regular: true),
    ]
    let all = [browser, renderer, terminal, shell, tool, menuBar, agent, orphan, root, otherUser]
    let cpu = [browser.id: 10.0, renderer.id: 30, shell.id: 5, root.id: 50]
    let limits = [renderer.id: 20.0, tool.id: 40]
    let sections = groupedProcesses(
        all, apps: apps, query: "", showBackground: true, groupByType: true, sort: .cpu, cpu: cpu,
        limits: limits)
    #expect(sections.map(\.category) == [.apps, .background, .system])
    let appRows = sections[0].rows
    #expect(appRows.map(\.name) == ["Browser", "Terminal"])
    #expect(appRows[0].cpu == 40)
    #expect(appRows[0].helpers?.map(\.name) == ["Browser Helper"])
    #expect(appRows[0].limitedHelpers == 1)
    #expect(appRows[0].limitSortValue == 20)
    #expect(appRows[1].helpers?.map(\.name) == ["zsh", "make"])
    #expect(appRows[1].cpu == 5)
    #expect(appRows[1].limitSortValue == 40)
    #expect(sections[1].rows.map(\.name) == ["MenuTool", "agent", "orphan"])
    #expect(sections[1].rows.allSatisfy { $0.helpers == nil && $0.cpu == nil })
    #expect(sections[2].rows.map(\.name) == ["kernel_task", "other"])
    #expect(sections[0].allIDs == [browser.id, renderer.id, terminal.id, shell.id, tool.id])
    #expect(ProcessCategory.allCases.map(\.title).count == 3)
    #expect(Set(ProcessCategory.allCases.map(\.title)).count == 3)

    let appsOnly = groupedProcesses(
        all, apps: apps, query: "", showBackground: false, groupByType: true, sort: .name, cpu: [:])
    #expect(appsOnly.map(\.category) == [.apps, .background])
    #expect(appsOnly[1].rows.map(\.name) == ["MenuTool"])

    let helperMatch = groupedProcesses(
        all, apps: apps, query: "make", showBackground: true, groupByType: true, sort: .name,
        cpu: [:])
    #expect(helperMatch.count == 1)
    #expect(helperMatch[0].rows.map(\.name) == ["Terminal"])
    #expect(helperMatch[0].rows[0].helpers?.map(\.name) == ["make"])

    let leaderMatch = groupedProcesses(
        all, apps: apps, query: "Terminal", showBackground: true, groupByType: false, sort: .name,
        cpu: [:])
    #expect(leaderMatch.map(\.category) == [nil])
    #expect(leaderMatch[0].rows[0].helpers?.count == 2)
}

@Test func parentLoopsDoNotHangGrouping() {
    let a = snapshot(pid: 10, name: "a", parent: 11)
    let b = snapshot(pid: 11, name: "b", parent: 10)
    let sections = groupedProcesses(
        [a, b], apps: [], query: "", showBackground: true, groupByType: true, sort: .name, cpu: [:])
    #expect(sections.flatMap(\.allIDs) == [a.id, b.id])
}

@Test func xpcServicesJoinTheAppMacOSHoldsResponsible() {
    let browser = snapshot(pid: 100, name: "Safari", path: "/Apps/Safari.app/Contents/MacOS/Safari")
    let reader = snapshot(pid: 200, name: "Reader", path: "/Apps/Reader.app/Contents/MacOS/Reader")
    let webKit = "/System/WebKit.framework/XPCServices/WebContent.xpc/WebContent"
    let page = snapshot(pid: 101, name: "WebContent", responsible: 100, path: webKit)
    let feed = snapshot(pid: 201, name: "WebContent", responsible: 200, path: webKit)
    let menuAgent = snapshot(pid: 300, name: "Menu Helper")
    let gpu = snapshot(pid: 301, name: "GPU", responsible: 300)
    let nested = snapshot(pid: 302, name: "Nested", responsible: 101)
    let unknown = snapshot(pid: 303, name: "Unknown", responsible: 9999)
    let system = snapshot(pid: 400, name: "daemon", uid: 0)
    let systemClient = snapshot(pid: 401, name: "Client", responsible: 400)
    let apps = [
        RunningApp(pid: 100, bundlePath: "/Apps/Safari.app", regular: true),
        RunningApp(pid: 200, bundlePath: "/Apps/Reader.app", regular: true),
        // NSWorkspace also reports XPC helpers as accessory/prohibited running applications.
        RunningApp(
            pid: 101, bundlePath: "/System/WebKit.framework/XPCServices/WebContent.xpc",
            regular: false),
        RunningApp(
            pid: 201, bundlePath: "/System/WebKit.framework/XPCServices/WebContent.xpc",
            regular: false),
    ]
    let sections = groupedProcesses(
        [browser, reader, page, feed, menuAgent, gpu, nested, unknown, system, systemClient],
        apps: apps, query: "", showBackground: true, groupByType: true, sort: .name, cpu: [:])
    let rows = sections.flatMap(\.rows)
    func helpers(_ name: String) -> [Int32]? {
        rows.first { $0.name == name }?.helpers?.map(\.id.pid)
    }
    #expect(helpers("Reader") == [201])
    #expect(helpers("Safari") == [101])
    #expect(helpers("Menu Helper") == [301])
    #expect(Set(rows.map(\.name)).isSuperset(of: ["Nested", "Unknown", "Client", "daemon"]))
    #expect(ap_process_responsible(getpid()) > 0)
    #expect(ap_process_responsible(0) == 0)
}

@Test func heldRanksReorderRowsAndHelpers() {
    let app = snapshot(pid: 1000, name: "App", path: "/A.app/Contents/MacOS/App")
    let h1 = snapshot(pid: 1001, name: "H1", path: "/A.app/Contents/H1")
    let h2 = snapshot(pid: 1002, name: "H2", path: "/A.app/Contents/H2")
    let other = snapshot(pid: 2000, name: "Other")
    let fresh = snapshot(pid: 3000, name: "Fresh")
    let sections = groupedProcesses(
        [app, h1, h2, other, fresh],
        apps: [RunningApp(pid: 1000, bundlePath: "/A.app", regular: false)],
        query: "", showBackground: true, groupByType: false, sort: .name, cpu: [:])
    #expect(sections[0].allIDs == [app.id, h1.id, h2.id, fresh.id, other.id])
    let ranked = sections.ranked(by: [other.id: 0, app.id: 1, h2.id: 2, h1.id: 3])
    #expect(ranked[0].allIDs == [other.id, app.id, h2.id, h1.id, fresh.id])
}

@Test func updateSpeedsMatchTaskManagerOptions() {
    #expect(UpdateSpeed.allCases.map(\.interval) == [1, 2, 5, nil])
    #expect(Set(UpdateSpeed.allCases.map(\.title)).count == 4)
}

@Test func displaySmoothingIsTimeWeightedAndPreservesMulticoreValues() {
    var smoother = CPUDisplaySmoother()
    let a = snapshot().id
    let restarted = snapshot(seconds: 2).id
    #expect(smoother.sample([:], at: 0).isEmpty)
    #expect(smoother.sample([a: 200], at: 1)[a] == 200)
    let afterSpike = smoother.sample([a: 400], at: 2)[a] ?? 0
    #expect(abs(afterSpike - (200 + 200 * (1 - exp(-0.2)))) < 0.0001)
    #expect(smoother.sample([a: 0], at: 2)[a] == afterSpike)
    let decayed = smoother.sample([a: 0], at: 7)[a] ?? 0
    #expect(abs(decayed - afterSpike * exp(-1)) < 0.0001)
    let fresh = smoother.sample([restarted: 75], at: 8)
    #expect(fresh[a] == nil)
    #expect(fresh[restarted] == 75)
    #expect(smoother.sample([:], at: 9).isEmpty)
    #expect(smoother.sample([a: 10], at: 10)[a] == 10)
}

@Test func rowOrderChangesOnlyEveryFiveSecondsUnlessExplicitlyRequested() {
    var order = ProcessListOrder()
    let a = snapshot(pid: 10).id
    let b = snapshot(pid: 20).id
    let c = snapshot(pid: 30).id
    order.update([a, b], at: 0, frozen: false)
    order.update([b, a], at: 4.999, frozen: false)
    #expect(order.ids == [a, b])
    order.update([b, a], at: 5, frozen: false)
    #expect(order.ids == [b, a])
    order.update([a, b], at: 10, frozen: true)
    #expect(order.ids == [b, a])
    order.update([c, a, b], at: 11, frozen: true)
    #expect(order.ids == [b, a, c])
    order.update([c, a], at: 12, frozen: true)
    #expect(order.ids == [a, c])
    order.update([c, a], at: 12, frozen: false)
    #expect(order.ids == [c, a])
    order.update([a, c], at: 13, frozen: true, force: true)
    #expect(order.ids == [a, c])
    order.update([], at: 14, frozen: true)
    #expect(order.ids.isEmpty)
    order.update([a, c], at: 14, frozen: false, interval: 0)
    #expect(order.ids == [a, c])
    var initiallyFrozen = ProcessListOrder()
    initiallyFrozen.update([a], at: 0, frozen: true)
    #expect(initiallyFrozen.ids == [a])
}

@Test func headerClicksToggleDirectionAndResetOnNewColumn() {
    #expect(ProcessSort.cpu.ascending == false)
    #expect(ProcessSort.name.ascending == true)
    #expect(ProcessSort.limit.ascending == false)
    #expect(ProcessSort(column: .pid).ascending)
    let flipped = ProcessSort.cpu.selecting(.cpu)
    #expect(flipped == ProcessSort(column: .cpu, ascending: true))
    #expect(flipped.selecting(.cpu) == .cpu)
    #expect(flipped.selecting(.name) == .name)
    #expect(ProcessSort.name.selecting(.limit) == .limit)
}

@Test func protectedTargetsAreReadOnly() {
    #expect(snapshot().canControl)
    #expect(!snapshot(pid: 1).canControl)
    #expect(!snapshot(pid: getpid()).canControl)
    #expect(!snapshot(pid: getppid()).canControl)
    #expect(!snapshot(uid: 0).canControl)
    #expect(!snapshot(stopped: true).canControl)
    for name in ["loginwindow", "WindowServer", "Dock", "SystemUIServer", "CoreTamerController"] {
        #expect(!snapshot(name: name).canControl)
    }
}

@Test func processInspectionAndErrors() throws {
    let current = try ProcessSnapshot.read(pid: getpid())
    #expect(current.id.pid == getpid())
    #expect(current.uid == getuid())
    #expect(!current.name.isEmpty)
    #expect(!current.path.isEmpty)
    #expect(try ProcessSnapshot.all().contains { $0.id == current.id })
    #expect(throws: ProcessFailure.self) { try ProcessSnapshot.read(pid: -1) }
    let failure = ProcessFailure(operation: "Testing", code: EPERM)
    #expect(failure.localizedDescription.contains("Testing"))
}

@Test(arguments: [Double.nan, .infinity, -1, 0, 0.5, 1_000_000])
func invalidBudgetsAreRejected(value: Double) {
    var budget = APBudget()
    #expect(ap_budget_init(&budget, value) == EINVAL)
}

@Test func budgetLimitsAndRecoversWithoutIdleCreditAccumulation() {
    var budget = APBudget()
    #expect(ap_budget_init(&budget, 50) == 0)
    #expect(budget.rate == 0.5)
    #expect(ap_budget_update(&budget, 100, 0) == 0)
    #expect(budget.credit == budget.capacity)
    #expect(ap_budget_update(&budget, 0.02, 0.04) == 1)
    #expect(ap_budget_update(&budget, 0.1, 0) == 0)
    #expect(ap_monotonic_seconds() > 0)
}

@Test func nativeIdentityChecksAndSignals() {
    var info = APProcessInfo()
    #expect(ap_process_read(getpid(), &info) == 0)
    var copy = info
    #expect(ap_same_process(&info, &copy) != 0)
    copy.start_microseconds += 1
    #expect(ap_same_process(&info, &copy) == 0)
    #expect(ap_signal_process(&copy, 0) == ESRCH)
    #expect(ap_signal_process(&info, 0) == 0)
    #expect(ap_validate_target(&info, 0) == EPERM)
    var target = APProcessInfo(
        pid: 123456, uid: getuid(), parent: 1,
        start_seconds: 1, start_microseconds: 0, cpu_nanoseconds: 0, stopped: 0)
    #expect(ap_validate_target(&target, 0) == 0)
    #expect(ap_validate_target(&target, target.pid) == EPERM)
    target.stopped = 1
    #expect(ap_validate_target(&target, 0) == EBUSY)
    target.uid = 0
    #expect(ap_validate_target(&target, 0) == EPERM)
    #expect(ap_process_read(0, &info) == EINVAL)
    #expect(ap_process_read(getpid(), nil) == EINVAL)
    var buffer = [CChar](repeating: 0, count: 4096)
    #expect(ap_process_path(-1, &buffer, UInt32(buffer.count)) != 0)
    #expect(ap_process_name(-1, &buffer, UInt32(buffer.count)) != 0)
}

@Test func machTicksAreNormalizedOnBothArchitectures() {
    #expect(ap_ticks_to_nanoseconds(24_000_000, 125, 3) == 1_000_000_000)
    #expect(ap_ticks_to_nanoseconds(1_000_000_000, 1, 1) == 1_000_000_000)
    #expect(ap_ticks_to_nanoseconds(1_000_000_000_000_000, 125, 3) == 41_666_666_666_666_666)
}

@Test func kernelTimebaseMatchesNativeTickRate() {
    var numerator: UInt32 = 0
    var denominator: UInt32 = 0
    #expect(ap_kernel_timebase(&numerator, &denominator) == 0)
    var frequency: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    #expect(sysctlbyname("hw.tbfrequency", &frequency, &size, nil, 0) == 0)
    #expect(ap_ticks_to_nanoseconds(frequency, numerator, denominator) == 1_000_000_000)
    #expect(ap_kernel_timebase(nil, &denominator) == EINVAL)
}

private var controllerURL: URL {
    if let path = ProcessInfo.processInfo.environment["CORE_TAMER_TEST_CONTROLLER"] {
        return URL(fileURLWithPath: path)
    }
    // Tests run inside the host app, which embeds the controller like a release build.
    return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CoreTamerController")
}

private func workload() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func cleanup(_ process: Process) {
    if process.isRunning {
        kill(process.processIdentifier, SIGCONT)
        process.terminate()
    }
    process.waitUntilExit()
}

private func measuredCPU(pid: Int32, duration: TimeInterval) throws -> Double {
    let first = try ProcessSnapshot.read(pid: pid)
    let start = ap_monotonic_seconds()
    Thread.sleep(forTimeInterval: duration)
    let second = try ProcessSnapshot.read(pid: pid)
    return Double(second.cpuNanoseconds - first.cpuNanoseconds) / 1e9
        / (ap_monotonic_seconds() - start) * 100
}

@Suite(.serialized)
struct ControllerIntegrationTests {
    private func combinedCPU(_ pids: [Int32], duration: TimeInterval) throws -> Double {
        let before = try pids.map { try ProcessSnapshot.read(pid: $0).cpuNanoseconds }
        let start = ap_monotonic_seconds()
        Thread.sleep(forTimeInterval: duration)
        let after = try pids.map { try ProcessSnapshot.read(pid: $0).cpuNanoseconds }
        let total = zip(before, after).reduce(0.0) { $0 + Double($1.1 - $1.0) / 1e9 }
        return total / (ap_monotonic_seconds() - start) * 100
    }

    @Test func sharedBudgetIncludesNewHelpersAndReleasesRemovedHelpers() throws {
        let leader = try workload()
        let helper = try workload()
        let newcomer = try workload()
        defer {
            cleanup(leader)
            cleanup(helper)
            cleanup(newcomer)
        }
        let root = try ProcessSnapshot.read(pid: leader.processIdentifier)
        let child = try ProcessSnapshot.read(pid: helper.processIdentifier)
        let next = try ProcessSnapshot.read(pid: newcomer.processIdentifier)
        let limiter = try Limiter(
            target: root, percent: 50, executable: controllerURL, includesHelpers: true,
            members: [child])
        defer { limiter.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let initial = try combinedCPU([root.id.pid, child.id.pid], duration: 1.5)
        #expect(initial > 32 && initial < 68)
        try limiter.updateMembers([root, child, next])
        Thread.sleep(forTimeInterval: 0.3)
        let expanded = try combinedCPU([root.id.pid, child.id.pid, next.id.pid], duration: 1.5)
        #expect(expanded > 32 && expanded < 68)
        try limiter.updateMembers([root, child])
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try measuredCPU(pid: next.id.pid, duration: 0.4) > 70)
        #expect(limiter.memberIDs == [root.id, child.id])
        #expect(limiter.stop() == nil)
        #expect(try combinedCPU([root.id.pid, child.id.pid], duration: 0.4) > 120)
        #expect(throws: ProcessFailure.self) { try limiter.updateMembers([root]) }
    }

    @Test(arguments: [SIGKILL, SIGTERM])
    func groupWatchdogResumesEveryMember(signal: Int32) throws {
        let leader = try workload()
        let helper = try workload()
        defer {
            cleanup(leader)
            cleanup(helper)
        }
        let root = try ProcessSnapshot.read(pid: leader.processIdentifier)
        let child = try ProcessSnapshot.read(pid: helper.processIdentifier)
        let limiter = try Limiter(
            target: root, percent: 1, executable: controllerURL, includesHelpers: true,
            members: [child])
        defer { limiter.stop() }
        var bothStopped = false
        for _ in 0..<200 {
            if try ProcessSnapshot.read(pid: root.id.pid).stopped
                && ProcessSnapshot.read(pid: child.id.pid).stopped
            {
                bothStopped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(bothStopped)
        #expect(kill(limiter.controllerPID, signal) == 0)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try !ProcessSnapshot.read(pid: root.id.pid).stopped)
        #expect(try !ProcessSnapshot.read(pid: child.id.pid).stopped)
    }

    @Test func helperExitKeepsBudgetAndLeaderExitReleasesSurvivors() throws {
        let leader = try workload()
        let helper = try workload()
        let survivor = try workload()
        defer {
            cleanup(leader)
            cleanup(helper)
            cleanup(survivor)
        }
        let root = try ProcessSnapshot.read(pid: leader.processIdentifier)
        let child = try ProcessSnapshot.read(pid: helper.processIdentifier)
        let other = try ProcessSnapshot.read(pid: survivor.processIdentifier)
        let limiter = try Limiter(
            target: root, percent: 50, executable: controllerURL,
            includesHelpers: true, members: [child, other])
        defer { limiter.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        cleanup(helper)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(limiter.isRunning)
        let remaining = try combinedCPU([root.id.pid, other.id.pid], duration: 1)
        #expect(remaining > 32 && remaining < 68)
        cleanup(leader)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(limiter.stop() == nil)
        #expect(try measuredCPU(pid: other.id.pid, duration: 0.4) > 70)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORE_TAMER_TEST_WORKLOAD"] != nil))
    func multicoreLimitUsesMoreThanOneCore() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORE_TAMER_TEST_WORKLOAD"])
        let target = Process()
        target.executableURL = URL(fileURLWithPath: path)
        try target.run()
        defer { cleanup(target) }
        let info = try ProcessSnapshot.read(pid: target.processIdentifier)
        let baseline = try measuredCPU(pid: info.id.pid, duration: 0.5)
        let limiter = try Limiter(target: info, percent: 150, executable: controllerURL)
        defer { limiter.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let limited = try measuredCPU(pid: info.id.pid, duration: 2)
        print("Multicore CPU measurement: target=150% baseline=\(baseline)% limited=\(limited)%")
        #expect(baseline > 200)
        #expect(limited > 120)
        #expect(limited < 180)
    }

    @Test func controllerRejectsMalformedAndUnsafeRequests() throws {
        let target = try workload()
        defer { cleanup(target) }
        let info = try ProcessSnapshot.read(pid: target.processIdentifier)
        let valid = [
            String(info.id.pid), String(info.id.seconds), String(info.id.microseconds), "50",
        ]
        var requests: [[String]] = [
            [], ["-1", "0", "0", "50"], ["999999999999", "0", "0", "50"],
            ["", "0", "0", "50"], ["1x", "0", "0", "50"],
            valid + ["--invalid"],
        ]
        for value in ["nan", "inf", "x", "-1", "0", "999999999999999999999999999999999999"] {
            requests.append(Array(valid.prefix(3)) + [value])
        }
        requests.append([valid[0], "0", valid[2], valid[3]])
        for arguments in requests {
            let controller = Process()
            controller.executableURL = controllerURL
            controller.arguments = arguments
            controller.standardInput = FileHandle.nullDevice
            controller.standardError = FileHandle.nullDevice
            try controller.run()
            controller.waitUntilExit()
            #expect(controller.terminationStatus != 0)
        }
        #expect(kill(info.id.pid, SIGSTOP) == 0)
        Thread.sleep(forTimeInterval: 0.02)
        let controller = Process()
        controller.executableURL = controllerURL
        controller.arguments = valid
        controller.standardInput = FileHandle.nullDevice
        controller.standardError = FileHandle.nullDevice
        try controller.run()
        controller.waitUntilExit()
        #expect(controller.terminationStatus != 0)
        #expect(try ProcessSnapshot.read(pid: info.id.pid).stopped)
    }

    @Test(arguments: [20.0, 50.0])
    func limitsActualCPUAndResumesAfterPipeCloses(percent: Double) throws {
        let target = try workload()
        defer { cleanup(target) }
        let original = try ProcessSnapshot.read(pid: target.processIdentifier)
        let baseline = try measuredCPU(pid: original.id.pid, duration: 0.4)
        let limiter = try Limiter(target: original, percent: percent, executable: controllerURL)
        defer { limiter.stop() }
        Thread.sleep(forTimeInterval: 0.25)
        #expect(limiter.isRunning)
        let limited = try measuredCPU(pid: original.id.pid, duration: 1.5)
        print("CPU measurement: target=\(percent)% baseline=\(baseline)% limited=\(limited)%")
        #expect(baseline > percent * 1.3)
        #expect(limited >= percent * 0.65)
        #expect(limited <= percent * 1.3)
        #expect(limited < baseline)
        #expect(limiter.stop() == nil)
        let restored = try measuredCPU(pid: original.id.pid, duration: 0.4)
        #expect(restored > limited * 1.25)
        #expect(limiter.failure() == nil)
    }

    @Test func validatesInputsBeforeLaunch() throws {
        let target = try workload()
        defer { cleanup(target) }
        let info = try ProcessSnapshot.read(pid: target.processIdentifier)
        for percent in [Double.nan, .infinity, 0, -10, 1_000_000] {
            #expect(throws: ProcessFailure.self) {
                try Limiter(target: info, percent: percent, executable: controllerURL)
            }
        }
        #expect(throws: ProcessFailure.self) {
            try Limiter(target: snapshot(uid: 0), percent: 50, executable: controllerURL)
        }
        #expect(throws: (any Error).self) {
            try Limiter(target: info, percent: 50, executable: URL(fileURLWithPath: "/nonexistent"))
        }
    }

    @Test func targetExitAndControllerFailureAreVisible() throws {
        let target = try workload()
        let info = try ProcessSnapshot.read(pid: target.processIdentifier)
        let limiter = try Limiter(target: info, percent: 50, executable: controllerURL)
        Thread.sleep(forTimeInterval: 0.1)
        cleanup(target)
        Thread.sleep(forTimeInterval: 0.15)
        #expect(limiter.stop() == nil)
        let invalid = try Limiter(target: info, percent: 50, executable: controllerURL)
        Thread.sleep(forTimeInterval: 0.15)
        #expect(invalid.stop()?.contains("cannot inspect target") == true)
    }

    @Test(arguments: [SIGKILL, SIGTERM])
    func controllerExitResumesStoppedTarget(signal: Int32) throws {
        let target = try workload()
        defer { cleanup(target) }
        let info = try ProcessSnapshot.read(pid: target.processIdentifier)
        let process = Process()
        let input = Pipe()
        process.executableURL = controllerURL
        process.arguments = [
            String(info.id.pid), String(info.id.seconds), String(info.id.microseconds), "1",
        ]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var foundStopped = false
        for _ in 0..<200 {
            if try ProcessSnapshot.read(pid: info.id.pid).stopped {
                foundStopped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(foundStopped)
        #expect(kill(process.processIdentifier, signal) == 0)
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.15)
        #expect(try !ProcessSnapshot.read(pid: info.id.pid).stopped)
        #expect(try measuredCPU(pid: info.id.pid, duration: 0.25) > 10)
    }

    @Test func releasingLimiterClosesItsLifetimePipe() throws {
        let target = try workload()
        defer { cleanup(target) }
        let info = try ProcessSnapshot.read(pid: target.processIdentifier)
        var limiter: Limiter? = try Limiter(target: info, percent: 1, executable: controllerURL)
        #expect(limiter?.isRunning == true)
        Thread.sleep(forTimeInterval: 0.15)
        limiter = nil
        Thread.sleep(forTimeInterval: 0.15)
        #expect(try !ProcessSnapshot.read(pid: info.id.pid).stopped)
    }
}
