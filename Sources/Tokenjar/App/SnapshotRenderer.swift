import AppKit
import SwiftUI
import TokenjarCore

/// `Tokenjar --render-snapshots <dir>` draws every surface from `AppModel.preview()` to PNGs, in light and
/// dark, then exits. Used to review visuals without screen recording permission. Never touches real data.
enum SnapshotRenderer {
    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)!
            NSApp.appearance = appearance

            let model = AppModel.preview()
            render(PopoverView().environment(model), size: nil, width: 360, appearance: appearance, to: outputDirectory.appending(path: "popover-\(suffix).png"))
            render(PopoverView(maxCardsHeight: 4000).environment(model), size: nil, width: 360, appearance: appearance, to: outputDirectory.appending(path: "popover-full-\(suffix).png"))
            let states = AppModel.previewStates()
            render(PopoverView(maxCardsHeight: 4000).environment(states), size: nil, width: 360, appearance: appearance, to: outputDirectory.appending(path: "popover-states-\(suffix).png"))
            renderStatusIcon(states.menuBarState, appearance: appearance, to: outputDirectory.appending(path: "menubar-states-\(suffix).png"))

            model.dashboardSelection = nil
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-all-\(suffix).png"))
            model.dashboardSelection = "claude-work"
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-account-\(suffix).png"))
            render(DashboardView(range: .month, grouping: .project).environment(model), size: NSSize(width: 980, height: 1400), appearance: appearance, to: outputDirectory.appending(path: "dashboard-account-tall-\(suffix).png"))
            render(DashboardView().environment(model), size: NSSize(width: 760, height: 520), appearance: appearance, to: outputDirectory.appending(path: "dashboard-account-small-\(suffix).png"))
            model.dashboardSelection = "antigravity"
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-antigravity-\(suffix).png"))
            model.dashboardSelection = "copilot"
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-copilot-\(suffix).png"))
            model.dashboardSelection = "devin"
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-devin-\(suffix).png"))
            model.dashboardSelection = "opencode-zen"
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-zen-\(suffix).png"))
            model.dashboardSelection = nil
            render(DashboardView(range: .day).environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-all-day-\(suffix).png"))
            render(DashboardView(range: .month, grouping: .harness).environment(model), size: NSSize(width: 980, height: 1400), appearance: appearance, to: outputDirectory.appending(path: "dashboard-all-tall-\(suffix).png"))

            model.settingsSelection = nil
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 560), appearance: appearance, to: outputDirectory.appending(path: "settings-general-\(suffix).png"))
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 900), appearance: appearance, to: outputDirectory.appending(path: "settings-general-tall-\(suffix).png"))
            model.config.menuBar.icon = .logoClaude
            model.config.menuBar.mode = .icon
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 900), appearance: appearance, to: outputDirectory.appending(path: "settings-general-logo-\(suffix).png"))
            model.config.menuBar.mode = .bars
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 900), appearance: appearance, to: outputDirectory.appending(path: "settings-general-bars-\(suffix).png"))
            model.config.menuBar = MenuBarConfig()
            model.settingsSelection = "claude-work"
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 560), appearance: appearance, to: outputDirectory.appending(path: "settings-account-\(suffix).png"))
            model.settingsSelection = "copilot"
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 900), appearance: appearance, to: outputDirectory.appending(path: "settings-copilot-\(suffix).png"))
            model.settingsSelection = "devin"
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 900), appearance: appearance, to: outputDirectory.appending(path: "settings-devin-\(suffix).png"))

            for mode in MenuBarMode.allCases {
                model.config.menuBar.mode = mode
                renderStatusIcon(model.menuBarState, appearance: appearance, to: outputDirectory.appending(path: "menubar-\(mode.rawValue)-\(suffix).png"))
            }

            let slots = slotStates(now: model.now)
            for (name, _, state) in slots {
                renderStatusIcon(state, appearance: appearance, to: outputDirectory.appending(path: "menubar-slot-\(name)-\(suffix).png"))
            }
            let sheet = slots.map { ($0.label, [StatusIconRenderer.render($0.state)]) }
            render(StatusItemSheet(rows: sheet), size: nil, width: 360, appearance: appearance, to: outputDirectory.appending(path: "menubar-slot-sheet-\(suffix).png"))

            var choices: [(label: String, rendered: [RenderedStatusIcon])] = []
            for icon in MenuBarIcon.allCases {
                let states = choiceStates(icon, now: model.now)
                let slug = icon.rawValue.replacingOccurrences(of: ":", with: "-")
                renderStatusIcon(states[0], appearance: appearance, to: outputDirectory.appending(path: "menubar-choice-\(slug)-\(suffix).png"))
                choices.append((icon.title, states.map(StatusIconRenderer.render)))
            }
            render(StatusItemSheet(rows: choices), size: nil, width: 780, appearance: appearance, to: outputDirectory.appending(path: "menubar-choices-\(suffix).png"))
            render(MenuBarIconMenuSheet(), size: nil, width: 240, appearance: appearance, to: outputDirectory.appending(path: "menubar-picker-items-\(suffix).png"))
        }
        print("Rendered snapshots to \(outputDirectory.path)")
    }

    /// One pool per capture, so a closed window's views go away instead of reloading on every later model change.
    private static func render<V: View>(_ view: V, size: NSSize?, width: CGFloat? = nil, appearance: NSAppearance, to url: URL) {
        autoreleasepool { renderOnce(view, size: size, width: width, appearance: appearance, to: url) }
    }

    private static func renderOnce<V: View>(_ view: V, size: NSSize?, width: CGFloat?, appearance: NSAppearance, to url: URL) {
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        var target = size ?? NSSize(width: width ?? 360, height: 10)
        if size == nil {
            hosting.frame = NSRect(x: 0, y: 0, width: target.width, height: 2000)
            hosting.layoutSubtreeIfNeeded()
            target.height = min(2400, max(120, hosting.fittingSize.height))
        }
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: target.width, height: target.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // The pool releases it; close() releasing it too would free it twice.
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: target)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    /// Draws the status item contents on a strip shaped like the menu bar, at 2x.
    private static func renderStatusIcon(_ state: MenuBarState, appearance: NSAppearance, to url: URL) {
        let button = StatusItemPreview.button(StatusIconRenderer.render(state))
        button.appearance = appearance
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: max(60, button.frame.width + 24), height: 24))
        strip.appearance = appearance
        strip.wantsLayer = true
        strip.layer?.backgroundColor = (appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
        button.frame.origin = NSPoint(x: 12, y: (24 - button.frame.height) / 2)
        strip.addSubview(button)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: strip.frame.width, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        guard let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) else { return }
        strip.cacheDisplay(in: strip.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    /// Every look of the app mark: fill levels, severity tints, stale, the error dot, the neutral state, the offline
    /// slash, settings problems and Bars.
    static func slotStates(now: Date) -> [(name: String, label: String, state: MenuBarState)] {
        func entry(_ used: Double?, _ severity: Severity = .ok, stale: Bool = false, error: Bool = false, id: String = "preview") -> MenuBarState.Entry {
            let window = used.map { UsageWindow(id: "session", label: "5-hour", usedPercent: $0, windowMinutes: 300, resetsAt: now.addingTimeInterval(47 * 60)) }
            return MenuBarState.Entry(
                accountID: id, provider: .claude, label: id == "preview" ? "Preview" : id, tightest: window, severity: severity, isStale: stale,
                attention: error ? .actionable : nil, failureNeedsAttention: error, fetchedAt: used.map { _ in now.addingTimeInterval(stale ? -25 * 60 : -60) }
            )
        }
        func state(_ entry: MenuBarState.Entry, mode: MenuBarMode = .worst, connectivity: Connectivity = .online, settings: SettingsProblem? = nil) -> MenuBarState {
            MenuBarState(mode: mode, entries: [entry], showResetCountdownWhenFull: true, now: now, connectivity: connectivity, settingsProblem: settings)
        }
        func bars(_ count: Int, connectivity: Connectivity = .online, error: Bool = false) -> MenuBarState {
            let levels: [Double] = [75, 12, 40]
            let entries = (0..<count).map { entry(levels[$0], stale: connectivity != .online, error: error && $0 == 1, id: "account-\($0)") }
            return MenuBarState(mode: .bars, entries: entries, showResetCountdownWhenFull: true, now: now, connectivity: connectivity)
        }
        let kept = SettingsProblem(
            message: "Could not read config.local.json. Using the last good settings, and nothing is saved until it is fixed and reloaded.",
            file: "config.local.json", nothingLoaded: false
        )
        let unloaded = SettingsProblem(
            message: "Could not read config.json. No settings are loaded, and nothing is saved until it is fixed and reloaded.",
            file: "config.json", nothingLoaded: true
        )
        return [
            ("000", "0 %", state(entry(0))),
            ("030", "30 %", state(entry(30))),
            ("085", "85 %, untinted (Amber at set above 85)", state(entry(85))),
            ("100", "100 %, full", state(entry(100, .critical))),
            ("warn", "85 %, amber", state(entry(85, .warning))),
            ("critical", "97 %, red", state(entry(97, .critical))),
            ("neutral", "No data yet", state(entry(nil))),
            ("neutral-error", "No data, check failed", state(entry(nil, error: true))),
            ("stale", "42 %, out of date", state(entry(42, stale: true))),
            ("stale-warn", "85 %, amber, out of date", state(entry(85, .warning, stale: true))),
            ("stale-critical", "97 %, red, out of date", state(entry(97, .critical, stale: true))),
            ("error", "42 %, check failed", state(entry(42, error: true))),
            ("critical-error", "97 %, red, check failed", state(entry(97, .critical, error: true))),
            ("icon-030", "Icon only, 30 %", state(entry(30), mode: .icon)),
            ("icon-critical", "Icon only, 97 %, red", state(entry(97, .critical), mode: .icon)),
            ("offline", "Offline, 16 %, last checked 25m ago", state(entry(16, stale: true), connectivity: .offline)),
            ("offline-fresh", "Offline, 16 %, last checked 1m ago", state(entry(16), connectivity: .offline)),
            ("offline-warn", "Offline, 85 %, amber", state(entry(85, .warning, stale: true), connectivity: .offline)),
            ("offline-critical", "Offline, 97 %, red", state(entry(97, .critical, stale: true), connectivity: .offline)),
            ("offline-full", "Offline, full (countdown)", state(entry(100, .critical, stale: true), connectivity: .offline)),
            ("offline-neutral", "Offline before any data", state(entry(nil), connectivity: .offline)),
            ("offline-error", "Offline and a check failed", state(entry(16, stale: true, error: true), connectivity: .offline)),
            ("no-answer", "No provider answers, 16 %", state(entry(16, stale: true), connectivity: .noAnswer)),
            ("settings-kept", "Settings unreadable, last good kept", state(entry(16), settings: kept)),
            ("settings-unloaded", "Settings unreadable, none loaded", MenuBarState(mode: .worst, entries: [], showResetCountdownWhenFull: true, now: now, settingsProblem: unloaded)),
            ("offline-icon", "Offline, Icon only", state(entry(16, stale: true), mode: .icon, connectivity: .offline)),
            ("bars-3", "Bars, 3 accounts", bars(3)),
            ("bars-3-error", "Bars, 3 accounts, a check failed", bars(3, error: true)),
            ("offline-bars-1", "Offline, Bars, 1 account", bars(1, connectivity: .offline)),
            ("offline-bars-3", "Offline, Bars, 3 accounts", bars(3, connectivity: .offline)),
        ]
    }

    /// One picker choice at 42 %, amber, full, with no data, out of date, after a failed check and offline.
    private static func choiceStates(_ icon: MenuBarIcon, now: Date) -> [MenuBarState] {
        func state(_ used: Double?, _ severity: Severity = .ok, stale: Bool = false, error: Bool = false, connectivity: Connectivity = .online) -> MenuBarState {
            let window = used.map { UsageWindow(id: "session", label: "5-hour", usedPercent: $0, windowMinutes: 300, resetsAt: now.addingTimeInterval(47 * 60)) }
            let entry = MenuBarState.Entry(accountID: "preview", provider: .claude, label: "Preview", tightest: window, severity: severity, isStale: stale, attention: error ? .actionable : nil, failureNeedsAttention: error)
            return MenuBarState(mode: .worst, icon: icon, entries: [entry], showResetCountdownWhenFull: true, now: now, connectivity: connectivity)
        }
        return [
            state(42), state(85, .warning), state(100, .critical), state(nil), state(42, stale: true), state(42, error: true),
            state(42, stale: true, connectivity: .offline),
        ]
    }
}

/// The icon picker's items laid out the way its menu groups them, since a closed pop-up shows only the selection.
private struct MenuBarIconMenuSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(MenuBarIcon.Group.allCases, id: \.self) { group in
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(group.icons, id: \.self) { icon in
                    MenuBarIconLabel(icon: icon)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Labelled menu bar strips, one row per label, for reviewing several icon states in one image.
private struct StatusItemSheet: View {
    var rows: [(label: String, rendered: [RenderedStatusIcon])]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    Text(rows[index].label).font(.caption).foregroundStyle(.secondary)
                    ForEach(rows[index].rendered.indices, id: \.self) { column in
                        StatusItemPreview(rendered: rows[index].rendered[column])
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
