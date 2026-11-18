import Foundation

/// The `rate_limits` object that `claude -p /usage` prints in its `usage_report` and that Claude Code also caches
/// in `.claude.json` under `cachedUsageUtilization.utilization`. Decoding is lenient per entry so one limit of an
/// unexpected shape does not hide the others.
struct ClaudeRateLimits: Decodable, Sendable {
    var limits: [Limit]
    var extraUsage: ExtraUsage?
    /// Prepaid credits left, from `spend.balance`. Seen only as null so far; the shapes accepted are guesses.
    var creditBalance: Money?

    struct Limit: Sendable {
        var kind: String
        var percent: Double
        var resetsAt: Date?
        var scopeName: String?
    }

    struct ExtraUsage: Decodable, Sendable {
        var isEnabled: Bool?
        var monthlyLimit: Double?
        var usedCredits: Double?
        var currency: String?
        var decimalPlaces: Int?
        var spendLimitReached: Bool?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case currency
            case decimalPlaces = "decimal_places"
            case spendLimitReached = "spend_limit_reached"
        }
    }

    /// `{"amount_minor": 1234, "currency": "EUR", "exponent": 2}`, the shape Claude Code 2026-11 caches for `spend.used`.
    struct Money: Decodable, Sendable {
        var amountMinor: Double
        var currency: String
        var exponent: Int?

        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case currency, exponent
        }

        var amount: Double { amountMinor / pow(10, Double(exponent ?? DisplayCurrency.minorUnitDigits(currency))) }
    }

    enum CodingKeys: String, CodingKey {
        case limits, spend
        case extraUsage = "extra_usage"
    }

    private struct Spend: Decodable {
        var balance: Money?

        enum CodingKeys: String, CodingKey { case balance }

        /// `spend.cap` wraps its amount as `{"money": {...}}`, so a balance may come either way.
        private struct Wrapped: Decodable { var money: Money? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            balance = (try? c.decodeIfPresent(Money.self, forKey: .balance)) ?? (try? c.decodeIfPresent(Wrapped.self, forKey: .balance))?.money
        }
    }

    init(limits: [Limit], extraUsage: ExtraUsage?) {
        self.limits = limits
        self.extraUsage = extraUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([Lenient<RawLimit>].self, forKey: .limits)) ?? []
        limits = raw.compactMap { $0.value?.limit }
        extraUsage = try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        creditBalance = (try? c.decodeIfPresent(Spend.self, forKey: .spend))?.balance
    }

    var windows: [UsageWindow] {
        var seen = Set<String>()
        return coveredByCredits(limits.map(Self.window).filter { seen.insert($0.id).inserted })
    }

    /// Plan limits that extra usage takes over at 100 %, while it is on and its monthly cap has room.
    func coveredByCredits(_ windows: [UsageWindow]) -> [UsageWindow] {
        guard let extra = extraUsage, extra.isEnabled == true, !capReached else { return windows }
        return windows.map { window in
            var window = window
            window.limitStyle = .credits
            return window
        }
    }

    private var capReached: Bool {
        guard let extra = extraUsage else { return false }
        if extra.spendLimitReached == true { return true }
        if let balance = creditBalance, balance.amount <= 0 { return true }
        guard let used = extra.usedCredits, let cap = extra.monthlyLimit, cap > 0 else { return false }
        return used >= cap
    }

    var money: [MoneyLine] {
        var lines: [MoneyLine] = []
        if let extra = extraUsage, extra.isEnabled == true {
            let currency = extra.currency ?? "USD"
            let divisor = pow(10, Double(extra.decimalPlaces ?? DisplayCurrency.minorUnitDigits(currency)))
            lines.append(MoneyLine(label: "Extra usage", amount: (extra.usedCredits ?? 0) / divisor, limit: extra.monthlyLimit.map { $0 / divisor }, currency: currency))
        }
        if let balance = creditBalance {
            lines.append(MoneyLine(label: "Credit balance", amount: balance.amount, currency: balance.currency))
        }
        return lines
    }

    /// The monthly cap as a bar for the UTC calendar month (Claude's usage page resets it at midnight UTC on the 1st).
    /// A seat billed per use may pass it (`.overage`). On a plan it shows once credits are in play, and it is hard only
    /// while a plan limit is full: then the cap is what stops the work. Otherwise it caps extras beside the plan.
    func spendCapWindow(now: Date, planWindows: [UsageWindow]) -> UsageWindow? {
        guard let line = money.first, let cap = line.limit, cap > 0 else { return nil }
        let onPlan = !planWindows.isEmpty
        let planFull = planWindows.contains { $0.usedPercent >= 100 }
        if onPlan, line.amount <= 0, !planFull { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let resetsAt = calendar.nextDate(after: now, matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0), matchingPolicy: .strict)
        let used = line.amount / cap * 100
        return UsageWindow(
            id: UsageWindow.spendCapID, label: onPlan ? "Extra usage" : "Spend limit",
            usedPercent: extraUsage?.spendLimitReached == true ? max(used, 100) : used,
            windowMinutes: UsageWindow.monthMinutes(endingAt: resetsAt), resetsAt: resetsAt, limitStyle: onPlan ? (planFull ? nil : .extras) : .overage
        )
    }

    static func window(_ limit: Limit) -> UsageWindow {
        switch (limit.kind, limit.scopeName) {
        case ("session", _):
            UsageWindow(id: "session", label: "5-hour", usedPercent: limit.percent, windowMinutes: 300, resetsAt: limit.resetsAt)
        case ("weekly_all", _):
            UsageWindow(id: "weekly", label: "Week", usedPercent: limit.percent, windowMinutes: 10_080, resetsAt: limit.resetsAt)
        case ("weekly_scoped", let name?):
            UsageWindow(id: "weekly:\(name)", label: "Week · \(name)", usedPercent: limit.percent, windowMinutes: 10_080, resetsAt: limit.resetsAt)
        case (let kind, let name):
            UsageWindow(
                id: name.map { "\(kind):\($0)" } ?? kind,
                label: ([readable(kind)] + [name].compactMap { $0 }).joined(separator: " · "),
                usedPercent: limit.percent, windowMinutes: nil, resetsAt: limit.resetsAt
            )
        }
    }

    /// "monthly_all" -> "Monthly all".
    static func readable(_ kind: String) -> String {
        let words = kind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private struct RawLimit: Decodable {
        var kind: String
        var percent: Double?
        var resetsAt: String?
        var scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
            scope = try? c.decodeIfPresent(Scope.self, forKey: .scope)
        }

        var limit: Limit? {
            guard let percent else { return nil }
            return Limit(kind: kind, percent: percent, resetsAt: resetsAt.flatMap(DateParsing.iso8601), scopeName: scope?.name)
        }
    }

    private struct Scope: Decodable {
        var model: Named?
        var surface: Named?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try? c.decodeIfPresent(Named.self, forKey: .model)
            surface = try? c.decodeIfPresent(Named.self, forKey: .surface)
        }

        enum CodingKeys: String, CodingKey { case model, surface }

        var name: String? { model?.displayName ?? surface?.displayName }
    }

    private struct Named: Decodable {
        var displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    /// Decodes `T` or yields nil, so one malformed array element does not fail the whole array.
    private struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
