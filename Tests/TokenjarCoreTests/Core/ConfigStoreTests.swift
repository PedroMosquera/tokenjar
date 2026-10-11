import Foundation
import Testing
@testable import TokenjarCore

struct ConfigStoreTests {
    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tokenjar-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    @Test func localOverridesWinAndAccountsMergeByID() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"refreshMinutes": 10, "accounts": [{"id": "claude", "provider": "claude", "label": "Personal"}, {"id": "codex", "provider": "codex"}]}"#, to: paths.configFile)
        try write(#"{"refreshMinutes": 5, "accounts": [{"id": "claude", "showInMenuBar": false}, {"id": "work", "provider": "claude", "label": "Work"}]}"#, to: paths.localConfigFile)

        let loaded = try #require(try ConfigStore(paths: paths).load())
        #expect(loaded.hasLocalOverrides)
        #expect(loaded.merged.refreshMinutes == 5)
        #expect(loaded.base.refreshMinutes == 10)
        #expect(loaded.merged.accounts.map(\.id) == ["claude", "codex", "work"])
        #expect(loaded.merged.accounts[0].label == "Personal")
        #expect(loaded.merged.accounts[0].showInMenuBar == false)
    }

    @Test func savingAnEditDoesNotLeakLocalOverridesIntoTheSharedFile() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"accounts": [{"id": "claude", "provider": "claude", "label": "Personal", "refreshMinutes": 10}]}"#, to: paths.configFile)
        try write(#"{"refreshMinutes": 2, "accounts": [{"id": "claude", "refreshMinutes": 1, "showInMenuBar": false}]}"#, to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edited.accounts[0].label = "Home"
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let shared = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(shared.accounts[0].label == "Home")
        #expect(shared.accounts[0].refreshMinutes == 10)
        #expect(shared.accounts[0].showInMenuBar == true)
        #expect(shared.refreshMinutes == AppConfig().refreshMinutes)
    }

    /// `apply` remaps every account once any account changes, so the untouched `claude` entry still goes through the
    /// per-field copy. Comparing whole structs also covers fields added later.
    @Test func savingOneEditLeavesEveryLocallyOverriddenFieldOutOfTheSharedFile() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"accounts": [{"id": "claude", "provider": "claude", "label": "Personal"}, {"id": "codex", "provider": "codex", "label": "Plus"}]}"#, to: paths.configFile)
        try write(#"""
            {"version": 2, "refreshMinutes": 2, "launchAtLogin": true, "cliPaths": {"claude": "/opt/claude"},
             "menuBar": {"mode": "bars", "icon": "symbol:cpu", "warnAt": 60, "criticalAt": 90, "showResetCountdownWhenFull": false},
             "alerts": {"enabled": false, "thresholds": [50], "projectedExhaustion": false, "windowResets": true, "sourceProblems": false},
             "accounts": [{"id": "claude", "label": "Work", "enabled": false, "profileDir": "~/.claude-alt",
                           "credential": {"keychain": {"account": "x"}}, "showInMenuBar": false, "refreshMinutes": 1,
                           "alertThresholds": [50], "dashboardURL": "https://x.example"}]}
            """#, to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edited.accounts[1].label = "Pro"
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        var expected = loaded.base
        expected.accounts[1].label = "Pro"
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile)) == expected)
    }

    /// Settings binds single fields (Amber at, one alert toggle, one CLI path). Saving one must not carry the sibling
    /// fields config.local.json sets into the shared file.
    @Test func editingOneSubfieldWritesOnlyThatSubfield() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"cliPaths": {"agy": "/opt/agy"}, "accounts": []}"#, to: paths.configFile)
        try write(#"{"cliPaths": {"claude": "/opt/work/claude"}, "launchAtLogin": true, "menuBar": {"mode": "bars"}, "alerts": {"thresholds": [50]}}"#, to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edited.menuBar.warnAt = 70
        edited.alerts.enabled = false
        edited.cliPaths["codex"] = "/opt/codex"
        edited.cliPaths["agy"] = nil
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let shared = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(shared.menuBar == MenuBarConfig(warnAt: 70))
        #expect(shared.alerts == AlertConfig(enabled: false))
        #expect(shared.cliPaths == ["codex": "/opt/codex"])
        #expect(shared.launchAtLogin == false)
    }

    @Test func everyEditedTopLevelFieldIsWritten() {
        let old = AppConfig()
        var new = old
        new.version = 2
        new.refreshMinutes = 5
        new.launchAtLogin = true
        new.cliPaths = ["claude": "/opt/claude"]
        new.menuBar = MenuBarConfig(mode: .icon, icon: .logoClaude, warnAt: 60, criticalAt: 90, showResetCountdownWhenFull: false)
        new.alerts = AlertConfig(enabled: false, thresholds: [70], projectedExhaustion: false, windowResets: true, sourceProblems: false)

        #expect(ConfigStore.apply(from: old, to: new, onto: old) == new)
    }

    /// An account a machine's config.local.json hides is in neither merged view, only in config.json.
    @Test func accountsOnlyInTheSharedFileSurviveAnEdit() {
        let a = AccountConfig(id: "a", provider: .claude, label: "A")
        let b = AccountConfig(id: "b", provider: .codex, label: "B")
        var renamed = a
        renamed.label = "A2"

        let out = ConfigStore.apply(from: AppConfig(accounts: [a]), to: AppConfig(accounts: [renamed]), onto: AppConfig(accounts: [a, b]))

        #expect(out.accounts == [renamed, b])
    }

    /// The config is meant to be stowed from a dotfiles repo; replacing the symlink would silently stop syncing.
    @Test func writeKeepsAStowSymlinkPointingAtTheRepo() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let repoFile = home.appending(path: "dotfiles/tokenjar/.config/tokenjar/config.json")
        try write(#"{"accounts": []}"#, to: repoFile)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.configFile, withDestinationURL: repoFile)

        var config = AppConfig()
        config.refreshMinutes = 15
        try ConfigStore(paths: paths).write(config)

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.configFile.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let written = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: repoFile))
        #expect(written.refreshMinutes == 15)
    }

    /// Stow writes relative links, resolved against the link's own folder.
    @Test func writeFollowsARelativeStowLink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let repoFile = home.appending(path: "dotfiles/tokenjar/.config/tokenjar/config.json")
        try write(#"{"accounts": []}"#, to: repoFile)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: paths.configFile.path, withDestinationPath: "../../dotfiles/tokenjar/.config/tokenjar/config.json")

        var config = AppConfig()
        config.refreshMinutes = 15
        try ConfigStore(paths: paths).write(config)

        #expect(try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: repoFile)).refreshMinutes == 15)
    }

    /// A save through a link whose repo file is gone (a branch switch in the dotfiles repo) would replace the link with
    /// a regular file, and the config would silently stop syncing.
    @Test func writeThroughADanglingLinkThrowsAndKeepsTheLink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: paths.configFile.path, withDestinationPath: "../../dotfiles/tokenjar/.config/tokenjar/config.json")

        #expect {
            try ConfigStore(paths: paths).write(AppConfig())
        } throws: { error in
            if case ConfigError.brokenLink(file: "config.json") = error { return true }
            return false
        }
        #expect(try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "dotfiles").path))
    }

    /// The app names the broken file in its banner, so a syntax error such as a merge conflict must say which one.
    @Test(arguments: [("config.json", true), ("config.local.json", false)])
    func unreadableJSONNamesItsFile(file: String, isBase: Bool) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let conflicted = "<<<<<<< HEAD\n{\"refreshMinutes\": 5}\n=======\n{\"refreshMinutes\": 15}\n>>>>>>> theirs\n"
        try write(isBase ? conflicted : #"{"accounts": []}"#, to: paths.configFile)
        try write(isBase ? #"{"refreshMinutes": 5}"# : conflicted, to: paths.localConfigFile)

        #expect {
            try ConfigStore(paths: paths).load()
        } throws: { error in
            guard case ConfigError.invalidJSON(let name, let detail) = error else { return false }
            return name == file && !detail.isEmpty
        }
    }

    @Test func missingFieldsDecodeToDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts": [{"id": "x", "provider": "codex"}]}"#.utf8))
        #expect(config.alerts.thresholds == [80, 95])
        #expect(config.menuBar.mode == .worst)
        #expect(config.menuBar.icon == .app)
        #expect(config.accounts[0].label == "Codex")
        #expect(config.accounts[0].enabled)
    }

    /// These strings are what config.json stores, so renaming one would reset everyone who picked it.
    @Test func menuBarIconValuesArePinned() {
        #expect(MenuBarIcon.allCases.map(\.rawValue) == [
            "app", "mark:mana", "mark:taper", "mark:tally", "mark:burnrate", "mark:genio",
            "logo:claude", "logo:openai", "logo:antigravity", "logo:copilot", "logo:opencode", "logo:windsurf",
            "symbol:sparkles", "symbol:brain", "symbol:cpu", "symbol:gauge.with.needle",
        ])
    }

    @Test(arguments: MenuBarIcon.allCases)
    func menuBarIconRoundTrips(_ icon: MenuBarIcon) throws {
        let data = try JSONEncoder().encode(AppConfig(menuBar: MenuBarConfig(icon: icon)))
        #expect(String(decoding: data, as: UTF8.self).contains(#""icon":"\#(icon.rawValue)""#))
        #expect(try JSONDecoder().decode(AppConfig.self, from: data).menuBar.icon == icon)
    }

    /// A config written before the setting existed, or by a newer build with a choice this one lacks, keeps loading.
    @Test(arguments: [
        #"{"menuBar": {"mode": "icon"}}"#, #"{"menuBar": {"icon": "mark:unknown"}}"#, #"{"menuBar": {"icon": ""}}"#,
        #"{"menuBar": {"icon": "logo:"}}"#, #"{"menuBar": {"icon": null}}"#,
    ])
    func menuBarIconFallsBackToTheAppMark(_ json: String) {
        let config = try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config?.menuBar.icon == .app)
    }
}
