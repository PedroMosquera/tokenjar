import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
#if os(Windows)
import WinSDK
#endif

public struct SQLiteError: Error, CustomStringConvertible {
    public var code: Int32
    public var message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// SQLite-backed `UsageStore`, normally at `AppPaths.databaseFile`. Same contract as `InMemoryUsageStore`, plus:
/// `record` skips a window sample identical to the previous one when it is less than `sampleDedupeInterval` newer
/// (for a not-started window only the used % counts, since its reset time is synthetic) and writes the last one it
/// skipped just before the window's next change. It deletes samples older than `sampleRetention` at most once a day.
/// Dedupe keys are stored as `sha256Hex` digests, since they carry provider message, request and session ids; nothing
/// reads them back.
///
/// `@unchecked Sendable`: the store owns one connection, and every use of it and of its mutable state holds `lock`.
public final class SQLiteUsageStore: UsageStore, @unchecked Sendable {
    public static let sampleRetention: TimeInterval = 180 * 86_400
    /// Under the dashboard's 2-hour gap, so an idle window's line stays whole.
    public static let sampleDedupeInterval: TimeInterval = 60 * 60
    static let upsertChunkSize = 2_000
    private static let busyTimeout: TimeInterval = 5

    private let connection: Connection
    private let lock = FairLock()
    private var lastPrune: Date?
    private var commitCount = 0
    /// The newest repeat `record` skipped for each window. Written before the window's next change, it makes a chart
    /// draw a flat run then a jump rather than a ramp across the run. Memory only: a relaunch loses at most one per window.
    private var skippedRepeats: [WindowKey: WindowSample] = [:]

    private struct WindowKey: Hashable {
        var accountID: String
        var windowID: String
    }

    private var db: OpaquePointer { connection.handle }

    /// Opens or creates the database (mode 0600, WAL) and applies pending migrations. Several processes may open
    /// the same path at once, including for the first time. `calendar` decides which local day an event falls on in `dailyUsage`.
    public init(url: URL, calendar: Calendar = .current) throws {
        try AppPaths.createOwnerOnlyDirectory(url.deletingLastPathComponent())
        // Windows files have no mode bits to copy, so there SQLite creates the file itself.
        #if !os(Windows)
        // SQLite creates new files 0644 and gives the -wal and -shm files the main file's mode, so create it 0600 first.
        // O_EXCL rather than FileManager.createFile, which replaces the path and so orphans a concurrent opener's file.
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        let createError = errno
        if fd >= 0 {
            close(fd)
        } else if createError != EEXIST {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot create the database file (errno \(createError))")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard let handle else { throw SQLiteError(code: rc, message: "cannot open the database") }
        connection = Connection(handle: handle)
        try check(rc)
        sqlite3_busy_timeout(db, Int32(Self.busyTimeout * 1_000))
        try enableWAL()
        try exec("PRAGMA synchronous = NORMAL")
        try registerDayFunction(calendar)
        try registerDigestFunction()
        try migrate()
    }

    // MARK: UsageStore

    @discardableResult
    public func record(_ snapshot: UsageSnapshot) throws -> Bool {
        let json = try String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)
        let ts = snapshot.fetchedAt.timeIntervalSince1970
        var stored = false
        try locked {
            var skipped = skippedRepeats
            try transaction {
                try run(
                    """
                    INSERT INTO snapshots (account_id, fetched_at, json) VALUES (?1, ?2, ?3)
                    ON CONFLICT(account_id) DO UPDATE SET fetched_at = excluded.fetched_at, json = excluded.json
                    """,
                    [.text(snapshot.accountID), .real(ts), .text(json)]
                )
                let previous = try prepare(
                    "SELECT ts, used_percent, resets_at FROM window_samples WHERE account_id = ?1 AND window_id = ?2 ORDER BY ts DESC, rowid DESC LIMIT 1"
                )
                let insert = try prepare("INSERT INTO window_samples (account_id, window_id, ts, used_percent, resets_at) VALUES (?1, ?2, ?3, ?4, ?5)")
                func insertSample(_ sample: WindowSample) throws {
                    try insert.bind([
                        .text(sample.accountID), .text(sample.windowID), .real(sample.timestamp.timeIntervalSince1970), .real(sample.usedPercent),
                        sample.resetsAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    ])
                    try insert.run()
                }
                for window in snapshot.windows {
                    let sample = WindowSample(
                        accountID: snapshot.accountID, windowID: window.id, timestamp: snapshot.fetchedAt,
                        usedPercent: window.usedPercent, resetsAt: window.resetsAt
                    )
                    let key = WindowKey(accountID: snapshot.accountID, windowID: window.id)
                    var changed = true
                    try previous.bind([.text(snapshot.accountID), .text(window.id)])
                    if try previous.step() {
                        changed = previous.double(1) != window.usedPercent
                            || (!window.notStarted && previous.optionalDouble(2) != window.resetsAt?.timeIntervalSince1970)
                        let isRecent = ts - previous.double(0) < Self.sampleDedupeInterval
                        previous.reset()
                        if !changed, isRecent {
                            skipped[key] = sample
                            continue
                        }
                    }
                    // A repeat stored for its age already marks the run. A snapshot read from Claude's cache or a Codex
                    // session log carries the time it was written, which can be older than the held repeat.
                    if let held = skipped.removeValue(forKey: key), changed, held.timestamp < sample.timestamp {
                        try insertSample(held)
                    }
                    try insertSample(sample)
                    stored = true
                }
                if lastPrune.map({ snapshot.fetchedAt.timeIntervalSince($0) > 86_400 }) ?? true {
                    try run("DELETE FROM window_samples WHERE ts < ?1", [.real(ts - Self.sampleRetention)])
                    lastPrune = snapshot.fetchedAt
                }
            }
            skippedRepeats = skipped
        }
        return stored
    }

    /// Transactions committed since the store opened, for tests.
    var commits: Int { locked { commitCount } }

    /// Commits every `upsertChunkSize` events and lets go of the lock in between, so a first scan's tens of thousands of
    /// events never hold off a read from the main thread for long. A failed chunk leaves the earlier ones stored; the
    /// caller keeps its checkpoints, and the rescan merges into them.
    public func upsert(_ events: [UsageEvent]) throws {
        for start in stride(from: 0, to: events.count, by: Self.upsertChunkSize) {
            try upsertChunk(events[start..<min(start + Self.upsertChunkSize, events.count)])
        }
    }

    private func upsertChunk(_ events: ArraySlice<UsageEvent>) throws {
        try locked {
            try transaction {
                // A NULL incoming cost keeps the stored one; otherwise keep the larger, a stored NULL counting as 0.
                let statement = try prepare(
                    """
                    INSERT INTO usage_events (
                        dedupe_key, ts, account_id, harness, model, project,
                        input, output, cache_read, cache_write_5m, cache_write_1h, reasoning, web_search_requests, reported_cost
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                    ON CONFLICT(dedupe_key) DO UPDATE SET
                        input = max(input, excluded.input),
                        output = max(output, excluded.output),
                        cache_read = max(cache_read, excluded.cache_read),
                        cache_write_5m = max(cache_write_5m, excluded.cache_write_5m),
                        cache_write_1h = max(cache_write_1h, excluded.cache_write_1h),
                        reasoning = max(reasoning, excluded.reasoning),
                        web_search_requests = max(web_search_requests, excluded.web_search_requests),
                        reported_cost = CASE
                            WHEN excluded.reported_cost IS NULL THEN reported_cost
                            ELSE max(coalesce(reported_cost, 0), excluded.reported_cost)
                        END
                    """
                )
                for e in events {
                    try statement.bind([
                        .text(sha256Hex(e.dedupeKey)), .real(e.timestamp.timeIntervalSince1970), .text(e.accountID), .text(e.harness.rawValue),
                        .text(e.model), e.project.map(SQLValue.text) ?? .null,
                        .int(e.inputTokens), .int(e.outputTokens), .int(e.cacheReadTokens), .int(e.cacheWrite5mTokens),
                        .int(e.cacheWrite1hTokens), .int(e.reasoningTokens), .int(e.webSearchRequests), e.reportedCostUSD.map(SQLValue.real) ?? .null,
                    ])
                    try statement.run()
                }
            }
        }
    }

    public func checkpoints(scanner: String, accountID: String) throws -> ScanCheckpoints {
        try locked {
            let statement = try prepare("SELECT path, value FROM scan_state WHERE scanner = ?1 AND account_id = ?2")
            try statement.bind([.text(scanner), .text(accountID)])
            var out: ScanCheckpoints = [:]
            while try statement.step() {
                out[statement.text(0)] = statement.text(1)
            }
            return out
        }
    }

    public func saveCheckpoints(_ checkpoints: ScanCheckpoints, scanner: String, accountID: String) throws {
        try locked {
            try transaction {
                try run("DELETE FROM scan_state WHERE scanner = ?1 AND account_id = ?2", [.text(scanner), .text(accountID)])
                let insert = try prepare("INSERT INTO scan_state (scanner, account_id, path, value) VALUES (?1, ?2, ?3, ?4)")
                for (path, value) in checkpoints {
                    try insert.bind([.text(scanner), .text(accountID), .text(path), .text(value)])
                    try insert.run()
                }
            }
        }
    }

    /// Two statements rather than `(?2 IS NULL OR window_id = ?2)`: SQLite plans that form once for both cases, so one
    /// window's read scanned every sample of the account and then sorted the matches.
    static let windowSamplesSQL = """
        SELECT window_id, ts, used_percent, resets_at FROM window_samples
        WHERE account_id = ?1 AND window_id = ?2 AND ts >= ?3
        ORDER BY ts, rowid
        """
    static let accountSamplesSQL = """
        SELECT window_id, ts, used_percent, resets_at FROM window_samples
        WHERE account_id = ?1 AND ts >= ?2
        ORDER BY ts, rowid
        """

    public func samples(accountID: String, windowID: String?, since: Date) throws -> [WindowSample] {
        try locked {
            let statement: Statement
            if let windowID {
                statement = try prepare(Self.windowSamplesSQL)
                try statement.bind([.text(accountID), .text(windowID), .real(since.timeIntervalSince1970)])
            } else {
                statement = try prepare(Self.accountSamplesSQL)
                try statement.bind([.text(accountID), .real(since.timeIntervalSince1970)])
            }
            var out: [WindowSample] = []
            while try statement.step() {
                out.append(WindowSample(
                    accountID: accountID, windowID: statement.text(0), timestamp: Date(timeIntervalSince1970: statement.double(1)),
                    usedPercent: statement.double(2), resetsAt: statement.optionalDouble(3).map(Date.init(timeIntervalSince1970:))
                ))
            }
            return out
        }
    }

    public func dailyUsage(accountIDs: [String]?, since: Date) throws -> [DailyUsageRow] {
        try usageRows(accountIDs: accountIDs, since: since, before: nil)
    }

    public func usage(accountIDs: [String]?, in interval: DateInterval) throws -> [DailyUsageRow] {
        try usageRows(accountIDs: accountIDs, since: interval.start, before: interval.end)
    }

    /// Rows per local day without `end`; with it, one row per key over the whole span, its day the span's start.
    private func usageRows(accountIDs: [String]?, since: Date, before end: Date?) throws -> [DailyUsageRow] {
        let accountFilter = try accountIDs.map { SQLValue.text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null
        return try locked {
            // sum() over no non-NULL values is NULL, which is exactly a nil reportedCostUSD.
            let statement = try prepare(
                """
                SELECT \(end == nil ? "tokenjar_local_day(ts)" : "?1") AS day, account_id, harness, model, project, count(*),
                    sum(input), sum(output), sum(cache_read), sum(cache_write_5m), sum(cache_write_1h), sum(reasoning),
                    sum(reported_cost),
                    sum(CASE WHEN reported_cost IS NULL THEN input ELSE 0 END),
                    sum(CASE WHEN reported_cost IS NULL THEN output ELSE 0 END),
                    sum(CASE WHEN reported_cost IS NULL THEN cache_read ELSE 0 END),
                    sum(CASE WHEN reported_cost IS NULL THEN cache_write_5m ELSE 0 END),
                    sum(CASE WHEN reported_cost IS NULL THEN cache_write_1h ELSE 0 END),
                    sum(CASE WHEN reported_cost IS NULL THEN web_search_requests ELSE 0 END)
                FROM usage_events
                WHERE ts >= ?1 AND (?3 IS NULL OR ts < ?3) AND (?2 IS NULL OR account_id IN (SELECT value FROM json_each(?2)))
                GROUP BY day, account_id, harness, model, project
                ORDER BY day, model, account_id, harness, project
                """
            )
            try statement.bind([.real(since.timeIntervalSince1970), accountFilter, end.map { .real($0.timeIntervalSince1970) } ?? .null])
            var out: [DailyUsageRow] = []
            while try statement.step() {
                guard let harness = Harness(rawValue: statement.text(2)) else { continue }
                out.append(DailyUsageRow(
                    day: Date(timeIntervalSince1970: statement.double(0)), accountID: statement.text(1), harness: harness,
                    model: statement.text(3), project: statement.optionalText(4), requests: statement.int(5),
                    inputTokens: statement.int(6), outputTokens: statement.int(7), cacheReadTokens: statement.int(8),
                    cacheWrite5mTokens: statement.int(9), cacheWrite1hTokens: statement.int(10), reasoningTokens: statement.int(11),
                    reportedCostUSD: statement.optionalDouble(12),
                    unpricedInputTokens: statement.int(13), unpricedOutputTokens: statement.int(14), unpricedCacheReadTokens: statement.int(15),
                    unpricedCacheWrite5mTokens: statement.int(16), unpricedCacheWrite1hTokens: statement.int(17),
                    unpricedWebSearchRequests: statement.int(18)
                ))
            }
            return out
        }
    }

    /// The latest snapshots without opening the store for writing: nothing is created, migrated or locked beyond a read,
    /// so a command line can ask while the app runs. Empty when the store does not exist yet.
    public static func latestSnapshotsReadOnly(at url: URL) throws -> [UsageSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard let handle else { throw SQLiteError(code: rc, message: "cannot open the database") }
        let connection = Connection(handle: handle)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(connection.handle))) }
        sqlite3_busy_timeout(connection.handle, Int32(busyTimeout * 1_000))
        var statementHandle: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection.handle, snapshotsQuery, -1, &statementHandle, nil)
        guard prepared == SQLITE_OK, let statementHandle else {
            throw SQLiteError(code: prepared, message: String(cString: sqlite3_errmsg(connection.handle)))
        }
        let statement = Statement(handle: statementHandle, db: connection.handle)
        var rows: [String] = []
        while try statement.step() { rows.append(statement.text(0)) }
        return decodeSnapshots(rows)
    }

    public func latestSnapshots() throws -> [UsageSnapshot] {
        let rows: [String] = try locked {
            let statement = try prepare(Self.snapshotsQuery)
            var out: [String] = []
            while try statement.step() { out.append(statement.text(0)) }
            return out
        }
        return Self.decodeSnapshots(rows)
    }

    private static let snapshotsQuery = "SELECT json FROM snapshots ORDER BY account_id"

    private static func decodeSnapshots(_ rows: [String]) -> [UsageSnapshot] {
        let decoder = JSONDecoder()
        // A row written by an older build may no longer decode. It is only a last-known value, so drop it.
        return rows.compactMap { try? decoder.decode(UsageSnapshot.self, from: Data($0.utf8)) }
    }

    // MARK: Schema

    /// Entry i takes the schema from version i to i + 1. Append only; never edit an entry that has shipped.
    static let migrations: [String] = [
        """
        CREATE TABLE snapshots (
            account_id TEXT PRIMARY KEY,
            fetched_at REAL NOT NULL,
            json TEXT NOT NULL
        );
        CREATE TABLE window_samples (
            account_id TEXT NOT NULL,
            window_id TEXT NOT NULL,
            ts REAL NOT NULL,
            used_percent REAL NOT NULL,
            resets_at REAL
        );
        CREATE INDEX window_samples_account_window_ts ON window_samples (account_id, window_id, ts);
        CREATE TABLE usage_events (
            dedupe_key TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            account_id TEXT NOT NULL,
            harness TEXT NOT NULL,
            model TEXT NOT NULL,
            project TEXT,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_read INTEGER NOT NULL,
            cache_write_5m INTEGER NOT NULL,
            cache_write_1h INTEGER NOT NULL,
            reasoning INTEGER NOT NULL,
            reported_cost REAL
        );
        CREATE INDEX usage_events_ts ON usage_events (ts);
        CREATE INDEX usage_events_account_ts ON usage_events (account_id, ts);
        CREATE TABLE scan_state (
            scanner TEXT NOT NULL,
            account_id TEXT NOT NULL,
            path TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (scanner, account_id, path)
        );
        """,
        // Builds before this one stored raw dedupe keys and raw log paths. Scanners now key checkpoints by digest, so the
        // old rows could never match again; dropping them costs one full rescan, which merges into the rehashed events.
        """
        UPDATE usage_events SET dedupe_key = tokenjar_sha256(dedupe_key);
        DELETE FROM scan_state;
        """,
        // Rescanning Claude transcripts still on disk merges their web search counts into the events already stored.
        """
        ALTER TABLE usage_events ADD COLUMN web_search_requests INTEGER NOT NULL DEFAULT 0;
        DELETE FROM scan_state WHERE scanner = 'claude-transcripts';
        """,
    ]

    /// Switching a new file to WAL upgrades a read lock to a write lock, where SQLite returns SQLITE_BUSY at once instead of
    /// waiting out the busy timeout. Two first opens collide there, so the loser retries until the winner has switched the file.
    private func enableWAL() throws {
        let deadline = Date().addingTimeInterval(Self.busyTimeout)
        while true {
            let rc = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            guard rc == SQLITE_BUSY, Date() < deadline else { return try check(rc) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Reads the version under the write lock, so a second opener waits for the first to finish and then finds nothing pending.
    private func migrate() throws {
        try transaction {
            try exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
            let version = try schemaVersion()
            guard version <= Self.migrations.count else {
                throw SQLiteError(code: SQLITE_ERROR, message: "database schema \(version) is newer than this build supports (\(Self.migrations.count))")
            }
            for (index, sql) in Self.migrations.enumerated() where index >= version {
                try exec(sql)
                try run("INSERT INTO schema_version (version) VALUES (?1)", [.int(index + 1)])
            }
        }
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("SELECT coalesce(max(version), 0) FROM schema_version")
        _ = try statement.step()
        return statement.int(0)
    }

    /// `tokenjar_local_day(ts)`: local midnight per `calendar`, as unix seconds. Used instead of
    /// `date(ts, 'unixepoch', 'localtime')` so the zone is injectable and days match `Calendar.startOfDay` exactly.
    private func registerDayFunction(_ calendar: Calendar) throws {
        let rc = sqlite3_create_function_v2(
            db, "tokenjar_local_day", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            Unmanaged.passRetained(CalendarBox(calendar)).toOpaque(),
            { context, _, arguments in
                guard let context, let user = sqlite3_user_data(context), let argument = arguments?[0] else { return }
                let box = Unmanaged<CalendarBox>.fromOpaque(user).takeUnretainedValue()
                sqlite3_result_double(context, box.startOfDay(sqlite3_value_double(argument)))
            },
            nil, nil,
            // SQLite calls this when the connection closes, and also when registration fails.
            { user in if let user { Unmanaged<CalendarBox>.fromOpaque(user).release() } }
        )
        try check(rc)
    }

    /// `tokenjar_sha256(text)`: `sha256Hex`, for migrations that rewrite stored identifiers.
    private func registerDigestFunction() throws {
        let rc = sqlite3_create_function_v2(
            db, "tokenjar_sha256", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, _, arguments in
                guard let context, let argument = arguments?[0], let text = sqlite3_value_text(argument) else { return }
                sqlite3_result_text(context, sha256Hex(String(cString: text)), -1, Statement.transient)
            },
            nil, nil, nil
        )
        try check(rc)
    }

    // MARK: Plumbing

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
            commitCount += 1
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Only for SQL without values; anything carrying a value goes through `run` or `prepare` with bound parameters.
    private func exec(_ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func run(_ sql: String, _ values: [SQLValue]) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        try statement.run()
    }

    private func prepare(_ sql: String) throws -> Statement {
        var handle: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &handle, nil))
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "empty statement") }
        return Statement(handle: handle, db: db)
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
    }
}

/// A mutex that hands itself to the longest waiter. NSLock lets the thread that just unlocked take it straight back,
/// so a scan committing chunk after chunk kept a main-thread read waiting through several of them.
private final class FairLock: @unchecked Sendable {
    #if os(Windows)
    // Windows has no fair lock to ask for; an SRW lock is the light exclusive one.
    private let srw = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)

    init() { InitializeSRWLock(srw) }
    deinit { srw.deallocate() }

    func lock() { AcquireSRWLockExclusive(srw) }
    func unlock() { ReleaseSRWLockExclusive(srw) }
    #else
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init() {
        var attributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&attributes)
        #if canImport(Darwin)
        pthread_mutexattr_setpolicy_np(&attributes, PTHREAD_MUTEX_POLICY_FAIRSHARE_NP)
        #endif
        pthread_mutex_init(mutex, &attributes)
        pthread_mutexattr_destroy(&attributes)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }
    #endif
}

/// Closes the handle exactly once, including when `SQLiteUsageStore.init` throws after opening it.
private final class Connection {
    let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close_v2(handle) }
}

/// SQLite calls `tokenjar_local_day` once per row a daily query reads, mostly in time order, so the last day's bounds
/// answer nearly every call without asking the calendar. Only used under the store's lock.
private final class CalendarBox {
    let calendar: Calendar
    private var day: DateInterval?

    init(_ calendar: Calendar) { self.calendar = calendar }

    func startOfDay(_ ts: Double) -> Double {
        let date = Date(timeIntervalSince1970: ts)
        if let day, day.start <= date, date < day.end { return day.start.timeIntervalSince1970 }
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return calendar.startOfDay(for: date).timeIntervalSince1970 }
        day = interval
        return interval.start.timeIntervalSince1970
    }
}

private enum SQLValue {
    case text(String)
    case real(Double)
    case int(Int)
    case null
}

private final class Statement {
    private let handle: OpaquePointer
    private let db: OpaquePointer

    init(handle: OpaquePointer, db: OpaquePointer) {
        self.handle = handle
        self.db = db
    }

    deinit { sqlite3_finalize(handle) }

    /// Resets the statement and binds `values` to ?1, ?2, ...
    func bind(_ values: [SQLValue]) throws {
        reset()
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32 = switch value {
            case .text(let string): sqlite3_bind_text(handle, index, string, -1, Self.transient)
            case .real(let double): sqlite3_bind_double(handle, index, double)
            case .int(let int): sqlite3_bind_int64(handle, index, Int64(int))
            case .null: sqlite3_bind_null(handle, index)
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        }
    }

    /// True when a row is available, false when the statement has finished.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let rc: throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Steps a statement that returns no rows and resets it.
    func run() throws {
        _ = try step()
        reset()
    }

    func reset() { sqlite3_reset(handle) }

    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func text(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }

    func optionalDouble(_ column: Int32) -> Double? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : double(column)
    }

    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : text(column)
    }

    /// SQLITE_TRANSIENT, which the C macro cannot express in Swift: SQLite copies the bytes before the call returns.
    static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
