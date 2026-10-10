import Foundation
import SQLite3
import Testing
@testable import HeadroomCore

struct SQLiteUsageStoreTests {
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    @Test func createsAPrivateWALDatabaseInAMissingDirectory() throws {
        let url = makeTemporaryDirectory().appending(path: "nested/headroom.sqlite")
        _ = try SQLiteUsageStore(url: url)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try query(url, "PRAGMA journal_mode") == ["wal"])
        #expect(try query(url, "SELECT version FROM schema_version") == ["1"])
    }

    @Test func migratesAnEmptyFile() throws {
        let url = makeTemporaryDirectory().appending(path: "headroom.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644]))

        _ = try SQLiteUsageStore(url: url)

        let tables = try query(url, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        #expect(tables == ["scan_state", "schema_version", "snapshots", "usage_events", "window_samples"])
        let indexes = try query(url, "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        #expect(indexes == ["usage_events_account_ts", "usage_events_ts", "window_samples_account_window_ts"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func reopeningKeepsDataAndDoesNotMigrateAgain() throws {
        let url = makeTemporaryDirectory().appending(path: "headroom.sqlite")
        do {
            let store = try SQLiteUsageStore(url: url)
            try store.upsert([usageEvent("k", at: now, input: 5)])
            try store.saveCheckpoints(["/a.jsonl": "10"], scanner: "claude", accountID: "acct")
            try store.record(UsageSnapshot(accountID: "acct", provider: .claude, windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 1)], fetchedAt: now, source: "test"))
        }

        let reopened = try SQLiteUsageStore(url: url)
        #expect(try reopened.dailyUsage(accountIDs: nil, since: .distantPast).map(\.inputTokens) == [5])
        #expect(try reopened.checkpoints(scanner: "claude", accountID: "acct") == ["/a.jsonl": "10"])
        #expect(try reopened.latestSnapshots().map(\.accountID) == ["acct"])
        #expect(try reopened.samples(accountID: "acct", windowID: nil, since: .distantPast).count == 1)
        #expect(try query(url, "SELECT version FROM schema_version") == ["1"])
    }

    @Test func refusesASchemaNewerThanThisBuild() throws {
        let url = makeTemporaryDirectory().appending(path: "headroom.sqlite")
        _ = try SQLiteUsageStore(url: url)
        _ = try query(url, "INSERT INTO schema_version (version) VALUES (99)")

        #expect(throws: SQLiteError.self) { try SQLiteUsageStore(url: url) }
    }

    @Test func skipsARepeatedSampleWithinFiveMinutes() throws {
        let store = try StoreKind.sqlite.make()
        let reset = now.addingTimeInterval(3600)
        func record(_ offset: TimeInterval, _ used: Double, _ resetsAt: Date?) throws {
            try store.record(UsageSnapshot(
                accountID: "acct", provider: .claude, windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: used, resetsAt: resetsAt)],
                fetchedAt: now.addingTimeInterval(offset), source: "test"
            ))
        }
        try record(0, 40, reset)
        try record(60, 40, reset)       // repeat within 5 minutes: skipped
        try record(299, 40, reset)      // still within 5 minutes of the kept sample at 0: skipped
        try record(300, 40, reset)      // 5 minutes after the kept sample: kept
        try record(360, 41, reset)      // value changed: kept
        try record(420, 41, reset.addingTimeInterval(60)) // reset moved: kept
        try record(480, 41, nil)        // reset dropped: kept
        try record(540, 41, nil)        // repeat of a nil reset within 5 minutes: skipped

        let offsets = try store.samples(accountID: "acct", windowID: "session", since: .distantPast).map { $0.timestamp.timeIntervalSince(now) }
        #expect(offsets == [0, 300, 360, 420, 480])
        #expect(try store.latestSnapshots().first?.fetchedAt == now.addingTimeInterval(540))
    }

    @Test func prunesSamplesOlderThanTheRetention() throws {
        let store = try StoreKind.sqlite.make()
        func record(_ at: Date, window: String) throws {
            try store.record(UsageSnapshot(accountID: "acct", provider: .claude, windows: [UsageWindow(id: window, label: window, usedPercent: 1)], fetchedAt: at, source: "test"))
        }
        try record(now.addingTimeInterval(-181 * 86_400), window: "old")
        try record(now.addingTimeInterval(-179 * 86_400), window: "recent")
        try record(now, window: "now")

        let windows = try store.samples(accountID: "acct", windowID: nil, since: .distantPast).map(\.windowID)
        #expect(windows == ["recent", "now"])
    }

    @Test func survivesConcurrentWriters() async throws {
        let store = try SQLiteUsageStore(url: makeTemporaryDirectory().appending(path: "headroom.sqlite"))
        let start = now
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<50 {
                        try? store.upsert([usageEvent("w\(worker)-\(i)", at: start, input: 1)])
                        try? store.record(UsageSnapshot(accountID: "w\(worker)", provider: .claude, fetchedAt: start, source: "test"))
                    }
                }
            }
        }

        #expect(try store.dailyUsage(accountIDs: nil, since: .distantPast).map(\.requests).reduce(0, +) == 400)
        #expect(try store.latestSnapshots().count == 8)
    }

    /// Reads the database through its own connection, so assertions do not depend on the store's code paths.
    private func query(_ url: URL, _ sql: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw SQLiteError(code: SQLITE_CANTOPEN, message: "open") }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteError(code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return out
    }
}
