import Foundation

/// The few fields Tokenjar needs from Claude Code's global config (`.claude.json`). Identity fields are decoded
/// only to check that the usage cache belongs to the signed-in account; they are private and never leave this type.
struct ClaudeGlobalConfig: Decodable, Sendable {
    private var oauthAccount: OAuthAccount?
    private var cachedUsageUtilization: CachedUsage?

    private enum CodingKeys: String, CodingKey { case oauthAccount, cachedUsageUtilization }

    /// Keys decode independently: a shape change in the undocumented usage cache must not also lose the account,
    /// which carries the plan label and sign-in detection.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        oauthAccount = try? c.decodeIfPresent(OAuthAccount.self, forKey: .oauthAccount)
        cachedUsageUtilization = try? c.decodeIfPresent(CachedUsage.self, forKey: .cachedUsageUtilization)
    }

    /// `<configDir>/.config.json` (legacy) wins over `.claude.json`. Without a profile dir the global file is
    /// `~/.claude.json`, outside `~/.claude`.
    static func file(configDir: URL?, home: URL) -> URL {
        let legacy = (configDir ?? home.appending(path: ".claude")).appending(path: ".config.json")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return (configDir ?? home).appending(path: ".claude.json")
    }

    /// nil when the file is missing or unreadable. Running Claude Code processes rewrite it often, so a parse
    /// failure is retried once before giving up.
    static func load(configDir: URL?, home: URL) -> ClaudeGlobalConfig? {
        let url = file(configDir: configDir, home: home)
        for _ in 0..<2 {
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let config = try? JSONDecoder().decode(ClaudeGlobalConfig.self, from: data) { return config }
        }
        return nil
    }

    var isSignedIn: Bool { oauthAccount != nil }

    var plan: String? { oauthAccount.flatMap(Self.planLabel) }

    /// Subscription plans that always carry session and weekly limits. A run that reports none for these failed
    /// to load them; it does not mean the login has no limits.
    var planHasLimits: Bool {
        switch oauthAccount?.organizationType {
        case "claude_max", "claude_pro", "claude_team": true
        default: false
        }
    }

    /// The last limits Claude Code itself fetched, when they belong to the signed-in account. Windows whose reset
    /// has already passed are dropped: their percentage describes a window that no longer exists.
    func cachedLimits(now: Date) -> (windows: [UsageWindow], money: [MoneyLine], fetchedAt: Date)? {
        guard let cache = cachedUsageUtilization, let accountID = oauthAccount?.accountUuid,
              cache.accountUuid == accountID, let fetchedAtMs = cache.fetchedAtMs, let utilization = cache.utilization
        else { return nil }
        let windows = utilization.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
        guard !windows.isEmpty else { return nil }
        return (windows, utilization.rateLimits.money, Date(timeIntervalSince1970: fetchedAtMs / 1000))
    }

    static func planLabel(_ account: OAuthAccount) -> String? {
        if account.seatTier == "enterprise_usage_based" { return "Enterprise (usage-based)" }
        let tiers = [account.userRateLimitTier, account.organizationRateLimitTier].compactMap { $0 }
        switch account.organizationType {
        case "claude_max":
            if tiers.contains(where: { $0.hasSuffix("max_20x") }) { return "Max 20x" }
            if tiers.contains(where: { $0.hasSuffix("max_5x") }) { return "Max 5x" }
            return "Max"
        case "claude_pro":
            return "Pro"
        case "claude_team":
            return tiers.contains("default_claude_max_5x") ? "Team Premium" : "Team"
        case "claude_enterprise":
            return "Enterprise"
        default:
            return nil
        }
    }

    struct OAuthAccount: Decodable, Sendable {
        fileprivate var accountUuid: String?
        var organizationType: String?
        var organizationRateLimitTier: String?
        var userRateLimitTier: String?
        var seatTier: String?

        init(organizationType: String?, organizationRateLimitTier: String? = nil, userRateLimitTier: String? = nil, seatTier: String? = nil) {
            self.organizationType = organizationType
            self.organizationRateLimitTier = organizationRateLimitTier
            self.userRateLimitTier = userRateLimitTier
            self.seatTier = seatTier
        }
    }

    private struct CachedUsage: Decodable, Sendable {
        var fetchedAtMs: Double?
        var accountUuid: String?
        var utilization: Utilization?
    }

    /// Prefers `limits[]`; older caches only have the per-window buckets.
    private struct Utilization: Decodable, Sendable {
        var rateLimits: ClaudeRateLimits
        var buckets: [String: Bucket]

        init(from decoder: Decoder) throws {
            rateLimits = try ClaudeRateLimits(from: decoder)
            let c = try decoder.container(keyedBy: BucketKey.self)
            var buckets: [String: Bucket] = [:]
            for key in BucketKey.allCases {
                if let bucket = try? c.decodeIfPresent(Bucket.self, forKey: key) { buckets[key.rawValue] = bucket }
            }
            self.buckets = buckets
        }

        var windows: [UsageWindow] {
            if !rateLimits.limits.isEmpty { return rateLimits.windows }
            return BucketKey.allCases.compactMap { key in
                guard let bucket = buckets[key.rawValue], let used = bucket.utilization else { return nil }
                let limit = ClaudeRateLimits.Limit(kind: key.kind, percent: used, resetsAt: bucket.resetsAt.flatMap(DateParsing.iso8601), scopeName: key.model)
                return ClaudeRateLimits.window(limit)
            }
        }
    }

    private enum BucketKey: String, CodingKey, CaseIterable {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"

        var kind: String {
            switch self {
            case .fiveHour: "session"
            case .sevenDay: "weekly_all"
            case .sevenDayOpus, .sevenDaySonnet: "weekly_scoped"
            }
        }

        var model: String? {
            switch self {
            case .fiveHour, .sevenDay: nil
            case .sevenDayOpus: "Opus"
            case .sevenDaySonnet: "Sonnet"
            }
        }
    }

    private struct Bucket: Decodable, Sendable {
        var utilization: Double?
        var resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

/// Claude Code routes to Bedrock, Vertex or Foundry when these are set in its settings `env`. Such logins have
/// no subscription limits and no `oauthAccount`, which otherwise looks the same as being signed out.
struct ClaudeProviderSettings: Decodable, Sendable {
    private var env: Env?

    static func load(configDir: URL?, home: URL) -> ClaudeProviderSettings? {
        let url = (configDir ?? home.appending(path: ".claude")).appending(path: "settings.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeProviderSettings.self, from: data)
    }

    var usesThirdPartyProvider: Bool { env?.thirdParty ?? false }

    private struct Env: Decodable, Sendable {
        var thirdParty = false

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            thirdParty = Key.allCases.contains { key in
                guard let value = try? c.decodeIfPresent(String.self, forKey: key) else { return false }
                return ["1", "true"].contains(value.lowercased())
            }
        }

        enum Key: String, CodingKey, CaseIterable {
            case bedrock = "CLAUDE_CODE_USE_BEDROCK"
            case vertex = "CLAUDE_CODE_USE_VERTEX"
            case foundry = "CLAUDE_CODE_USE_FOUNDRY"
        }
    }
}
