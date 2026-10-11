import Foundation
import SQLite3
import Testing
@testable import TokenjarCore

struct SQLiteUsageStoreTests {
    let temp = TemporaryDirectory()
    let now = Date(timeIntervalSince1970: 1_791_660_000)
    let allVersions = SQLiteUsageStore.migrations.indices.map { String($0 + 1) }

    @Test func createsAPrivateWALDatabaseInAMissingDirectory() throws {
        let url = temp.url.appending(path: "nested/tokenjar.sqlite")
        _ = try SQLiteUsageStore(url: url)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try query(url, "PRAGMA journal_mode") == ["wal"])
        #expect(try query(url, "SELECT version FROM schema_version") == allVersions)
    }

    /// A dev probe may have created the support folder first, with the default 0755.
    @Test func tightensAFolderAnotherWriterCreatedFirst() throws {
        let folder = temp.url.appending(path: "Tokenjar")
        try makeWorldReadableDirectory(folder)

        _ = try SQLiteUsageStore(url: folder.appending(path: "tokenjar.sqlite"))

        #expect(try posixMode(folder) == 0o700)
    }

    @Test func migratesAnEmptyFile() throws {
        let url = temp.url.appending(path: "tokenjar.sqlite")
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
        let url = temp.url.appending(path: "tokenjar.sqlite")
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
        #expect(try query(url, "SELECT version FROM schema_version") == allVersions)
    }

    @Test func refusesASchemaNewerThanThisBuild() throws {
        let url = temp.url.appending(path: "tokenjar.sqlite")
        _ = try SQLiteUsageStore(url: url)
        _ = try query(url, "INSERT INTO schema_version (version) VALUES (99)")

        #expect(throws: SQLiteError.self) { try SQLiteUsageStore(url: url) }
    }

    /// An idle window repeats the same numbers on every refresh. One sample an hour keeps its line unbroken (the
    /// dashboard splits lines at a 2-hour gap) without a row every 10 minutes.
    @Test func skipsARepeatedSampleWithinAnHour() throws {
        let store = try StoreKind.sqlite.make(in: temp.url)
        let reset = now.addingTimeInterval(86_400)
        func record(_ minutes: TimeInterval, _ used: Double, _ resetsAt: Date?) throws {
            try store.record(UsageSnapshot(
                accountID: "acct", provider: .claude, windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: used, resetsAt: resetsAt)],
                fetchedAt: now.addingTimeInterval(minutes * 60), source: "test"
            ))
        }
        try record(0, 40, reset)
        try record(10, 40, reset)       // repeat 10 minutes later: skipped
        try record(59, 40, reset)       // still within the hour of the kept sample at 0: skipped
        try record(61, 40, reset)       // 61 minutes after the kept sample: kept
        try record(62, 41, reset)       // value changed: kept
        try record(63, 41, reset.addingTimeInterval(60)) // reset moved: kept
        try record(64, 41, nil)         // reset dropped: kept
        try record(70, 41, nil)         // repeat of a nil reset within the hour: skipped

        let minutes = try store.samples(accountID: "acct", windowID: "weekly", since: .distantPast).map { $0.timestamp.timeIntervalSince(now) / 60 }
        #expect(minutes == [0, 61, 62, 63, 64])
        #expect(try store.latestSnapshots().first?.fetchedAt == now.addingTimeInterval(70 * 60))
    }

    /// A flat run that ends in a change keeps its last skipped repeat, so a chart draws flat-then-jump instead of a ramp
    /// from the run's first sample to the change.
    @Test func aFlatRunKeepsItsLastRepeatBeforeAChange() throws {
        let store = try StoreKind.sqlite.make(in: temp.url)
        let reset = now.addingTimeInterval(86_400)
        func record(_ minutes: TimeInterval, _ used: Double) throws -> Bool {
            try store.record(UsageSnapshot(
                accountID: "acct", provider: .claude, windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: used, resetsAt: reset)],
                fetchedAt: now.addingTimeInterval(minutes * 60), source: "test"
            ))
        }
        #expect(try record(0, 40))
        #expect(try !record(10, 40))
        #expect(try !record(40, 40))
        #expect(try record(50, 55))
        #expect(try !record(60, 55))

        let samples = try store.samples(accountID: "acct", windowID: "weekly", since: .distantPast)
        #expect(samples.map { $0.timestamp.timeIntervalSince(now) / 60 } == [0, 40, 50])
        #expect(samples.map(\.usedPercent) == [40, 40, 55])
    }

    /// Claude's cache reports the time it was written, which can be older than the last live check. The repeat held
    /// from that check is not written after the older change, where it would draw the old value again.
    @Test func aChangeOlderThanTheHeldRepeatDropsIt() throws {
        let store = try StoreKind.sqlite.make(in: temp.url)
        let reset = now.addingTimeInterval(86_400)
        func record(_ minutes: TimeInterval, _ used: Double) throws {
            try store.record(UsageSnapshot(
                accountID: "acct", provider: .claude, windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: used, resetsAt: reset)],
                fetchedAt: now.addingTimeInterval(minutes * 60), source: "test"
            ))
        }
        try record(0, 40)
        try record(30, 40)
        try record(20, 55)

        let samples = try store.samples(accountID: "acct", windowID: "weekly", since: .distantPast)
        #expect(samples.map { $0.timestamp.timeIntervalSince(now) / 60 } == [0, 20])
    }

    /// OpenCode Go reports an idle window as not started, with a reset time of now plus the window. That time moves on
    /// every refresh and says nothing, so only the used % counts.
    @Test func skipsARepeatedNotStartedWindowWhoseResetTimeMoved() throws {
        let store = try StoreKind.sqlite.make(in: temp.url)
        func record(_ minutes: TimeInterval) throws {
            let at = now.addingTimeInterval(minutes * 60)
            try store.record(UsageSnapshot(
                accountID: "go", provider: .opencodeGo,
                windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 0, windowMinutes: 300, resetsAt: at.addingTimeInterval(5 * 3600), notStarted: true)],
                fetchedAt: at, source: "test"
            ))
        }
        for minutes in [0.0, 10, 20, 61] { try record(minutes) }

        let minutes = try store.samples(accountID: "go", windowID: "session", since: .distantPast).map { $0.timestamp.timeIntervalSince(now) / 60 }
        #expect(minutes == [0, 61])
    }

    /// The repeat check compares with the same window's last sample, never another window's with equal values.
    @Test func windowsWithIdenticalValuesEachKeepTheirSample() throws {
        let store = try StoreKind.sqlite.make(in: temp.url)
        let reset = now.addingTimeInterval(86_400)
        try store.record(UsageSnapshot(
            accountID: "acct", provider: .claude,
            windows: [
                UsageWindow(id: "weekly:Fable", label: "Fable", usedPercent: 0, resetsAt: reset),
                UsageWindow(id: "weekly:Opus", label: "Opus", usedPercent: 0, resetsAt: reset),
            ],
            fetchedAt: now, source: "test"
        ))

        #expect(try store.samples(accountID: "acct", windowID: nil, since: .distantPast).map(\.windowID) == ["weekly:Fable", "weekly:Opus"])
    }

    /// The local-day function remembers the last day it computed. Events every 37 minutes through both US clock changes
    /// of 2026 must land on the same days `Calendar.startOfDay` gives each one.
    @Test func localDaysMatchStartOfDayAcrossClockChanges() throws {
        let newYork = fixedCalendar("America/New_York")
        let store = try StoreKind.sqlite.make(in: temp.url, calendar: newYork)
        var events: [UsageEvent] = []
        for (month, day) in [(3, 6), (10, 30)] {
            let start = newYork.date(from: DateComponents(year: 2026, month: month, day: day))!
            for step in 0..<(5 * 24 * 60 / 37) {
                events.append(usageEvent("\(month)-\(step)", at: start.addingTimeInterval(Double(step) * 37 * 60), input: step + 1))
            }
        }
        try store.upsert(events)

        let expected = Dictionary(grouping: events) { newYork.startOfDay(for: $0.timestamp) }
            .map { (day: $0.key, requests: $0.value.count, input: $0.value.map(\.inputTokens).reduce(0, +)) }
            .sorted { $0.day < $1.day }
        let rows = try store.dailyUsage(accountIDs: nil, since: .distantPast)
        #expect(rows.map(\.day) == expected.map(\.day))
        #expect(rows.map(\.requests) == expected.map(\.requests))
        #expect(rows.map(\.inputTokens) == expected.map(\.input))
    }

    /// A first scan stores tens of thousands of events. Each chunk commits and lets go of the store, so a samples read
    /// from the main thread waits for one chunk, not the whole scan.
    @Test func largeUpsertsCommitInChunks() throws {
        let store = try SQLiteUsageStore(url: temp.url.appending(path: "tokenjar.sqlite"))
        let events = (0..<5_000).map { usageEvent("k\($0)", at: now.addingTimeInterval(Double($0)), input: 1) }
        let before = store.commits

        try store.upsert(events)

        #expect(store.commits - before == 3)
        try store.upsert(events.map { usageEvent($0.dedupeKey, at: $0.timestamp, input: 2) })
        let rows = try store.dailyUsage(accountIDs: nil, since: .distantPast)
        #expect(rows.map(\.requests).reduce(0, +) == 5_000)
        #expect(rows.map(\.inputTokens).reduce(0, +) == 10_000)
    }

    /// The popover reads one window's samples on every render, so that read must walk the index in order.
    @Test func oneWindowsSamplesAreReadInIndexOrder() throws {
        let url = temp.url.appending(path: "tokenjar.sqlite")
        _ = try SQLiteUsageStore(url: url)

        let plan = try query(url, "EXPLAIN QUERY PLAN " + SQLiteUsageStore.windowSamplesSQL, column: 3)
        #expect(plan.contains { $0.contains("(account_id=? AND window_id=? AND ts>?)") }, "\(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    }

    @Test func prunesSamplesOlderThanTheRetention() throws {
        let store = try StoreKind.sqlite.make(in: temp.url)
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
        let store = try SQLiteUsageStore(url: temp.url.appending(path: "tokenjar.sqlite"))
        let start = now
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<50 {
                        try? store.upsert([usageEvent("w\(worker)-\(i)", at: start, input: 1)])
                        _ = try? store.record(UsageSnapshot(accountID: "w\(worker)", provider: .claude, fetchedAt: start, source: "test"))
                    }
                }
            }
        }

        #expect(try store.dailyUsage(accountIDs: nil, since: .distantPast).map(\.requests).reduce(0, +) == 400)
        #expect(try store.latestSnapshots().count == 8)
    }

    /// The app and a dev command can open the same database for the first time at the same moment.
    @Test func concurrentFirstOpensShareOneDatabase() async throws {
        let start = now
        for round in 0..<20 {
            let url = temp.url.appending(path: "\(round)/tokenjar.sqlite")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for opener in 0..<2 {
                    group.addTask { try SQLiteUsageStore(url: url).upsert([usageEvent("\(opener)", at: start, input: 1)]) }
                }
                try await group.waitForAll()
            }
            #expect(try query(url, "SELECT count(*) FROM usage_events") == ["2"])
            #expect(try query(url, "SELECT version FROM schema_version") == allVersions)
        }
    }

    /// SQLite skips the busy timeout when switching a new file to WAL collides with another writer.
    @Test func firstOpenWaitsForAnotherWriterOnTheNewFile() async throws {
        let url = temp.url.appending(path: "tokenjar.sqlite")
        let other = try OtherConnection(url)
        try other.exec("BEGIN IMMEDIATE")
        let opening = Task.detached { try SQLiteUsageStore(url: url) }
        try await Task.sleep(for: .milliseconds(200))
        try other.exec("COMMIT")

        _ = try await opening.value
        #expect(try query(url, "PRAGMA journal_mode") == ["wal"])
    }

    @Test func skipsMigrationsAnotherOpenerAppliedWhileThisOneWaited() async throws {
        let url = temp.url.appending(path: "tokenjar.sqlite")
        let other = try OtherConnection(url)
        try other.exec("PRAGMA journal_mode = WAL; CREATE TABLE schema_version (version INTEGER NOT NULL); BEGIN IMMEDIATE")
        let opening = Task.detached { try SQLiteUsageStore(url: url) }
        try await Task.sleep(for: .milliseconds(200))
        try other.exec(SQLiteUsageStore.migrations[0] + "; INSERT INTO schema_version (version) VALUES (1); COMMIT")

        _ = try await opening.value
        #expect(try query(url, "SELECT version FROM schema_version") == allVersions)
    }

    /// Reads the database through its own connection, so assertions do not depend on the store's code paths.
    private func query(_ url: URL, _ sql: String, column: Int32 = 0) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw SQLiteError(code: SQLITE_CANTOPEN, message: "open") }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteError(code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
        }
        return out
    }
}

/// Stands in for another process, holding locks the store has to wait for.
private final class OtherConnection {
    private var db: OpaquePointer?

    init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "open")
        }
    }

    deinit { sqlite3_close_v2(db) }

    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
    }
}
