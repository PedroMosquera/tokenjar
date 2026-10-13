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

    private final class Target: NSObject {
        @objc func clicked(_ sender: Any?) {}
    }

    private final class Opens {
        var count = 0
    }

    /// Never put in a window or a status item.
    private func configuredButton(target: Target, opens: Opens) -> NSStatusBarButton {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        StatusItemClick.configure(button, target: target, action: #selector(Target.clicked(_:))) { opens.count += 1 }
        return button
    }

    /// A button acts on a left mouse-up only unless told otherwise, which is why a right-click did nothing.
    @Test func theButtonActsOnLeftAndRightMouseUp() {
        let target = Target()
        let button = configuredButton(target: target, opens: Opens())
        // sendAction(on:) returns the mask it replaces, so setting the same mask again reads back what configure set.
        let mask = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        #expect(mask == Int(NSEvent.EventTypeMask([.leftMouseUp, .rightMouseUp]).rawValue))
        #expect(button.target === target)
        #expect(button.action == #selector(Target.clicked(_:)))
    }

    /// A status bar button with no menu of its own offers VoiceOver no show-menu action, so it gets a custom one. The
    /// menu opens on a later main-queue turn, once the accessibility request has had its answer.
    @Test func voiceOverCanOpenTheMenu() async throws {
        let opens = Opens()
        let button = configuredButton(target: Target(), opens: opens)
        let actions = button.accessibilityCustomActions() ?? []
        #expect(actions.map(\.name) == ["Show Menu"])
        let handler = try #require(actions.first?.handler)
        #expect(handler())
        #expect(opens.count == 0)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(opens.count == 1)
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

struct ClosingPressTests {
    /// The usual click: its press closes the popover, and its release must not reopen it.
    @Test func theReleaseOfThePressThatClosedThePopoverDoesNotReopenIt() {
        var press = StatusItemClick.ClosingPress()
        press.pressBegan(at: 10)
        press.popoverClosed(byPressAt: 10)
        let toggles1 = press.releaseToggles()
        #expect(!toggles1)
        press.pressBegan(at: 12)
        let toggles2 = press.releaseToggles()
        #expect(toggles2)
    }

    /// The popover can swallow the whole click while it closes, release included. The next click is a new one and
    /// must open the popover at once, not need a second try.
    @Test func aSwallowedReleaseDoesNotCostTheNextClick() {
        var press = StatusItemClick.ClosingPress()
        press.popoverClosed(byPressAt: 10)
        press.pressBegan(at: 12)
        let toggles3 = press.releaseToggles()
        #expect(toggles3)
    }

    /// The press can reach the event monitor after the popover has already closed on it.
    @Test func thePressThatClosedThePopoverSeenLateStillCounts() {
        var press = StatusItemClick.ClosingPress()
        press.popoverClosed(byPressAt: 10)
        press.pressBegan(at: 10)
        let toggles4 = press.releaseToggles()
        #expect(!toggles4)
    }

    @Test func aClickThatClosedNothingToggles() {
        var press = StatusItemClick.ClosingPress()
        press.pressBegan(at: 10)
        let toggles5 = press.releaseToggles()
        #expect(toggles5)
    }
}
