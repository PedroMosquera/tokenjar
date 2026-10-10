import Foundation
import Testing
@testable import HeadroomCore

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
        let home = try TempHome()
        defer { home.remove() }
        try home.copyFixture("codexbar-config.json", to: ".config/codexbar/config.json")
        let defaults = FakeDefaults(codexBarDefaults)

        let preview = CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: defaults)

        #expect(preview == CodexBarImportPreview(
            enabledProviders: [.codex, .claude, .opencodeGo, .antigravity], thresholdsUsed: [50, 80], refreshMinutes: 15, notificationsEnabled: true
        ))
        #expect(Set(defaults.requested) == Set(CodexBarImport.defaultsKeys))
    }

    @Test func defaultsAllowlistIsPinned() {
        #expect(CodexBarImport.defaultsKeys == ["refreshFrequency", "quotaWarningNotificationsEnabled", "quotaWarningThresholds"])
    }

    @Test func nothingToImportIsNil() throws {
        let home = try TempHome()
        defer { home.remove() }
        #expect(CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults()) == nil)
    }

    @Test func defaultsAloneStillPreview() throws {
        let home = try TempHome()
        defer { home.remove() }
        let preview = CodexBarImport.preview(paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults(["refreshFrequency": "twoMinutes"]))
        #expect(preview == CodexBarImportPreview(enabledProviders: [], refreshMinutes: 2))
    }

    @Test func findsConfigUnderXDGAndLegacyPaths() throws {
        let home = try TempHome()
        defer { home.remove() }
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
        let home = try TempHome()
        defer { home.remove() }
        let preview = CodexBarImport.preview(
            paths: AppPaths(home: home.url), environment: [:], defaults: FakeDefaults(["quotaWarningThresholds": [0], "quotaWarningNotificationsEnabled": false])
        )
        #expect(preview == CodexBarImportPreview(enabledProviders: [], notificationsEnabled: false))
    }

    @Test func geminiAndAntigravityCollapseIntoOneProvider() {
        #expect(CodexBarImport.providerID("gemini") == .antigravity)
        #expect(CodexBarImport.providerID("antigravity") == .antigravity)
        #expect(CodexBarImport.providerID("opencode") == .opencodeZen)
        #expect(CodexBarImport.providerID("opencodego") == .opencodeGo)
        #expect(CodexBarImport.providerID("cursor") == nil)
    }

    // MARK: apply

    let discovered = [
        AccountConfig(id: "claude", provider: .claude, label: "Work"),
        AccountConfig(id: "codex", provider: .codex, label: "ChatGPT"),
        AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go"),
        AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", showInMenuBar: false),
    ]

    @Test func applyMirrorsProvidersAndCopiesSettings() {
        let custom = AccountConfig(id: "claude-personal", provider: .claude, label: "Personal", profileDir: "~/.claude-personal")
        var claudeEdited = discovered[0]
        claudeEdited.alertThresholds = [70]
        let config = AppConfig(accounts: [claudeEdited, discovered[2], custom])
        let preview = CodexBarImportPreview(enabledProviders: [.claude, .codex], thresholdsUsed: [50, 80], refreshMinutes: 5, notificationsEnabled: false)

        let applied = CodexBarImport.apply(preview, to: config, discovered: discovered)

        #expect(applied.accounts.map(\.id) == ["claude", "opencode-go", "claude-personal", "codex", "opencode-zen"])
        #expect(applied.accounts.map(\.enabled) == [true, false, true, true, false])
        #expect(applied.accounts[0].alertThresholds == [70])
        #expect(applied.accounts[2] == custom)
        #expect(applied.alerts.thresholds == [50, 80])
        #expect(applied.refreshMinutes == 5)
        #expect(applied.alerts.enabled == false)
    }

    @Test func applyLeavesAccountsAloneWithoutProviderList() {
        let config = AppConfig(accounts: discovered)
        let applied = CodexBarImport.apply(CodexBarImportPreview(enabledProviders: [], refreshMinutes: 2), to: config, discovered: discovered)
        #expect(applied.accounts == discovered)
        #expect(applied.refreshMinutes == 2)
        #expect(applied.alerts == AlertConfig())
    }
}
