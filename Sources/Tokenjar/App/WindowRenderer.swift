import AppKit
import SwiftUI
import TokenjarCore

/// `Tokenjar --render-windows <dir> [--real-data] [--only <name-prefix>]` opens the windows the app opens, built by
/// the same code (`WindowPresenter.makeWindow`, `AppDelegate.popoverContent`, `AppDelegate.show`), lets each settle,
/// and saves it with the app's own drawing as `<screen>-<light|dark>.png` at 2x, title bar included. Status item strips
/// are also saved at 1x as `<screen>-<light|dark>@1x.png`. Prints each file written.
///
/// Windows stay off every screen and the app never activates, so the frontmost app keeps keyboard focus. `CaptureWindow`
/// stands in for the key window an activation would give: it draws as key and ends up with the focus the app leaves it.
///
/// Data is `AppModel.preview()` and the `PreviewPlans` pages, or with `--real-data` this Mac's config and a copy of its
/// history (`RealDataLoader`).
enum WindowRenderer {
    static func run(_ options: WindowRenderOptions) {
        RenderSession(options: options).render()
    }
}

private final class RenderSession {
    private let options: WindowRenderOptions
    private var slugs: [String: String] = [:]

    private static let offscreen = NSPoint(x: -30_000, y: -30_000)
    private static let openDelay: TimeInterval = 0.8
    private static let stepDelay: TimeInterval = 0.6
    private static let scrollDelay: TimeInterval = 0.3
    private static let largeDashboard = NSSize(width: 1440, height: 900)
    private static let menuBarHeight: CGFloat = 24

    init(options: WindowRenderOptions) {
        self.options = options
    }

    private struct RenderData {
        var model: AppModel
        /// Edge states, no accounts at all, a config that failed to reload, and a screen too short for the popover:
        /// preview data only.
        var states: AppModel?
        var empty: AppModel?
        var configError: AppModel?
        var short: AppModel?
        var menuBar: [(name: String, state: MenuBarState)]
        var plans: [(name: String, model: AppModel)] = []
        /// Plan rows with usage history, the only ones whose dashboard page has more than All to show.
        var planHistory: Set<String> = []
    }

    func render() {
        let fm = FileManager.default
        try? fm.createDirectory(at: options.directory, withIntermediateDirectories: true)
        let scratch = options.directory.deletingLastPathComponent().appending(path: ".tokenjar-render-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }

        let data = makeData(scratch: scratch)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: name) else { continue }
            NSApp.appearance = appearance
            renderSettings(data.model, appearance: appearance, suffix: suffix)
            renderSettingsAccounts(data.model, prefix: "settings-narrow", size: WindowPresenter.Spec.settings.minSize, appearance: appearance, suffix: suffix)
            renderDashboard(data.model, appearance: appearance, suffix: suffix)
            renderPopover(data.model, screen: "popover", appearance: appearance, suffix: suffix)
            if let short = data.short {
                renderPopover(short, screen: "popover-short", appearance: appearance, suffix: suffix)
            }
            if let states = data.states {
                renderPopover(states, screen: "popover-states", appearance: appearance, suffix: suffix)
                renderSettingsAccounts(states, prefix: "settings-states", appearance: appearance, suffix: suffix)
                renderDashboard(states, prefix: "dashboard-states", sizes: ["default"], appearance: appearance, suffix: suffix)
            }
            if let empty = data.empty {
                renderSettings(empty, opening: .accounts, appearance: appearance, suffix: suffix) { _ in [Step(screen: "settings-accounts-empty") {}] }
                renderPopover(empty, screen: "popover-empty", appearance: appearance, suffix: suffix)
            }
            if let failed = data.configError {
                renderSettings(failed, opening: .accounts, appearance: appearance, suffix: suffix) { controller in
                    [
                        Step(screen: "settings-config-error-accounts") {},
                        Step(screen: "settings-config-error-alerts") { controller.rootView = SettingsRoot(model: failed, pane: .alerts) },
                    ]
                }
            }
            for page in data.plans {
                renderPopover(page.model, screen: "popover-\(page.name)", appearance: appearance, suffix: suffix)
                renderSettingsAccounts(page.model, prefix: "settings-\(page.name)", appearance: appearance, suffix: suffix)
                renderDashboard(
                    page.model, prefix: "dashboard-\(page.name)", sizes: ["default"],
                    accounts: page.model.accounts.filter { data.planHistory.contains($0.id) }, appearance: appearance, suffix: suffix
                )
            }
            renderMenuBar(data.menuBar, appearance: appearance, suffix: suffix)
        }
    }

    private func makeData(scratch: URL) -> RenderData {
        if options.realData {
            let loaded = RealDataLoader(paths: AppPaths(), scratch: scratch).load()
            for warning in loaded.warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
            return RenderData(model: loaded.model, menuBar: [("real", loaded.model.menuBarState)])
        }
        let model = AppModel.preview()
        let states = AppModel.previewStates()
        let empty = AppModel.previewEmpty()
        let configError = AppModel.preview()
        configError.showFailedLoad(of: "config.json", nothingLoaded: false)
        let short = AppModel.preview()
        short.popoverMaxHeight = 400
        let plans = PreviewPlans.pages(now: model.now)
        for preview in [model, states, empty, configError, short] + plans.map(\.model) { preview.secrets = SessionSecretStore(InMemorySecretStore()) }
        let slots = SnapshotRenderer.slotStates(now: model.now).map { (name: "slot-\($0.name)", state: $0.state) }
        return RenderData(
            model: model, states: states, empty: empty, configError: configError, short: short,
            menuBar: [("preview", model.menuBarState), ("states", states.menuBarState)] + slots + plans.map { ($0.name, $0.model.menuBarState) },
            plans: plans, planHistory: Set(PreviewPlans.rows.filter(\.history).map(\.id))
        )
    }

    // MARK: Screens

    /// Opens Settings on General, as the app does, then moves through the panes and accounts the way clicks would.
    private func renderSettings(_ model: AppModel, appearance: NSAppearance, suffix: String) {
        renderSettings(model, opening: nil, appearance: appearance, suffix: suffix) { controller in
            var steps: [Step] = [Step(screen: "settings-general") { model.settingsSelection = nil }]
            steps.append(Step(screen: "settings-accounts") { controller.rootView = SettingsRoot(model: model, pane: .accounts) })
            for account in model.config.accounts {
                steps.append(Step(screen: "settings-account-\(self.slug(account.id))") { model.settingsSelection = account.id })
            }
            for pane in [SettingsPane.alerts, .about] {
                steps.append(Step(screen: "settings-\(pane.rawValue)") {
                    model.settingsSelection = nil
                    controller.rootView = SettingsRoot(model: model, pane: pane)
                })
            }
            return steps
        }
    }

    /// Opens Settings on Accounts, as "Settings for This Account" does, then moves through the accounts. `size` replaces
    /// the window's default content size; `settings-narrow` uses the minimum, where a row is first to wrap.
    private func renderSettingsAccounts(_ model: AppModel, prefix: String, size: NSSize? = nil, appearance: NSAppearance, suffix: String) {
        renderSettings(model, opening: .accounts, size: size, appearance: appearance, suffix: suffix) { _ in
            [Step(screen: "\(prefix)-accounts") { model.settingsSelection = nil }] + model.config.accounts.map { account in
                Step(screen: "\(prefix)-account-\(self.slug(account.id))") { model.settingsSelection = account.id }
            }
        }
    }

    /// Settings opened on `pane` (nil follows `settingsSelection`, as the app does), then `steps`, which get the
    /// controller so they can switch panes.
    private func renderSettings(
        _ model: AppModel, opening pane: SettingsPane?, size: NSSize? = nil, appearance: NSAppearance, suffix: String,
        steps: (NSHostingController<SettingsRoot>) -> [Step]
    ) {
        let controller = WindowPresenter.makeController(.settings, rootView: SettingsRoot(model: model, pane: pane))
        walk(steps(controller), appearance: appearance, suffix: suffix) {
            let window = WindowPresenter.makeWindow(.settings, controller: controller, make: CaptureWindow.init(contentViewController:))
            if let size { window.setContentSize(size) }
            return window
        }
    }

    /// One window per size, opened on All and then moved through the sidebar's accounts, or only `accounts` when given.
    private func renderDashboard(
        _ model: AppModel, prefix: String = "dashboard", sizes: Set<String> = ["default", "small", "large"], accounts: [AccountConfig]? = nil,
        appearance: NSAppearance, suffix: String
    ) {
        let spec = WindowPresenter.Spec.dashboard
        for (sizeName, size) in [("default", spec.size), ("small", spec.minSize), ("large", Self.largeDashboard)] where sizes.contains(sizeName) {
            var steps = [Step(screen: "\(prefix)-all-\(sizeName)") { model.dashboardSelection = nil }]
            for account in accounts ?? model.accounts {
                steps.append(Step(screen: "\(prefix)-\(slug(account.id))-\(sizeName)") { model.dashboardSelection = account.id })
            }
            walk(steps, appearance: appearance, suffix: suffix) {
                let controller = WindowPresenter.makeController(spec, rootView: DashboardView().environment(model))
                let window = WindowPresenter.makeWindow(spec, controller: controller, make: CaptureWindow.init(contentViewController:))
                window.setContentSize(size)
                return window
            }
        }
    }

    /// The popover's controller in a borderless window of the size `AppDelegate.open` gives the popover: the content's
    /// settled size. The window background stands in for the popover material, which cacheDisplay cannot blend.
    /// AppDelegate's `popoverWillOpen` is left out: it moves `now` to the wall clock, which would shift every preview
    /// countdown.
    private func renderPopover(_ model: AppModel, screen: String, appearance: NSAppearance, suffix: String) {
        let steps = [Step(screen: screen) {}]
        walk(steps, appearance: appearance, suffix: suffix) {
            let controller = AppDelegate.popoverContent(model)
            let window = CaptureWindow(contentViewController: controller)
            window.styleMask = [.borderless]
            window.isReleasedWhenClosed = false
            if let size = AppDelegate.settledSize(of: controller) { window.setContentSize(size) }
            return window
        }
    }

    /// The status item button, set up as AppDelegate sets it up, on a strip as tall as the menu bar.
    private func renderMenuBar(_ states: [(name: String, state: MenuBarState)], appearance: NSAppearance, suffix: String) {
        for (name, state) in states {
            let screen = "menubar-\(name)"
            guard wants(screen) else { continue }
            let button = NSStatusBarButton(frame: .zero)
            button.imagePosition = .imageLeading
            // Outside the status bar template images draw mid-gray; the menu bar draws them at label contrast.
            button.contentTintColor = .labelColor
            AppDelegate.show(StatusIconRenderer.render(state), in: button)
            button.sizeToFit()
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: max(60, button.frame.width + 24), height: Self.menuBarHeight))
            strip.wantsLayer = true
            strip.layer?.backgroundColor = (appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
            button.frame.origin = NSPoint(x: 12, y: ((Self.menuBarHeight - button.frame.height) / 2).rounded())
            strip.addSubview(button)
            let window = CaptureWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.setFrameOrigin(Self.offscreen)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            save(strip, to: "\(screen)-\(suffix).png", scale: 2)
            save(strip, to: "\(screen)-\(suffix)@1x.png", scale: 1)
            window.close()
        }
    }

    // MARK: Windows

    /// One screen and how to get there from the one before it.
    private struct Step {
        var screen: String
        var go: () -> Void
    }

    /// Runs the first step, opens the window, then runs each later step and captures its screen, stopping after the
    /// last screen asked for. Every screen is reached the same way, whatever `--only` asks for.
    private func walk(_ steps: [Step], appearance: NSAppearance, suffix: String, makeWindow: () -> NSWindow) {
        guard let last = steps.lastIndex(where: { wantsEither($0.screen) }) else { return }
        steps[0].go()
        let window = makeWindow()
        open(window, appearance: appearance)
        for index in 0...last {
            if index > 0 {
                steps[index].go()
                settle(Self.stepDelay)
            }
            capture(window, steps[index].screen, suffix)
        }
        close(window)
    }

    /// WindowPresenter activates the app and makes the window key. This orders the window in off every screen without
    /// activating, then tells it it became key and main, so AppKit and SwiftUI draw it and pick its focus as they do
    /// for a key window.
    private func open(_ window: NSWindow, appearance: NSAppearance) {
        window.appearance = appearance
        window.setFrameOrigin(Self.offscreen)
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.becomeKey()
        window.becomeMain()
        window.contentView?.layoutSubtreeIfNeeded()
        // A window that becomes key moves focus to its initialFirstResponder, or else to its first key view, when
        // nothing that takes typing has it yet. Without activation it never becomes key, so that step runs here, and
        // then what WindowPresenter does when a window it opened first becomes key.
        if let responder = window.firstResponder, responder === window || !responder.acceptsFirstResponder,
           !(window.initialFirstResponder.map(window.makeFirstResponder) ?? false) {
            window.selectNextKeyView(nil)
        }
        WindowPresenter.firstBecameKey(window)
        settle(Self.openDelay)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Saves the screen as it is, then once more scrolled to the bottom when its main scroll view has more to show.
    private func capture(_ window: NSWindow, _ screen: String, _ suffix: String) {
        guard let frameView = window.contentView?.superview else { return }
        if wants(screen) { save(frameView, to: "\(screen)-\(suffix).png", scale: 2) }
        guard wants("\(screen)-bottom"), let scrollView = mainScrollView(in: window), let bottom = scrollOrigin(scrollView, bottom: true),
              let top = scrollOrigin(scrollView, bottom: false), bottom != top else { return }
        scroll(scrollView, to: bottom)
        save(frameView, to: "\(screen)-bottom-\(suffix).png", scale: 2)
        scroll(scrollView, to: top)
    }

    /// The largest outermost scroll view: the form, the dashboard or the popover's cards on every screen here.
    private func mainScrollView(in window: NSWindow) -> NSScrollView? {
        func outermost(_ view: NSView) -> [NSScrollView] {
            if let scrollView = view as? NSScrollView { return [scrollView] }
            return view.subviews.flatMap(outermost)
        }
        guard let content = window.contentView else { return nil }
        return outermost(content).filter { $0.documentView != nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func scrollOrigin(_ scrollView: NSScrollView, bottom: Bool) -> NSPoint? {
        guard let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let far: CGFloat = bottom == document.isFlipped ? 1_000_000 : -1_000_000
        return clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: far), size: clip.bounds.size)).origin
    }

    private func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(Self.scrollDelay)
    }

    // MARK: Files

    private func save(_ view: NSView, to name: String, scale: CGFloat) {
        view.window?.layoutIfNeeded()
        view.window?.displayIfNeeded()
        let hidden = Self.hidePortalLayers(in: view.layer)
        defer { hidden.forEach { $0.isHidden = false } }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()), pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let url = options.directory.appending(path: name)
        do {
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: url)
            print(url.path)
        } catch {
            FileHandle.standardError.write(Data("warning: could not write \(url.path)\n".utf8))
        }
    }

    /// macOS 26 scroll views mirror their top edge through a CAPortalLayer composited destination-in. cacheDisplay
    /// draws in-process, where a portal draws nothing and that compositing erases the whole window, so portals are
    /// hidden while drawing. The edge blur under the title bar is the only thing missing from a capture.
    private static func hidePortalLayers(in layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        var hidden: [CALayer] = []
        if NSStringFromClass(type(of: layer)) == "CAPortalLayer", !layer.isHidden {
            layer.isHidden = true
            hidden.append(layer)
        }
        for sublayer in layer.sublayers ?? [] { hidden += hidePortalLayers(in: sublayer) }
        return hidden
    }

    // MARK: Names

    private func wants(_ screen: String) -> Bool {
        options.only.isEmpty || options.only.contains { screen.hasPrefix($0) }
    }

    /// The screen itself or its scrolled-down capture.
    private func wantsEither(_ screen: String) -> Bool {
        wants(screen) || wants("\(screen)-bottom")
    }

    /// Account ids come from config.json, so they are reduced to letters, digits and dashes for file names.
    private func slug(_ id: String) -> String {
        if let known = slugs[id] { return known }
        let base = id.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        var name = base.isEmpty ? "account" : base
        var counter = 2
        while slugs.values.contains(name) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        slugs[id] = name
        return name
    }
}

/// Settings as WindowPresenter shows it, on the pane a sidebar click would pick. A new pane is a new view identity, so
/// the content is replaced while the window keeps its size and key state, as after a click.
private struct SettingsRoot: View {
    var model: AppModel
    var pane: SettingsPane?

    var body: some View {
        SettingsView(pane: pane).environment(model).id(pane)
    }
}

/// Draws as the key window of the active app without being either, and stays where it is put, off every screen.
private final class CaptureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
