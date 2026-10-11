import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

/// `--render-windows --real-data` runs next to the live app, so loading must not write to anything the app owns.
struct RealDataLoaderTests {
    let account = AccountConfig(id: "claude-work", provider: .claude, label: "Work")
    let fetchedAt = Date(timeIntervalSince1970: 1_791_650_000)

    private func makeHome() throws -> ModelHome {
        let home = try ModelHome()
        try home.writeConfig(AppConfig(accounts: [account]))
        try SQLiteUsageStore(url: home.paths.databaseFile).record(usageSnapshot(account, plan: "Enterprise", fetchedAt: fetchedAt))
        return home
    }

    @Test func loadsConfigAndLatestSnapshotsFromReadOnlyFilesWithoutChangingThem() throws {
        let home = try makeHome()
        let paths = home.paths
        let database = paths.databaseFile.path
        let files = [paths.configFile.path, database, database + "-wal", database + "-shm"].filter { FileManager.default.fileExists(atPath: $0) }
        let folders = [paths.configDirectory.path, paths.supportDirectory.path]
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file) }
        for folder in folders { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder) }
        defer {
            for folder in folders { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
            home.remove()
        }
        let before = try fileState(files + folders)

        let loaded = RealDataLoader(paths: paths, scratch: home.url.appending(path: "render-scratch")).load()

        #expect(loaded.warnings.isEmpty)
        #expect(loaded.model.config.accounts.map(\.id) == ["claude-work"])
        #expect(loaded.model.statuses["claude-work"]?.snapshot?.fetchedAt == fetchedAt)
        #expect(loaded.model.statuses["claude-work"]?.snapshot?.plan == "Enterprise")
        #expect(try fileState(files + folders) == before)
    }

    /// A text field that commits on losing focus would otherwise save through config.json's stow link.
    @Test func editsToTheLoadedModelAreNeverSaved() throws {
        let home = try makeHome()
        defer { home.remove() }
        let saved = try Data(contentsOf: home.configFile)

        let model = RealDataLoader(paths: home.paths, scratch: home.url.appending(path: "render-scratch")).load().model
        model.updateConfig { $0.refreshMinutes = 3 }

        #expect(try Data(contentsOf: home.configFile) == saved)
        #expect(model.configError == nil)
    }

    /// A fetch runs the account's CLI, which can start a model turn; a refresh from any view must do nothing.
    @Test func theLoadedModelNeverFetches() async throws {
        let home = try makeHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        let log = FetchLog()
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } })
        model.loadReadOnly(store: InMemoryUsageStore())
        try #require(model.accounts.map(\.id) == ["claude-work"])

        await model.refresh(force: true)?.value
        await model.refresh(accountID: "claude-work")?.value

        #expect(log.count("claude-work") == 0)
    }

    /// Modification date and permissions, the two things a stray write or chmod would change.
    private func fileState(_ paths: [String]) throws -> [String] {
        try paths.map { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path) \(modified) \(attributes[.posixPermissions] as? Int ?? -1)"
        }
    }
}
