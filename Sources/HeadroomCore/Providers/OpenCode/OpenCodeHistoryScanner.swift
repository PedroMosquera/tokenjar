import Foundation

/// Reads assistant usage from opencode's own SQLite database, read-only. Selects only ids, numbers, model ids
/// and the working directory (reduced to its last path component); message text lives in other fields and in
/// the `part` table, which are never queried.
public struct OpenCodeHistoryScanner: HistoryScanner {
    public let name: String
    /// opencode `providerID`s to keep, e.g. "opencode-go" or "opencode" (Zen).
    public let providerIDs: Set<String>
    let environment: [String: String]

    public init(providerIDs: Set<String>) {
        self.init(providerIDs: providerIDs, environment: ProcessInfo.processInfo.environment)
    }

    init(providerIDs: Set<String>, environment: [String: String]) {
        self.providerIDs = providerIDs
        self.environment = environment
        self.name = "opencode-db:" + providerIDs.sorted().joined(separator: ",")
    }

    func databaseFile(for account: AccountConfig, paths: AppPaths) -> URL {
        OpenCodeLocalData.databaseFile(in: OpenCodeLocalData.dataDirectory(for: account, paths: paths, environment: environment))
    }

    /// Checkpoint: the source table and the largest `time_updated` seen, keyed by the database path. opencode
    /// rewrites a message row when cost and tokens land on completion, so `time_updated` is what moves.
    /// A missing database is not an error: opencode may not be used on this Mac.
    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        let database = databaseFile(for: account, paths: paths)
        guard FileManager.default.fileExists(atPath: database.path) else { return ScanResult(events: [], checkpoints: checkpoints) }
        let db = try ReadOnlySQLite(url: database)
        guard let source = try Source.detect(in: db) else { return ScanResult(events: [], checkpoints: checkpoints) }

        let key = database.path
        let previous = Checkpoint(checkpoints[key])
        let since = previous?.table == source.table ? previous?.updatedAt ?? 0 : 0
        var latest = since
        var events: [UsageEvent] = []
        try readRows(db, source: source, updatedSince: since) { row in
            latest = max(latest, row.updatedAt)
            events.append(row.event(accountID: account.id, home: paths.home))
        }

        var out = checkpoints
        out[key] = Checkpoint(table: source.table, updatedAt: latest).description
        return ScanResult(events: events, checkpoints: out)
    }

    private enum Source {
        /// opencode 1.x: `message.data` holds role, providerID, modelID, cost, tokens and path.cwd.
        case message
        /// opencode 2.x projection: `session_message.data` holds model{id, providerID}, cost and tokens; the
        /// working directory comes from the session row.
        case sessionMessage

        var table: String {
            switch self {
            case .message: "message"
            case .sessionMessage: "session_message"
            }
        }

        /// The v2 migration copies rows into `session_message` without deleting `message`, so reading both
        /// would double count. The v1 table wins whenever it exists.
        static func detect(in db: ReadOnlySQLite) throws -> Source? {
            if try db.tableExists("message") { return .message }
            if try db.tableExists("session_message") { return .sessionMessage }
            return nil
        }
    }

    private struct Row {
        var id: String
        var createdAt: Int64
        var updatedAt: Int64
        var model: String?
        var cost: Double?
        var input: Int64
        var output: Int64
        var reasoning: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        var cwd: String?

        func event(accountID: String, home: URL) -> UsageEvent {
            UsageEvent(
                dedupeKey: "opencode:\(id)", timestamp: DateParsing.epoch(Double(createdAt)), accountID: accountID,
                harness: .opencode, model: model ?? "unknown",
                project: OpenCodeHistoryScanner.project(fromWorkingDirectory: cwd, home: home),
                inputTokens: Int(input), outputTokens: Int(output), cacheReadTokens: Int(cacheRead),
                cacheWrite5mTokens: Int(cacheWrite), reasoningTokens: Int(reasoning), reportedCostUSD: cost
            )
        }
    }

    private func readRows(_ db: ReadOnlySQLite, source: Source, updatedSince: Int64, _ handle: (Row) -> Void) throws {
        let providers = providerIDs.sorted()
        guard !providers.isEmpty else { return }
        let placeholders = providers.indices.map { "?\($0 + 2)" }.joined(separator: ", ")
        // `>=` rather than `>`: a row written later in the same millisecond as the previous scan is not lost.
        // Re-reading the boundary rows is harmless because the store upserts by dedupeKey.
        let sql = switch source {
        case .message:
            """
            SELECT id, time_created, time_updated, json_extract(data, '$.modelID'), json_extract(data, '$.cost'),
                   json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
                   json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.cache.read'),
                   json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.path.cwd')
            FROM message
            WHERE time_updated >= ?1
              AND json_extract(data, '$.role') = 'assistant'
              AND json_extract(data, '$.providerID') IN (\(placeholders))
            ORDER BY time_updated
            """
        case .sessionMessage:
            """
            SELECT m.id, m.time_created, m.time_updated, json_extract(m.data, '$.model.id'), json_extract(m.data, '$.cost'),
                   json_extract(m.data, '$.tokens.input'), json_extract(m.data, '$.tokens.output'),
                   json_extract(m.data, '$.tokens.reasoning'), json_extract(m.data, '$.tokens.cache.read'),
                   json_extract(m.data, '$.tokens.cache.write'), s.directory
            FROM session_message m LEFT JOIN session s ON s.id = m.session_id
            WHERE m.time_updated >= ?1
              AND m.type = 'assistant'
              AND json_extract(m.data, '$.model.providerID') IN (\(placeholders))
            ORDER BY m.time_updated
            """
        }
        let bindings: [ReadOnlySQLite.Value] = [.int(updatedSince)] + providers.map { .text($0) }
        try db.query(sql, bindings) { r in
            guard let id = r.text(0) else { return }
            handle(Row(
                id: id, createdAt: r.int(1), updatedAt: r.int(2), model: r.text(3), cost: r.double(4),
                input: r.int(5), output: r.int(6), reasoning: r.int(7), cacheRead: r.int(8), cacheWrite: r.int(9),
                cwd: r.text(10)
            ))
        }
    }

    /// Last path component only. The home directory itself maps to "~" so the user's account name is never stored.
    static func project(fromWorkingDirectory cwd: String?, home: URL) -> String? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        if url.path == home.standardizedFileURL.path { return "~" }
        let last = url.lastPathComponent
        return last == "/" ? nil : last
    }

    private struct Checkpoint: CustomStringConvertible {
        var table: String
        var updatedAt: Int64

        init(table: String, updatedAt: Int64) {
            self.table = table
            self.updatedAt = updatedAt
        }

        init?(_ raw: String?) {
            guard let raw, let colon = raw.lastIndex(of: ":"), let value = Int64(raw[raw.index(after: colon)...]) else { return nil }
            table = String(raw[..<colon])
            updatedAt = value
        }

        var description: String { "\(table):\(updatedAt)" }
    }
}
