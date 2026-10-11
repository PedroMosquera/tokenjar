import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

/// The first launch after the rename opens what Headroom left, because the move runs before the config and the
/// database are opened.
@MainActor
struct LegacyMoveTests {
    private func model(_ home: ModelHome, legacyAppIsRunning: Bool) -> AppModel {
        let log = FetchLog()
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } })
        model.legacyAppIsRunning = { legacyAppIsRunning }
        return model
    }

    private func writeHeadroomState(in home: ModelHome) throws {
        try home.write(".config/headroom/config.json", #"{"accounts": [{"id": "work", "provider": "claude", "label": "Work"}]}"#)
        let store = try SQLiteUsageStore(url: home.url.appending(path: "Library/Application Support/Headroom/headroom.sqlite"))
        try store.record(usageSnapshot(AccountConfig(id: "work", provider: .claude, label: "Work")))
    }

    private func exists(_ home: ModelHome, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: home.url.appending(path: relative).path)
    }

    @Test func launchOpensTheConfigAndHistoryHeadroomLeft() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try writeHeadroomState(in: home)
        let model = model(home, legacyAppIsRunning: false)

        model.loadState()

        #expect(model.config.accounts.map(\.id) == ["work"])
        #expect(model.statuses["work"]?.snapshot?.source == "test")
        #expect(!exists(home, "Library/Application Support/Headroom"))
        #expect(!exists(home, ".config/headroom"))
    }

    /// The move skips a Tokenjar name that is taken, so a launch that creates Tokenjar's config or database while
    /// Headroom runs would strand Headroom's for good.
    @Test func aLaunchWhileHeadroomRunsWaitsAndTheNextLaunchMoves() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try writeHeadroomState(in: home)
        let first = model(home, legacyAppIsRunning: true)

        first.loadState()
        first.tick()
        first.loadConfig()

        #expect(exists(home, "Library/Application Support/Headroom/headroom.sqlite"))
        #expect(exists(home, ".config/headroom/config.json"))
        #expect(!exists(home, "Library/Application Support/Tokenjar"))
        #expect(!exists(home, ".config/tokenjar"))
        #expect(first.statuses["work"]?.snapshot == nil)
        #expect(first.configError?.contains("Quit Headroom, then reopen Tokenjar") == true)

        let second = model(home, legacyAppIsRunning: false)
        second.loadState()

        #expect(second.config.accounts.map(\.id) == ["work"])
        #expect(second.statuses["work"]?.snapshot?.source == "test")
        #expect(second.configError == nil)
    }

    /// Here the config folder moves and the support folder cannot. Loading the moved config would let a refresh write
    /// alert state into a new support folder, which then blocks the retry.
    @Test func aMoveThatFailsLoadsNothingAndIsTriedAgainAtTheNextLaunch() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try writeHeadroomState(in: home)
        let parent = home.url.appending(path: "Library/Application Support").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        let first = model(home, legacyAppIsRunning: false)

        first.loadState()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
        first.loadConfig()
        await first.refresh(force: true)?.value

        #expect(first.config.accounts.isEmpty)
        #expect(!exists(home, "Library/Application Support/Tokenjar"))
        #expect(first.configError?.contains("could not be moved") == true)

        let second = model(home, legacyAppIsRunning: false)
        second.loadState()

        #expect(second.config.accounts.map(\.id) == ["work"])
        #expect(second.statuses["work"]?.snapshot?.source == "test")
        #expect(second.configError == nil)
    }
}
