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

    @Test func launchLeavesHeadroomsFoldersAloneWhileItRuns() throws {
        let home = try ModelHome()
        defer { home.remove() }
        try writeHeadroomState(in: home)
        let model = model(home, legacyAppIsRunning: true)

        model.loadState()

        #expect(exists(home, "Library/Application Support/Headroom/headroom.sqlite"))
        #expect(exists(home, ".config/headroom/config.json"))
        #expect(model.statuses["work"]?.snapshot == nil)
    }
}
