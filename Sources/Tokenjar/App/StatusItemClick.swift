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
