import Foundation
import Testing
@testable import TokenjarCore

/// Events carry no account in their dedupe key, so two accounts scanning one source store its rows under whichever
/// scanned first. The key is how callers tell that happened.
struct SharedSourceKeyTests {
    private let paths = AppPaths(home: URL(fileURLWithPath: "/Users/someone"))

    private func key(_ provider: ProviderID, _ profileDir: String?, environment: [String: String] = [:]) -> String? {
        let account = AccountConfig(id: UUID().uuidString, provider: provider, label: "x", profileDir: profileDir)
        let scanner: any HistoryScanner = switch provider {
        case .opencodeGo: OpenCodeHistoryScanner(providerIDs: ["opencode-go"], environment: environment)
        default: FetcherRegistry.scanner(for: provider)!
        }
        return scanner.sharedSourceKey(for: account, paths: paths)
    }

    @Test(arguments: [(ProviderID.claude, "~/.claude"), (.codex, "~/.codex")])
    func anAccountNamingTheDefaultFolderSharesItWithOneThatDoesNot(provider: ProviderID, defaultFolder: String) throws {
        let implicit = try #require(key(provider, nil))
        #expect(key(provider, defaultFolder + "/") == implicit)
        #expect(key(provider, "/Users/someone/" + defaultFolder.dropFirst(2)) == implicit)
        #expect(key(provider, defaultFolder + "-work") != implicit)
        #expect(!implicit.contains("/"))
    }

    @Test func opencodeAccountsShareTheDatabaseTheyRead() throws {
        let implicit = try #require(key(.opencodeGo, nil))
        #expect(key(.opencodeGo, "~/.local/share/opencode") == implicit)
        #expect(key(.opencodeGo, nil, environment: ["XDG_DATA_HOME": "/Volumes/data"]) != implicit)
        #expect(key(.opencodeGo, "~/opencode-work") != implicit)
        #expect(!implicit.contains("/"))
    }
}
