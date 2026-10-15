import Foundation
import TokenjarCore

/// `Tokenjar --status`: the last numbers of each enabled account as one line of JSON (`StatusReport`), for scripts such as
/// a tmux or Claude Code status line. Runs no check and writes nothing, so it is safe to call every few seconds while the
/// app runs. Handled before AppKit starts, which keeps it quick.
enum StatusCommand {
    /// The exit status, or nil when `args` do not ask for it.
    static func run(_ args: [String], paths: AppPaths, now: Date, output: (String) -> Void, errorOutput: (String) -> Void) -> Int32? {
        guard args.dropFirst().contains("--status") else { return nil }
        let config: AppConfig
        do {
            config = try ConfigStore(paths: paths).load()?.merged ?? AppConfig()
        } catch ConfigError.invalidJSON(let file, _) {
            errorOutput("Could not read \(file). Fix it, then ask again.\n")
            return 1
        } catch let error as ConfigError where error.userMessage != nil {
            errorOutput("\(error.userMessage!) Then ask again.\n")
            return 1
        } catch ConfigError.brokenLink(let file) {
            errorOutput("\(file) is missing or its link is broken.\n")
            return 1
        } catch {
            errorOutput("Could not read Tokenjar's settings.\n")
            return 1
        }
        do {
            let snapshots = try SQLiteUsageStore.latestSnapshotsReadOnly(at: paths.databaseFile)
            let json = try StatusReport.make(config: config, snapshots: snapshots, now: now).json()
            output(String(decoding: json, as: UTF8.self) + "\n")
            return 0
        } catch {
            errorOutput("Could not read Tokenjar's history.\n")
            return 1
        }
    }
}
