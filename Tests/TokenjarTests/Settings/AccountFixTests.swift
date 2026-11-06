import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AccountFixTests {
    @Test func signedOutOffersTheCLILogin() {
        #expect(AccountFix.primary(for: .notSignedIn, provider: .codex) == .signIn)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .claude) == .signIn)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .opencodeGo) == .signIn)
    }

    /// opencode's own login is the only way to replace the key it saved.
    @Test func aRejectedOpenCodeKeySignsInAgain() {
        #expect(AccountFix.primary(for: .unauthorized, provider: .opencodeGo) == .signIn)
    }

    @Test func aRejectedCLILoginSignsInAgain() {
        #expect(AccountFix.primary(for: .unauthorized, provider: .copilot) == .signIn)
    }

    @Test func aMissingCLIListsWhereTokenjarLooked() {
        #expect(AccountFix.primary(for: .cliNotFound("agy"), provider: .antigravity) == .searchedFolders)
    }

    @Test func aLatchedProbeKeepsTryOnceMore() {
        #expect(AccountFix.primary(for: .unsupported(ClaudeUsageFetcher.modelTurnMessage), provider: .claude) == .tryOnceMore)
        #expect(AccountFix.primary(for: .unsupported(AntigravityUsageFetcher.modelTurnMessage), provider: .antigravity) == .tryOnceMore)
    }

    @Test func passingOrCalmFailuresOfferNoFix() {
        #expect(AccountFix.primary(for: .network("offline"), provider: .claude) == nil)
        #expect(AccountFix.primary(for: .noSubscription("none"), provider: .opencodeGo) == nil)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .antigravity) == nil)
    }

    /// Pinned so that giving an outdated CLI a fix later is a deliberate change.
    @Test func anOutdatedCLIHasNoFixYet() {
        for provider in ProviderID.allCases {
            #expect(AccountFix.primary(for: .cliTooOld(name: "codex", minimum: nil), provider: provider) == nil, "\(provider)")
        }
    }

    @Test func anOutdatedCLIIsCaptionedCheckFailed() {
        let codex = AccountConfig(id: "codex", provider: .codex, label: "Plus")
        let status = AccountStatus(error: .cliTooOld(name: "codex", minimum: "0.50.0"))
        let line = AccountStatusText.make(account: codex, status: status, missingPath: nil, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(line.caption == AccountStatusText.Caption(text: "Check failed", isActionable: true))
        #expect(line.text == "Update codex to 0.50.0 or later.")
    }

    @Test func theSearchedFoldersReadAsTildePaths() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let text = AccountFix.searchedText(for: "agy", locator: CLILocator(home: home), home: home.path)
        #expect(text == "Looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and 5 more")
    }

    @Test func aConfiguredCLIPathIsTheOnlyPlaceLooked() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let locator = CLILocator(home: home, overrides: ["agy": "/Users/someone/bin/agy"])
        #expect(AccountFix.searchedText(for: "agy", locator: locator, home: home.path) == "Looked only at ~/bin/agy, set in cliPaths")
    }
}

struct PlanLoginTests {
    private func snapshot(_ billing: Billing?) -> UsageSnapshot {
        UsageSnapshot(accountID: "claude", provider: .claude, billing: billing, fetchedAt: Date(timeIntervalSince1970: 0), source: "test")
    }

    @Test func aLoginBilledOutsideAPlanHasNothingToSignIn() {
        #expect(PlanLogin.applies(snapshot: snapshot(.payAsYouGo)) == false)
    }

    @Test func aPlanLoginOrAnUncheckedOneKeepsThem() {
        #expect(PlanLogin.applies(snapshot: snapshot(nil)))
        #expect(PlanLogin.applies(snapshot: snapshot(.subscription)))
        #expect(PlanLogin.applies(snapshot: nil))
    }
}
