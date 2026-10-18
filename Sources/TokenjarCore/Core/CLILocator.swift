import Foundation

/// Finds the CLIs Tokenjar runs (claude, codex, agy, gh) without a login shell. A menu bar app launched by launchd
/// does not inherit the user's shell PATH, and sourcing their shell rc files would run arbitrary user code on every refresh.
public struct CLILocator: Sendable {
    public let home: URL
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

    #if os(Windows)
    /// The native installers' and npm's folders, then the user's PATH: a tray app started from the Run key or the Start
    /// menu inherits Explorer's environment, which already holds it, so nothing has to be sourced to find it.
    public static func standardSearchDirectories(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let value = { (key: String) in environment.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
        let appData = value("APPDATA").map { URL(fileURLWithPath: $0) } ?? home.appending(path: "AppData/Roaming")
        let programFiles = value("ProgramFiles").map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #"C:\Program Files"#)
        let path = (value("PATH") ?? "").split(separator: ";").map { URL(fileURLWithPath: String($0)) }
        return [
            home.appending(path: ".local/bin"),
            appData.appending(path: "npm"),
            programFiles.appending(path: "GitHub CLI"),
            home.appending(path: "scoop/shims"),
            home.appending(path: ".opencode/bin"),
            home.appending(path: ".bun/bin"),
        ] + path
    }
    #else
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
    #endif

    /// An override wins only when it is an executable on this Mac. config.json syncs between Macs, so an entry set on
    /// another one must not make the CLI read as missing here when the search would find it.
    public func locate(_ name: String) -> URL? {
        if let override = overrides[name] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if Self.isLaunchable(url) { return url }
        }
        for directory in searchDirectories {
            if let found = Self.fileNames(name).map({ directory.appending(path: $0) }).first(where: Self.isLaunchable) { return found }
        }
        return nil
    }

    #if os(Windows)
    /// Windows picks a program by its extension, so a folder holding npm's `claude` for Git Bash beside `claude.cmd`
    /// yields the .cmd. Foundation's isExecutableFile reads the file's header instead, and so turns down a .cmd.
    static func fileNames(_ name: String) -> [String] { ["\(name).exe", "\(name).cmd"] }

    static func isLaunchable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let ext = url.pathExtension.lowercased()
        return (ext == "exe" || ext == "cmd") && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
    #else
    static func fileNames(_ name: String) -> [String] { [name] }
    static func isLaunchable(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }
    #endif

    #if os(Windows)
    /// What a Windows program expects to find set: without SystemRoot, for one, Winsock and so every network call fails.
    static let inheritedVariables = [
        "SystemRoot", "SystemDrive", "windir", "ComSpec", "PATHEXT", "USERPROFILE", "USERNAME", "USERDOMAIN", "HOMEDRIVE",
        "HOMEPATH", "APPDATA", "LOCALAPPDATA", "ProgramData", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432",
        "CommonProgramFiles", "TEMP", "TMP", "OS", "PROCESSOR_ARCHITECTURE", "NUMBER_OF_PROCESSORS", "LANG",
    ]
    /// One spelling each, since Windows has one variable whatever its case.
    static let proxyVariables = ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"]
    #else
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"]
    static let proxyVariables = ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"]
    #endif

    /// Environment for spawned CLIs: only `inheritedVariables` and `proxyVariables` that are set in `inherited`, a PATH
    /// covering the search directories, and NO_COLOR. Nothing else passes through, so a launch environment's API keys or
    /// config dirs cannot change which login a CLI reports. Proxy values can hold credentials, so never log the result.
    /// Callers add their own on top (CLAUDE_CONFIG_DIR, CODEX_HOME, and for gh its GH_* variables and DO_NOT_TRACK).
    public func baseEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        #if os(Windows)
        // Windows names are case-insensitive, and its own environment spells some its own way, such as Path.
        for key in Self.inheritedVariables + Self.proxyVariables {
            if let value = inherited.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value { env[key] = value }
        }
        let system = URL(fileURLWithPath: env["SystemRoot"] ?? #"C:\Windows"#)
        let systemFolders = [system.appending(path: "System32"), system, system.appending(path: "System32/WindowsPowerShell/v1.0")]
        env["PATH"] = (searchDirectories + systemFolders).map(windowsPath).joined(separator: ";")
        #else
        for key in Self.inheritedVariables + Self.proxyVariables {
            if let value = inherited[key] { env[key] = value }
        }
        env["HOME"] = home.path
        env["PATH"] = (searchDirectories.map(\.path) + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        #endif
        env["NO_COLOR"] = "1"
        return env
    }
}
