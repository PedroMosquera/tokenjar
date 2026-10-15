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

    enum NewLeaf: String, CaseIterable, Sendable {
        case paceDays, spendDisplay, accountOrder, dailyBudget, monthlyBudget

        func edit(_ config: inout AppConfig) {
            switch self {
            case .paceDays: config.paceDays = .workingDays
            case .spendDisplay: config.menuBar.spendDisplay = .amount
            case .accountOrder: config.accountOrder = .tightestFirst
            case .dailyBudget: config.accounts[0].dailyBudget = DailyBudget(amount: 100)
            case .monthlyBudget: config.accounts[0].monthlyBudget = 200
            }
        }

        /// A config.local.json value for this leaf that differs from its default, the value config.json holds, so a
        /// leak shows in the saved file.
        var localOverride: [String: Any] {
            switch self {
            case .paceDays: ["paceDays": "workingDays"]
            case .spendDisplay: ["menuBar": ["spendDisplay": "amount"]]
            case .accountOrder: ["accountOrder": "byProvider"]
            case .dailyBudget: ["accounts": [["id": "claude", "dailyBudget": ["amount": 50]]]]
            case .monthlyBudget: ["accounts": [["id": "claude", "monthlyBudget": 500]]]
            }
        }
    }

    /// config.local.json overrides every other new leaf, so one save checks that the edited leaf is written and that
    /// none of the others leaks.
    @Test(arguments: NewLeaf.allCases)
    func everyNewLeafSavesWithoutLeakingLocalOverrides(_ leaf: NewLeaf) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"accounts": [{"id": "claude", "provider": "claude", "label": "Personal"}]}"#, to: paths.configFile)
        let local = NewLeaf.allCases.filter { $0 != leaf }.reduce(["refreshMinutes": 2] as [String: Any]) { ConfigStore.merge($0, $1.localOverride) }
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: local).write(to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        leaf.edit(&edited)
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        var expected = loaded.base
        leaf.edit(&expected)
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile)) == expected)
    }

    @Test func anAccountEditKeepsLocalOnlyAccountsOutOfConfigJSON() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"accounts": [{"id": "claude", "provider": "claude", "label": "Personal"}]}"#, to: paths.configFile)
        try write(#"{"accounts": [{"id": "claude-work", "provider": "claude", "label": "Work", "profileDir": "~/.claude-work"}]}"#, to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edited.accounts[0].label = "Home"
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let shared = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(shared.accounts.map(\.id) == ["claude"])
        #expect(shared.accounts[0].label == "Home")
    }

    enum AccountEdit: String, CaseIterable, Sendable {
        case renameShared, renameLocalOnly, moveLocalOnlyFirst, addAccount, removeShared

        func apply(_ accounts: inout [AccountConfig]) {
            switch self {
            case .renameShared: accounts[0].label = "Renamed"
            case .renameLocalOnly: accounts[2].label = "Renamed"
            case .moveLocalOnlyFirst: accounts.insert(accounts.removeLast(), at: 0)
            case .addAccount: accounts.append(AccountConfig(id: "codex-2", provider: .codex, label: "Second"))
            case .removeShared: accounts.remove(at: 1)
            }
        }
    }

    /// merge appends accounts that exist only in config.local.json, so they load last whatever order a save wrote.
    @Test(arguments: AccountEdit.allCases)
    func aLocalOnlyAccountStaysLastAfterAnyEditAndReload(_ edit: AccountEdit) throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"accounts": [{"id": "claude", "provider": "claude"}, {"id": "codex", "provider": "codex"}]}"#, to: paths.configFile)
        try write(#"{"accounts": [{"id": "claude-work", "provider": "claude", "profileDir": "~/.claude-work"}]}"#, to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edit.apply(&edited.accounts)
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let reloaded = try #require(try store.load())
        #expect(reloaded.merged.accounts.last?.id == "claude-work")
        #expect(reloaded.base.accounts.map(\.id) == edited.accounts.map(\.id).filter { $0 != "claude-work" })
    }

    /// config.json syncs to Macs that may run a newer build; a save here must not drop what that build added.
    @Test func saveKeepsKeysThisBuildDoesNotKnow() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"""
            {"futureTop": {"nested": [1, 2]}, "menuBar": {"mode": "bars", "futureMenuBarKey": "x"},
             "alerts": {"futureAlertKey": true}, "cliPaths": {"agy": "/opt/agy", "codex": "/opt/codex"},
             "accounts": [{"id": "claude", "provider": "claude", "dashboardURL": "https://x.example", "futureAccountKey": 7},
                          {"id": "codex", "provider": "codex", "futureAccountKey": 8}]}
            """#, to: paths.configFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edited.refreshMinutes = 5
        edited.cliPaths["agy"] = nil
        edited.accounts[0].dashboardURL = nil
        edited.accounts.remove(at: 1)
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as? [String: Any])
        #expect(raw["futureTop"] as? [String: [Int]] == ["nested": [1, 2]])
        #expect((raw["menuBar"] as? [String: Any])?["futureMenuBarKey"] as? String == "x")
        #expect((raw["menuBar"] as? [String: Any])?["mode"] as? String == "bars")
        #expect((raw["alerts"] as? [String: Any])?["futureAlertKey"] as? Bool == true)
        #expect(raw["refreshMinutes"] as? Int == 5)
        // Keys this build knows follow the edit, so a removed value stays removed.
        #expect(raw["cliPaths"] as? [String: String] == ["codex": "/opt/codex"])
        let accounts = try #require(raw["accounts"] as? [[String: Any]])
        #expect(accounts.map { $0["id"] as? String } == ["claude"])
        #expect(accounts.first?["futureAccountKey"] as? Int == 7)
        #expect(accounts.first?["dashboardURL"] == nil)
    }

    /// Earlier builds wrote these keys to the same synced file, so this build must load it and leave them in place.
    @Test func keysRemovedFromThisBuildStillLoadAndSurviveASave() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"""
            {"hotkey": "control+option+command+U", "alerts": {"thresholds": [70], "shortThresholds": [95]},
             "accounts": [{"id": "claude", "provider": "claude", "label": "Personal", "shortAlertThresholds": [60], "creditAllowance": 1500}]}
            """#, to: paths.configFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())
        #expect(loaded.merged.alerts.thresholds == [70])
        #expect(loaded.merged.accounts.map(\.label) == ["Personal"])

        var edited = loaded.merged
        edited.refreshMinutes = 5
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as? [String: Any])
        #expect(raw["refreshMinutes"] as? Int == 5)
        #expect(raw["hotkey"] as? String == "control+option+command+U")
        #expect((raw["alerts"] as? [String: Any])?["shortThresholds"] as? [Int] == [95])
        let account = try #require((raw["accounts"] as? [[String: Any]])?.first)
        #expect(account["shortAlertThresholds"] as? [Int] == [60])
        #expect(account["creditAllowance"] as? Int == 1500)
    }

    @Test func aConfigWithoutTheNewKeysLoadsTheDefaults() throws {
        let json = #"{"alerts": {"thresholds": [70]}, "accounts": [{"id": "copilot", "provider": "copilot"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.alerts.thresholds == [70])
        #expect(config.paceDays == .everyDay)
        #expect(config.accounts[0].dailyBudget == nil)
        #expect(config.accounts[0].monthlyBudget == nil)
        #expect(config.menuBar.spendDisplay == .percent)
        #expect(config.accountOrder == .manual)
    }

    /// Like the menu bar icon: a choice from a newer build must not fail the whole load on an older one.
    @Test(arguments: [#"{"paceDays": "someFutureChoice"}"#, #"{"paceDays": null}"#])
    func aPaceDaysValueThisBuildDoesNotKnowReadsAsEveryDay(_ json: String) {
        let config = try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config?.paceDays == .everyDay)
    }

    /// Cost stays private unless the user opts in, so an unknown choice reads as the percentage.
    @Test(arguments: [#"{"menuBar": {"spendDisplay": "someFutureChoice"}}"#, #"{"menuBar": {"spendDisplay": null}}"#])
    func aSpendDisplayThisBuildDoesNotKnowReadsAsPercent(_ json: String) {
        let config = try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config?.menuBar.spendDisplay == .percent)
    }

    @Test(arguments: [#"{"accountOrder": "someFutureChoice"}"#, #"{"accountOrder": null}"#])
    func anAccountOrderThisBuildDoesNotKnowReadsAsManual(_ json: String) {
        let config = try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config?.accountOrder == .manual)
    }

    /// A reorder writes the shared accounts in their new order and still keeps an account only config.local.json holds
    /// out of config.json.
    @Test func aReorderSavesTheNewOrderWithoutLeakingLocalAccounts() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try write(#"{"accounts": [{"id": "claude", "provider": "claude"}, {"id": "copilot", "provider": "copilot"}]}"#, to: paths.configFile)
        try write(#"{"accounts": [{"id": "claude-work", "provider": "claude", "label": "Work"}]}"#, to: paths.localConfigFile)
        let store = ConfigStore(paths: paths)
        let loaded = try #require(try store.load())

        var edited = loaded.merged
        edited.accounts = [edited.accounts[2], edited.accounts[1], edited.accounts[0]]
        try store.save(old: loaded.merged, new: edited, base: loaded.base)

        let saved = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(saved.accounts.map(\.id) == ["copilot", "claude"])
    }
}
