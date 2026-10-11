import AppKit
import SwiftUI
import Testing
import TokenjarCore
@testable import Tokenjar

@MainActor
struct SettingsMinimumSizeTests {
    /// Laid out with no room at all, each pane takes the smallest size it draws in. The window's minimum must be that
    /// size, because the `settings-narrow` renders open the window at it to show the narrowest layout a user can reach.
    /// Measured inside the Settings window, never shown, because the content also sits under its title bar.
    @Test(arguments: SettingsPane.allCases)
    func theWindowMinimumIsTheSmallestSizeEachPaneFits(pane: SettingsPane) {
        let model = AppModel.preview()
        model.secrets = SessionSecretStore(InMemorySecretStore())
        // Copilot's account page has the widest row: the GitHub CLI folder field and its Choose button.
        model.settingsSelection = model.config.accounts.first { $0.provider == .copilot }?.id
        let spec = WindowPresenter.Spec.settings
        let controller = WindowPresenter.makeController(spec, rootView: SettingsView(pane: pane).environment(model))
        let window = WindowPresenter.makeWindow(spec, controller: controller)
        defer { window.close() }

        let smallest = controller.sizeThatFits(in: .zero)
        #expect(smallest.width == spec.minSize.width)
        #expect(smallest.height == spec.minSize.height)
        #expect(!window.isVisible)
    }
}
