import AppKit
import SwiftUI
import Testing
@testable import Tokenjar

@MainActor
struct WindowPresenterTests {
    @Test func settingsCannotMinimize() {
        let window = WindowPresenter.makeWindow(.settings, controller: NSHostingController(rootView: Text("Settings")))
        defer { window.close() }

        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.resizable))
    }

    /// AppKit focuses a new window's first text field when it becomes key, which shows the value selected as if the
    /// user were about to retype it. Only that first time is undone; later the focus is the user's.
    @Test func aWindowLeavesItsFieldsUnfocusedTheFirstTimeItBecomesKey() {
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 80, height: 22))
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        controller.view.addSubview(field)
        let window = WindowPresenter.makeWindow(.settings, controller: controller)
        defer { window.close() }
        let presenter = WindowPresenter()
        let becameKey = Notification(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.makeFirstResponder(field))
        presenter.windowDidBecomeKey(becameKey)
        #expect(window.firstResponder === window)

        #expect(window.makeFirstResponder(field))
        presenter.windowDidBecomeKey(becameKey)
        #expect(window.firstResponder !== window)
    }

    @Test func theDashboardTitleNamesTheWindow() {
        #expect(WindowPresenter.Spec.dashboard.title == "Tokenjar Dashboard")
    }
}
