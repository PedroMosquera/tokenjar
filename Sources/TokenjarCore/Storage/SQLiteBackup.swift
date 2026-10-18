import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Consistent copies of a database another process may be writing, for tools that must leave it untouched.
public enum SQLiteBackup {
    /// Copies `source` into a new database at `destination` with SQLite's online backup API. Never writes to `source`,
    /// its -wal and -shm files or its folder. Throws when `source` cannot be read that way.
    public static func copy(_ source: URL, to destination: URL) throws {
        do {
            // A plain read-only open still writes the -shm file: it rebuilds the wal-index there when no other
            // connection has it open. readonly_shm maps it read-only and SQLite reads the -wal file itself instead.
            try backup(uri: uri(source, query: "mode=ro&readonly_shm=1"), to: destination)
        } catch let error as SQLiteError {
            // Without a -shm file nothing has the database open in WAL mode, so with nothing in the -wal file the
            // main file holds every committed row and can be read as a file that does not change.
            guard !FileManager.default.fileExists(atPath: source.path + "-shm"), walIsEmpty(source) else { throw error }
            try? FileManager.default.removeItem(at: destination)
            try backup(uri: uri(source, query: "immutable=1"), to: destination)
        }
    }

    private static func uri(_ file: URL, query: String) -> String {
        var components = URLComponents()
        components.scheme = "file"
        components.path = file.path
        components.query = query
        return components.string ?? ""
    }

    private static func walIsEmpty(_ database: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: database.path + "-wal"))?[.size] as? Int
        return (size ?? 0) == 0
    }

    private static func backup(uri: String, to destination: URL) throws {
        var source: OpaquePointer?
        defer { sqlite3_close_v2(source) }
        var rc = sqlite3_open_v2(uri, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let source else { throw SQLiteError(code: rc, message: "cannot open the source database") }
        var target: OpaquePointer?
        defer { sqlite3_close_v2(target) }
        rc = sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let target else { throw SQLiteError(code: rc, message: "cannot create the copy") }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw SQLiteError(code: sqlite3_errcode(target), message: String(cString: sqlite3_errmsg(target)))
        }
        // One step copies every page inside a single read transaction, so the copy is one committed state.
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw SQLiteError(code: step == SQLITE_DONE ? finish : step, message: String(cString: sqlite3_errmsg(target)))
        }
    }
}
