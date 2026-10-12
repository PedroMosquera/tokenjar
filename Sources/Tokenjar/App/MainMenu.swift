import AppKit

/// The menu bar shown while a Dashboard or Settings window is open. Without a SwiftUI App, AppKit has no menu unless
/// one is built here, and text fields get Command-C, -V and -A only from the Edit menu's items.
enum MainMenu {
    /// Settings and Quit go to `target`, so Command-comma opens the same window as the popover's Settings button and
    /// Command-Q asks first like the popover's Quit. Every other item has no target and goes down the responder chain
    /// to the key window or the app.
    static func make(appName: String, target: AnyObject, settingsAction: Selector, quitAction: Selector) -> NSMenu {
        let settings = item("Settings\u{2026}", settingsAction, ",")
        settings.target = target
        let quit = item("Quit \(appName)", quitAction, "q")
        quit.target = target
        // macOS 26 picks an item's symbol from its action, so Quit borrows the one it shows for terminate:.
        quit.image = item("", #selector(NSApplication.terminate(_:))).image
        let app = submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            settings,
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            quit,
        ])
        let edit = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        let bar = NSMenu()
        for menu in [app, edit, window] {
            let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            bar.addItem(holder)
        }
        return bar
    }

    /// Hands `app` the menu bar from `make`, with Window as the menu AppKit lists open windows in.
    static func install(in app: NSApplication, appName: String, target: AnyObject, settingsAction: Selector, quitAction: Selector) {
        let menu = make(appName: appName, target: target, settingsAction: settingsAction, quitAction: quitAction)
        app.mainMenu = menu
        app.windowsMenu = menu.item(withTitle: "Window")?.submenu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.items = items
        return menu
    }
}
