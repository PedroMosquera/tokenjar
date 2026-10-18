import Foundation

public struct AppPaths: Sendable {
    public static let bundleIdentifier = "com.pedromosquera.tokenjar"
    public static let keychainService = "com.pedromosquera.tokenjar.apikeys"

    public var home: URL
    /// Where machine-wide files such as an MDM profile's managed settings live.
    public var systemRoot: URL
    private var xdgConfigHome: String?
    private var xdgDataHome: String?
    private var localAppData: String?

    /// `environment` and `systemRoot` are seams for tests, so a test never reads the real managed settings.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment,
        systemRoot: URL = AppPaths.defaultSystemRoot
    ) {
        self.home = home
        self.systemRoot = systemRoot
        func nonEmpty(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        xdgConfigHome = nonEmpty("XDG_CONFIG_HOME")
        xdgDataHome = nonEmpty("XDG_DATA_HOME")
        localAppData = nonEmpty("LOCALAPPDATA")
    }

    #if os(Windows)
    public static let defaultSystemRoot = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemDrive"] ?? "C:") + "\\")
    #else
    public static let defaultSystemRoot = URL(fileURLWithPath: "/")
    #endif

    /// Claude Code's machine-wide settings, written by an administrator or an MDM profile, in the folder its docs name
    /// for each OS.
    public var claudeManagedSettingsFile: URL {
        #if os(macOS)
        systemRoot.appending(path: "Library/Application Support/ClaudeCode/managed-settings.json")
        #elseif os(Windows)
        systemRoot.appending(path: "Program Files/ClaudeCode/managed-settings.json")
        #else
        systemRoot.appending(path: "etc/claude-code/managed-settings.json")
        #endif
    }

    /// ~/.config/tokenjar. Honors XDG_CONFIG_HOME only when it is set in the app's own environment.
    public var configDirectory: URL {
        if let xdgConfigHome { return URL(fileURLWithPath: xdgConfigHome).appending(path: "tokenjar") }
        return home.appending(path: ".config/tokenjar")
    }

    public var configFile: URL { configDirectory.appending(path: "config.json") }
    public var localConfigFile: URL { configDirectory.appending(path: "config.local.json") }
    public var pricingOverrideFile: URL { configDirectory.appending(path: "pricing.json") }

    /// Where the database and app state live: Application Support on macOS, `%LOCALAPPDATA%` on Windows, and the XDG
    /// data folder elsewhere. Unlike the config folder this never syncs, so each machine keeps its own history.
    public var supportDirectory: URL {
        #if os(macOS)
        home.appending(path: "Library/Application Support/Tokenjar")
        #elseif os(Windows)
        (localAppData.map { URL(fileURLWithPath: $0) } ?? home.appending(path: "AppData/Local")).appending(path: "Tokenjar")
        #else
        (xdgDataHome.map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".local/share")).appending(path: "tokenjar")
        #endif
    }
    public var databaseFile: URL { supportDirectory.appending(path: "tokenjar.sqlite") }

    /// Fixed, empty working directory for CLI probes, so probes never create per-run folders in a CLI's project list.
    public var probeDirectory: URL { supportDirectory.appending(path: "probe") }

    /// Creates the probe directory inside the support directory, both owner-only, and returns it.
    @discardableResult
    public func createProbeDirectory() throws -> URL {
        try Self.createOwnerOnlyDirectory(supportDirectory)
        try Self.createOwnerOnlyDirectory(probeDirectory)
        return probeDirectory
    }

    /// Creates `url` and missing parents at 0700, and also tightens `url` when it exists already: whichever of the
    /// store, a fetcher or an older build got there first may have left the default 0755.
    public static func createOwnerOnlyDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}
