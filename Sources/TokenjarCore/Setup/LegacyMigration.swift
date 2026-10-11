import Foundation

/// The one-time move of what the app kept as Headroom, its old name, into Tokenjar's folders. Runs at launch before the
/// config or the database is opened. Never touches the Keychain (hard rule 2): keys pasted under Headroom's service stay
/// there and are pasted again.
public enum LegacyMigration {
    public static let legacyBundleIdentifier = "com.pedromosquera.headroom"

    public enum Event: Equatable, Sendable {
        case skippedWhileLegacyAppRuns
        case movedSupportFolder
        case renamedDatabase
        case movedConfigFolder
        /// A step that did not happen, with a reason that names no path. The other steps still run.
        case failed(String)
    }

    /// Moves each Headroom folder whose Tokenjar folder does not exist yet, then gives the database the moved support
    /// folder brought along its new name. Changes nothing while the old app runs, since it holds that database open.
    /// Never throws, so a failure cannot stop the launch.
    public static func run(paths: AppPaths, legacyAppIsRunning: Bool) -> [Event] {
        guard !legacyAppIsRunning else { return [.skippedWhileLegacyAppRuns] }
        var events: [Event] = []
        // Each old folder is the new one's sibling, so XDG_CONFIG_HOME applies to both and a move never leaves the volume.
        let support = paths.supportDirectory
        let oldSupport = support.deletingLastPathComponent().appending(path: "Headroom")
        if exists(oldSupport) { removeIfOnlyAnEmptyProbeFolder(support) }
        if move(oldSupport, to: support, events: &events) {
            events.append(.movedSupportFolder)
        }
        renameDatabase(to: paths.databaseFile, events: &events)
        let config = paths.configDirectory
        if move(config.deletingLastPathComponent().appending(path: "headroom"), to: config, events: &events) {
            events.append(.movedConfigFolder)
        }
        return events
    }

    /// A rename, so a folder that is itself a stow link moves as the link, and relative links inside keep resolving
    /// because the depth does not change.
    private static func move(_ old: URL, to new: URL, events: inout [Event]) -> Bool {
        guard exists(old), !exists(new) else { return false }
        do {
            try FileManager.default.moveItem(at: old, to: new)
            return true
        } catch {
            events.append(.failed("could not move \(old.lastPathComponent) to \(new.lastPathComponent): \(code(error))"))
            return false
        }
    }

    /// `--probe` before the first launch creates the support folder with an empty probe folder in it, which would keep
    /// Headroom's from moving. rmdir(2) removes only an empty folder, never a file or a link, so nothing else can go.
    private static func removeIfOnlyAnEmptyProbeFolder(_ support: URL) {
        guard (try? FileManager.default.contentsOfDirectory(atPath: support.path)) == ["probe"] else { return }
        if rmdir(support.appending(path: "probe").path) == 0 { _ = rmdir(support.path) }
    }

    /// SQLite pairs a database with its -wal by name, and the -wal can hold transactions not yet in the database, so the
    /// files are renamed as a set and a rename that cannot finish puts back the ones already done.
    private static func renameDatabase(to database: URL, events: inout [Event]) {
        let folder = database.deletingLastPathComponent()
        let renames = ["", "-wal", "-shm"].map { (folder.appending(path: "headroom.sqlite\($0)"), folder.appending(path: "\(database.lastPathComponent)\($0)")) }
        guard exists(renames[0].0), !renames.contains(where: { exists($0.1) }) else { return }
        var done: [(URL, URL)] = []
        for (old, new) in renames where exists(old) {
            do {
                try FileManager.default.moveItem(at: old, to: new)
                done.append((old, new))
            } catch {
                for (old, new) in done.reversed() { try? FileManager.default.moveItem(at: new, to: old) }
                events.append(.failed("could not rename the database files: \(code(error))"))
                return
            }
        }
        events.append(.renamedDatabase)
    }

    /// lstat, so a link whose target is gone still counts: a dangling stow link is the user's, not free space.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Error descriptions carry the full path, which would put the home folder in the log.
    private static func code(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
