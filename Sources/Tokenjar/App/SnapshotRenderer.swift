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
            model.dashboardSelection = "opencode-zen"
            render(DashboardView().environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-zen-\(suffix).png"))
            model.dashboardSelection = nil
            render(DashboardView(range: .day).environment(model), size: NSSize(width: 980, height: 660), appearance: appearance, to: outputDirectory.appending(path: "dashboard-all-day-\(suffix).png"))
            render(DashboardView(range: .month, grouping: .harness).environment(model), size: NSSize(width: 980, height: 1400), appearance: appearance, to: outputDirectory.appending(path: "dashboard-all-tall-\(suffix).png"))

            model.settingsSelection = nil
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 560), appearance: appearance, to: outputDirectory.appending(path: "settings-general-\(suffix).png"))
            model.settingsSelection = "claude-work"
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 560), appearance: appearance, to: outputDirectory.appending(path: "settings-account-\(suffix).png"))
            model.settingsSelection = "copilot"
            render(SettingsView().environment(model), size: NSSize(width: 760, height: 900), appearance: appearance, to: outputDirectory.appending(path: "settings-copilot-\(suffix).png"))

            for mode in MenuBarMode.allCases {
                model.config.menuBar.mode = mode
                renderStatusIcon(model.menuBarState, appearance: appearance, to: outputDirectory.appending(path: "menubar-\(mode.rawValue)-\(suffix).png"))
            }
        }
        print("Rendered snapshots to \(outputDirectory.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize?, width: CGFloat? = nil, appearance: NSAppearance, to url: URL) {
        let root = view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        var target = size ?? NSSize(width: width ?? 360, height: 10)
        if size == nil {
            hosting.frame = NSRect(x: 0, y: 0, width: target.width, height: 2000)
            hosting.layoutSubtreeIfNeeded()
            target.height = min(1400, max(120, hosting.fittingSize.height))
        }
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: target.width, height: target.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
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
        let rendered = StatusIconRenderer.render(state)
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.appearance = appearance
        button.image = rendered.image
        // An off-screen NSButton draws template images mid-gray; the real status bar draws them at label contrast.
        button.contentTintColor = .labelColor
        button.imagePosition = .imageLeading
        if rendered.attributedTitle.length > 0 { button.attributedTitle = rendered.attributedTitle } else { button.title = rendered.title }
        button.sizeToFit()
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
}
