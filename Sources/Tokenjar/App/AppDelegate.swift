import AppKit
import os
import SwiftUI
import TokenjarCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, StatusItemMenuTarget {
    let model = AppModel(defaults: UserDefaults.standard)
    private let windows = WindowPresenter()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var quitConfirmation = QuitConfirmation()
    private var clicks = StatusItemClick.Router()
    private var popoverFocus = PopoverFocus()
    /// Set when a press on the status item closed the transient popover, so that click's mouse-up does not reopen it.
    private var popoverClosedByItemPress = false
    var popoverFrameObservers: [NSObjectProtocol] = [] {
        didSet { oldValue.forEach(NotificationCenter.default.removeObserver) }
    }
    private static let popoverLog = Logger(subsystem: AppPaths.bundleIdentifier, category: "popover")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        switch LaunchMode.parse(args) {
        case .renderSnapshots(let directory):
            StrayWindowSweeper.start()
            Self.pinPreviewRegion()
            SnapshotRenderer.run(outputDirectory: directory)
            exit(0)
        case .renderWindows(let options):
            StrayWindowSweeper.start()
            if !options.realData { Self.pinPreviewRegion() }
            WindowRenderer.run(options)
            exit(0)
        case .devCommand:
            Task {
                _ = await DevCommands.handle(args)
                exit(0)
            }
            return
        case .invalid(let usage):
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(64)
        case .app:
            break
        }

        model.presenter = .init(
            showDashboard: { [weak self] accountID in self?.showDashboard(accountID: accountID) },
            showSettings: { [weak self] accountID in self?.showSettings(accountID: accountID) },
            closePopover: { [weak self] in self?.popover.performClose(nil) },
            requestQuit: { [weak self] in self?.requestQuit(nil) }
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            StatusItemClick.configure(button, target: self, action: #selector(statusItemClicked(_:))) { [weak self] in
                self?.showMenu()
            }
            button.imagePosition = .imageLeading
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = Self.popoverContent(model)

        let notifications = NotificationManager()
        notifications.onOpenDashboard = { [weak self] accountID in self?.showDashboard(accountID: accountID) }
        notifications.activate()
        model.notifications = notifications

        observeIcon()
        model.start()
        if model.config.alerts.enabled { model.requestNotificationPermission(prominent: false) }
    }

    /// Preview renders end up in the README and in PRs, so they use US English and UTC instead of the local region
    /// and time zone. In memory only: the argument domain and TZ last for this process and are never saved.
    private static func pinPreviewRegion() {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLocale"] = "en_US"
        arguments["AppleLanguages"] = ["en-US"]
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        setenv("TZ", "UTC", 1)
        NSTimeZone.resetSystemTimeZone()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let alreadyClosed = popoverClosedByItemPress
        popoverClosedByItemPress = false
        switch clicks.route(NSApp.currentEvent) {
        case .popover: if !alreadyClosed { togglePopover(sender) }
        case .menu: showMenu()
        }
    }

    private func showMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        // Taken before the popover closes, so its close leaves focus alone while the menu is up.
        let refocus = popover.isShown ? popoverFocus.closing(tokenjarIsActive: true, keepsFocus: false) : nil
        StatusItemMenu.open(
            StatusItemMenu.make(hasAccounts: !model.accounts.isEmpty, target: self),
            closePopover: { if popover.isShown { popover.performClose(nil) } },
            attach: { statusItem.menu = $0 },
            click: { button.performClick(nil) }
        )
        if let refocus, NSApp.isActive, !tokenjarNeedsFocus { Self.handFocusBack(to: refocus) }
    }

    /// A Tokenjar window or the quit alert is up, so the keyboard stays with Tokenjar.
    private var tokenjarNeedsFocus: Bool { windows.hasOpenWindows || quitConfirmation.isAsking }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popoverFocus.opening(frontmost: NSWorkspace.shared.frontmostApplication)
            NSApp.activate()
            Self.open(popover, willOpen: {
                model.popoverMaxHeight = Self.anchorGeometry(of: sender).map {
                    PopoverPlacement.maxContentHeight(anchor: $0.anchor, visibleFrame: $0.visibleFrame)
                }
                model.popoverWillOpen()
            }) {
                popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            }
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Runs `willOpen`, which may change what the popover shows, sizes the popover to the result, then calls `show`.
    /// NSPopover places the popover from `contentSize` at show, and that is 0x0 for a controller never laid out.
    /// Later size changes reach NSPopover through the preferred size (see `popoverContent`) and it re-places the
    /// popover for each one, so the app should not move a shown popover itself. The content lives as long as the
    /// app, so its cards would otherwise reopen where the last open left them; they go back to the top before `show`.
    static func open(_ popover: NSPopover, willOpen: () -> Void, show: () -> Void) {
        willOpen()
        if let size = settledSize(of: popover.contentViewController) { popover.contentSize = size }
        if let view = popover.contentViewController?.view { scrollToTop(view) }
        show()
    }

    private static func scrollToTop(_ view: NSView) {
        if let scrollView = view as? NSScrollView {
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let top = clip.isFlipped ? 0 : max(0, documentHeight - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
            scrollView.reflectScrolledClipView(clip)
            return
        }
        view.subviews.forEach(scrollToTop)
    }

    /// The content's size with every pending change applied. SwiftUI applies a model change at the next layout, which
    /// would come only after the popover is placed. Nil before the content has a size.
    static func settledSize(of controller: NSViewController?) -> NSSize? {
        guard let controller else { return nil }
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.preferredContentSize
        return size.width > 0 && size.height > 0 ? size : nil
    }

    private static func anchorGeometry(of button: NSView) -> (anchor: NSRect, visibleFrame: NSRect)? {
        guard let window = button.window, let screen = window.screen else { return nil }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), screen.visibleFrame)
    }

    @objc func refreshNow(_ sender: Any?) {
        PopoverHeader.refreshNow(model)
    }

    @objc func openDashboard(_ sender: Any?) {
        model.showDashboard()
    }

    @objc func openSettings(_ sender: Any?) {
        model.showSettings()
    }

    /// The alert waits for the run loop's default mode, which menu tracking never runs in, so a request from a menu
    /// shows it only after that menu has closed and the status item has let go of it.
    @objc func requestQuit(_ sender: Any?) {
        // With the popover open Tokenjar is in front, so the app to return to after Cancel is the one before it.
        let frontmost = popover.isShown ? popoverFocus.appBefore : NSWorkspace.shared.frontmostApplication
        guard quitConfirmation.shouldAsk(frontmost: frontmost) else { return }
        if popover.isShown { popover.performClose(nil) }
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { self.askToQuit() }
        }
    }

    @objc func quitWithoutAsking(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func askToQuit() {
        // An accessory app's alert would otherwise open behind the frontmost app.
        NSApp.activate()
        switch quitConfirmation.outcome(of: QuitConfirmation.makeAlert().runModal()) {
        case .quit: NSApp.terminate(nil)
        case .stay(let refocus): refocus.map(Self.handFocusBack)
        }
    }

    /// Without this, Tokenjar stays active with no window after Cancel, and typing goes nowhere until the person
    /// clicks back into their app.
    private static func handFocusBack(to app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    func popoverWillShow(_ notification: Notification) {
        model.isPopoverShown = true
    }

    func popoverDidShow(_ notification: Notification) {
        logPopoverGeometry(opening: true)
        guard let window = popover.contentViewController?.view.window else { return }
        popoverFrameObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.logPopoverGeometry(opening: false) }
            }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        if let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(event.type), event.window === statusItem?.button?.window {
            popoverClosedByItemPress = true
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.isPopoverShown = false
        popoverFrameObservers = []
        if let app = popoverFocus.closing(tokenjarIsActive: NSApp.isActive, keepsFocus: tokenjarNeedsFocus) { Self.handFocusBack(to: app) }
    }

    /// Where the popover went, so an open that ends up over the menu bar leaves a trace in the unified log. Frames only.
    private func logPopoverGeometry(opening: Bool) {
        guard let window = popover.contentViewController?.view.window, let button = statusItem?.button,
              let geometry = Self.anchorGeometry(of: button) else { return }
        let line = PopoverPlacement.describe(window: window.frame, anchor: geometry.anchor, visibleFrame: geometry.visibleFrame)
        if PopoverPlacement.isAboveAnchor(window: window.frame, anchor: geometry.anchor) {
            Self.popoverLog.warning("Above its status item: \(line, privacy: .public)")
        } else if opening {
            Self.popoverLog.notice("Opened: \(line, privacy: .public)")
        } else {
            Self.popoverLog.info("Moved: \(line, privacy: .public)")
        }
    }

    private func showDashboard(accountID: String?) {
        popover.performClose(nil)
        model.dashboardSelection = accountID
        windows.show(.dashboard) {
            DashboardView().environment(model)
        }
    }

    private func showSettings(accountID: String?) {
        popover.performClose(nil)
        model.settingsSelection = accountID
        windows.show(.settings) {
            SettingsView().environment(model)
        }
    }

    /// Re-renders the menu bar icon whenever anything it reads from the model changes.
    private func observeIcon() {
        let rendered = withObservationTracking {
            StatusIconRenderer.render(model.menuBarState)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
        if let button = statusItem?.button { Self.show(rendered, in: button) }
    }

    /// The popover's content. `--render-windows` captures this same controller.
    static func popoverContent(_ model: AppModel) -> NSViewController {
        let controller = NSHostingController(rootView: PopoverView().environment(model))
        // Under the default options SwiftUI resizes the popover's window itself and NSPopover's contentSize does not
        // follow; in a popover window that was never shown, the window grew from a fixed bottom edge. This option
        // hands every size change to NSPopover, and keeps preferredContentSize current for `open`.
        controller.sizingOptions = .preferredContentSize
        return controller
    }

    /// How the status item shows an icon. `--render-windows` draws its menu bar strips through this too.
    static func show(_ rendered: RenderedStatusIcon, in button: NSButton) {
        button.image = rendered.image
        button.title = rendered.title
        button.attributedTitle = rendered.attributedTitle
        button.toolTip = rendered.toolTip
    }
}
