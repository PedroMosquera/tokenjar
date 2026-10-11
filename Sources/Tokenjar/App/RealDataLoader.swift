import Foundation
import TokenjarCore

/// This Mac's settings and stored history for `--render-windows --real-data`, read next to the running app without
/// writing to anything it owns: config.json through `ConfigStore.load` only, and the database through a copy made in
/// `scratch` with SQLite's online backup. Nothing is fetched, scanned, saved or asked of macOS or the Keychain.
struct RealDataLoader {
    var paths: AppPaths
    /// A folder of the caller's own; the copy of the history lives here until the caller deletes it.
    var scratch: URL

    struct Loaded {
        var model: AppModel
        /// What could not be read, for the console. The model still loads with what could.
        var warnings: [String]
    }

    func load(now: Date = Date()) -> Loaded {
        var warnings: [String] = []
        let model = AppModel(paths: paths)
        model.now = now
        model.popoverNow = now
        model.secrets = SessionSecretStore(InMemorySecretStore())
        // .unavailable is what a build outside an app bundle reports; asking SMAppService is off limits here.
        model.launchAtLoginState = { .unavailable }

        var store: any UsageStore = InMemoryUsageStore()
        if FileManager.default.fileExists(atPath: paths.databaseFile.path) {
            do {
                try AppPaths.createOwnerOnlyDirectory(scratch)
                let copy = scratch.appending(path: "tokenjar.sqlite")
                try SQLiteBackup.copy(paths.databaseFile, to: copy)
                store = try SQLiteUsageStore(url: copy)
            } catch {
                warnings.append("History not loaded: could not copy \(paths.databaseFile.path) (\(error)).")
            }
        } else {
            warnings.append("History not loaded: no database at \(paths.databaseFile.path).")
        }
        model.loadReadOnly(store: store)
        if let problem = model.configError { warnings.append(problem) }
        // The app's own "Updated" time is not stored; the newest snapshot is the last time anything was fetched.
        model.lastRefreshAt = model.statuses.values.compactMap(\.snapshot?.fetchedAt).max()
        return Loaded(model: model, warnings: warnings)
    }
}
