import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AccountFixTests {
    @Test func signedOutOffersTheCLILogin() {
        #expect(AccountFix.primary(for: .notSignedIn, provider: .codex, credential: nil) == .signIn)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .claude, credential: nil) == .signIn)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .opencodeGo, credential: .file(path: "~/auth.json", key: "opencode-go")) == .signIn)
    }

    @Test func aRejectedOpenCodeKeyIsChangedNotSignedInAgain() {
        #expect(AccountFix.primary(for: .unauthorized, provider: .opencodeGo, credential: nil) == .changeKey)
        #expect(AccountFix.primary(for: .unauthorized, provider: .opencodeGo, credential: .keychain(account: "go")) == .changeKey)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .opencodeGo, credential: .keychain(account: "go")) == .changeKey)
    }

    /// The key is still in the Keychain; changing it would not get past the prompt.
    @Test func aDeniedKeychainReadIsTriedAgainNotChanged() {
        #expect(AccountFix.primary(for: .keychainDenied, provider: .opencodeGo, credential: .keychain(account: "go")) == .tryAgain)
    }

    @Test func aRejectedCLILoginSignsInAgain() {
        #expect(AccountFix.primary(for: .unauthorized, provider: .copilot, credential: nil) == .signIn)
    }

    @Test func aMissingCLIListsWhereTokenjarLooked() {
        #expect(AccountFix.primary(for: .cliNotFound("agy"), provider: .antigravity, credential: nil) == .searchedFolders)
    }

    @Test func aLatchedProbeKeepsTryOnceMore() {
        #expect(AccountFix.primary(for: .unsupported(ClaudeUsageFetcher.modelTurnMessage), provider: .claude, credential: nil) == .tryOnceMore)
        #expect(AccountFix.primary(for: .unsupported(AntigravityUsageFetcher.modelTurnMessage), provider: .antigravity, credential: nil) == .tryOnceMore)
    }

    @Test func passingOrCalmFailuresOfferNoFix() {
        #expect(AccountFix.primary(for: .network("offline"), provider: .claude, credential: nil) == nil)
        #expect(AccountFix.primary(for: .noSubscription("none"), provider: .opencodeGo, credential: nil) == nil)
        #expect(AccountFix.primary(for: .notSignedIn, provider: .antigravity, credential: nil) == nil)
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
