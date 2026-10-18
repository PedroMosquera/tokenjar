import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

enum ReadOnlySQLiteError: Error, Equatable {
    case open(Int32)
    case query(Int32)
}

/// A read-only connection to a SQLite file that another process owns and may be writing (opencode keeps
/// its database in WAL mode). Never writes, never creates the file, never runs a migration.
final class ReadOnlySQLite {
    enum Value {
        case int(Int64)
        case text(String)
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: raw)
        }
    }

    private var handle: OpaquePointer?

    init(url: URL, busyTimeoutMilliseconds: Int32 = 2_000) throws {
        do {
            try open(url.path, flags: SQLITE_OPEN_READONLY, busyTimeout: busyTimeoutMilliseconds)
        } catch {
            close()
            // A read-only connection cannot create the -shm a WAL database needs. Without a -wal file there are
            // no uncommitted pages to miss, so treating the file as immutable is safe; with one it is not.
            guard !FileManager.default.fileExists(atPath: url.path + "-wal") else { throw error }
            try open(url.absoluteString + "?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, busyTimeout: busyTimeoutMilliseconds)
        }
    }

    deinit { close() }

    func tableExists(_ name: String) throws -> Bool {
        var found = false
        try query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [.text(name)]) { _ in found = true }
        return found
    }

    func query(_ sql: String, _ bindings: [Value] = [], row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw ReadOnlySQLiteError.query(prepared)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw ReadOnlySQLiteError.query(step) }
            try row(Row(statement: statement))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// sqlite3_open_v2 defers opening the file, so a probe query is what surfaces a missing -shm.
    private func open(_ filename: String, flags: Int32, busyTimeout: Int32) throws {
        let status = sqlite3_open_v2(filename, &handle, flags, nil)
        guard status == SQLITE_OK else { throw ReadOnlySQLiteError.open(status) }
        sqlite3_busy_timeout(handle, busyTimeout)
        try query("SELECT count(*) FROM sqlite_master") { _ in }
    }

    private func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }
}
