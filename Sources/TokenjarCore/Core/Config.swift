import Foundation

public enum MenuBarMode: String, Codable, CaseIterable, Sendable {
    /// The menu bar icon plus the tightest used % of the account with the least room left.
    case worst
    /// One thin bar per account flagged showInMenuBar.
    case bars
    /// The menu bar icon only, tinted by the worst state.
    case icon
}

/// The menu bar glyph, stored as `app`, `mark:<name>`, `logo:<name>` or `symbol:<SF Symbol name>`. Only `app` shows
/// the fill level; the others are static glyphs.
public enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    case app
    case markMana = "mark:mana"
    case markTaper = "mark:taper"
    case markTally = "mark:tally"
    case markBurnrate = "mark:burnrate"
    case markGenio = "mark:genio"
    case logoClaude = "logo:claude"
    case logoOpenAI = "logo:openai"
    case logoAntigravity = "logo:antigravity"
    case logoCopilot = "logo:copilot"
    case logoOpenCode = "logo:opencode"
    case logoWindsurf = "logo:windsurf"
    case symbolSparkles = "symbol:sparkles"
    case symbolBrain = "symbol:brain"
    case symbolCPU = "symbol:cpu"
    case symbolGauge = "symbol:gauge.with.needle"

    /// config.json syncs between Macs, so a choice from a newer build falls back here instead of failing the load.
    public init(from decoder: Decoder) throws {
        self = MenuBarIcon(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .app
    }
}

public struct MenuBarConfig: Codable, Equatable, Sendable {
    public var mode: MenuBarMode
    public var icon: MenuBarIcon
    public var warnAt: Int
    public var criticalAt: Int
    public var showResetCountdownWhenFull: Bool

    public init(mode: MenuBarMode = .worst, icon: MenuBarIcon = .app, warnAt: Int = 80, criticalAt: Int = 95, showResetCountdownWhenFull: Bool = true) {
        self.mode = mode
        self.icon = icon
        self.warnAt = warnAt
        self.criticalAt = criticalAt
        self.showResetCountdownWhenFull = showResetCountdownWhenFull
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuBarConfig()
        mode = try c.decodeIfPresent(MenuBarMode.self, forKey: .mode) ?? d.mode
        icon = try c.decodeIfPresent(MenuBarIcon.self, forKey: .icon) ?? d.icon
        warnAt = try c.decodeIfPresent(Int.self, forKey: .warnAt) ?? d.warnAt
        criticalAt = try c.decodeIfPresent(Int.self, forKey: .criticalAt) ?? d.criticalAt
        showResetCountdownWhenFull = try c.decodeIfPresent(Bool.self, forKey: .showResetCountdownWhenFull) ?? d.showResetCountdownWhenFull
    }
}

public enum PaceDays: String, Codable, CaseIterable, Sendable {
    case everyDay
    case workingDays

    /// config.json syncs between Macs, so a choice from a newer build falls back here instead of failing the load.
    public init(from decoder: Decoder) throws {
        self = PaceDays(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .everyDay
    }
}

public struct AlertConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Used-% thresholds for windows longer than a day, ascending. An empty list turns them off.
    public var thresholds: [Int]
    /// Used-% thresholds for windows of a day or less (`UsageWindow.isShort`). An empty list turns them off.
    public var shortThresholds: [Int]
    public var projectedExhaustion: Bool
    public var windowResets: Bool
    public var sourceProblems: Bool

    public init(
        enabled: Bool = true, thresholds: [Int] = [80, 95], shortThresholds: [Int] = [95], projectedExhaustion: Bool = true,
        windowResets: Bool = false, sourceProblems: Bool = true
    ) {
        self.enabled = enabled
        self.thresholds = thresholds
        self.shortThresholds = shortThresholds
        self.projectedExhaustion = projectedExhaustion
        self.windowResets = windowResets
        self.sourceProblems = sourceProblems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        thresholds = try c.decodeIfPresent([Int].self, forKey: .thresholds) ?? d.thresholds
        shortThresholds = try c.decodeIfPresent([Int].self, forKey: .shortThresholds) ?? d.shortThresholds
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
    /// Absolute paths to CLIs that are not in the standard locations, keyed by binary name ("claude", "codex", "agy", "gh").
    public var cliPaths: [String: String]
    public var launchAtLogin: Bool
    /// Whether pace in windows longer than a day counts every day or only working days (`WorkWeek`).
    public var paceDays: PaceDays
    /// The global shortcut that opens the popover, as a readable combination such as "control+option+command+U"; nil is off.
    public var hotkey: String?

    public init(
        version: Int = 1, refreshMinutes: Int = 10, menuBar: MenuBarConfig = MenuBarConfig(), alerts: AlertConfig = AlertConfig(),
        accounts: [AccountConfig] = [], cliPaths: [String: String] = [:], launchAtLogin: Bool = false, paceDays: PaceDays = .everyDay,
        hotkey: String? = nil
    ) {
        self.version = version
        self.refreshMinutes = refreshMinutes
        self.menuBar = menuBar
        self.alerts = alerts
        self.accounts = accounts
        self.cliPaths = cliPaths
        self.launchAtLogin = launchAtLogin
        self.paceDays = paceDays
        self.hotkey = hotkey
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
        paceDays = try c.decodeIfPresent(PaceDays.self, forKey: .paceDays) ?? d.paceDays
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
    }

    /// The long-window list for every window: what `AlertEngine` uses until it moves to `thresholds(for:window:)`.
    public func thresholds(for account: AccountConfig) -> [Int] {
        (account.alertThresholds ?? alerts.thresholds).sorted()
    }

    /// An account's own list applies to both kinds of window, so an override set before the split keeps its alerts.
    public func thresholds(for account: AccountConfig, window: UsageWindow) -> [Int] {
        (account.alertThresholds ?? (window.isShort ? alerts.shortThresholds : alerts.thresholds)).sorted()
    }
}

extension UsageWindow {
    /// A day or less, such as a 5-hour session. An unknown length counts as long, which keeps the long-window alerts.
    public var isShort: Bool {
        windowMinutes.map { $0 <= 1440 } ?? false
    }
}

public enum ConfigError: Error {
    /// The file could not be read, is not a JSON object, or does not decode as a config. `file` is the name only, safe to show.
    case invalidJSON(file: String, detail: String)
    /// The file is a symlink whose destination is gone, so a save would replace the link instead of writing through it.
    case brokenLink(file: String)
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
        let target = try Self.writeTarget(paths.configFile)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
    }

    /// The real file behind a stow symlink, so an atomic save replaces that file and the link keeps pointing at the
    /// dotfiles repo. realpath resolves a relative link against the link's own folder, as the kernel does. A link whose
    /// destination is gone throws: `resolvingSymlinksInPath` returns such a link unchanged, and the save would replace it.
    static func writeTarget(_ file: URL) throws -> URL {
        let type = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType
        guard type == .typeSymbolicLink else { return file }
        guard let resolved = realpath(file.path, nil) else { throw ConfigError.brokenLink(file: file.lastPathComponent) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Copies leaf fields one by one: the merge is deep, so a local override can sit beside a field the user edits in
    /// the same struct or dictionary, and copying the whole value would write the override into config.json.
    static func apply(from old: AppConfig, to new: AppConfig, onto base: AppConfig) -> AppConfig {
        var out = base
        // Every leaf of AppConfig except accounts must be listed here; one left out is never saved.
        func copyIfEdited<T: Equatable>(_ field: WritableKeyPath<AppConfig, T>) {
            if old[keyPath: field] != new[keyPath: field] { out[keyPath: field] = new[keyPath: field] }
        }
        copyIfEdited(\.version)
        copyIfEdited(\.refreshMinutes)
        copyIfEdited(\.launchAtLogin)
        copyIfEdited(\.paceDays)
        copyIfEdited(\.hotkey)
        copyIfEdited(\.menuBar.mode)
        copyIfEdited(\.menuBar.icon)
        copyIfEdited(\.menuBar.warnAt)
        copyIfEdited(\.menuBar.criticalAt)
        copyIfEdited(\.menuBar.showResetCountdownWhenFull)
        copyIfEdited(\.alerts.enabled)
        copyIfEdited(\.alerts.thresholds)
        copyIfEdited(\.alerts.shortThresholds)
        copyIfEdited(\.alerts.projectedExhaustion)
        copyIfEdited(\.alerts.windowResets)
        copyIfEdited(\.alerts.sourceProblems)
        for name in Set(old.cliPaths.keys).union(new.cliPaths.keys) where old.cliPaths[name] != new.cliPaths[name] {
            out.cliPaths[name] = new.cliPaths[name]
        }
        if old.accounts != new.accounts {
            let oldByID = Dictionary(old.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let baseByID = Dictionary(base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // An account only config.local.json holds stays out: config.json reaches every Mac, and merge appends such
            // an account after the shared ones on each load anyway.
            out.accounts = new.accounts.compactMap { account in
                guard let before = oldByID[account.id] else { return account }
                guard let shared = baseByID[account.id] else { return nil }
                return Self.applyEditedFields(from: before, to: account, onto: shared)
            }
            // Accounts that exist only in base (hidden by a local override) are kept.
            let newIDs = Set(new.accounts.map(\.id)), oldIDs = Set(old.accounts.map(\.id))
            out.accounts += base.accounts.filter { !newIDs.contains($0.id) && !oldIDs.contains($0.id) }
        }
        return out
    }

    /// Copies only the fields the user changed, so values a machine's config.local.json overrides stay local.
    static func applyEditedFields(from before: AccountConfig, to after: AccountConfig, onto shared: AccountConfig) -> AccountConfig {
        var out = shared
        if before.label != after.label { out.label = after.label }
        if before.enabled != after.enabled { out.enabled = after.enabled }
        if before.profileDir != after.profileDir { out.profileDir = after.profileDir }
        if before.credential != after.credential { out.credential = after.credential }
        if before.showInMenuBar != after.showInMenuBar { out.showInMenuBar = after.showInMenuBar }
        if before.refreshMinutes != after.refreshMinutes { out.refreshMinutes = after.refreshMinutes }
        if before.alertThresholds != after.alertThresholds { out.alertThresholds = after.alertThresholds }
        if before.dashboardURL != after.dashboardURL { out.dashboardURL = after.dashboardURL }
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
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch {
            throw ConfigError.invalidJSON(file: url.lastPathComponent, detail: String(describing: error))
        }
        guard let dictionary = object as? [String: Any] else {
            throw ConfigError.invalidJSON(file: url.lastPathComponent, detail: "top level is not an object")
        }
        return dictionary
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
