import Foundation

public struct AppPaths: Sendable {
    public static let bundleIdentifier = "com.pedromosquera.headroom"
    public static let keychainService = "com.pedromosquera.headroom.apikeys"

    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// ~/.config/headroom. Honors XDG_CONFIG_HOME only when it is set in the app's own environment.
    public var configDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appending(path: "headroom")
        }
        return home.appending(path: ".config/headroom")
    }

    public var configFile: URL { configDirectory.appending(path: "config.json") }
    public var localConfigFile: URL { configDirectory.appending(path: "config.local.json") }
    public var pricingOverrideFile: URL { configDirectory.appending(path: "pricing.json") }

    public var supportDirectory: URL { home.appending(path: "Library/Application Support/Headroom") }
    public var databaseFile: URL { supportDirectory.appending(path: "headroom.sqlite") }

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
