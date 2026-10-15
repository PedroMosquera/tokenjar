import Foundation
import Testing
@testable import TokenjarCore

/// Stands in for CodexBar's defaults suite and records every key the import asks for.
final class FakeDefaults: DefaultsReading {
    var values: [String: Any]
    private(set) var requested: [String] = []

    init(_ values: [String: Any] = [:]) { self.values = values }

    func object(forKey defaultName: String) -> Any? {
        requested.append(defaultName)
        return values[defaultName]
    }
}

struct CodexBarImportTests {
    let codexBarDefaults: [String: Any] = [
        "refreshFrequency": "fifteenMinutes",
        "quotaWarningNotificationsEnabled": true,
        "quotaWarningThresholds": [50, 20],
        "openAIAPIKey": "REDACTED",
    ]

    @Test func previewReadsProvidersAndAllowlistedDefaults() throws {
        let home = TempHome()
        try home.copyFixture("codexbar-config.json", to: ".config/codexbar/config.json")
        let defaults = FakeDefaults(codexBarDefaults)

        let preview = CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: defaults)

        #expect(preview == CodexBarImportPreview(
            enabledProviders: [.codex, .claude, .opencodeGo, .antigravity], thresholdsUsed: [50, 80], refreshMinutes: 15, notificationsEnabled: true
        ))
        // A literal, so a key added to the import or to the allowlist fails here.
        #expect(Set(defaults.requested) == ["refreshFrequency", "quotaWarningNotificationsEnabled", "quotaWarningThresholds"])
        #expect(Set(defaults.requested) == Set(CodexBarImport.defaultsKeys))
    }

    @Test func nothingToImportIsNil() throws {
        let home = TempHome()
        #expect(CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults()) == nil)
    }

    @Test func defaultsAloneStillPreview() throws {
        let home = TempHome()
        let preview = CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults(["refreshFrequency": "twoMinutes"]))
        #expect(preview == CodexBarImportPreview(refreshMinutes: 2))
    }

    @Test func configWithNoneOfOurProvidersPreviewsAnEmptyList() throws {
        let home = TempHome()
        try home.write(".config/codexbar/config.json", #"{"providers":[{"id":"cursor","enabled":true},{"id":"claude","enabled":false}]}"#)
        #expect(CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults())?.enabledProviders == [])
    }

    @Test func findsConfigUnderXDGAndLegacyPaths() throws {
        let home = TempHome()
        let paths = AppPaths(home: home.url)
        try home.write(".codexbar/config.json", #"{"providers":[{"id":"claude","enabled":true}]}"#)
        #expect(CodexBarImport.preview(paths: paths, environment: [:], defaults: FakeDefaults())?.enabledProviders == [.claude])

        try home.write("xdg/codexbar/config.json", #"{"providers":[{"id":"codex","enabled":true}]}"#)
        let xdg = ["XDG_CONFIG_HOME": home.url.appending(path: "xdg").path]
        #expect(CodexBarImport.preview(paths: paths, environment: xdg, defaults: FakeDefaults())?.enabledProviders == [.codex])
    }

    @Test(arguments: [
        ("oneMinute", 1), ("twoMinutes", 2), ("fiveMinutes", 5), ("fifteenMinutes", 15), ("thirtyMinutes", 30),
        ("manual", nil), ("adaptive", nil), ("adaptiveAgentAware", nil), ("hourly", nil),
    ] as [(String, Int?)])
    func refreshFrequencyMapsToMinutes(frequency: String, minutes: Int?) {
        #expect(CodexBarImport.refreshMinutes(frequency) == minutes)
    }

    @Test func thresholdsConvertFromRemainingToUsed() {
        #expect(CodexBarImport.usedThresholds([50, 20]) == [50, 80])
        #expect(CodexBarImport.usedThresholds([5, 20, 20, 0]) == [80, 95])
        #expect(CodexBarImport.usedThresholds([0, 100]).isEmpty)
    }

    @Test func offOnlyThresholdsAreNotImported() throws {
        let home = TempHome()
        let preview = CodexBarImport.preview(
            paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults(["quotaWarningThresholds": [0], "quotaWarningNotificationsEnabled": false])
        )
        #expect(preview == CodexBarImportPreview(notificationsEnabled: false))
    }

    @Test func geminiAndAntigravityCollapseIntoOneProvider() {
        #expect(CodexBarImport.providerID("gemini") == .antigravity)
        #expect(CodexBarImport.providerID("antigravity") == .antigravity)
        #expect(CodexBarImport.providerID("opencode") == .opencodeZen)
        #expect(CodexBarImport.providerID("opencodego") == .opencodeGo)
        #expect(CodexBarImport.providerID("cursor") == nil)
    }

    @Test func copilotKeepsItsIDAndWindsurfIsNowDevin() {
        #expect(CodexBarImport.providerID("copilot") == .copilot)
        #expect(CodexBarImport.providerID("devin") == .devin)
        #expect(CodexBarImport.providerID("windsurf") == .devin)
    }

    @Test func devinIsOneLoginPerMac() {
        let config = AppConfig(accounts: [AccountConfig(id: "windsurf", provider: .devin, label: "Windsurf", showInMenuBar: false)])
        let applied = apply(CodexBarImportPreview(enabledProviders: []), to: config, discovered: [AccountConfig(id: "devin", provider: .devin, label: "Devin")])
        #expect(applied.accounts.map(\.id) == ["windsurf"])
        #expect(applied.accounts.map(\.enabled) == [false])
    }

    // MARK: apply

    let paths = AppPaths(home: URL(fileURLWithPath: "/Users/test"))
    let authFile = "~/.local/share/opencode/auth.json"

    var discovered: [AccountConfig] {
        [
            AccountConfig(id: "claude", provider: .claude, label: "Work"),
            AccountConfig(id: "codex", provider: .codex, label: "ChatGPT"),
            AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: authFile, key: "opencode-go")),
            AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", credential: .file(path: authFile, key: "opencode"), showInMenuBar: false),
        ]
    }

    func apply(_ preview: CodexBarImportPreview, to config: AppConfig, discovered: [AccountConfig]? = nil) -> AppConfig {
        CodexBarImport.apply(preview, to: config, discovered: discovered ?? self.discovered, paths: paths, environment: [:])
    }

    @Test func applyMirrorsProvidersAndCopiesSettings() {
        let custom = AccountConfig(id: "claude-personal", provider: .claude, label: "Personal", profileDir: "~/.claude-personal")
        var claudeEdited = discovered[0]
        claudeEdited.alertThresholds = [70]
        let config = AppConfig(accounts: [claudeEdited, discovered[2], custom])
        let preview = CodexBarImportPreview(enabledProviders: [.claude, .codex], thresholdsUsed: [50, 80], refreshMinutes: 5, notificationsEnabled: false)

        let applied = apply(preview, to: config)

        #expect(applied.accounts.map(\.id) == ["claude", "opencode-go", "claude-personal", "codex", "opencode-zen"])
        #expect(applied.accounts.map(\.enabled) == [true, false, true, true, false])
        #expect(applied.accounts[0].alertThresholds == [70])
        #expect(applied.accounts[2] == custom)
        #expect(applied.alerts.thresholds == [50, 80])
        #expect(applied.refreshMinutes == 5)
        #expect(applied.alerts.enabled == false)
    }

    @Test func applyMatchesTheSameLoginUnderAnotherID() {
        let config = AppConfig(accounts: [
            AccountConfig(id: "claude-personal", provider: .claude, label: "Personal"),
            AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work"),
            AccountConfig(id: "plus", provider: .codex, label: "Plus", profileDir: "/Users/test/.codex/"),
            AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: .file(path: "/Users/test/.local/share/opencode/auth.json", key: "opencode-go")),
            AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen"),
            AccountConfig(id: "google", provider: .antigravity, label: "Google"),
        ])
        let discovered = discovered + [AccountConfig(id: "antigravity", provider: .antigravity, label: "Google")]

        let applied = apply(CodexBarImportPreview(enabledProviders: [.codex, .antigravity]), to: config, discovered: discovered)

        #expect(applied.accounts.map(\.id) == config.accounts.map(\.id))
        #expect(applied.accounts.map(\.enabled) == [false, true, true, false, false, true])
    }

    /// gh's default config folder spelled out is the same login, and another GH_CONFIG_DIR is a second one.
    @Test func applyMatchesCopilotByGhConfigFolder() {
        let config = AppConfig(accounts: [
            AccountConfig(id: "github", provider: .copilot, label: "GitHub", profileDir: "~/.config/gh/"),
            AccountConfig(id: "github-work", provider: .copilot, label: "Work", profileDir: "~/.config/gh-work"),
        ])
        let discovered = [AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")]

        let applied = apply(CodexBarImportPreview(enabledProviders: []), to: config, discovered: discovered)

        #expect(applied.accounts.map(\.id) == ["github", "github-work"])
        #expect(applied.accounts.map(\.enabled) == [false, true])
    }

    /// Zen reads only opencode.db, so its data folder is the login whatever key its credential names.
    @Test func applyMatchesZenByItsDatabase() {
        let config = AppConfig(accounts: [
            AccountConfig(id: "zen-pasted", provider: .opencodeZen, label: "Zen", credential: .keychain(account: "zen-pasted")),
            AccountConfig(id: "zen-go-entry", provider: .opencodeZen, label: "Zen", credential: .file(path: authFile, key: "opencode-go")),
            AccountConfig(id: "zen-elsewhere", provider: .opencodeZen, label: "Zen", profileDir: "~/elsewhere/opencode"),
        ])

        let applied = apply(CodexBarImportPreview(enabledProviders: []), to: config, discovered: [discovered[3]])

        #expect(applied.accounts.map(\.id) == config.accounts.map(\.id))
        #expect(applied.accounts.map(\.enabled) == [false, false, true])
    }

    @Test func applyAddsAnotherLoginUnderAFreeID() throws {
        let config = AppConfig(accounts: [
            AccountConfig(id: "claude", provider: .claude, label: "Work", profileDir: "~/.claude-work"),
            AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Pasted", credential: .keychain(account: "opencode-go")),
            AccountConfig(id: "opencode-go-2", provider: .opencodeGo, label: "Zen key", credential: .file(path: authFile, key: "opencode")),
        ])

        let applied = apply(CodexBarImportPreview(enabledProviders: [.claude, .opencodeGo]), to: config, discovered: [discovered[0], discovered[2]])

        try #require(applied.accounts.map(\.id) == ["claude", "opencode-go", "opencode-go-2", "claude-2", "opencode-go-3"])
        #expect(applied.accounts[3].profileDir == nil)
        #expect(applied.accounts[4].credential == discovered[2].credential)
    }

    @Test func applyMirrorsAConfigWithNoneOfOurProvidersOn() {
        let applied = apply(CodexBarImportPreview(enabledProviders: []), to: AppConfig(accounts: discovered))
        #expect(applied.accounts.map(\.enabled) == [false, false, false, false])
    }

    @Test func applyLeavesAccountsAloneWithoutCodexBarConfig() {
        let config = AppConfig(accounts: discovered)
        let applied = apply(CodexBarImportPreview(refreshMinutes: 2), to: config)
        #expect(applied.accounts == discovered)
        #expect(applied.refreshMinutes == 2)
        #expect(applied.alerts == AlertConfig())
    }
}
