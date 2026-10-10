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

    public func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}
