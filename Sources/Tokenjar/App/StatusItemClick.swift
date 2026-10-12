import AppKit

/// What a click on the status item opens, from `NSApp.currentEvent` as the button's action runs.
enum StatusItemClick: Equatable {
    case popover
    case menu

    /// A right click, or a click with Control held, opens the menu. Anything else opens the popover, including no
    /// event or a key event: a VoiceOver press, or Return while the menu bar is navigated by keyboard.
    static func route(_ type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> StatusItemClick {
        switch type {
        case .rightMouseUp: .menu
        case .leftMouseUp where modifiers.contains(.control): .menu
        default: .popover
        }
    }
}
