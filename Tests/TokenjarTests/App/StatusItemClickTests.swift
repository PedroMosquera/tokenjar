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

    /// A VoiceOver press can come with no current event, and Return during keyboard navigation of the menu bar with a
    /// key event, so neither may be read as a right click.
    @Test func noEventOrAKeyEventOpensThePopover() {
        #expect(StatusItemClick.route(nil, modifiers: []) == .popover)
        #expect(StatusItemClick.route(.keyDown, modifiers: []) == .popover)
        #expect(StatusItemClick.route(.keyDown, modifiers: .control) == .popover)
        #expect(StatusItemClick.route(.keyUp, modifiers: .control) == .popover)
        #expect(StatusItemClick.route(.otherMouseUp, modifiers: .control) == .popover)
    }
}
