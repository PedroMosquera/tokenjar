import AppKit
import Testing
@testable import Tokenjar

@MainActor
struct StatusItemClickTests {
    @Test func aClickOpensThePopover() {
        #expect(StatusItemClick.route(.leftMouseUp, modifiers: []) == .popover)
    }

    @Test func aRightClickOpensTheMenuWhateverIsHeld() {
        for modifiers: NSEvent.ModifierFlags in [[], .option, .control, .command, .shift] {
            #expect(StatusItemClick.route(.rightMouseUp, modifiers: modifiers) == .menu, "\(modifiers.rawValue)")
        }
    }

    /// A real event's flags also carry device bits, such as which Control key was held.
    @Test func aControlClickOpensTheMenu() {
        #expect(StatusItemClick.route(.leftMouseUp, modifiers: .control) == .menu)
        #expect(StatusItemClick.route(.leftMouseUp, modifiers: [.control, .shift]) == .menu)
        #expect(StatusItemClick.route(.leftMouseUp, modifiers: NSEvent.ModifierFlags(rawValue: 0x40101)) == .menu)
    }

    @Test func aClickWithOtherKeysHeldOpensThePopover() {
        for modifiers: NSEvent.ModifierFlags in [.option, .command, .shift, .capsLock] {
            #expect(StatusItemClick.route(.leftMouseUp, modifiers: modifiers) == .popover, "\(modifiers.rawValue)")
        }
    }

    /// A press that is not a mouse click may come with no current event or a key event, and neither may be read as a
    /// right click.
    @Test func noEventOrAKeyEventOpensThePopover() {
        #expect(StatusItemClick.route(nil, modifiers: []) == .popover)
        #expect(StatusItemClick.route(.keyDown, modifiers: []) == .popover)
        #expect(StatusItemClick.route(.keyDown, modifiers: .control) == .popover)
        #expect(StatusItemClick.route(.keyUp, modifiers: .control) == .popover)
        #expect(StatusItemClick.route(.otherMouseUp, modifiers: .control) == .popover)
    }

    /// Built only, never posted.
    private func mouseUp(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = [], at timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    /// AppKit keeps the last event it dispatched while the app idles, so a VoiceOver or Voice Control press after a
    /// right-click would find that same right mouse-up and open the menu instead of the popover.
    @Test func anEventAlreadyRoutedOpensThePopover() throws {
        var router = StatusItemClick.Router()
        let rightClick = try mouseUp(.rightMouseUp, at: 100)
        let controlClick = try mouseUp(.leftMouseUp, .control, at: 200)

        let first = router.route(rightClick)
        let again = router.route(rightClick)
        let controlFirst = router.route(controlClick)
        let controlAgain = router.route(controlClick)

        #expect([first, again, controlFirst, controlAgain] == [.menu, .popover, .menu, .popover])
    }

    @Test func eachNewClickIsRoutedOnItsOwn() throws {
        var router = StatusItemClick.Router()
        let routes = try [
            router.route(mouseUp(.rightMouseUp, at: 100)),
            router.route(mouseUp(.leftMouseUp, at: 101)),
            router.route(mouseUp(.rightMouseUp, at: 102)),
            router.route(nil),
            router.route(mouseUp(.leftMouseUp, .control, at: 103)),
        ]
        #expect(routes == [.menu, .popover, .menu, .popover, .menu])
    }
}
