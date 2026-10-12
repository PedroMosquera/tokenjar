import AppKit

/// What a click on the status item opens, from `NSApp.currentEvent` as the button's action runs.
enum StatusItemClick: Equatable {
    case popover
    case menu

    /// A right click, or a click with Control held, opens the menu. Anything else opens the popover, so a press that
    /// arrives with no event or a key event cannot open the menu.
    static func route(_ type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> StatusItemClick {
        switch type {
        case .rightMouseUp: .menu
        case .leftMouseUp where modifiers.contains(.control): .menu
        default: .popover
        }
    }

    /// Points the status item's button at `action` for left and right mouse-up, and gives VoiceOver a Show Menu
    /// action: a status bar button with no menu of its own offers no show-menu command.
    static func configure(_ button: NSButton, target: AnyObject, action: Selector, showMenu: @escaping @MainActor @Sendable () -> Void) {
        button.target = target
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show Menu") {
            // The menu's tracking loop would hold up the accessibility request until the menu closed.
            DispatchQueue.main.async { showMenu() }
            return true
        }])
    }

    /// AppKit keeps the last event it dispatched while the app idles, so an accessibility press after a right-click
    /// finds that same right mouse-up. An event already routed once counts as no event.
    struct Router {
        private var lastRouted: TimeInterval?

        mutating func route(_ event: NSEvent?) -> StatusItemClick {
            guard let event, event.timestamp != lastRouted else { return .popover }
            lastRouted = event.timestamp
            return StatusItemClick.route(event.type, modifiers: event.modifierFlags)
        }
    }
}
