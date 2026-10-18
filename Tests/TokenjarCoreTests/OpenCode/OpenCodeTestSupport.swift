import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
@testable import TokenjarCore

enum OpenCodeFixtures {
    static func data(_ name: String) throws -> Data {
        try fixture("OpenCode/\(name)")
    }
}

final class OpenCodeFakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: HTTPResponse
    private var sent: [URLRequest] = []

    init(_ response: HTTPResponse) { self.response = response }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { sent.append(request) }
        return response
    }
}

/// Builds an opencode-shaped database with the schemas of opencode 1.18.35. Every string is a placeholder.
final class OpenCodeFixtureDatabase {
    private var handle: OpaquePointer?

    init(at url: URL, wal: Bool = false) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw ReadOnlySQLiteError.open(-1) }
        if wal { try exec("PRAGMA journal_mode = WAL") }
    }

    deinit { close() }

    /// Apple's SQLite keeps an empty -wal file after the last close; turning that off leaves no sidecars behind.
    func close() {
        guard let handle else { return }
        var persist: Int32 = 0
        sqlite3_file_control(handle, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
        sqlite3_close(handle)
        self.handle = nil
    }

    func exec(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw ReadOnlySQLiteError.query(status) }
    }

    func createV1Tables() throws {
        try exec("""
            CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL);
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL,
                                  time_updated integer NOT NULL, data text NOT NULL);
            CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
                               time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            """)
    }

    func createV2Tables() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS session (id text PRIMARY KEY, directory text NOT NULL);
            CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
                                          time_created integer NOT NULL, time_updated integer NOT NULL,
                                          data text NOT NULL, seq integer NOT NULL);
            """)
    }

    func insertSession(_ id: String, directory: String) throws {
        try exec("INSERT INTO session (id, directory) VALUES ('\(id)', '\(directory)')")
    }

    /// `cost` is spliced into the JSON as written, so "0" stays a JSON integer and "0.25" a float.
    func insertV1(
        id: String, role: String = "assistant", provider: String, model: String = "glm-5.2", cost: String = "0.25",
        input: Int = 100, output: Int = 50, reasoning: Int = 7, cacheRead: Int = 1_000, cacheWrite: Int = 20,
        cwd: String = "/work/alpha", created: Int64, updated: Int64? = nil
    ) throws {
        let data = """
            {"role":"\(role)","providerID":"\(provider)","modelID":"\(model)","cost":\(cost),\
            "tokens":{"total":0,"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}},\
            "time":{"created":\(created)},"path":{"cwd":"\(cwd)","root":"\(cwd)"}}
            """
        try exec("""
            INSERT INTO message (id, session_id, time_created, time_updated, data)
            VALUES ('\(id)', 'ses_1', \(created), \(updated ?? created), '\(data)')
            """)
    }

    func updateV1(id: String, cost: String, updated: Int64) throws {
        try exec("UPDATE message SET time_updated = \(updated), data = json_set(data, '$.cost', json('\(cost)')) WHERE id = '\(id)'")
    }

    func insertV2(
        id: String, type: String = "assistant", session: String = "ses_1", provider: String, model: String = "glm-5.2",
        cost: String = "0.25", input: Int = 100, output: Int = 50, created: Int64, seq: Int
    ) throws {
        let data = """
            {"type":"\(type)","agent":"build","model":{"id":"\(model)","providerID":"\(provider)"},"content":[],"cost":\(cost),\
            "tokens":{"input":\(input),"output":\(output),"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":\(created)}}
            """
        try exec("""
            INSERT INTO session_message (id, session_id, type, time_created, time_updated, data, seq)
            VALUES ('\(id)', '\(session)', '\(type)', \(created), \(created), '\(data)', \(seq))
            """)
    }
}
