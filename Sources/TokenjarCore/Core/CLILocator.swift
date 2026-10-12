import Foundation

/// Finds the CLIs Tokenjar runs (claude, codex, agy, gh) without a login shell. A menu bar app launched by launchd
/// does not inherit the user's shell PATH, and sourcing their shell rc files would run arbitrary user code on every refresh.
public struct CLILocator: Sendable {
    public var home: URL
    /// Per-CLI overrides from config (`cliPaths`), checked first.
    public var overrides: [String: String]
    /// Where a CLI is looked for, in order. Also the head of every spawned CLI's PATH.
    public var searchDirectories: [URL]

    /// `searchDirectories` defaults to `standardSearchDirectories(home:)`. Tests pass their own, so a CLI installed on
    /// the Mac running them is never found.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, overrides: [String: String] = [:], searchDirectories: [URL]? = nil
    ) {
        self.home = home
        self.overrides = overrides
        self.searchDirectories = searchDirectories ?? Self.standardSearchDirectories(home: home)
    }

    public static func standardSearchDirectories(home: URL) -> [URL] {
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

    /// An override wins only when it is an executable on this Mac. config.json syncs between Macs, so an entry set on
    /// another one must not make the CLI read as missing here when the search would find it.
    public func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        if let override = overrides[name] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return searchDirectories
            .map { $0.appending(path: name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"]
    static let proxyVariables = ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"]

    /// Environment for spawned CLIs: only `inheritedVariables` and `proxyVariables` that are set in `inherited`, a PATH
    /// covering the search directories, and NO_COLOR. Nothing else passes through, so a launch environment's API keys or
    /// config dirs cannot change which login a CLI reports. Proxy values can hold credentials, so never log the result.
    /// Callers add their own on top (CLAUDE_CONFIG_DIR, CODEX_HOME, and for gh its GH_* variables and DO_NOT_TRACK).
    public func baseEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in Self.inheritedVariables + Self.proxyVariables {
            if let value = inherited[key] { env[key] = value }
        }
        env["HOME"] = home.path
        env["PATH"] = (searchDirectories.map(\.path) + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }
}
