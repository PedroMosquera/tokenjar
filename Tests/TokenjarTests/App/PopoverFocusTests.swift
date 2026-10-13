import AppKit
import Testing
@testable import Tokenjar

@MainActor
struct PopoverFocusTests {
    private let tokenjar = NSRunningApplication.current

    /// Any running app but the test runner, standing in for the app the person was typing in. Only read, never activated.
    private func otherApp() throws -> NSRunningApplication {
        try #require(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != tokenjar.processIdentifier })
    }

    /// Closed from the icon or with Escape, Tokenjar is still active with no window, so the keyboard goes back.
    @Test func closingWhileTokenjarIsActiveHandsFocusBack() throws {
        let app = try otherApp()
        var focus = PopoverFocus()
        focus.opening(frontmost: app)
        #expect(focus.closing(tokenjarIsActive: true, keepsFocus: false) == app)
    }

    /// A click into another app closed it, and that app already has the keyboard.
    @Test func closingAfterAClickElsewhereLeavesFocusAlone() throws {
        var focus = PopoverFocus()
        focus.opening(frontmost: try otherApp())
        #expect(focus.closing(tokenjarIsActive: false, keepsFocus: false) == nil)
    }

    /// Dashboard, Settings or the quit alert opened from the popover need Tokenjar in front.
    @Test func aTokenjarWindowKeepsFocus() throws {
        var focus = PopoverFocus()
        focus.opening(frontmost: try otherApp())
        #expect(focus.closing(tokenjarIsActive: true, keepsFocus: true) == nil)
    }

    @Test func nothingToHandBackWhenTokenjarWasInFront() {
        var focus = PopoverFocus()
        focus.opening(frontmost: tokenjar)
        #expect(focus.appBefore == nil)
        #expect(focus.closing(tokenjarIsActive: true, keepsFocus: false) == nil)
    }

    /// One open's app must not come back after a later open from Tokenjar itself.
    @Test func eachCloseForgetsTheApp() throws {
        var focus = PopoverFocus()
        focus.opening(frontmost: try otherApp())
        _ = focus.closing(tokenjarIsActive: false, keepsFocus: false)
        #expect(focus.appBefore == nil)
        #expect(focus.closing(tokenjarIsActive: true, keepsFocus: false) == nil)
    }
}
