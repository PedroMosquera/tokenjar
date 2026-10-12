import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct PreviewDataTests {
    private static var previewModels: [AppModel] {
        [AppModel.preview(), .previewStates(), .previewEmpty()] + PreviewPlans.pages().map(\.model)
    }

    /// Preview renders end up in the README and in PRs, so no path in them may come from this Mac.
    @Test func everyPreviewModelUsesTheStandInHome() {
        for model in Self.previewModels {
            #expect(model.paths.home.path == "/Users/you")
            #expect(model.paths.configFile.path == "/Users/you/.config/tokenjar/config.json")
        }
    }

    @Test func theConfigFileRowShowsThePlaceholderPath() {
        let caption = GeneralSettingsPane.configFileCaption(paths: AppModel.preview().paths)
        #expect(caption.path == "~/.config/tokenjar/config.json")
        #expect(!caption.isLink)
    }
}
