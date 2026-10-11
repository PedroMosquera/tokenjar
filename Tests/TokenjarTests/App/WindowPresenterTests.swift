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

    /// Only the first time is undone; later the focus is the user's.
    @Test func settingsLeavesItsFieldsUnfocusedTheFirstTimeItBecomesKey() {
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

    @Test func onlySettingsTakesFocusOffItsFieldsWhenItFirstBecomesKey() {
        #expect(WindowPresenter.Spec.settings.clearsFieldFocus)
        #expect(!WindowPresenter.Spec.dashboard.clearsFieldFocus)
    }

    @Test func theDashboardKeepsTheFocusAppKitGivesItTheFirstTimeItBecomesKey() {
        let sidebar = FocusableView(frame: NSRect(x: 20, y: 20, width: 120, height: 60))
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        controller.view.addSubview(sidebar)
        let window = WindowPresenter.makeWindow(.dashboard, controller: controller)
        defer { window.close() }
        let presenter = WindowPresenter()

        #expect(window.makeFirstResponder(sidebar))
        #expect(window.firstResponder === sidebar)
        presenter.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(window.firstResponder === sidebar)
    }

    /// Takes focus the way the Dashboard's sidebar list does, without needing rows to accept it.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func theDashboardTitleNamesTheWindow() {
        #expect(WindowPresenter.Spec.dashboard.title == "Tokenjar Dashboard")
    }
}
