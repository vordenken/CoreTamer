import AppKit
import CoreTamerCore
import ServiceManagement
import SwiftUI

struct TamerView: View {
    static let size = CGSize(width: 680, height: 660)
    @Bindable var model: AppModel
    @State private var iconCache = ProcessIconCache()
    var updates: UpdateController?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.showsWelcome { welcome }
            if let updates, let version = updates.availableUpdateVersion {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                    Text("Version \(version) is available")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Show Update…") { updates.checkForUpdates() }
                }
                .padding(12)
                .background(.orange.opacity(0.1))
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button {
                        model.error = nil
                    } label: {
                        Image(systemName: "xmark")
                    }

                    .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
                .padding(12).background(.orange.opacity(0.1))
            }
            if model.settingsVisible { settings }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search processes or PID", text: $model.query).textFieldStyle(.plain)
            }.padding(12)
            processList
                .onHover { model.setListHovered($0) }
                .onDisappear { model.setListHovered(false) }
            if model.isListPausedByHover || model.updateSpeed == .paused {
                Text(
                    model.updateSpeed == .paused
                        ? "Updates paused · limits keep running"
                        : "Paused while pointing at the list · limits keep running"
                )
                .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            Divider()
            if let process = model.inspectedProcess { inspector(process) }
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                .accessibilityHidden(true)
            Text("CoreTamer").font(.title2.bold())
            Spacer()
            if model.paused {
                Text("Limits paused").font(.callout.weight(.medium))
            } else if model.limits.isEmpty {
                Text("No active limits").font(.callout.weight(.medium))
            } else if model.limits.count == 1 {
                Text("1 active limit").font(.callout.weight(.medium))
            } else {
                Text(
                    String(
                        format: String(localized: "%lld active limits"),
                        locale: .current,
                        arguments: [model.limits.count]
                    )
                )
                .font(.callout.weight(.medium))
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Maps the native table's sort descriptors to the model's single sort column.
    private var sortOrder: Binding<[KeyPathComparator<ProcessRow>]> {
        Binding(
            get: {
                let order: SortOrder = model.sort.ascending ? .forward : .reverse
                return switch model.sort.column {
                case .name: [KeyPathComparator(\ProcessRow.name, order: order)]
                case .pid: [KeyPathComparator(\ProcessRow.pid, order: order)]
                case .cpu: [KeyPathComparator(\ProcessRow.cpuSortValue, order: order)]
                case .limit: [KeyPathComparator(\ProcessRow.limitSortValue, order: order)]
                }
            },
            set: { comparators in
                guard let first = comparators.first else { return }
                model.setSort(Self.sort(for: first, current: model.sort))
            })
    }

    /// A new column starts with its natural direction (busiest first for CPU and limits).
    static func sort(for comparator: KeyPathComparator<ProcessRow>, current: ProcessSort)
        -> ProcessSort
    {
        let column: ProcessSortColumn =
            switch comparator.keyPath {
            case \ProcessRow.name: .name
            case \ProcessRow.pid: .pid
            case \ProcessRow.limitSortValue: .limit
            default: .cpu
            }
        guard column == current.column else { return ProcessSort(column: column) }
        return ProcessSort(column: column, ascending: comparator.order == .forward)
    }

    /// Executables inside an app bundle show that app's icon instead of the generic Unix one.
    static func iconPath(for path: String) -> String {
        path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
    }

    /// Subtle Task-Manager-style heat: stronger tint for busier rows, adapts to light/dark mode.
    static func heat(_ cpu: Double?) -> Double {
        guard let cpu, cpu >= 1 else { return 0 }
        return 0.08 + min(cpu, 100) / 100 * 0.37
    }

    /// Whole-percent binding: a stepped macOS Slider draws one tick mark per step,
    /// which with hundreds of steps renders as a solid white bar under the track.
    private var wholePercent: Binding<Double> {
        Binding(get: { model.proposedLimit }, set: { model.proposedLimit = $0.rounded() })
    }

    private var processList: some View {
        let sections = model.sections
        return Table(of: ProcessRow.self, selection: selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: iconCache.icon(for: row.process.path))
                        .resizable().frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1)
                    if let helpers = row.helpers {
                        Text("(\(helpers.count + 1))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .help(row.process.path)
            }
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("CPU", value: \.cpuSortValue) { row in
                Text(row.cpu.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 4)
                    .background(
                        .orange.opacity(Self.heat(row.cpu)), in: RoundedRectangle(cornerRadius: 3)
                    )
                    .help(
                        row.helpers == nil
                            ? "Smoothed CPU usage · 100% = one CPU core"
                            : "Smoothed CPU usage of the app and its helpers · 100% = one CPU core")
            }
            .width(min: 55, ideal: 70, max: 90)
            TableColumn("Limit", value: \.limitSortValue) { row in
                limitLabel(row).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 85, max: 110)
        } rows: {
            ForEach(sections) { section in
                if let category = section.category {
                    Section {
                        tableRows(section.rows)
                    } header: {
                        Text(
                            String(
                                format: String(localized: "%1$@ (%2$d)"),
                                locale: .current,
                                arguments: [category.title, section.rows.count]
                            ))
                    }
                } else {
                    tableRows(section.rows)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .background(RepeatedRowClick { model.deselect() })
        .overlay {
            if sections.isEmpty {
                Text("No matching processes").foregroundStyle(.secondary)
            }
        }
    }

    @TableRowBuilder<ProcessRow>
    private func tableRows(_ rows: [ProcessRow]) -> some TableRowContent<ProcessRow> {
        ForEach(rows) { row in
            if let helpers = row.helpers {
                DisclosureTableRow(row) {
                    ForEach(helpers) { TableRow($0) }
                }
            } else {
                TableRow(row)
            }
        }
    }

    private func limitLabel(_ row: ProcessRow) -> some View {
        limitText(row).monospacedDigit()
            .foregroundStyle(
                row.limit == nil && row.limitedHelpers == 0 ? Color.secondary : Color.blue)
    }

    private func limitText(_ row: ProcessRow) -> Text {
        if let limit = row.limit {
            if model.groupLimits.contains(row.id) {
                Text(
                    String(
                        format: String(localized: "%.0f%% total"),
                        locale: .current,
                        arguments: [limit]
                    ))
            } else {
                Text(
                    String(
                        format: String(localized: "%.0f%%"),
                        locale: .current,
                        arguments: [limit]
                    ))
            }
        } else if model.coveringGroup(for: row.id) != nil {
            Text("Shared")
        } else if row.limitedHelpers > 0 {
            Text(
                String(
                    format: String(localized: "%lld limited"),
                    locale: .current,
                    arguments: [row.limitedHelpers]
                ))
        } else {
            Text("No limit")
        }
    }

    private var selection: Binding<ProcessIdentity?> {
        Binding(get: { model.selected }, set: { model.select(id: $0) })
    }

    private func inspector(_ process: ProcessSnapshot) -> some View {
        let group = model.appGroup(containing: process.id)
        let isAppGroup = group?.id == process.id
        let coveringGroup = model.coveringGroup(for: process.id)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(process.name).font(.headline).lineLimit(1)
                Text(
                    String(
                        format: String(localized: "PID %d"),
                        locale: .current,
                        arguments: [process.id.pid]
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("100% = one CPU core").font(.caption).foregroundStyle(.secondary)
                Button {
                    model.deselect()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deselect process")
                .help("Close inspector")
            }
            if isAppGroup {
                Text("App group").font(.caption).foregroundStyle(.secondary)
            } else if let group {
                Text("Individual process · Part of \(group.name)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Individual process").font(.caption).foregroundStyle(.secondary)
            }
            if let coveringGroup {
                if let owner = model.processes.first(where: { $0.id == coveringGroup }),
                    let limit = model.limits[coveringGroup]
                {
                    Text(
                        String(
                            format: String(localized: "Included in %@'s shared %.0f%% limit."),
                            locale: .current,
                            arguments: [owner.name, limit]
                        )
                    )
                    .font(.callout)
                } else {
                    Text("Included in a shared app limit.").font(.callout)
                }
                Text("Remove the app limit before limiting this process individually.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                if isAppGroup {
                    Picker("Limit", selection: $model.proposedIncludesHelpers) {
                        Text("Entire app").tag(true)
                        Text("Main process only").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                limitControls(process, isAppGroup: isAppGroup)
            }
            if let group, !isAppGroup {
                Button(
                    String(
                        format: String(localized: "Select %@ app group"),
                        locale: .current,
                        arguments: [group.name]
                    )
                ) { model.select(id: group.id) }
                .buttonStyle(.link)
            }
        }.padding(14)
    }

    private func limitControls(_ process: ProcessSnapshot, isAppGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Slider(value: wholePercent, in: 1...model.maximumLimit)
                    .accessibilityLabel("CPU limit")
                TextField("Percent", value: $model.proposedLimit, format: .number)
                    .frame(width: 65).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("CPU limit percentage")
                Text("%")
                Button("Apply") {
                    model.apply(
                        process, percent: model.proposedLimit,
                        includesHelpers: isAppGroup && model.proposedIncludesHelpers)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!process.canControl && model.limits[process.id] == nil)
                Button("Remove") { model.remove(process) }.disabled(model.limits[process.id] == nil)
            }
            if !process.canControl && model.limits[process.id] == nil {
                Text("Read-only: protected, already stopped, or owned by another user.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                if isAppGroup && model.proposedIncludesHelpers {
                    Text(
                        String(
                            format: String(
                                localized:
                                    "%.0f%% total, shared across %@ and its helper processes. Newly discovered helpers are included."
                            ),
                            locale: .current,
                            arguments: [model.proposedLimit, process.name]
                        )
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(
                        String(
                            format: String(localized: "Only %@ (PID %d) will be limited."),
                            locale: .current,
                            arguments: [process.name, process.id.pid]
                        )
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Low limits can make an app unresponsive.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // A closure literal instead of the `model.setLogin` method reference: converting the
    // method reference to SwiftUI's setter type crashes the Swift 6.3 compiler (Xcode 26.6).
    private var loginBinding: Binding<Bool> {
        Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to CoreTamer").font(.headline)
            Text(
                "Select a process and set a CPU limit. CoreTamer lives in the menu bar; click its icon to come back."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Toggle(
                    "Launch at login",
                    isOn: loginBinding)
                if let updates {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { updates.automaticallyChecks },
                            set: { updates.automaticallyChecks = $0 }))
                }
                Spacer()
                Button("Get Started") { model.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            if model.loginNeedsApproval {
                Button("Approve CoreTamer in Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        .font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSection("Process list") {
                Toggle(
                    "Show background and system processes (other users are read-only)",
                    isOn: $model.showBackground)
                Toggle("Group by type (apps, background, system)", isOn: $model.groupByType)
                Toggle("Pause list while pointing at it", isOn: $model.pauseListOnHover)
                Picker("Update speed", selection: $model.updateSpeed) {
                    ForEach(UpdateSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            settingsSection("General") {
                Toggle("Restore app limits when apps restart", isOn: $model.restoreLimits)
                Text(
                    "Restoration uses the app executable path, never a saved PID. No administrator access is used."
                )
                .font(.caption2).foregroundStyle(.secondary)
                Toggle(
                    "Launch at login",
                    isOn: loginBinding)
                if model.loginNeedsApproval {
                    Button("Approve CoreTamer in Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            settingsSection("Updates") {
                if let updates { UpdateSettings(updates: updates) }
            }
        }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3))
    }

    private func settingsSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Button(model.paused ? "Resume all limits" : "Pause all limits") { model.togglePause() }
                .disabled(model.limits.isEmpty)
            Spacer()
            Button {
                model.settingsVisible.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            Button("Quit") { NSApp.terminate(nil) }
        }.padding(12)
    }
}

struct UpdateSettings: View {
    @Bindable var updates: UpdateController

    var body: some View {
        HStack {
            Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
            Toggle("Download automatically", isOn: $updates.automaticallyDownloads)
            Toggle("Beta versions", isOn: $updates.betaUpdates)
            Spacer()
            Button("Check Now…") { updates.checkForUpdates() }
        }
    }
}

/// SwiftUI's selection binding does not fire when an already selected native row is clicked.
struct RepeatedRowClick: NSViewRepresentable {
    let deselect: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ClickRegion()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak view] event in
            guard let view else { return event }
            return Self.handle(event, in: view, deselect: deselect)
        }
        return view
    }

    static func handle(_ event: NSEvent, in view: NSView, deselect: () -> Void) -> NSEvent? {
        guard event.window === view.window,
            event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
            view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
            let content = event.window?.contentView
        else { return event }
        // hitTest expects coordinates in the receiver's superview, not its (possibly flipped) bounds.
        let point =
            content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var hit = content.hitTest(point)
        while let current = hit {
            // Disclosure triangles must keep their native expand/collapse behaviour.
            if current is NSButton { return event }
            if let table = current as? NSTableView {
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                if row >= 0 && table.isRowSelected(row) {
                    table.deselectRow(row)
                    deselect()
                    return nil
                }
                return event
            }
            hit = current.superview
        }
        return event
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    final class Coordinator {
        var monitor: Any?
    }

    final class ClickRegion: NSView {}
}
