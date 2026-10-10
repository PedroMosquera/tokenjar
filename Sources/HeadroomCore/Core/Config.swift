import Foundation

public enum MenuBarMode: String, Codable, CaseIterable, Sendable {
    /// Logo of the account with the least headroom plus its tightest used %.
    case worst
    /// One thin bar per account flagged showInMenuBar.
    case bars
    /// Logo only, tinted by the worst state.
    case icon
}

public struct MenuBarConfig: Codable, Equatable, Sendable {
    public var mode: MenuBarMode
    public var warnAt: Int
    public var criticalAt: Int
    public var showResetCountdownWhenFull: Bool

    public init(mode: MenuBarMode = .worst, warnAt: Int = 80, criticalAt: Int = 95, showResetCountdownWhenFull: Bool = true) {
        self.mode = mode
        self.warnAt = warnAt
        self.criticalAt = criticalAt
        self.showResetCountdownWhenFull = showResetCountdownWhenFull
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuBarConfig()
        mode = try c.decodeIfPresent(MenuBarMode.self, forKey: .mode) ?? d.mode
        warnAt = try c.decodeIfPresent(Int.self, forKey: .warnAt) ?? d.warnAt
        criticalAt = try c.decodeIfPresent(Int.self, forKey: .criticalAt) ?? d.criticalAt
        showResetCountdownWhenFull = try c.decodeIfPresent(Bool.self, forKey: .showResetCountdownWhenFull) ?? d.showResetCountdownWhenFull
    }
}

public struct AlertConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Used-% thresholds, ascending.
    public var thresholds: [Int]
    public var projectedExhaustion: Bool
    public var windowResets: Bool
    public var sourceProblems: Bool

    public init(enabled: Bool = true, thresholds: [Int] = [80, 95], projectedExhaustion: Bool = true, windowResets: Bool = false, sourceProblems: Bool = true) {
        self.enabled = enabled
        self.thresholds = thresholds
        self.projectedExhaustion = projectedExhaustion
        self.windowResets = windowResets
        self.sourceProblems = sourceProblems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        thresholds = try c.decodeIfPresent([Int].self, forKey: .thresholds) ?? d.thresholds
        projectedExhaustion = try c.decodeIfPresent(Bool.self, forKey: .projectedExhaustion) ?? d.projectedExhaustion
        windowResets = try c.decodeIfPresent(Bool.self, forKey: .windowResets) ?? d.windowResets
        sourceProblems = try c.decodeIfPresent(Bool.self, forKey: .sourceProblems) ?? d.sourceProblems
    }
}

/// Everything here is safe to commit to a dotfiles repo: no secrets, only references to where keys live.
public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var refreshMinutes: Int
    public var menuBar: MenuBarConfig
    public var alerts: AlertConfig
    public var accounts: [AccountConfig]
    /// Absolute paths to CLIs that are not in the standard locations, keyed by binary name ("claude", "codex", "agy").
    public var cliPaths: [String: String]
    public var launchAtLogin: Bool

    public init(
        version: Int = 1, refreshMinutes: Int = 10, menuBar: MenuBarConfig = MenuBarConfig(), alerts: AlertConfig = AlertConfig(),
        accounts: [AccountConfig] = [], cliPaths: [String: String] = [:], launchAtLogin: Bool = false
    ) {
        self.version = version
        self.refreshMinutes = refreshMinutes
        self.menuBar = menuBar
        self.alerts = alerts
        self.accounts = accounts
        self.cliPaths = cliPaths
        self.launchAtLogin = launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? d.refreshMinutes
        menuBar = try c.decodeIfPresent(MenuBarConfig.self, forKey: .menuBar) ?? d.menuBar
        alerts = try c.decodeIfPresent(AlertConfig.self, forKey: .alerts) ?? d.alerts
        accounts = try c.decodeIfPresent([AccountConfig].self, forKey: .accounts) ?? d.accounts
        cliPaths = try c.decodeIfPresent([String: String].self, forKey: .cliPaths) ?? d.cliPaths
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    /// Thresholds for an account, falling back to the global ones.
    public func thresholds(for account: AccountConfig) -> [Int] {
        (account.alertThresholds ?? alerts.thresholds).sorted()
    }
}

public enum ConfigError: Error {
    case invalidJSON(file: String, detail: String)
}

/// Loads `config.json` merged with `config.local.json` (local wins), and saves edits back to `config.json`
/// without leaking local overrides into it and without replacing a stow symlink with a regular file.
public struct ConfigStore: Sendable {
    public var paths: AppPaths

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    public struct Loaded: Sendable {
        /// What the app runs with.
        public var merged: AppConfig
        /// config.json alone; the target of saves.
        public var base: AppConfig
        public var hasLocalOverrides: Bool
    }

    /// nil when config.json does not exist yet (first run).
    public func load() throws -> Loaded? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.configFile.path) else { return nil }
        let baseJSON = try readJSONObject(paths.configFile)
        let base = try decode(baseJSON, file: paths.configFile)
        guard fm.fileExists(atPath: paths.localConfigFile.path) else {
            return Loaded(merged: base, base: base, hasLocalOverrides: false)
        }
        let localJSON = try readJSONObject(paths.localConfigFile)
        let merged = try decode(Self.merge(baseJSON, localJSON), file: paths.localConfigFile)
        return Loaded(merged: merged, base: base, hasLocalOverrides: true)
    }

    /// Applies the user's edit (`old` -> `new`, both merged views) onto `base` and writes config.json.
    @discardableResult
    public func save(old: AppConfig, new: AppConfig, base: AppConfig) throws -> AppConfig {
        let updated = Self.apply(from: old, to: new, onto: base)
        try write(updated)
        return updated
    }

    public func write(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        // Resolve the stow symlink and replace the real file, so the link keeps pointing at the dotfiles repo.
        let target = paths.configFile.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
    }

    static func apply(from old: AppConfig, to new: AppConfig, onto base: AppConfig) -> AppConfig {
        var out = base
        if old.version != new.version { out.version = new.version }
        if old.refreshMinutes != new.refreshMinutes { out.refreshMinutes = new.refreshMinutes }
        if old.menuBar != new.menuBar { out.menuBar = new.menuBar }
        if old.alerts != new.alerts { out.alerts = new.alerts }
        if old.cliPaths != new.cliPaths { out.cliPaths = new.cliPaths }
        if old.launchAtLogin != new.launchAtLogin { out.launchAtLogin = new.launchAtLogin }
        if old.accounts != new.accounts {
            let oldByID = Dictionary(old.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let baseByID = Dictionary(base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            out.accounts = new.accounts.compactMap { account in
                if let before = oldByID[account.id], before == account { return baseByID[account.id] ?? account }
                return account
            }
            // Accounts that exist only in base (hidden by a local override) are kept.
            let newIDs = Set(new.accounts.map(\.id)), oldIDs = Set(old.accounts.map(\.id))
            out.accounts += base.accounts.filter { !newIDs.contains($0.id) && !oldIDs.contains($0.id) }
        }
        return out
    }

    /// Deep merge, `overlay` wins. `accounts` arrays merge by `id`: matching entries merge field by field, new ones append.
    static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in overlay {
            if key == "accounts", let baseAccounts = base[key] as? [[String: Any]], let overlayAccounts = value as? [[String: Any]] {
                var merged = baseAccounts
                for account in overlayAccounts {
                    if let id = account["id"] as? String, let index = merged.firstIndex(where: { ($0["id"] as? String) == id }) {
                        merged[index] = merge(merged[index], account)
                    } else {
                        merged.append(account)
                    }
                }
                out[key] = merged
            } else if let b = base[key] as? [String: Any], let o = value as? [String: Any] {
                out[key] = merge(b, o)
            } else {
                out[key] = value
            }
        }
        return out
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidJSON(file: url.lastPathComponent, detail: "top level is not an object")
        }
        return object
    }

    private func decode(_ object: [String: Any], file: URL) throws -> AppConfig {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(file: file.lastPathComponent, detail: String(describing: error))
        }
    }
}
