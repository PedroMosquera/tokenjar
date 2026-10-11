import AppKit
import SwiftUI
import TokenjarCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private let windows = WindowPresenter()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        switch LaunchMode.parse(args) {
        case .renderSnapshots(let directory):
            StrayWindowSweeper.start()
            SnapshotRenderer.run(outputDirectory: directory)
            exit(0)
        case .renderWindows(let options):
            StrayWindowSweeper.start()
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
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageLeading
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

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            Self.open(popover, willOpen: { model.popoverWillOpen() }) {
                popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            }
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Runs `willOpen`, which may change what the popover shows, sizes the popover to the result, then calls `show`.
    /// NSPopover places itself once, from `contentSize`, and that is 0x0 until set here: assigning a controller whose
    /// view was never laid out leaves it so, and the popover then opens at a default size and grows past the menu bar.
    static func open(_ popover: NSPopover, willOpen: () -> Void, show: () -> Void) {
        willOpen()
        if let size = settledSize(of: popover.contentViewController) { popover.contentSize = size }
        show()
    }

    /// The content's size with every pending change applied. SwiftUI applies a model change at the next layout, which
    /// would come only after the popover is placed. Nil before the content has a size.
    static func settledSize(of controller: NSViewController?) -> NSSize? {
        guard let controller else { return nil }
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.preferredContentSize
        return size.width > 0 && size.height > 0 ? size : nil
    }

    @objc func openSettings(_ sender: Any?) {
        model.showSettings()
    }

    func popoverWillShow(_ notification: Notification) {
        model.isPopoverShown = true
    }

    func popoverDidClose(_ notification: Notification) {
        model.isPopoverShown = false
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
        // The default options let SwiftUI resize the popover's window itself, from its bottom edge, so content that
        // grows while the popover is open pushes the arrow and header above the menu bar. This leaves the resizing to
        // AppKit, and keeps preferredContentSize current for `open`.
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
