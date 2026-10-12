import Foundation

public struct AppPaths: Sendable {
    public static let bundleIdentifier = "com.pedromosquera.tokenjar"
    public static let keychainService = "com.pedromosquera.tokenjar.apikeys"

    public var home: URL
    /// Where machine-wide files such as an MDM profile's managed settings live.
    public var systemRoot: URL
    private var xdgConfigHome: String?

    /// `environment` and `systemRoot` are seams for tests, so a test never reads this Mac's managed settings.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment,
        systemRoot: URL = URL(fileURLWithPath: "/")
    ) {
        self.home = home
        self.systemRoot = systemRoot
        xdgConfigHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Claude Code's machine-wide settings, written by an administrator or an MDM profile.
    public var claudeManagedSettingsFile: URL {
        systemRoot.appending(path: "Library/Application Support/ClaudeCode/managed-settings.json")
    }

    /// ~/.config/tokenjar. Honors XDG_CONFIG_HOME only when it is set in the app's own environment.
    public var configDirectory: URL {
        if let xdgConfigHome { return URL(fileURLWithPath: xdgConfigHome).appending(path: "tokenjar") }
        return home.appending(path: ".config/tokenjar")
    }

    public var configFile: URL { configDirectory.appending(path: "config.json") }
    public var localConfigFile: URL { configDirectory.appending(path: "config.local.json") }
    public var pricingOverrideFile: URL { configDirectory.appending(path: "pricing.json") }

    public var supportDirectory: URL { home.appending(path: "Library/Application Support/Tokenjar") }
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
