import Foundation

/// Finds provider CLIs without a login shell. A menu bar app launched by launchd does not inherit the
/// user's shell PATH, and sourcing their shell rc files would run arbitrary user code on every refresh.
public struct CLILocator: Sendable {
    public var home: URL
    /// Per-CLI overrides from config (`cliPaths`), checked first.
    public var overrides: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, overrides: [String: String] = [:]) {
        self.home = home
        self.overrides = overrides
    }

    public var searchDirectories: [URL] {
        [
            home.appending(path: ".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appending(path: ".opencode/bin"),
            home.appending(path: ".bun/bin"),
            home.appending(path: ".npm-global/bin"),
            home.appending(path: ".volta/bin"),
            URL(fileURLWithPath: "/usr/bin"),
        ]
    }

    public func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        if let override = overrides[name] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        return searchDirectories
            .map { $0.appending(path: name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Environment for spawned CLIs: a PATH covering the search directories plus HOME, USER, LANG.
    /// Callers add provider variables (CLAUDE_CONFIG_DIR, CODEX_HOME) on top.
    public func baseEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] {
            if let value = inherited[key] { env[key] = value }
        }
        env["HOME"] = home.path
        env["PATH"] = (searchDirectories.map(\.path) + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }
}
