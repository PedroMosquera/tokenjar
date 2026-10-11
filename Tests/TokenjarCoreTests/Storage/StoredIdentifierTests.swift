import Foundation
import SQLite3
import Testing
@testable import TokenjarCore

/// docs/privacy.md promises that the database holds only SHA-256 digests of log paths and response ids. These tests
/// run the real scanners into a real store and read the file back through their own SQLite connection.
struct StoredIdentifierTests {
    let temp = TemporaryDirectory()

    @Test func sha256HexIsLowercaseHexOfTheUTF8Bytes() {
        #expect(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func scannedPathsAndResponseIDsAreStoredOnlyAsDigests() throws {
        let home = temp.url.appending(path: "home")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "Claude/projects"), to: home.appending(path: ".claude/projects"))
        let rollout = home.appending(path: ".codex/sessions/2026/10/09/rollout-2026-10-09T11-28-27-SESSIONUUID.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "Codex/rollout-token-count.jsonl"), to: rollout)
        let opencode = home.appending(path: ".local/share/opencode")
        try FileManager.default.createDirectory(at: opencode, withIntermediateDirectories: true)
        let db = try OpenCodeFixtureDatabase(at: opencode.appending(path: "opencode.db"))
        try db.createV1Tables()
        try db.insertV1(id: "msg_go_1", provider: "opencode-go", created: 1_791_000_000_000)
        db.close()

        let paths = AppPaths(home: home)
        let url = temp.url.appending(path: "tokenjar.sqlite")
        let store = try SQLiteUsageStore(url: url)
        let scans: [(any HistoryScanner, AccountConfig)] = [
            (ClaudeHistoryScanner(), AccountConfig(id: "claude", provider: .claude, label: "Personal")),
            (CodexHistoryScanner(), AccountConfig(id: "codex", provider: .codex, label: "Plus")),
            (OpenCodeHistoryScanner(providerIDs: ["opencode-go"], environment: [:]), AccountConfig(id: "go", provider: .opencodeGo, label: "Go")),
        ]
        func scanAll() throws -> Int {
            var events = 0
            for (scanner, account) in scans {
                let result = try scanner.scan(account, checkpoints: store.checkpoints(scanner: scanner.name, accountID: account.id), paths: paths)
                try store.upsert(result.events)
                try store.saveCheckpoints(result.checkpoints, scanner: scanner.name, accountID: account.id)
                events += result.events.count
            }
            return events
        }
        #expect(try scanAll() > 0)

        let storedPaths = try rawColumn(url, "SELECT path FROM scan_state")
        let storedKeys = try rawColumn(url, "SELECT dedupe_key FROM usage_events")
        // Two Claude transcripts, one rollout, one opencode table; five Claude responses, three Codex deltas, one opencode message.
        #expect(storedPaths.count == 4)
        #expect(storedKeys.count == 9)
        #expect(storedPaths.allSatisfy(isDigest), "\(storedPaths)")
        #expect(storedKeys.allSatisfy(isDigest), "\(storedKeys)")
        // Every column and page, not only the two above, including what is still in the write-ahead log.
        let bytes = try ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(into: Data()) { $0 += try Data(contentsOf: $1) }
        #expect(bytes.range(of: Data(home.path.utf8)) == nil, "the home folder path is stored")
        #expect(bytes.range(of: Data("SESSION_A".utf8)) == nil, "a raw session id is stored")
        // Digest keys still resume each scan where it stopped.
        #expect(try scanAll() == 1, "only opencode re-reads the row on its checkpoint boundary")
    }

    @Test func migrationRewritesIdentifiersAnEarlierBuildStoredRaw() throws {
        let url = temp.url.appending(path: "tokenjar.sqlite")
        try FileManager.default.createDirectory(at: temp.url, withIntermediateDirectories: true)
        try rawExec(url, """
            CREATE TABLE schema_version (version INTEGER NOT NULL);
            \(SQLiteUsageStore.migrations[0]);
            INSERT INTO schema_version (version) VALUES (1);
            INSERT INTO usage_events (dedupe_key, ts, account_id, harness, model, project, input, output, cache_read,
                cache_write_5m, cache_write_1h, reasoning, reported_cost)
            VALUES ('claude:msg_A:req_A', 1791660000, 'acct', 'claude-code', 'claude-opus-5-5', 'tokenjar', 5, 1, 0, 0, 0, 0, NULL);
            INSERT INTO scan_state (scanner, account_id, path, value)
            VALUES ('claude-transcripts', 'acct', '/Users/someone/.claude/projects/-Users-someone-client/SESSION.jsonl', '1:10');
            """)

        let store = try SQLiteUsageStore(url: url)

        #expect(try rawColumn(url, "SELECT dedupe_key FROM usage_events") == [sha256Hex("claude:msg_A:req_A")])
        #expect(try rawColumn(url, "SELECT path FROM scan_state").isEmpty)
        // The full rescan the dropped checkpoints cause merges into the rewritten row instead of adding a second one.
        try store.upsert([usageEvent("claude:msg_A:req_A", at: Date(timeIntervalSince1970: 1_791_660_000), input: 7)])
        #expect(try store.dailyUsage(accountIDs: nil, since: .distantPast).map(\.inputTokens) == [7])
    }

    private func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func rawExec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "open")
        }
        defer { sqlite3_close_v2(db) }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
    }

    private func rawColumn(_ url: URL, _ sql: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SQLiteError(code: SQLITE_CANTOPEN, message: "open") }
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
