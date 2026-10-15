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

    /// Checkpoints: the largest `time_updated` seen per table, keyed by `sha256Hex("<database path>#<table>")`. opencode
    /// rewrites a message row when cost and tokens land on completion, so `time_updated` is what moves.
    /// A missing database is not an error: opencode may not be used on this Mac.
    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        let database = databaseFile(for: account, paths: paths)
        guard FileManager.default.fileExists(atPath: database.path) else { return ScanResult(events: [], checkpoints: checkpoints) }
        let db = try ReadOnlySQLite(url: database)
        let tables = try Table.allCases.filter { try db.tableExists($0.rawValue) }

        var events: [UsageEvent] = []
        var out = checkpoints
        for table in tables {
            let key = sha256Hex(database.path + "#" + table.rawValue)
            let since = checkpoints[key].flatMap { Int64($0) } ?? 0
            var latest = since
            try readRows(db, table: table, skippingCopiesOfMessageRows: tables.contains(.message), updatedSince: since) { row in
                latest = max(latest, row.updatedAt)
                events.append(row.event(accountID: account.id, home: paths.home))
            }
            out[key] = String(latest)
        }
        return ScanResult(events: events, checkpoints: out)
    }

    /// opencode 1.18 keeps `session_message` next to `message` and new turns may land in either, so both are read.
    /// A `session_message` row with the id, or the session and creation time, of a `message` row is a copy and skipped.
    private enum Table: String, CaseIterable {
        /// opencode 1.x: `message.data` holds role, providerID, modelID, cost, tokens and path.cwd.
        case message
        /// opencode 2.x projection: `session_message.data` holds model{id, providerID}, cost and tokens; the
        /// working directory comes from the session row.
        case sessionMessage = "session_message"
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
                project: UsageEvent.project(fromWorkingDirectory: cwd, home: home),
                inputTokens: Int(input), outputTokens: Int(output), cacheReadTokens: Int(cacheRead),
                cacheWrite5mTokens: Int(cacheWrite), reasoningTokens: Int(reasoning), reportedCostUSD: cost
            )
        }
    }

    private func readRows(
        _ db: ReadOnlySQLite, table: Table, skippingCopiesOfMessageRows skipCopies: Bool, updatedSince: Int64,
        _ handle: (Row) -> Void
    ) throws {
        let providers = providerIDs.sorted()
        guard !providers.isEmpty else { return }
        let placeholders = providers.indices.map { "?\($0 + 2)" }.joined(separator: ", ")
        let notACopy = skipCopies ? """
            AND NOT EXISTS (SELECT 1 FROM message v1 WHERE v1.id = m.id)
              AND NOT EXISTS (SELECT 1 FROM message v1 WHERE v1.session_id = m.session_id AND v1.time_created = m.time_created)
            """ : ""
        // json_extract on one malformed row fails the whole query. CASE guarantees json_valid runs first; AND does not.
        // `>=` rather than `>`: a row written later in the same millisecond as the previous scan is not lost.
        // Re-reading the boundary rows is harmless because the store upserts by dedupeKey.
        let sql = switch table {
        case .message:
            """
            SELECT id, time_created, time_updated, json_extract(data, '$.modelID'), json_extract(data, '$.cost'),
                   json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
                   json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.cache.read'),
                   json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.path.cwd')
            FROM message
            WHERE time_updated >= ?1
              AND CASE WHEN json_valid(data)
                  THEN json_extract(data, '$.role') = 'assistant' AND json_extract(data, '$.providerID') IN (\(placeholders)) END
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
              AND CASE WHEN json_valid(m.data) THEN json_extract(m.data, '$.model.providerID') IN (\(placeholders)) END
              \(notACopy)
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
}
