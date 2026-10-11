import AppKit
import SwiftUI
import TokenjarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let windows = WindowPresenter()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let args = CommandLine.arguments
        switch LaunchMode.parse(args) {
        case .renderSnapshots(let directory):
            SnapshotRenderer.run(outputDirectory: directory)
            exit(0)
        case .renderWindows(let options):
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
            model.popoverWillOpen()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
        NSHostingController(rootView: PopoverView().environment(model))
    }

    /// How the status item shows an icon. `--render-windows` draws its menu bar strips through this too.
    static func show(_ rendered: RenderedStatusIcon, in button: NSButton) {
        button.image = rendered.image
        button.title = rendered.title
        button.attributedTitle = rendered.attributedTitle
        button.toolTip = rendered.toolTip
    }
}
