import AppKit
import SwiftUI
import Testing
@testable import Tokenjar

@MainActor
struct SettingsWindowTitleTests {
    /// SettingsView names the window after its pane through navigationTitle, which SwiftUI sets once as the content is
    /// attached and again only when it changes. Replacing it then would keep the spec's title until another pane is picked.
    @Test func settingsOpensTitledByThePaneItShows() {
        let controller = NSHostingController(rootView: Text("General").navigationTitle("General"))
        controller.sceneBridgingOptions = [.title]
        let window = WindowPresenter.makeWindow(.settings, controller: controller)
        defer { window.close() }

        #expect(window.title == "General")
    }

    @Test func contentThatNamesNoWindowGetsTheSpecTitle() {
        let window = WindowPresenter.makeWindow(.settings, controller: NSHostingController(rootView: Text("Settings")))
        defer { window.close() }

        #expect(window.title == WindowPresenter.Spec.settings.title)
    }
}
