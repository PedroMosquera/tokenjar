import AppKit
import SwiftUI
import HeadroomCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let windows = WindowPresenter()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
        popover.contentViewController = NSHostingController(rootView: PopoverView().environment(model))

        observeIcon()
        model.start()
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
        windows.show(id: "dashboard", title: "Headroom", size: NSSize(width: 980, height: 660), minSize: NSSize(width: 760, height: 520)) {
            DashboardView().environment(model)
        }
    }

    private func showSettings(accountID: String?) {
        popover.performClose(nil)
        model.settingsSelection = accountID
        windows.show(id: "settings", title: "Headroom Settings", size: NSSize(width: 760, height: 560), minSize: NSSize(width: 640, height: 460)) {
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
        statusItem?.button?.image = rendered.image
        statusItem?.button?.title = rendered.title
        statusItem?.button?.attributedTitle = rendered.attributedTitle
        statusItem?.button?.toolTip = rendered.toolTip
    }
}
