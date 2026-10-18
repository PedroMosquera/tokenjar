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
        case .devin: URL(string: "https://app.devin.ai/settings/usage")!
        }
    }

    /// Opened in the browser, never fetched. Antigravity has no official status page.
    public var statusPageURL: URL? {
        switch self {
        case .claude: URL(string: "https://status.claude.com")
        case .codex: URL(string: "https://status.openai.com")
        case .opencodeGo, .opencodeZen: URL(string: "https://status.opencode.ai")
        case .copilot: URL(string: "https://www.githubstatus.com")
        case .devin: URL(string: "https://www.devinstatus.com")
        case .antigravity: nil
        }
    }

    /// The status JSON Tokenjar reads when provider status is on, nil for a provider whose status it never fetches.
    /// Each is an exact entry in `HTTPClient.allowedEndpoints`.
    public var statusFeedURL: URL? {
        switch self {
        case .claude: URL(string: "https://status.claude.com/api/v2/summary.json")
        case .codex: URL(string: "https://status.openai.com/proxy/status.openai.com")
        case .copilot: URL(string: "https://www.githubstatus.com/api/v2/summary.json")
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

    /// False when the provider never reports a limit window (Zen shows local spend, Devin is a link), so the menu bar,
    /// thresholds and limit charts have nothing to show for it.
    public var reportsWindows: Bool {
        switch self {
        case .opencodeZen, .devin: false
        case .claude, .codex, .opencodeGo, .antigravity, .copilot: true
        }
    }

    /// Whether a check of this provider's account contacts a server, directly or through its CLI. Answers a different
    /// question from `reportsWindows`, though the values match today: a Zen balance check would split them.
    public var checkUsesNetwork: Bool {
        switch self {
        case .opencodeZen, .devin: false
        case .claude, .codex, .opencodeGo, .antigravity, .copilot: true
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
    /// nil is off; on, it draws a Today bar for an account limited by what it spends.
    public var dailyBudget: DailyBudget?
    /// What a login billed per use may spend per calendar month, in USD, set by hand (`MonthlyBudget`). nil is none.
    public var monthlyBudget: Double?

    public init(
        id: String, provider: ProviderID, label: String, enabled: Bool = true,
        profileDir: String? = nil, credential: CredentialRef? = nil, showInMenuBar: Bool = true,
        refreshMinutes: Int? = nil, alertThresholds: [Int]? = nil,
        dashboardURL: String? = nil, dailyBudget: DailyBudget? = nil, monthlyBudget: Double? = nil
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
        self.dailyBudget = dailyBudget
        self.monthlyBudget = monthlyBudget
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
        dailyBudget = try c.decodeIfPresent(DailyBudget.self, forKey: .dailyBudget)
        monthlyBudget = try c.decodeIfPresent(Double.self, forKey: .monthlyBudget)
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

/// What reaching 100 % of a window means when it is not a hard stop.
public enum LimitStyle: String, Codable, CaseIterable, Sendable {
    /// Use past 100 % is billed as extra use; nothing stops.
    case overage
    /// The window is this seat's share of an allowance pooled across an org, so 100 % is not where the pool runs out.
    case share
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
    /// nil means a hard limit: at 100 % the provider stops serving.
    public var limitStyle: LimitStyle?

    public init(
        id: String, label: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil, notStarted: Bool = false,
        limitStyle: LimitStyle? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.notStarted = notStarted
        self.limitStyle = limitStyle
    }

    public static let spendCapID = "spend-cap"

    /// A monthly allowance follows its billing month, so its window is the UTC calendar month ending at the reported
    /// reset: 28 to 31 days. Pace needs that length; nil only when the reset is unknown.
    public static func monthMinutes(endingAt resetsAt: Date?) -> Int? {
        guard let resetsAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        return Int((resetsAt.timeIntervalSince(start) / 60).rounded())
    }

    /// At 100 % on a limit that stops the work there. A limit billed past 100 % (`.overage`) or a share of a pool is
    /// never full: use goes on.
    public var isFull: Bool { usedPercent >= 100 && limitStyle == nil }

    /// True once the reported reset time has passed: until the next check, the used % describes a cycle that is over.
    public func hasReset(now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
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

/// Why the live check failed when a snapshot is the provider's own saved copy. Stored with the snapshot, so the raw
/// values are permanent; a value from a newer build decodes as `.other` rather than failing the whole row.
public enum LiveCheckFailure: String, Codable, Sendable {
    case network, timeout, other

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    /// A small stable enum rather than `FetchError`, whose cases may change without breaking stored rows.
    public init(_ error: FetchError) {
        switch error {
        case .network: self = .network
        case .timeout: self = .timeout
        default: self = .other
        }
    }
}

/// How the account itself pays for use. `CostLine` reads it, so it decides who sees a dollar estimate.
public enum Billing: String, Codable, CaseIterable, Sendable {
    case free
    /// A flat plan, extra usage included: the provider's own money row is the bill.
    case subscription
    /// A seat that draws on credits pooled at the org.
    case pooled
    /// A seat billed per use under an org or team contract.
    case usageBased
    /// An API key, cloud lane, gateway or prepaid balance.
    case payAsYouGo
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var accountID: String
    public var provider: ProviderID
    /// Human plan label, e.g. "Max 20x", "Plus", "Enterprise".
    public var plan: String?
    /// nil when the fetcher cannot tell, which never shows a cost line.
    public var billing: Billing?
    public var windows: [UsageWindow]
    public var money: [MoneyLine]
    public var fetchedAt: Date
    /// Short source label shown in the UI, e.g. "claude CLI", "codex app-server", "opencode API".
    public var source: String
    /// Plain-language notes, e.g. "No plan limits for this login". Never raw errors, emails or ids.
    public var notes: [String]
    /// nil for a live answer; set when this is the provider's saved copy, shown because the live check failed.
    public var liveCheckFailure: LiveCheckFailure?

    public init(
        accountID: String, provider: ProviderID, plan: String? = nil, billing: Billing? = nil, windows: [UsageWindow] = [],
        money: [MoneyLine] = [], fetchedAt: Date, source: String, notes: [String] = [], liveCheckFailure: LiveCheckFailure? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.plan = plan
        self.billing = billing
        self.windows = windows
        self.money = money
        self.fetchedAt = fetchedAt
        self.source = source
        self.notes = notes
        self.liveCheckFailure = liveCheckFailure
    }

    /// The capped money a spend-limit window measures, shown with that bar rather than as a row of its own.
    public var spendLimitMoney: MoneyLine? {
        guard windows.contains(where: { $0.id == UsageWindow.spendCapID }) else { return nil }
        return money.first { $0.limit != nil }
    }

    /// The window with the highest used %, ties broken by the sooner reset.
    public var tightestWindow: UsageWindow? {
        Self.tightest(windows)
    }

    /// `tightestWindow` among the windows that have not reset by `now`.
    /// Older than twice the refresh interval: shown faded, since it may no longer reflect the account.
    public func isStale(now: Date, refreshMinutes: Int) -> Bool {
        now.timeIntervalSince(fetchedAt) > Double(max(refreshMinutes, 1) * 2 * 60)
    }

    public func tightestWindow(now: Date) -> UsageWindow? {
        Self.tightest(windows.filter { !$0.hasReset(now: now) })
    }

    private static func tightest(_ windows: [UsageWindow]) -> UsageWindow? {
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
    /// The user refused Tokenjar's own Keychain item. Only the account's Try Again asks again.
    case keychainDenied
    /// The CLI is older than the answer format this build reads. `minimum` is the first version known to work, when
    /// there is one.
    case cliTooOld(name: String, minimum: String?)

    /// How much a failed check asks of the user. The popover, menu bar, dashboard and Settings all read this one
    /// classification, so they agree on what counts as a problem.
    public enum Attention: Sendable {
        /// Nothing to fix: the account has no plan to show, such as a key without a subscription.
        case calm
        /// Likely to clear on its own by the next check.
        case transient
        case actionable
    }

    public var attention: Attention {
        switch self {
        case .noSubscription: .calm
        case .network, .timeout, .rateLimited: .transient
        case .cliNotFound, .notSignedIn, .unauthorized, .parse, .unsupported, .keychainDenied, .cliTooOld: .actionable
        }
    }

    /// Safe for display and notifications: no ids, emails, tokens or raw bodies.
    public var userMessage: String {
        switch self {
        case .cliNotFound(let name): "Can't find the \(name) command on this Mac."
        case .notSignedIn: "Signed out. Sign in again to see limits."
        case .noSubscription(let detail): detail
        case .unauthorized: "The sign-in or API key was rejected."
        case .rateLimited: "Checking too often. Tokenjar waits before the next check."
        case .network: "Can't reach the server. Tokenjar tries again at the next refresh."
        case .timeout: "No answer in time. Tokenjar tries again at the next refresh."
        case .parse: "Couldn't read the usage answer. An update may have changed it."
        case .unsupported(let detail): detail
        case .keychainDenied: "Keychain access was denied. Tokenjar won't ask again on its own."
        case .cliTooOld(let name, let minimum?): "Update \(name) to \(minimum) or later."
        case .cliTooOld(let name, nil): "Update \(name): this version answers in a format Tokenjar can't read."
        }
    }

    /// `userMessage` for a surface that shows one account: a connection failure names the provider, since "the server"
    /// does not say which of several is down, and Claude's signed-out copy also names the routes a shell-only setup
    /// hides (Tokenjar runs claude outside the user's shell, so an API key or cloud switch exported only there reads as
    /// signed out).
    public func userMessage(provider: ProviderID) -> String {
        switch self {
        case .network: return "Can't reach \(provider.displayName). Tokenjar tries again at the next refresh."
        case .timeout: return "No answer from \(provider.displayName) in time. Tokenjar tries again at the next refresh."
        case .notSignedIn where provider == .claude:
            return "Signed out of claude. Sign in again. \(ClaudeUsageFetcher.shellOnlyLoginHint)"
        default: return userMessage
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
    /// Server-side web searches, billed per request on top of tokens.
    public var webSearchRequests: Int
    /// Cost the harness itself recorded (opencode). nil means price it with `PriceTable`.
    public var reportedCostUSD: Double?

    public init(
        dedupeKey: String, timestamp: Date, accountID: String, harness: Harness, model: String, project: String?,
        inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0, reasoningTokens: Int = 0, webSearchRequests: Int = 0, reportedCostUSD: Double? = nil
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
        self.webSearchRequests = webSearchRequests
        self.reportedCostUSD = reportedCostUSD
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// The working directory's last path component, with the home folder itself mapped to "~" so the user's account
    /// name is never stored. nil for a relative path, the root, or no path. Every history scanner goes through this.
    /// On Windows a CLI records a drive path such as `C:\Users\x\repo`, and paths match whatever their case.
    static func project(fromWorkingDirectory cwd: String?, home: URL) -> String? {
        #if os(Windows)
        guard let cwd, cwd.hasPrefix("/") || cwd.dropFirst().hasPrefix(":") else { return nil }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        #else
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        func same(_ a: String, _ b: String) -> Bool { a == b }
        #endif
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
                var parent = url
                for _ in hidden..<parts.count { parent.deleteLastPathComponent() }
                if !same(parent.path, homePath) { url = parent }
            }
        }
        if same(url.path, homePath) { return "~" }
        let last = url.lastPathComponent
        #if os(Windows)
        if url.pathComponents.count <= 2 { return nil }
        #endif
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
    public var unpricedWebSearchRequests: Int

    public init(
        day: Date, accountID: String, harness: Harness, model: String, project: String?, requests: Int,
        inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWrite5mTokens: Int, cacheWrite1hTokens: Int,
        reasoningTokens: Int, reportedCostUSD: Double?, unpricedInputTokens: Int, unpricedOutputTokens: Int,
        unpricedCacheReadTokens: Int, unpricedCacheWrite5mTokens: Int, unpricedCacheWrite1hTokens: Int, unpricedWebSearchRequests: Int = 0
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
        self.unpricedWebSearchRequests = unpricedWebSearchRequests
    }
}
