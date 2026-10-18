import Foundation
import Testing
@testable import TokenjarCore

/// `SQLiteBackup.copy` reads the live app's database for `--render-windows --real-data`, so it must see what the app
/// committed and must not write to the database, its -wal and -shm files, or its folder.
struct SQLiteBackupTests {
    let temp = TemporaryDirectory()
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    private var live: URL { temp.url.appending(path: "live/tokenjar.sqlite") }
    private var copy: URL { temp.url.appending(path: "copy/tokenjar.sqlite") }

    private func snapshot(_ id: String) -> UsageSnapshot {
        UsageSnapshot(accountID: id, provider: .claude, windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 42)], fetchedAt: now, source: "test")
    }

    private func copiedSnapshotIDs() throws -> [String] {
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SQLiteBackup.copy(live, to: copy)
        return try SQLiteUsageStore(url: copy).latestSnapshots().map(\.accountID)
    }

    /// Rows the app committed but has not checkpointed live only in the -wal file.
    @Test func copyHoldsRowsStillInTheWALOfAnOpenWriter() throws {
        let writer = try SQLiteUsageStore(url: live)
        try writer.record(snapshot("claude-work"))

        #expect(try copiedSnapshotIDs() == ["claude-work"])
        withExtendedLifetime(writer) {}
    }

    #if canImport(Darwin)
    /// With no other connection open, a plain read-only open rebuilds the wal-index in a writable -shm file. macOS's
    /// SQLite keeps the -shm after the last connection closes; Linux's deletes it, so there is nothing to leave untouched.
    @Test func copyLeavesTheShmFileOfAClosedDatabaseUntouched() throws {
        try SQLiteUsageStore(url: live).record(snapshot("codex"))
        let shm = live.path + "-shm"
        try #require(FileManager.default.fileExists(atPath: shm))
        let before = try fileState([live.path, live.path + "-wal", shm, live.deletingLastPathComponent().path])

        #expect(try copiedSnapshotIDs() == ["codex"])
        #expect(try fileState([live.path, live.path + "-wal", shm, live.deletingLastPathComponent().path]) == before)
    }
    #endif

    // Windows ignores a folder's read-only flag, so nothing there stops SQLite writing beside the database.
    #if !os(Windows)
    @Test func copyReadsADatabaseWhoseFilesAndFolderAreReadOnly() throws {
        try SQLiteUsageStore(url: live).record(snapshot("opencode-go"))
        let folder = live.deletingLastPathComponent()
        let files = [live.path, live.path + "-wal", live.path + "-shm"].filter { FileManager.default.fileExists(atPath: $0) }
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let before = try fileState(files + [folder.path])

        #expect(try copiedSnapshotIDs() == ["opencode-go"])
        #expect(try fileState(files + [folder.path]) == before)
    }
    #endif

    // Windows ignores a folder's read-only flag, so nothing there stops SQLite writing beside the database.
    #if !os(Windows)
    /// A SQLite build without persistent WAL deletes the -shm file on close, and a folder it cannot write in stops
    /// SQLite from making a new one.
    @Test func copyReadsAClosedDatabaseWithoutAShmFileInAReadOnlyFolder() throws {
        try SQLiteUsageStore(url: live).record(snapshot("antigravity"))
        let folder = live.deletingLastPathComponent()
        try? FileManager.default.removeItem(atPath: live.path + "-shm")
        try? FileManager.default.removeItem(atPath: live.path + "-wal")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let before = try fileState([live.path, folder.path])

        #expect(try copiedSnapshotIDs() == ["antigravity"])
        #expect(try fileState([live.path, folder.path]) == before)
    }
    #endif

    /// Modification date and permissions, the two things a stray write or chmod would change.
    private func fileState(_ paths: [String]) throws -> [String] {
        try paths.map { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path) \(modified) \(attributes[.posixPermissions] as? Int ?? -1)"
        }
    }
}
