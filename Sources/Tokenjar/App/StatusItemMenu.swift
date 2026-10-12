import AppKit

/// Where the status item menu sends its items. `AppDelegate` is the one in the app.
@objc protocol StatusItemMenuTarget: AnyObject {
    func refreshNow(_ sender: Any?)
    func openDashboard(_ sender: Any?)
    func openSettings(_ sender: Any?)
    func requestQuit(_ sender: Any?)
}

/// The menu a right-click or Control-click on the status item opens.
///
/// Built fresh for each open, so it never needs a delegate or validation to stay current: Refresh Now is left out
/// without accounts rather than dimmed, and every other item always works. Every item names its target, so nothing
/// depends on which window happens to be key.
enum StatusItemMenu {
    static func make(hasAccounts: Bool, target: StatusItemMenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Always enabled: a refresh skips the accounts already being checked, and runs offline like the header's button.
        if hasAccounts { menu.addItem(item("Refresh Now", #selector(StatusItemMenuTarget.refreshNow(_:)), target)) }
        menu.addItem(item("Open Dashboard", #selector(StatusItemMenuTarget.openDashboard(_:)), target))
        menu.addItem(item("Settings\u{2026}", #selector(StatusItemMenuTarget.openSettings(_:)), target))
        menu.addItem(.separator())
        menu.addItem(item("Quit Tokenjar\u{2026}", #selector(StatusItemMenuTarget.requestQuit(_:)), target))
        let quitNow = item("Quit Tokenjar", #selector(NSApplication.terminate(_:)), NSApplication.shared)
        quitNow.isAlternate = true
        quitNow.keyEquivalentModifierMask = .option
        // macOS 26 gives a terminate: item the system quit symbol, which would appear on this row alone. The getter
        // picks it on first read, and a nil set before that read does not stick.
        _ = quitNow.image
        quitNow.image = nil
        menu.addItem(quitNow)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
