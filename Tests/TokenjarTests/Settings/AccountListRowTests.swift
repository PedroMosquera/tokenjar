import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AccountListRowTests {
    private let now = Date(timeIntervalSince1970: 1_791_660_000)

    private func row(_ account: AccountConfig, _ status: AccountStatus) -> AccountListRowContent {
        AccountListRowContent.make(account: account, status: AccountStatusText.make(account: account, status: status, missingPath: nil, now: now))
    }

    @Test func aLabelThatRepeatsTheProviderShowsTheProvider() {
        #expect(row(AccountConfig(id: "go", provider: .opencodeGo, label: "Go"), AccountStatus()).title == "OpenCode Go")
        #expect(row(AccountConfig(id: "work", provider: .claude, label: "Work"), AccountStatus()).title == "Work")
    }

    @Test func actionableFailuresSayWhatToFix() {
        let signedOut = row(AccountConfig(id: "codex", provider: .codex, label: "Work"), AccountStatus(error: .notSignedIn))
        #expect(signedOut == AccountListRowContent(title: "Work", caption: "Signed out", isActionable: true))
        let rejected = row(AccountConfig(id: "go", provider: .opencodeGo, label: "Pasted"), AccountStatus(error: .unauthorized))
        #expect(rejected == AccountListRowContent(title: "Pasted", caption: "Key rejected", isActionable: true))
        let latched = row(AccountConfig(id: "c", provider: .claude, label: "Work"), AccountStatus(error: .unsupported(ClaudeUsageFetcher.modelTurnMessage)))
        #expect(latched.caption == "Paused")
        #expect(latched.isActionable)
    }

    @Test func calmStatesAreQuiet() {
        let noSub = row(AccountConfig(id: "go", provider: .opencodeGo, label: "Go"), AccountStatus(error: .noSubscription("none")))
        #expect(noSub == AccountListRowContent(title: "OpenCode Go", caption: "Not subscribed", isActionable: false))
        let off = row(AccountConfig(id: "codex", provider: .codex, label: "Old", enabled: false), AccountStatus())
        #expect(off == AccountListRowContent(title: "Old", caption: "Off", isActionable: false))
    }

    @Test func aPassingProblemGetsNoCaption() {
        #expect(row(AccountConfig(id: "c", provider: .claude, label: "Team"), AccountStatus(error: .network("offline"))).caption == nil)
        #expect(row(AccountConfig(id: "c", provider: .claude, label: "Team"), AccountStatus(error: .timeout)).caption == nil)
    }
}
