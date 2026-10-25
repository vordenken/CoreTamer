import Darwin
import Foundation
import ProcessControl

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(pid: Int32, seconds: UInt64, microseconds: UInt64) {
        self.pid = pid
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct ProcessSnapshot: Identifiable, Sendable {
    public let id: ProcessIdentity
    public let uid: UInt32
    public let parent: Int32
    /// The process macOS holds responsible, e.g. Safari for its WebKit content processes.
    public let responsible: Int32
    public let name: String
    public let path: String
    public let cpuNanoseconds: UInt64
    public let stopped: Bool

    public var canControl: Bool {
        uid == getuid() && uid != 0 && id.pid > 1 && id.pid != getpid() && id.pid != getppid()
            && !stopped
            && !["loginwindow", "WindowServer", "Dock", "SystemUIServer", "CoreTamerController"]
                .contains(
                    name)
    }

    public init(
        id: ProcessIdentity, uid: UInt32, parent: Int32 = 0, responsible: Int32? = nil,
        name: String,
        path: String, cpuNanoseconds: UInt64, stopped: Bool
    ) {
        self.id = id
        self.uid = uid
        self.parent = parent
        self.responsible = responsible ?? id.pid
        self.name = name
        self.path = path
        self.cpuNanoseconds = cpuNanoseconds
        self.stopped = stopped
    }

    public static func read(pid: Int32) throws -> Self {
        var info = APProcessInfo()
        let error = ap_process_read(pid, &info)
        guard error == 0 else {
            throw ProcessFailure(
                operation: String(
                    format: String(localized: "Inspect PID %d"),
                    locale: .current,
                    arguments: [pid]
                ),
                code: error)
        }
        var path = [CChar](repeating: 0, count: 4096)
        let pathError = ap_process_path(pid, &path, UInt32(path.count))
        guard pathError == 0 else {
            throw ProcessFailure(
                operation: String(
                    format: String(localized: "Read executable path for PID %d"),
                    locale: .current,
                    arguments: [pid]
                ),
                code: pathError)
        }
        var name = [CChar](repeating: 0, count: 1024)
        let nameError = ap_process_name(pid, &name, UInt32(name.count))
        guard nameError == 0 else {
            throw ProcessFailure(
                operation: String(
                    format: String(localized: "Read name for PID %d"),
                    locale: .current,
                    arguments: [pid]
                ),
                code: nameError)
        }
        return Self(
            id: ProcessIdentity(
                pid: pid, seconds: info.start_seconds, microseconds: info.start_microseconds),
            uid: info.uid, parent: info.parent, responsible: ap_process_responsible(pid),
            name: String(
                decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            path: String(
                decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            cpuNanoseconds: info.cpu_nanoseconds, stopped: info.stopped != 0
        )
    }

    public static func all() throws -> [Self] {
        let bytes = ap_process_list(nil, 0)
        guard bytes > 0 else {
            throw ProcessFailure(
                operation: String(localized: "List processes"), code: errno == 0 ? EIO : errno)
        }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 1024)
        let actual = ap_process_list(&pids, UInt32(pids.count))
        guard actual > 0 else {
            throw ProcessFailure(
                operation: String(localized: "Read process list"),
                code: errno == 0 ? EIO : errno)
        }
        var snapshots: [Self] = []
        for pid in pids.prefix(Int(actual) / MemoryLayout<pid_t>.size) where pid > 0 {
            do {
                snapshots.append(try read(pid: pid))
            } catch let failure as ProcessFailure
                where [ESRCH, EPERM, EACCES].contains(failure.code)
            {
                // Processes exit during enumeration; macOS also hides protected process details.
                continue
            }
        }
        return snapshots
    }
}

public struct ProcessFailure: LocalizedError, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var errorDescription: String? {
        String(
            format: String(localized: "%1$@: %2$@ (%3$d)."),
            locale: .current,
            arguments: [operation, String(cString: strerror(code)), code]
        )
    }
}

public struct CPUSampler {
    private var previous: [ProcessIdentity: UInt64] = [:]
    private var timestamp: TimeInterval?

    public init() {}

    public mutating func sample(_ processes: [ProcessSnapshot], at time: TimeInterval)
        -> [ProcessIdentity: Double]
    {
        defer {
            previous = Dictionary(
                uniqueKeysWithValues: processes.map { ($0.id, $0.cpuNanoseconds) })
            timestamp = time
        }
        guard let timestamp, time > timestamp else { return [:] }
        var values: [ProcessIdentity: Double] = [:]
        for process in processes {
            if let before = previous[process.id], process.cpuNanoseconds >= before {
                values[process.id] =
                    Double(process.cpuNanoseconds - before) / 1e9 / (time - timestamp) * 100
            }
        }
        return values
    }
}

/// Time-weighted smoothing for display only; CPU enforcement uses the raw process counters.
public struct CPUDisplaySmoother {
    private var values: [ProcessIdentity: Double] = [:]
    private var timestamp: TimeInterval?

    public init() {}

    public mutating func sample(_ cpu: [ProcessIdentity: Double], at time: TimeInterval)
        -> [ProcessIdentity: Double]
    {
        let weight = timestamp.map { 1 - exp(-max(0, time - $0) / 5) } ?? 1
        values = cpu.reduce(into: [:]) { result, entry in
            let (id, current) = entry
            result[id] = values[id].map { $0 + weight * (current - $0) } ?? current
        }
        timestamp = time
        return values
    }
}

/// Keeps row positions stable between sort updates and while the list is held.
public struct ProcessListOrder {
    public private(set) var ids: [ProcessIdentity] = []
    private var lastSort: TimeInterval?

    public init() {}

    public mutating func update(
        _ sorted: [ProcessIdentity], at time: TimeInterval, frozen: Bool, force: Bool = false,
        interval: TimeInterval = 5
    ) {
        if force || lastSort == nil || (!frozen && time - (lastSort ?? time) >= interval) {
            ids = sorted
            lastSort = time
        } else {
            let live = Set(sorted)
            ids.removeAll { !live.contains($0) }
            let existing = Set(ids)
            ids.append(contentsOf: sorted.filter { !existing.contains($0) })
        }
    }
}

/// Table column used for ordering the process list.
public enum ProcessSortColumn: String, CaseIterable, Sendable {
    case name = "Name"
    case pid = "PID"
    case cpu = "CPU"
    case limit = "Limit"

    /// Load columns start with the largest value; names and PIDs start ascending.
    public var defaultAscending: Bool { self == .name || self == .pid }
}

/// A sortable-table state: the active column and its direction.
public struct ProcessSort: Equatable, Sendable {
    public var column: ProcessSortColumn
    public var ascending: Bool

    public init(column: ProcessSortColumn, ascending: Bool? = nil) {
        self.column = column
        self.ascending = ascending ?? column.defaultAscending
    }

    public static let cpu = ProcessSort(column: .cpu)
    public static let name = ProcessSort(column: .name)
    public static let limit = ProcessSort(column: .limit)

    /// Clicking the active header flips direction; another header starts with its default.
    public func selecting(_ next: ProcessSortColumn) -> ProcessSort {
        next == column
            ? ProcessSort(column: column, ascending: !ascending) : ProcessSort(column: next)
    }
}

/// A running application as reported by the window server.
public struct RunningApp: Equatable, Sendable {
    public let pid: Int32
    public let bundlePath: String?
    /// `true` for apps with a Dock icon and windows (`NSApplication.ActivationPolicy.regular`).
    public let regular: Bool

    public init(pid: Int32, bundlePath: String?, regular: Bool) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.regular = regular
    }
}

/// Task-Manager-style process type; the raw value is the fixed section order.
public enum ProcessCategory: Int, CaseIterable, Sendable {
    case apps
    case background
    case system

    public var title: String {
        switch self {
        case .apps: String(localized: "Apps")
        case .background: String(localized: "Background processes")
        case .system: String(localized: "System & other users")
        }
    }
}

/// One table row: a process plus, for apps, the helper processes it launched.
public struct ProcessRow: Identifiable, Sendable {
    public let process: ProcessSnapshot
    /// Own smoothed CPU plus all helpers; `nil` until the first sample exists.
    public let cpu: Double?
    public let limit: Double?
    public internal(set) var helpers: [ProcessRow]?

    public var id: ProcessIdentity { process.id }
    public var name: String { process.name }
    public var pid: Int32 { process.id.pid }
    public var cpuSortValue: Double { cpu ?? 0 }
    /// Highest limit in the group; unlimited rows rank below any limit.
    public var limitSortValue: Double {
        (helpers ?? []).reduce(limit ?? -1) { max($0, $1.limitSortValue) }
    }
    public var limitedHelpers: Int { (helpers ?? []).filter { $0.limit != nil }.count }
}

/// Rows of one process type, or of the whole list when grouping by type is off.
public struct ProcessSection: Identifiable, Sendable {
    public let category: ProcessCategory?
    public internal(set) var rows: [ProcessRow]

    public var id: Int { category?.rawValue ?? -1 }
    /// Rows in display order including expanded helpers; used to rank the list.
    public var allIDs: [ProcessIdentity] { rows.flatMap { [$0.id] + ($0.helpers ?? []).map(\.id) } }
}

/// Builds Task-Manager-style sections: apps, background and system processes, with helpers
/// folded under the app macOS holds responsible, whose bundle contains them or that launched them.
public func groupedProcesses(
    _ processes: [ProcessSnapshot], apps: [RunningApp], query: String, showBackground: Bool,
    groupByType: Bool, sort: ProcessSort, cpu: [ProcessIdentity: Double],
    limits: [ProcessIdentity: Double] = [:]
) -> [ProcessSection] {
    let user = getuid()
    let appsByPID = Dictionary(apps.map { ($0.pid, $0) }) { first, _ in first }
    let byPID = Dictionary(processes.map { ($0.id.pid, $0) }) { first, _ in first }
    // Longest bundle path first so helpers of a nested running app join that app.
    let bundles = apps.compactMap { app in
        app.bundlePath.map { ($0.hasSuffix("/") ? $0 : $0 + "/", app.pid) }
    }.filter { byPID[$0.1] != nil }.sorted { $0.0.count > $1.0.count }

    func isSystem(_ process: ProcessSnapshot) -> Bool { process.uid != user || process.uid == 0 }
    func owner(of process: ProcessSnapshot, depth: Int = 0) -> Int32? {
        if appsByPID[process.id.pid]?.regular == true { return process.id.pid }
        // An XPC service started by launchd still names its client app as responsible process.
        // Only app leaders or responsibility roots are followed, so bad data cannot loop.
        if depth < 32, process.responsible != process.id.pid,
            let responsible = byPID[process.responsible], !isSystem(responsible),
            appsByPID[responsible.id.pid]?.regular == true
                || responsible.responsible == responsible.id.pid
        {
            return owner(of: responsible, depth: depth + 1) ?? responsible.id.pid
        }
        if appsByPID[process.id.pid] != nil { return process.id.pid }
        if let bundle = bundles.first(where: { process.path.hasPrefix($0.0) }) { return bundle.1 }
        // Fall back to the launching process (e.g. a shell under Terminal); depth guards PID loops.
        guard depth < 32, process.parent > 1, let parent = byPID[process.parent], !isSystem(parent)
        else { return nil }
        return owner(of: parent, depth: depth + 1)
    }

    var leaders: [ProcessSnapshot] = []
    var helpers: [Int32: [ProcessSnapshot]] = [:]
    for process in processes {
        if !isSystem(process), let owner = owner(of: process), owner != process.id.pid {
            helpers[owner, default: []].append(process)
        } else {
            leaders.append(process)
        }
    }

    func matches(_ process: ProcessSnapshot) -> Bool {
        query.isEmpty || process.name.localizedCaseInsensitiveContains(query)
            || String(process.id.pid).contains(query)
    }
    func ordered(_ rows: [ProcessRow]) -> [ProcessRow] {
        rows.sorted {
            let order: ComparisonResult
            switch sort.column {
            case .name: order = $0.name.localizedStandardCompare($1.name)
            case .pid: order = compare(Double($0.pid), Double($1.pid))
            case .cpu: order = compare($0.cpuSortValue, $1.cpuSortValue)
            case .limit: order = compare($0.limitSortValue, $1.limitSortValue)
            }
            // Ties always use ascending PID so the list stays stable between refreshes.
            if order == .orderedSame { return $0.pid < $1.pid }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
    func row(_ process: ProcessSnapshot, helpers: [ProcessSnapshot]) -> ProcessRow {
        let children = ordered(helpers.map { row($0, helpers: []) })
        let samples = ([cpu[process.id]] + children.map(\.cpu)).compactMap { $0 }
        return ProcessRow(
            process: process, cpu: samples.isEmpty ? nil : samples.reduce(0, +),
            limit: limits[process.id], helpers: children.isEmpty ? nil : children)
    }

    var rows: [ProcessCategory: [ProcessRow]] = [:]
    for leader in leaders {
        let category: ProcessCategory =
            isSystem(leader)
            ? .system : (appsByPID[leader.id.pid]?.regular == true ? .apps : .background)
        guard showBackground || (category != .system && appsByPID[leader.id.pid] != nil) else {
            continue
        }
        let group = helpers[leader.id.pid] ?? []
        let shown = matches(leader) ? group : group.filter(matches)
        guard matches(leader) || !shown.isEmpty else { continue }
        rows[category, default: []].append(row(leader, helpers: shown))
    }
    guard groupByType else {
        let all = ordered(rows.values.flatMap { $0 })
        return all.isEmpty ? [] : [ProcessSection(category: nil, rows: all)]
    }
    return ProcessCategory.allCases.compactMap { category in
        rows[category].map { ProcessSection(category: category, rows: ordered($0)) }
    }
}

extension Array where Element == ProcessSection {
    /// Reorders rows and helpers by a held rank; rows without a rank keep their sorted position
    /// after all ranked rows.
    public func ranked(by ranks: [ProcessIdentity: Int]) -> [ProcessSection] {
        func apply(_ rows: [ProcessRow]) -> [ProcessRow] {
            rows.enumerated().sorted {
                (ranks[$0.element.id] ?? Int.max, $0.offset) < (
                    ranks[$1.element.id] ?? Int.max, $1.offset
                )
            }.map { entry in
                var row = entry.element
                row.helpers = row.helpers.map(apply)
                return row
            }
        }
        return map { section in
            var section = section
            section.rows = apply(section.rows)
            return section
        }
    }
}

private func compare(_ first: Double, _ second: Double) -> ComparisonResult {
    first == second ? .orderedSame : (first < second ? .orderedAscending : .orderedDescending)
}

/// How often the list refreshes, like Task Manager's "Update speed"; limits are enforced
/// independently by the controllers and keep working while the display is paused.
public enum UpdateSpeed: String, CaseIterable, Sendable {
    case fast
    case normal
    case slow
    case paused

    public var title: String {
        switch self {
        case .fast: String(localized: "Fast (1 s)")
        case .normal: String(localized: "Normal (2 s)")
        case .slow: String(localized: "Slow (5 s)")
        case .paused: String(localized: "Paused")
        }
    }

    /// Display refresh interval; `nil` while paused.
    public var interval: TimeInterval? {
        switch self {
        case .fast: 1
        case .normal: 2
        case .slow: 5
        case .paused: nil
        }
    }
}
