import Foundation
import Testing
@testable import HeadroomCore

struct AccountDiscoveryTests {
    /// A locator that only looks at the override, so the real /opt/homebrew/bin never leaks into a test.
    func locator(_ home: TempHome, agy: Bool) throws -> CLILocator {
        let path = home.url.appending(path: "bin/agy")
        if agy { try home.write("bin/agy", "#!/bin/sh\n", permissions: 0o755) }
        return CLILocator(home: home.url, overrides: ["agy": path.path])
    }

    func discover(_ home: TempHome, agy: Bool = false, environment: [String: String] = [:]) throws -> [AccountConfig] {
        AccountDiscovery.discover(paths: AppPaths(home: home.url), cli: try locator(home, agy: agy), environment: environment)
    }

    @Test func emptyHomeFindsNothing() throws {
        let home = try TempHome()
        defer { home.remove() }
        #expect(try discover(home).isEmpty)
    }

    @Test func findsEveryProviderPresent() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try home.copyFixture("claude.json", to: ".claude.json")
        // Unreadable on purpose: discovery may only check that Codex's auth.json exists.
        try home.write(".codex/auth.json", "{}", permissions: 0o000)
        try home.copyFixture("opencode-auth.json", to: ".local/share/opencode/auth.json")

        let auth = "~/.local/share/opencode/auth.json"
        #expect(try discover(home, agy: true) == [
            AccountConfig(id: "claude", provider: .claude, label: "Work"),
            AccountConfig(id: "codex", provider: .codex, label: "ChatGPT"),
            AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: auth, key: "opencode-go")),
            AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", credential: .file(path: auth, key: "opencode"), showInMenuBar: false),
            AccountConfig(id: "antigravity", provider: .antigravity, label: "Google"),
        ])
    }

    @Test(arguments: [
        (#"{"oauthAccount":{"organizationType":"claude_team"}}"#, "Work"),
        (#"{"oauthAccount":{"organizationType":"claude_enterprise"}}"#, "Work"),
        (#"{"oauthAccount":{"organizationType":"claude_max"}}"#, "Personal"),
        (#"{"oauthAccount":{}}"#, "Personal"),
        (#"{"oauthAccount":{"organizationType":42}}"#, "Personal"),
        ("not json", "Personal"),
    ])
    func claudeLabelFollowsTheSeatType(json: String, label: String) throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try home.write(".claude.json", json)
        #expect(try discover(home).map(\.label) == [label])
    }

    @Test func claudeWithoutClaudeJSONIsPersonal() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        #expect(try discover(home) == [AccountConfig(id: "claude", provider: .claude, label: "Personal")])
    }

    @Test func codexNeedsAuthJSON() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeDirectory(".codex")
        #expect(try discover(home).isEmpty)
    }

    @Test func goFallsBackToTheZenKey() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".local/share/opencode/auth.json", #"{"opencode":{"type":"api","key":"REDACTED"}}"#)
        let accounts = try discover(home)
        #expect(accounts.map(\.id) == ["opencode-go", "opencode-zen"])
        #expect(accounts.first?.credential == .file(path: "~/.local/share/opencode/auth.json", key: "opencode"))
    }

    @Test func goKeyAloneDoesNotAddZen() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".local/share/opencode/auth.json", #"{"opencode-go":{"type":"api","key":"REDACTED"},"anthropic":{}}"#)
        #expect(try discover(home).map(\.id) == ["opencode-go"])
    }

    @Test func honorsXDGDataHome() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.copyFixture("opencode-auth.json", to: "xdg/opencode/auth.json")
        try home.copyFixture("opencode-auth.json", to: "elsewhere/opencode/auth.json")
        let inside = try discover(home, environment: ["XDG_DATA_HOME": home.url.appending(path: "xdg").path])
        #expect(inside.first?.credential == .file(path: "~/xdg/opencode/auth.json", key: "opencode-go"))

        let outsideHome = try TempHome()
        defer { outsideHome.remove() }
        try outsideHome.copyFixture("opencode-auth.json", to: "opencode/auth.json")
        let outside = try discover(home, environment: ["XDG_DATA_HOME": outsideHome.url.path])
        #expect(outside.first?.credential == .file(path: outsideHome.url.appending(path: "opencode/auth.json").standardizedFileURL.path, key: "opencode-go"))
    }

    // MARK: isAvailable

    @Test func claudeAndCodexNeedTheirProfileDirectory() throws {
        let home = try TempHome()
        defer { home.remove() }
        let paths = AppPaths(home: home.url)
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let claudeWork = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        let codex = AccountConfig(id: "codex", provider: .codex, label: "ChatGPT")
        let codexWork = AccountConfig(id: "codex-work", provider: .codex, label: "Work", profileDir: "~/.codex-work")
        for account in [claude, claudeWork, codex, codexWork] {
            #expect(!AccountDiscovery.isAvailable(account, paths: paths, environment: [:]))
        }
        try home.makeDirectory(".claude")
        try home.makeDirectory(".codex-work")
        try home.write(".claude-work", "not a profile folder")
        #expect(AccountDiscovery.isAvailable(claude, paths: paths, environment: [:]))
        #expect(!AccountDiscovery.isAvailable(claudeWork, paths: paths, environment: [:]), "a file at the profile path is not a profile")
        #expect(!AccountDiscovery.isAvailable(codex, paths: paths, environment: [:]))
        #expect(AccountDiscovery.isAvailable(codexWork, paths: paths, environment: [:]))
    }

    @Test func openCodeNeedsItsCredential() throws {
        let home = try TempHome()
        defer { home.remove() }
        let paths = AppPaths(home: home.url)
        let file = AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/keys/auth.json", key: "opencode-go"))
        let keychain = AccountConfig(id: "opencode-go-2", provider: .opencodeGo, label: "Go", credential: .keychain(account: "opencode-go-2"))
        let implicit = AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen")
        #expect(!AccountDiscovery.isAvailable(file, paths: paths, environment: [:]))
        #expect(AccountDiscovery.isAvailable(keychain, paths: paths, environment: [:]))
        #expect(!AccountDiscovery.isAvailable(implicit, paths: paths, environment: [:]))

        try home.write("keys/auth.json", "{}")
        try home.write(".local/share/opencode/auth.json", "{}")
        #expect(AccountDiscovery.isAvailable(file, paths: paths, environment: [:]))
        #expect(AccountDiscovery.isAvailable(implicit, paths: paths, environment: [:]))
    }

    @Test func antigravityIsAlwaysAvailable() throws {
        let home = try TempHome()
        defer { home.remove() }
        let account = AccountConfig(id: "antigravity", provider: .antigravity, label: "Google")
        #expect(AccountDiscovery.isAvailable(account, paths: AppPaths(home: home.url), environment: [:]))
    }
}
