import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct MenuBarPinTests {
    /// Kept in this Mac's preferences, not config.json, so pinning Work on a work laptop leaves other Macs alone.
    @Test func aPinIsKeptOnThisMacAndCanBeCleared() {
        let defaults = MemoryDefaults()
        let model = AppModel(paths: .preview, defaults: defaults)
        let config = model.config
        model.setPinnedAccount("claude-work")
        #expect(AppModel(paths: .preview, defaults: defaults).pinnedAccountID == "claude-work")
        #expect(model.config == config)
        model.setPinnedAccount(nil)
        #expect(AppModel(paths: .preview, defaults: defaults).pinnedAccountID == nil)
    }

    @Test func theMenuBarFollowsThePin() {
        let model = AppModel.preview()
        model.setPinnedAccount("codex")
        #expect(model.menuBarState.worst?.accountID == "codex")
    }
}
