import AppKit

/// Where the status item menu sends its items.
@objc protocol StatusItemMenuTarget: AnyObject {
    func refreshNow(_ sender: Any?)
    func openDashboard(_ sender: Any?)
    func openSettings(_ sender: Any?)
    func requestQuit(_ sender: Any?)
    func quitWithoutAsking(_ sender: Any?)
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
        // Not terminate: on NSApp. macOS 26 gives that action the system quit symbol, which would show on this row alone.
        let quitNow = item("Quit Tokenjar", #selector(StatusItemMenuTarget.quitWithoutAsking(_:)), target)
        quitNow.isAlternate = true
        quitNow.keyEquivalentModifierMask = .option
        menu.addItem(quitNow)
        return menu
    }

    /// Shows `menu` from the status item. It is attached only while `click` runs, because a status item with a menu
    /// opens that menu on every click, left included.
    static func open(_ menu: NSMenu, closePopover: () -> Void, attach: (NSMenu?) -> Void, click: () -> Void) {
        closePopover()
        attach(menu)
        click()
        attach(nil)
    }

    private static func item(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
