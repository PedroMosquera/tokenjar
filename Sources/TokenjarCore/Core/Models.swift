import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Hashable {
    case claude
    case codex
    case opencodeGo = "opencode-go"
    case opencodeZen = "opencode-zen"
    case antigravity
    case copilot
    case devin

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencodeGo: "OpenCode Go"
        case .opencodeZen: "OpenCode Zen"
        case .antigravity: "Antigravity"
        case .copilot: "GitHub Copilot"
        case .devin: "Devin"
        }
    }

    /// Basename of the SVG in Resources/Logos (no extension). Devin has no mark of its own yet, so Windsurf's stands in.
    public var logoName: String {
        switch self {
        case .claude: "claude"
        case .codex: "openai"
        case .opencodeGo, .opencodeZen: "opencode"
        case .antigravity: "antigravity"
        case .copilot: "copilot"
        case .devin: "windsurf"
        }
    }

    public var defaultDashboardURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/settings/usage")!
        case .opencodeGo, .opencodeZen: URL(string: "https://opencode.ai/auth")!
        case .antigravity: URL(string: "https://antigravity.google/docs/plans")!
        case .copilot: URL(string: "https://github.com/settings/copilot")!
        case .devin: URL(string: "https://app.devin.ai/settings/plans")!
        }
    }

    public var statusPageURL: URL? {
        switch self {
        case .claude: URL(string: "https://status.claude.com")
        case .codex: URL(string: "https://status.openai.com")
        case .copilot: URL(string: "https://www.githubstatus.com")
        case .opencodeGo, .opencodeZen, .antigravity, .devin: nil
        }
    }

    /// True when the provider shares no usage Tokenjar can read, so its account is a link to the provider's own page.
    public var isLinkOnly: Bool {
        switch self {
        case .devin: true
        case .claude, .codex, .opencodeGo, .opencodeZen, .antigravity, .copilot: false
        }
    }

    /// The harness whose local logs feed this provider's history, if any.
    public var harness: Harness? {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        case .opencodeGo, .opencodeZen: .opencode
        case .antigravity, .copilot, .devin: nil
        }
    }
}

public enum Harness: String, Codable, CaseIterable, Sendable, Hashable {
    case claudeCode = "claude-code"
    case codex
    case opencode
}

/// Where an API key lives. The app never stores OAuth tokens; this is only for plain API keys.
public enum CredentialRef: Codable, Hashable, Sendable {
    /// A JSON file whose top-level `key` entry is an object with a string field `key` (opencode's auth.json shape).
    case file(path: String, key: String)
    /// The app's own Keychain item, service `AppPaths.keychainService`, under this account name.
    case keychain(account: String)
}

public struct AccountConfig: Codable, Hashable, Sendable, Identifiable {
    /// Stable slug used as the primary key in storage and alerts. Never rename once data exists.
    public var id: String
    public var provider: ProviderID
    public var label: String
    public var enabled: Bool
    /// CLAUDE_CONFIG_DIR for Claude, CODEX_HOME for Codex, GH_CONFIG_DIR for Copilot, opencode's data directory
    /// (holding auth.json and opencode.db) for OpenCode. `nil` means the default: ~/.claude, ~/.codex, ~/.config/gh,
    /// $XDG_DATA_HOME/opencode or ~/.local/share/opencode.
    public var profileDir: String?
    public var credential: CredentialRef?
    public var showInMenuBar: Bool
    public var refreshMinutes: Int?
    /// Used-% thresholds that override the global ones.
    public var alertThresholds: [Int]?
    public var dashboardURL: String?

    public init(
        id: String, provider: ProviderID, label: String, enabled: Bool = true,
        profileDir: String? = nil, credential: CredentialRef? = nil, showInMenuBar: Bool = true,
        refreshMinutes: Int? = nil, alertThresholds: [Int]? = nil, dashboardURL: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.enabled = enabled
        self.profileDir = profileDir
        self.credential = credential
        self.showInMenuBar = showInMenuBar
        self.refreshMinutes = refreshMinutes
        self.alertThresholds = alertThresholds
        self.dashboardURL = dashboardURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(ProviderID.self, forKey: .provider)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? provider.displayName
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        profileDir = try c.decodeIfPresent(String.self, forKey: .profileDir)
        credential = try c.decodeIfPresent(CredentialRef.self, forKey: .credential)
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes)
        alertThresholds = try c.decodeIfPresent([Int].self, forKey: .alertThresholds)
        dashboardURL = try c.decodeIfPresent(String.self, forKey: .dashboardURL)
    }

    public var displayName: String { "\(provider.displayName) · \(label)" }

    /// Only http(s) overrides are honored: config.json syncs between Macs, and NSWorkspace would happily open
    /// file:// or custom-scheme URLs from it.
    public var resolvedDashboardURL: URL {
        if let override = dashboardURL.flatMap(URL.init(string:)), ["http", "https"].contains(override.scheme?.lowercased()) {
            return override
        }
        return provider.defaultDashboardURL
    }
}

public struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    /// Stable key: `session`, `weekly`, `weekly:<model>`, `monthly`, `<limitId>:<window>` for extra Codex limits,
    /// `spend-cap` for a Codex workspace cap, or `<pool>:session` / `<pool>:weekly` for Antigravity's quota pools.
    public var id: String
    public var label: String
    /// 0...100, may exceed 100 when a provider reports overage.
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?
    /// True when the provider reports an idle window whose reset time is synthetic (now + window).
    public var notStarted: Bool

    public init(id: String, label: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil, notStarted: Bool = false) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.notStarted = notStarted
    }

    /// A monthly allowance follows its billing month, so its window is the UTC calendar month ending at the reported
    /// reset: 28 to 31 days. Pace needs that length; nil only when the reset is unknown.
    public static func monthMinutes(endingAt resetsAt: Date?) -> Int? {
        guard let resetsAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        return Int((resetsAt.timeIntervalSince(start) / 60).rounded())
    }
}

public struct MoneyLine: Codable, Hashable, Sendable {
    public var label: String
    public var amount: Double
    public var limit: Double?
    /// ISO 4217 code, e.g. "USD".
    public var currency: String

    public init(label: String, amount: Double, limit: Double? = nil, currency: String = "USD") {
        self.label = label
        self.amount = amount
        self.limit = limit
        self.currency = currency
    }
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var accountID: String
    public var provider: ProviderID
    /// Human plan label, e.g. "Max 20x", "Plus", "Enterprise".
    public var plan: String?
    public var windows: [UsageWindow]
    public var money: [MoneyLine]
    public var fetchedAt: Date
    /// Short source label shown in the UI, e.g. "claude CLI", "codex app-server", "opencode API".
    public var source: String
    /// Plain-language notes, e.g. "No plan limits for this login". Never raw errors, emails or ids.
    public var notes: [String]

    public init(accountID: String, provider: ProviderID, plan: String? = nil, windows: [UsageWindow] = [], money: [MoneyLine] = [], fetchedAt: Date, source: String, notes: [String] = []) {
        self.accountID = accountID
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.money = money
        self.fetchedAt = fetchedAt
        self.source = source
        self.notes = notes
    }

    /// The window with the highest used %, ties broken by the sooner reset.
    public var tightestWindow: UsageWindow? {
        windows.max { a, b in
            if a.usedPercent != b.usedPercent { return a.usedPercent < b.usedPercent }
            return (a.resetsAt ?? .distantFuture) > (b.resetsAt ?? .distantFuture)
        }
    }
}

public enum FetchError: Error, Codable, Hashable, Sendable {
    case cliNotFound(String)
    case notSignedIn
    case noSubscription(String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case timeout
    case parse(String)
    case unsupported(String)

    /// Safe for display and notifications: no ids, emails, tokens or raw bodies.
    public var userMessage: String {
        switch self {
        case .cliNotFound(let name): "\(name) CLI not found"
        case .notSignedIn: "Signed out. Sign in with the provider CLI."
        case .noSubscription(let detail): detail
        case .unauthorized: "Credential rejected"
        case .rateLimited: "Provider is rate limiting usage checks"
        case .network: "Network error"
        case .timeout: "Timed out"
        case .parse: "Unexpected response format"
        case .unsupported(let detail): detail
        }
    }
}

public struct WindowSample: Codable, Hashable, Sendable {
    public var accountID: String
    public var windowID: String
    public var timestamp: Date
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(accountID: String, windowID: String, timestamp: Date, usedPercent: Double, resetsAt: Date?) {
        self.accountID = accountID
        self.windowID = windowID
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// One model response read from a local log. Holds counts and identifiers only, never content.
public struct UsageEvent: Codable, Hashable, Sendable {
    /// Unique per response across rescans, e.g. "claude:<message.id>:<requestId>". Upserts keep the larger token totals.
    public var dedupeKey: String
    public var timestamp: Date
    public var accountID: String
    public var harness: Harness
    public var model: String
    /// See `project(fromWorkingDirectory:home:)`.
    public var project: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int
    public var reasoningTokens: Int
    /// Cost the harness itself recorded (opencode). nil means price it with `PriceTable`.
    public var reportedCostUSD: Double?

    public init(
        dedupeKey: String, timestamp: Date, accountID: String, harness: Harness, model: String, project: String?,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0, reasoningTokens: Int = 0, reportedCostUSD: Double? = nil
    ) {
        self.dedupeKey = dedupeKey
        self.timestamp = timestamp
        self.accountID = accountID
        self.harness = harness
        self.model = model
        self.project = project
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.reasoningTokens = reasoningTokens
        self.reportedCostUSD = reportedCostUSD
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// The working directory's last path component, with the home folder itself mapped to "~" so the user's account
    /// name is never stored. nil for a relative path, the root, or no path. Every history scanner goes through this.
    static func project(fromWorkingDirectory cwd: String?, home: URL) -> String? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let homePath = home.standardizedFileURL.path
        // Claude Code runs subagents and parallel sessions in <repo>/.claude/worktrees/<name>; the work belongs to <repo>.
        if let range = url.path.range(of: "/.claude/worktrees/") {
            url = URL(fileURLWithPath: String(url.path[..<range.lowerBound]))
        } else {
            // Tool workspaces inside a repo (.superpowers/sdd/<plan>, .cursor/...) belong to the repo. Hidden folders
            // directly under home (~/.config/nvim) are projects of their own.
            let parts = url.pathComponents
            if let hidden = parts.indices.dropFirst().first(where: { parts[$0].hasPrefix(".") }), hidden > 1 {
                let parent = NSString.path(withComponents: Array(parts[..<hidden]))
                if parent != homePath { url = URL(fileURLWithPath: parent) }
            }
        }
        if url.path == homePath { return "~" }
        let last = url.lastPathComponent
        return last == "/" ? nil : last
    }
}

/// Token sums for one day and one grouping key. `reportedCostUSD` covers only rows whose harness recorded cost.
public struct DailyUsageRow: Codable, Hashable, Sendable {
    /// Local calendar day at 00:00.
    public var day: Date
    public var accountID: String
    public var harness: Harness
    public var model: String
    public var project: String?
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int
    public var reasoningTokens: Int
    public var reportedCostUSD: Double?
    /// Tokens of rows that had no reported cost; these are the ones to price.
    public var unpricedInputTokens: Int
    public var unpricedOutputTokens: Int
    public var unpricedCacheReadTokens: Int
    public var unpricedCacheWrite5mTokens: Int
    public var unpricedCacheWrite1hTokens: Int

    public init(
        day: Date, accountID: String, harness: Harness, model: String, project: String?, requests: Int,
        inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWrite5mTokens: Int, cacheWrite1hTokens: Int,
        reasoningTokens: Int, reportedCostUSD: Double?, unpricedInputTokens: Int, unpricedOutputTokens: Int,
        unpricedCacheReadTokens: Int, unpricedCacheWrite5mTokens: Int, unpricedCacheWrite1hTokens: Int
    ) {
        self.day = day
        self.accountID = accountID
        self.harness = harness
        self.model = model
        self.project = project
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.reasoningTokens = reasoningTokens
        self.reportedCostUSD = reportedCostUSD
        self.unpricedInputTokens = unpricedInputTokens
        self.unpricedOutputTokens = unpricedOutputTokens
        self.unpricedCacheReadTokens = unpricedCacheReadTokens
        self.unpricedCacheWrite5mTokens = unpricedCacheWrite5mTokens
        self.unpricedCacheWrite1hTokens = unpricedCacheWrite1hTokens
    }
}
