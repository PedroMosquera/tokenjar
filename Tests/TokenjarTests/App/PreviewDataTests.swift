import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct PreviewDataTests {
    private static var previewModels: [AppModel] {
        [AppModel.preview(), .previewStates(), .previewEmpty(), .previewLimitHit()] + PreviewPlans.pages().map(\.model)
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

    @Test func theKeyFileRowIgnoresThisMacsDataFolderInPreview() {
        let go = AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go")
        let paths = AppModel.preview().paths
        let environment = ["XDG_DATA_HOME": "/Users/someone/.data"]
        #expect(AccountCredentialSection.keyFile(for: go, paths: paths, previewMode: true, environment: environment).path == "~/.local/share/opencode/auth.json")
        #expect(AccountCredentialSection.keyFile(for: go, paths: paths, previewMode: false, environment: environment).path == "/Users/someone/.data/opencode/auth.json")
    }
}
