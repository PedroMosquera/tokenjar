import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AppModelConfigTests {
    private func model(_ home: ModelHome) -> AppModel {
        let log = FetchLog()
        return AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } })
    }

    /// Settings > About promises CodexBar's settings are read only when the user clicks Import.
    @Test func firstRunUsesDiscoveryAndLeavesCodexBarAlone() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try home.write(".codex/auth.json", "{}")
        try home.write(".config/codexbar/config.json", #"{"providers": [{"id": "codex", "enabled": true}, {"id": "claude", "enabled": false}]}"#)
        let model = model(home)

        model.loadState()

        let written = try home.readConfig()
        #expect(written.accounts.first { $0.id == "claude" }?.enabled == true)
        #expect(written.accounts.first { $0.id == "codex" }?.enabled == true)
        #expect(model.config == written)
        #expect(model.configError == nil)
    }

    /// A stow link that dangles for a moment (a branch switch in the dotfiles repo) must not look like a first run.
    @Test func aMissingConfigAtRuntimeKeepsTheSettingsAndTheLink() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        let repoFile = try home.write("dotfiles/headroom/config.json", #"{"refreshMinutes": 5, "accounts": [{"id": "work", "provider": "claude", "label": "Work"}]}"#)
        try home.makeDirectory(".config/headroom")
        try FileManager.default.createSymbolicLink(at: home.configFile, withDestinationURL: repoFile)
        let model = model(home)
        model.loadState()
        #expect(model.config.accounts.map(\.id) == ["work"])

        try FileManager.default.removeItem(at: repoFile)
        model.loadConfig()
        #expect(model.config.accounts.map(\.id) == ["work"])
        #expect(model.config.refreshMinutes == 5)
        #expect(model.configError != nil)
        #expect(home.isSymlink(home.configFile))

        model.updateConfig { $0.refreshMinutes = 15 }
        #expect(home.isSymlink(home.configFile))
        #expect(!FileManager.default.fileExists(atPath: repoFile.path))

        try home.write("dotfiles/headroom/config.json", #"{"refreshMinutes": 7, "accounts": [{"id": "work", "provider": "claude", "label": "Work"}]}"#)
        model.loadConfig()
        #expect(model.config.refreshMinutes == 7)
        #expect(model.configError == nil)
    }

    @Test func anUnreadableConfigAtLaunchIsNeverOverwritten() throws {
        let home = try ModelHome()
        defer { home.remove() }
        let conflicted = """
        {
        <<<<<<< HEAD
          "refreshMinutes": 5,
        =======
          "refreshMinutes": 15,
        >>>>>>> other
          "accounts": [{"id": "work", "provider": "claude", "label": "Work"}]
        }
        """
        try home.write(".config/headroom/config.json", conflicted)
        let model = model(home)
        model.loadState()
        let error = try #require(model.configError)
        #expect(!error.contains("last good"))

        model.updateConfig { $0.refreshMinutes = 30 }

        #expect(try String(contentsOf: home.configFile, encoding: .utf8) == conflicted)
        #expect(model.configError != nil)
    }

    @Test func aBrokenLocalOverrideNeverOverwritesTheSharedFile() throws {
        let home = try ModelHome()
        defer { home.remove() }
        let shared = #"{"refreshMinutes": 5, "accounts": [{"id": "work", "provider": "claude", "label": "Work"}]}"#
        try home.write(".config/headroom/config.json", shared)
        try home.write(".config/headroom/config.local.json", #"{"refreshMinutes": "soon"}"#)
        let model = model(home)
        model.loadState()
        #expect(model.configError?.contains("config.local.json") == true)

        model.updateConfig { $0.refreshMinutes = 30 }

        #expect(try String(contentsOf: home.configFile, encoding: .utf8) == shared)
    }

    /// A `git pull` lands between two ticks; the next Settings edit must apply on top of it, not on the stale copy.
    @Test func anEditAfterAnOutsideChangeKeepsThatChange() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try home.makeDirectory(".claude-work")
        let personal = AccountConfig(id: "personal", provider: .claude, label: "Personal")
        try home.writeConfig(AppConfig(accounts: [personal]))
        let model = model(home)
        model.loadState()

        let work = AccountConfig(id: "work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        try home.writeConfig(AppConfig(accounts: [personal, work]))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: home.configFile.path)
        model.updateConfig { $0.refreshMinutes = 15 }

        let saved = try home.readConfig()
        #expect(saved.accounts.map(\.id) == ["personal", "work"])
        #expect(saved.refreshMinutes == 15)
        #expect(model.config.accounts.map(\.id) == ["personal", "work"])
    }

    @Test func aHistoryProblemOutlivesASuccessfulSave() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.writeConfig(AppConfig())
        // A file where the support directory should be: the database cannot open.
        try home.write("Library/Application Support/Headroom", "")
        let model = model(home)
        model.loadState()
        #expect(model.configError?.contains("History") == true)

        model.updateConfig { $0.refreshMinutes = 15 }

        #expect(try home.readConfig().refreshMinutes == 15)
        #expect(model.configError?.contains("History") == true)
    }

    @Test func aDanglingLinkAtLaunchIsNotAFirstRun() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try home.makeDirectory(".config/headroom")
        let repoFile = home.url.appending(path: "dotfiles/headroom/config.json")
        try FileManager.default.createSymbolicLink(at: home.configFile, withDestinationURL: repoFile)
        let model = model(home)

        model.loadState()

        #expect(home.isSymlink(home.configFile))
        #expect(!FileManager.default.fileExists(atPath: repoFile.path))
        #expect(model.config.accounts.isEmpty)
        #expect(model.configError != nil)
    }
}
