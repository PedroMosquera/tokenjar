import Foundation
import Testing
@testable import HeadroomCore

struct ConfigStoreTests {
    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "headroom-config-\(UUID().uuidString)")
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

    /// The config is meant to be stowed from a dotfiles repo; replacing the symlink would silently stop syncing.
    @Test func writeKeepsAStowSymlinkPointingAtTheRepo() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let repoFile = home.appending(path: "dotfiles/headroom/.config/headroom/config.json")
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

    @Test func missingFieldsDecodeToDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts": [{"id": "x", "provider": "codex"}]}"#.utf8))
        #expect(config.alerts.thresholds == [80, 95])
        #expect(config.menuBar.mode == .worst)
        #expect(config.accounts[0].label == "Codex")
        #expect(config.accounts[0].enabled)
    }
}
