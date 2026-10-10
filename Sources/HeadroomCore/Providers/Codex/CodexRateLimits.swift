import Foundation

/// One rate limit bucket as codex reports it. The same type decodes the app-server's camelCase result and,
/// with `.convertFromSnakeCase`, the `rate_limits` object of a rollout `token_count` event.
/// Every field is optional and decoded leniently: an unexpected type drops that field, not the response.
struct CodexRateLimitSnapshot: Decodable, Sendable, Equatable {
    struct Window: Decodable, Sendable, Equatable {
        var usedPercent: Double?
        /// The app-server's spelling.
        var windowDurationMins: Int?
        /// The rollout log's spelling (`window_minutes`).
        var windowMinutes: Int?
        /// Epoch seconds.
        var resetsAt: Double?

        var minutes: Int? { windowDurationMins ?? windowMinutes }

        init(usedPercent: Double?, windowDurationMins: Int? = nil, windowMinutes: Int? = nil, resetsAt: Double?) {
            self.usedPercent = usedPercent
            self.windowDurationMins = windowDurationMins
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = c.codexLenient(Double.self, .usedPercent)
            windowDurationMins = c.codexLenient(Int.self, .windowDurationMins)
            windowMinutes = c.codexLenient(Int.self, .windowMinutes)
            resetsAt = c.codexLenient(Double.self, .resetsAt)
        }

        private enum CodingKeys: String, CodingKey {
            case usedPercent, windowDurationMins, windowMinutes, resetsAt
        }
    }

    struct Credits: Decodable, Sendable, Equatable {
        var hasCredits: Bool?
        var unlimited: Bool?
        /// A string in both formats; credits are not dollars.
        var balance: CodexNumber?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = c.codexLenient(Bool.self, .hasCredits)
            unlimited = c.codexLenient(Bool.self, .unlimited)
            balance = c.codexLenient(CodexNumber.self, .balance)
        }

        private enum CodingKeys: String, CodingKey {
            case hasCredits, unlimited, balance
        }
    }

    /// Workspace per-user spend cap. Its field names are unverified (no workspace login to check against), so
    /// several spellings are accepted.
    struct SpendCap: Decodable, Sendable, Equatable {
        var limit: CodexNumber?
        var used: CodexNumber?
        var remaining: CodexNumber?
        var usedPercent: Double?
        var remainingPercent: Double?
        var resetsAt: Date?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limit = c.codexLenient(CodexNumber.self, .limit)
            used = c.codexLenient(CodexNumber.self, .used)
            remaining = c.codexLenient(CodexNumber.self, .remaining)
            usedPercent = c.codexLenient(Double.self, .usedPercent)
            remainingPercent = c.codexLenient(Double.self, .remainingPercent)
            resetsAt = (c.codexLenient(CodexTimestamp.self, .resetsAt) ?? c.codexLenient(CodexTimestamp.self, .resetAt))?.date
        }

        var percentUsed: Double? {
            if let usedPercent { return usedPercent }
            if let remainingPercent { return 100 - remainingPercent }
            if let used = used?.value, let limit = limit?.value, limit > 0 { return used / limit * 100 }
            if let remaining = remaining?.value, let limit = limit?.value, limit > 0 { return (limit - remaining) / limit * 100 }
            return nil
        }

        private enum CodingKeys: String, CodingKey {
            case limit, used, remaining, usedPercent, remainingPercent, resetsAt, resetAt
        }
    }

    var limitId: String?
    var limitName: String?
    var primary: Window?
    var secondary: Window?
    var credits: Credits?
    var individualLimit: SpendCap?
    var planType: String?

    init(limitId: String?, limitName: String? = nil, primary: Window?, secondary: Window?, planType: String? = nil) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limitId = c.codexLenient(String.self, .limitId)
        limitName = c.codexLenient(String.self, .limitName)
        primary = c.codexLenient(Window.self, .primary)
        secondary = c.codexLenient(Window.self, .secondary)
        credits = c.codexLenient(Credits.self, .credits)
        individualLimit = c.codexLenient(SpendCap.self, .individualLimit)
        planType = c.codexLenient(String.self, .planType)
    }

    private enum CodingKeys: String, CodingKey {
        case limitId, limitName, primary, secondary, credits, individualLimit, planType
    }
}

/// The `result` of `account/rateLimits/read`. `accountId` is deliberately not decoded.
struct CodexRateLimitsResult: Decodable, Sendable, Equatable {
    var rateLimits: CodexRateLimitSnapshot?
    var rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?

    init(rateLimits: CodexRateLimitSnapshot?, rateLimitsByLimitId: [String: CodexRateLimitSnapshot]? = nil) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = c.codexLenient(CodexRateLimitSnapshot.self, .rateLimits)
        rateLimitsByLimitId = c.codexLenient([String: CodexRateLimitSnapshot].self, .rateLimitsByLimitId)
    }

    private enum CodingKeys: String, CodingKey {
        case rateLimits, rateLimitsByLimitId
    }
}

/// A number that codex may send as a JSON number or as a numeric string.
struct CodexNumber: Decodable, Sendable, Equatable {
    var value: Double

    init(_ value: Double) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self) {
            value = number
        } else if let text = try? c.decode(String.self), let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number")
        }
    }

    /// "12", "12.5", "0.25": at most two decimals, no trailing zeros.
    var formatted: String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// Epoch seconds or milliseconds, or an ISO-8601 string.
struct CodexTimestamp: Decodable, Sendable {
    var date: Date

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self) {
            date = DateParsing.epoch(number)
        } else if let text = try? c.decode(String.self), let parsed = DateParsing.iso8601(text) {
            date = parsed
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a timestamp")
        }
    }
}

extension KeyedDecodingContainer {
    func codexLenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Turns codex rate limits into Headroom windows. Windows are keyed by their duration, never by
/// primary/secondary position, because some plans (Pro) report no 5-hour window at all.
enum CodexRateLimitMapping {
    static let mainLimitID = "codex"
    /// The backend reports an idle window's reset as now + window length; allow this much clock skew.
    static let notStartedTolerance: TimeInterval = 120

    static func snapshot(
        from result: CodexRateLimitsResult, accountID: String, fetchedAt: Date, source: String
    ) -> UsageSnapshot? {
        let byID = result.rateLimitsByLimitId ?? [:]
        guard let main = result.rateLimits ?? byID[mainLimitID] else { return nil }
        let mainID = main.limitId ?? mainLimitID

        var windows = self.windows(main, extraLimitID: nil, now: fetchedAt)
        for (limitID, limits) in byID.sorted(by: { $0.key < $1.key }) where limitID != mainID && limitID != mainLimitID {
            windows += self.windows(limits, extraLimitID: limitID, now: fetchedAt)
        }

        var notes: [String] = []
        if let cap = main.individualLimit {
            if let used = cap.percentUsed {
                windows.append(UsageWindow(id: "spend-cap", label: "Spend cap", usedPercent: used, resetsAt: cap.resetsAt))
            }
            if let used = cap.used, let limit = cap.limit {
                notes.append("Spend cap: \(used.formatted) of \(limit.formatted) used")
            } else if let remaining = cap.remaining {
                notes.append("Spend cap: \(remaining.formatted) remaining")
            }
        }
        if let note = creditsNote(main.credits) { notes.append(note) }

        let plan = (main.planType ?? byID.values.compactMap(\.planType).first).map(planLabel)
        return UsageSnapshot(
            accountID: accountID, provider: .codex, plan: plan, windows: windows,
            fetchedAt: fetchedAt, source: source, notes: notes
        )
    }

    static func windows(_ limits: CodexRateLimitSnapshot, extraLimitID: String?, now: Date) -> [UsageWindow] {
        [("primary", limits.primary), ("secondary", limits.secondary)].compactMap { slot, window in
            guard let window, let used = window.usedPercent else { return nil }
            let minutes = window.minutes
            let identity = windowIdentity(minutes: minutes, slot: slot)
            let resetsAt = window.resetsAt.map(DateParsing.epoch)
            var id = identity.id, label = identity.label
            if let extraLimitID {
                id = "\(extraLimitID):\(identity.id)"
                label = "\(limits.limitName ?? extraLimitID) · \(identity.label)"
            }
            return UsageWindow(
                id: id, label: label, usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt,
                notStarted: isNotStarted(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt, now: now)
            )
        }
    }

    static func windowIdentity(minutes: Int?, slot: String) -> (id: String, label: String) {
        guard let minutes, minutes > 0 else { return (slot, "Limit") }
        switch minutes {
        case 300: return ("session", "5-hour")
        case 10_080: return ("weekly", "Week")
        default:
            let label = if minutes % 1_440 == 0 {
                "\(minutes / 1_440)-day"
            } else if minutes % 60 == 0 {
                "\(minutes / 60)-hour"
            } else {
                "\(minutes)-minute"
            }
            return ("\(minutes)m", label)
        }
    }

    static func isNotStarted(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?, now: Date) -> Bool {
        guard usedPercent == 0, let windowMinutes, windowMinutes > 0, let resetsAt else { return false }
        let syntheticReset = now.addingTimeInterval(Double(windowMinutes) * 60)
        return abs(resetsAt.timeIntervalSince(syntheticReset)) <= notStartedTolerance
    }

    static func creditsNote(_ credits: CodexRateLimitSnapshot.Credits?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited == true { return "Credits: unlimited" }
        guard credits.hasCredits == true, let balance = credits.balance else { return nil }
        return "Credits: \(balance.formatted)"
    }

    static func planLabel(_ planType: String) -> String {
        let plan = planType.lowercased()
        switch plan {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "business", "team": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default:
            if plan.hasPrefix("edu") { return "Edu" }
            return plan.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
}
