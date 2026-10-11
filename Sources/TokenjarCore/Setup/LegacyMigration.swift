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
        let support = paths.supportDirectory
        if exists(oldSupport(paths)), holdsOnlyAnEmptyProbeFolder(support), rmdir(support.appending(path: "probe").path) == 0 {
            _ = rmdir(support.path)
        }
        if move(oldSupport(paths), to: support, events: &events) {
            events.append(.movedSupportFolder)
        }
        renameDatabase(to: paths.databaseFile, events: &events)
        if move(oldConfig(paths), to: paths.configDirectory, events: &events) {
            events.append(.movedConfigFolder)
        }
        return events
    }

    /// Whether a later `run` would still move something: a Headroom folder whose Tokenjar name is free, or a database
    /// still under its old name. While this holds the app must not create Tokenjar's config or database, since `run`
    /// never moves onto a name that is taken.
    public static func hasDataToMove(paths: AppPaths) -> Bool {
        let support = paths.supportDirectory
        let database = databaseNames(paths.databaseFile)
        return (exists(oldSupport(paths)) && (!exists(support) || holdsOnlyAnEmptyProbeFolder(support)))
            || (exists(oldConfig(paths)) && !exists(paths.configDirectory))
            || (exists(database[0].old) && !database.contains { exists($0.new) })
    }

    // Each old folder is the new one's sibling, so XDG_CONFIG_HOME applies to both and a move never leaves the volume.
    private static func oldSupport(_ paths: AppPaths) -> URL {
        paths.supportDirectory.deletingLastPathComponent().appending(path: "Headroom")
    }

    private static func oldConfig(_ paths: AppPaths) -> URL {
        paths.configDirectory.deletingLastPathComponent().appending(path: "headroom")
    }

    /// What `--probe` leaves when it runs before the first launch. It holds nothing of the user's, so it does not keep
    /// Headroom's support folder from moving; `run` clears it with rmdir(2), which removes only an empty folder.
    private static func holdsOnlyAnEmptyProbeFolder(_ support: URL) -> Bool {
        let probe = support.appending(path: "probe")
        return (try? FileManager.default.contentsOfDirectory(atPath: support.path)) == ["probe"]
            && (try? FileManager.default.attributesOfItem(atPath: probe.path))?[.type] as? FileAttributeType == .typeDirectory
            && (try? FileManager.default.contentsOfDirectory(atPath: probe.path))?.isEmpty == true
    }

    private static func databaseNames(_ database: URL) -> [(old: URL, new: URL)] {
        let folder = database.deletingLastPathComponent()
        return ["", "-wal", "-shm"].map { (folder.appending(path: "headroom.sqlite\($0)"), folder.appending(path: "\(database.lastPathComponent)\($0)")) }
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

    /// SQLite pairs a database with its -wal by name, and the -wal can hold transactions not yet in the database, so the
    /// files are renamed as a set and a rename that cannot finish puts back the ones already done.
    private static func renameDatabase(to database: URL, events: inout [Event]) {
        let renames = databaseNames(database)
        guard exists(renames[0].old), !renames.contains(where: { exists($0.new) }) else { return }
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
