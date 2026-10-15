import Foundation
import Testing
@testable import TokenjarCore

struct AccountDiscoveryTests {
    /// A locator that searches only the temp home's bin, so a CLI installed on the Mac running the tests never leaks in.
    func locator(_ home: TempHome, agy: Bool, gh: Bool) throws -> CLILocator {
        if agy { try home.write("bin/agy", "#!/bin/sh\n", permissions: 0o755) }
        if gh { try home.write("bin/gh", "#!/bin/sh\n", permissions: 0o755) }
        return CLILocator(home: home.url, searchDirectories: [home.url.appending(path: "bin")])
    }

    /// Stands in for /Applications, so an app installed on the machine running the tests is never seen.
    func discover(_ home: TempHome, agy: Bool = false, gh: Bool = false, environment: [String: String] = [:]) throws -> [AccountConfig] {
        AccountDiscovery.discover(
            paths: AppPaths(home: home.url), cli: try locator(home, agy: agy, gh: gh), environment: environment,
            systemApplications: home.url.appending(path: "SystemApplications")
        )
    }

    @Test func emptyHomeFindsNothing() throws {
        let home = TempHome()
        #expect(try discover(home).isEmpty)
    }

    @Test func findsEveryProviderPresent() throws {
        let home = TempHome()
        try home.makeDirectory(".claude")
        try home.copyFixture("claude.json", to: ".claude.json")
        // Unreadable on purpose: discovery may only check that Codex's auth.json exists.
        try home.write(".codex/auth.json", "{}", permissions: 0o000)
        try home.copyFixture("opencode-auth.json", to: ".local/share/opencode/auth.json")
        try home.makeDirectory("SystemApplications/Devin.app")

        let auth = "~/.local/share/opencode/auth.json"
        #expect(try discover(home, agy: true, gh: true) == [
            AccountConfig(id: "claude", provider: .claude, label: "Work"),
            AccountConfig(id: "codex", provider: .codex, label: "ChatGPT"),
            AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: auth, key: "opencode-go")),
            AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", credential: .file(path: auth, key: "opencode"), showInMenuBar: false),
            AccountConfig(id: "antigravity", provider: .antigravity, label: "Google"),
            AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
            AccountConfig(id: "devin", provider: .devin, label: "Devin", showInMenuBar: false),
        ])
    }

    /// Existence only: the bundles and data folders are never opened.
    @Test(arguments: [
        "SystemApplications/Devin.app", "Applications/Devin.app", "SystemApplications/Windsurf.app", "Applications/Windsurf.app",
        "Library/Application Support/Devin", "Library/Application Support/Windsurf",
    ])
    func anyDevinOrWindsurfInstallProposesALinkOnlyDevinAccount(marker: String) throws {
        let home = TempHome()
        try home.makeDirectory(marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.url.appending(path: marker).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.url.appending(path: marker).path) }
        #expect(try discover(home) == [AccountConfig(id: "devin", provider: .devin, label: "Devin", showInMenuBar: false)])
    }

    @Test func otherApplicationsDoNotProposeDevin() throws {
        let home = TempHome()
        try home.makeDirectory("SystemApplications/Cursor.app")
        try home.makeDirectory("Library/Application Support/Code")
        #expect(try discover(home).isEmpty)
    }

    /// gh is only located, never run, and its config folder is never opened: it can hold a token.
    @Test func ghOnThePathProposesCopilot() throws {
        let home = TempHome()
        try home.write(".config/gh/hosts.yml", "unreadable on purpose", permissions: 0o000)
        try home.write("bin/gh", "#!/bin/sh\ntouch \"$0.ran\"\n", permissions: 0o755)
        #expect(try discover(home) == [AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")])
        #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "bin/gh.ran").path))
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
        let home = TempHome()
        try home.makeDirectory(".claude")
        try home.write(".claude.json", json)
        #expect(try discover(home).map(\.label) == [label])
    }

    @Test func claudeWithoutClaudeJSONIsPersonal() throws {
        let home = TempHome()
        try home.makeDirectory(".claude")
        #expect(try discover(home) == [AccountConfig(id: "claude", provider: .claude, label: "Personal")])
    }

    @Test func codexNeedsAuthJSON() throws {
        let home = TempHome()
        try home.makeDirectory(".codex")
        #expect(try discover(home).isEmpty)
    }

    @Test func goFallsBackToTheZenKey() throws {
        let home = TempHome()
        try home.write(".local/share/opencode/auth.json", #"{"opencode":{"type":"api","key":"REDACTED"}}"#)
        let accounts = try discover(home)
        #expect(accounts.map(\.id) == ["opencode-go", "opencode-zen"])
        #expect(accounts.first?.credential == .file(path: "~/.local/share/opencode/auth.json", key: "opencode"))
    }

    @Test func goKeyAloneDoesNotAddZen() throws {
        let home = TempHome()
        try home.write(".local/share/opencode/auth.json", #"{"opencode-go":{"type":"api","key":"REDACTED"},"anthropic":{}}"#)
        #expect(try discover(home).map(\.id) == ["opencode-go"])
    }

    @Test func honorsXDGDataHome() throws {
        let home = TempHome()
        try home.copyFixture("opencode-auth.json", to: "xdg/opencode/auth.json")
        try home.copyFixture("opencode-auth.json", to: "elsewhere/opencode/auth.json")
        let inside = try discover(home, environment: ["XDG_DATA_HOME": home.url.appending(path: "xdg").path])
        #expect(inside.first?.credential == .file(path: "~/xdg/opencode/auth.json", key: "opencode-go"))

        let outsideHome = TempHome()
        try outsideHome.copyFixture("opencode-auth.json", to: "opencode/auth.json")
        let outside = try discover(home, environment: ["XDG_DATA_HOME": outsideHome.url.path])
        #expect(outside.first?.credential == .file(path: outsideHome.url.appending(path: "opencode/auth.json").standardizedFileURL.path, key: "opencode-go"))
    }

    // MARK: isAvailable

    @Test func claudeAndCodexNeedTheirProfileDirectory() throws {
        let home = TempHome()
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
        let home = TempHome()
        let paths = AppPaths(home: home.url)
        let file = AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/keys/auth.json", key: "opencode-go"))
        let keychain = AccountConfig(id: "opencode-go-2", provider: .opencodeGo, label: "Go", credential: .keychain(account: "opencode-go-2"))
        let implicit = AccountConfig(id: "opencode-go-3", provider: .opencodeGo, label: "Go")
        #expect(!AccountDiscovery.isAvailable(file, paths: paths, environment: [:]))
        #expect(AccountDiscovery.isAvailable(keychain, paths: paths, environment: [:]))
        #expect(!AccountDiscovery.isAvailable(implicit, paths: paths, environment: [:]))

        try home.write("keys/auth.json", "{}")
        try home.write(".local/share/opencode/auth.json", "{}")
        #expect(AccountDiscovery.isAvailable(file, paths: paths, environment: [:]))
        #expect(AccountDiscovery.isAvailable(implicit, paths: paths, environment: [:]))
    }

    /// Zen never reads a key, so the auth.json path first run gives it must not hide it, or name a file it does not read.
    @Test func zenNeedsOpencodesDatabaseNotAuthJSON() throws {
        let home = TempHome()
        let paths = AppPaths(home: home.url)
        let implicit = AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen")
        let discovered = AccountConfig(
            id: "opencode-zen", provider: .opencodeZen, label: "Zen",
            credential: .file(path: "~/.local/share/opencode/auth.json", key: "opencode"), showInMenuBar: false
        )
        try home.write(".local/share/opencode/auth.json", "{}")
        #expect(!AccountDiscovery.isAvailable(implicit, paths: paths, environment: [:]))
        #expect(!AccountDiscovery.isAvailable(discovered, paths: paths, environment: [:]))

        try FileManager.default.removeItem(at: home.url.appending(path: ".local/share/opencode/auth.json"))
        try home.write(".local/share/opencode/opencode.db", "")
        #expect(AccountDiscovery.isAvailable(implicit, paths: paths, environment: [:]))
        #expect(AccountDiscovery.isAvailable(discovered, paths: paths, environment: [:]))
        #expect(AccountDiscovery.location(of: discovered, paths: paths, environment: [:]) == home.url.appending(path: ".local/share/opencode/opencode.db"))
    }

    @Test(arguments: [
        (profileDir: nil, environment: [:]),
        (profileDir: nil, environment: ["XDG_DATA_HOME": "/data"]),
        (profileDir: "~/elsewhere/opencode", environment: ["XDG_DATA_HOME": "/data"]),
    ] as [(profileDir: String?, environment: [String: String])])
    func zenIsLookedForWhereItsFetcherReads(profileDir: String?, environment: [String: String]) {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/tester"))
        let zen = AccountConfig(
            id: "opencode-zen", provider: .opencodeZen, label: "Zen", profileDir: profileDir,
            credential: .file(path: "~/.local/share/opencode/auth.json", key: "opencode")
        )
        let read = OpenCodeHistoryScanner(providerIDs: [OpenCodeZenUsageFetcher.zenProviderID], environment: environment).databaseFile(for: zen, paths: paths)
        #expect(AccountDiscovery.location(of: zen, paths: paths, environment: environment) == read)
    }

    @Test func copilotNeedsGhsConfigFolder() throws {
        let home = TempHome()
        let paths = AppPaths(home: home.url)
        let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
        let work = AccountConfig(id: "copilot-work", provider: .copilot, label: "Work", profileDir: "~/.config/gh-work")
        #expect(!AccountDiscovery.isAvailable(copilot, paths: paths, environment: [:]))
        #expect(!AccountDiscovery.isAvailable(work, paths: paths, environment: [:]))
        try home.makeDirectory(".config/gh")
        #expect(AccountDiscovery.isAvailable(copilot, paths: paths, environment: [:]))
        #expect(!AccountDiscovery.isAvailable(work, paths: paths, environment: [:]))
        try home.makeDirectory(".config/gh-work")
        #expect(AccountDiscovery.isAvailable(work, paths: paths, environment: [:]))
    }

    @Test func antigravityIsAlwaysAvailable() throws {
        let home = TempHome()
        let account = AccountConfig(id: "antigravity", provider: .antigravity, label: "Google")
        #expect(AccountDiscovery.isAvailable(account, paths: AppPaths(home: home.url), environment: [:]))
    }

    /// A link reads nothing on this Mac, so a shared config shows it on every Mac.
    @Test func devinIsAlwaysAvailable() throws {
        let home = TempHome()
        let account = AccountConfig(id: "devin", provider: .devin, label: "Devin", profileDir: "~/missing")
        #expect(AccountDiscovery.isAvailable(account, paths: AppPaths(home: home.url), environment: [:]))
    }
}
