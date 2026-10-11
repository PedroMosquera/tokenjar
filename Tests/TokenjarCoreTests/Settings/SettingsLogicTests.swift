import Foundation
import Security
import Testing
@testable import TokenjarCore

struct SettingsLogicTests {
    let paths = AppPaths(home: URL(fileURLWithPath: "/Users/tester"))

    @Test func firstAccountOfAProviderTakesTheProviderSlug() {
        let account = SettingsLogic.newAccount(provider: .codex, existing: [AccountConfig(id: "claude", provider: .claude, label: "Default")])
        #expect(account.id == "codex")
        #expect(account.label == "Default")
    }

    @Test func newAccountIdSkipsTakenSlugs() {
        let existing = [
            AccountConfig(id: "claude", provider: .claude, label: "Personal"),
            AccountConfig(id: "claude-2", provider: .claude, label: "Work"),
        ]
        let account = SettingsLogic.newAccount(provider: .claude, existing: existing)
        #expect(account.id == "claude-3")
        #expect(account.label == "Account 3")
        #expect(account.provider == .claude)
    }

    @Test func thresholdsAreUniqueInRangeAndAscending() {
        #expect(SettingsLogic.normalizedThresholds([95, 0, 80, 101, 80, -5, 100, 1]) == [1, 80, 95, 100])
    }

    @Test func refreshOptionsKeepAHandEditedValue() {
        #expect(SettingsLogic.refreshOptions(including: 20) == [5, 10, 15, 20, 30])
        #expect(SettingsLogic.refreshOptions(including: 10) == [5, 10, 15, 30])
        #expect(SettingsLogic.refreshOptions(including: nil) == [5, 10, 15, 30])
        #expect(SettingsLogic.refreshOptions(including: 0) == [5, 10, 15, 30])
    }

    @Test(arguments: [
        ("", SettingsLogic.DashboardURLInput.providerDefault),
        ("  ", .providerDefault),
        (" https://claude.ai/settings/usage ", .custom("https://claude.ai/settings/usage")),
        ("http://localhost:8080/x", .custom("http://localhost:8080/x")),
        ("file:///etc/hosts", .invalid),
        ("file://localhost/etc/hosts", .invalid),
        ("smb://server/share", .invalid),
        ("javascript:alert(1)", .invalid),
        ("x-apple.systempreferences:com.apple.LoginItems", .invalid),
        ("claude.ai/settings", .invalid),
        ("https://", .invalid),
    ])
    func dashboardURLAcceptsOnlyWebAddresses(text: String, expected: SettingsLogic.DashboardURLInput) {
        #expect(SettingsLogic.dashboardURL(from: text) == expected)
    }

    @Test func blankProfileDirIsStoredAsNil() {
        #expect(SettingsLogic.profileDir(from: "  \n") == nil)
        #expect(SettingsLogic.profileDir(from: " ~/.claude-work ") == "~/.claude-work")
    }

    @Test func profileTwinCatchesTheDefaultSpelledOut() {
        let a = AccountConfig(id: "a", provider: .claude, label: "A")
        let b = AccountConfig(id: "b", provider: .claude, label: "B", profileDir: "~/.claude/")
        #expect(SettingsLogic.profileTwin(of: a, in: [a, b], paths: paths)?.id == "b")
    }

    @Test func profileTwinCoversGhsConfigFolder() {
        let a = AccountConfig(id: "a", provider: .copilot, label: "A")
        let b = AccountConfig(id: "b", provider: .copilot, label: "B", profileDir: "~/.config/gh")
        let other = AccountConfig(id: "c", provider: .copilot, label: "C", profileDir: "~/.config/gh-work")
        #expect(SettingsLogic.profileTwin(of: a, in: [a, other, b], paths: paths)?.id == "b")
        #expect(SettingsLogic.profileTwin(of: other, in: [a, other, b], paths: paths) == nil)
    }

    @Test func profileTwinIgnoresOtherProvidersDisabledAccountsAndOtherDirs() {
        let a = AccountConfig(id: "a", provider: .claude, label: "A")
        let codex = AccountConfig(id: "c", provider: .codex, label: "C", profileDir: "~/.claude")
        let off = AccountConfig(id: "off", provider: .claude, label: "Off", enabled: false)
        let work = AccountConfig(id: "w", provider: .claude, label: "W", profileDir: "~/.claude-work")
        #expect(SettingsLogic.profileTwin(of: a, in: [a, codex, off, work], paths: paths) == nil)
    }

    @Test func describeChangesListsWhatAnImportWouldDo() {
        let old = AppConfig(refreshMinutes: 10, accounts: [AccountConfig(id: "claude", provider: .claude, label: "Personal")])
        var new = old
        new.refreshMinutes = 5
        new.alerts.thresholds = [75, 90]
        new.accounts.append(AccountConfig(id: "codex", provider: .codex, label: "Default"))
        #expect(SettingsLogic.describeChanges(from: old, to: new) == [
            "Add account Codex \u{00B7} Default",
            "Alert thresholds: 75%, 90% used (now 80%, 95%)",
            "Refresh every 5 min (now 10 min)",
        ])
    }

    @Test func describeChangesIsEmptyWhenNothingChanges() {
        let config = AppConfig(accounts: [AccountConfig(id: "claude", provider: .claude, label: "Personal")])
        #expect(SettingsLogic.describeChanges(from: config, to: config).isEmpty)
    }

    @Test func tildePathOnlyAbbreviatesTheHomeFolder() {
        #expect(SettingsLogic.tildePath("/Users/tester/.claude-work", home: "/Users/tester") == "~/.claude-work")
        #expect(SettingsLogic.tildePath("/Users/testerX/.claude", home: "/Users/tester") == "/Users/testerX/.claude")
        #expect(SettingsLogic.tildePath("/Volumes/x", home: "/Users/tester") == "/Volumes/x")
    }

    @Test func removingAPastedKeyDeletesOnlyThatKey() throws {
        let secrets = InMemorySecretStore(["opencode-go": "placeholder-key", "opencode-zen": "placeholder-other"])
        let remaining = try SettingsLogic.removingPastedKey(from: .keychain(account: "opencode-go"), secrets: secrets)
        #expect(remaining == nil)
        #expect(try secrets.read(account: "opencode-go") == nil)
        #expect(try secrets.read(account: "opencode-zen") == "placeholder-other")
    }

    @Test func removingAPastedKeyKeepsAFileReference() throws {
        let secrets = InMemorySecretStore(["opencode-go": "placeholder-key"])
        let file = CredentialRef.file(path: "~/elsewhere/auth.json", key: "opencode-go")
        #expect(try SettingsLogic.removingPastedKey(from: file, secrets: secrets) == file)
        #expect(try secrets.read(account: "opencode-go") == "placeholder-key")
    }

    /// The caller only clears the account's reference when this throws nothing, so a refused delete must surface.
    @Test func aRefusedDeleteThrows() {
        #expect(throws: SecretStoreError.self) {
            try SettingsLogic.removingPastedKey(from: .keychain(account: "opencode-go"), secrets: RefusingSecretStore())
        }
    }
}

private struct RefusingSecretStore: SecretStore {
    func read(account: String) throws -> String? { nil }
    func write(_ secret: String, account: String) throws { throw SecretStoreError.keychain(errSecAuthFailed) }
    func delete(account: String) throws { throw SecretStoreError.keychain(errSecAuthFailed) }
}
