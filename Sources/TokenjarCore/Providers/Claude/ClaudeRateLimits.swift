import Foundation

/// The `rate_limits` object that `claude -p /usage` prints in its `usage_report` and that Claude Code also caches
/// in `.claude.json` under `cachedUsageUtilization.utilization`. Decoding is lenient per entry so one limit of an
/// unexpected shape does not hide the others.
struct ClaudeRateLimits: Decodable, Sendable {
    var limits: [Limit]
    var extraUsage: ExtraUsage?

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

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case currency
            case decimalPlaces = "decimal_places"
        }
    }

    enum CodingKeys: String, CodingKey {
        case limits
        case extraUsage = "extra_usage"
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
    }

    var windows: [UsageWindow] {
        var seen = Set<String>()
        return limits.map(Self.window).filter { seen.insert($0.id).inserted }
    }

    var money: [MoneyLine] {
        guard let extra = extraUsage, extra.isEnabled == true else { return [] }
        let currency = extra.currency ?? "USD"
        let divisor = pow(10, Double(extra.decimalPlaces ?? Self.minorUnitDigits(currency)))
        return [MoneyLine(label: "Extra usage", amount: (extra.usedCredits ?? 0) / divisor, limit: extra.monthlyLimit.map { $0 / divisor }, currency: currency)]
    }

    /// A seat with no plan limits, billed per use, can only run into its monthly cap on extra usage. Uncapped spend
    /// has no share to show. Spend past the cap is allowed, so the window is `.overage`. The report gives no reset; Claude's own usage page resets the cap at midnight UTC on the
    /// 1st, so the window is the UTC calendar month.
    func spendCapWindow(now: Date) -> UsageWindow? {
        guard limits.isEmpty, let line = money.first, let cap = line.limit, cap > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let resetsAt = calendar.nextDate(after: now, matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0), matchingPolicy: .strict)
        return UsageWindow(
            id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: line.amount / cap * 100,
            windowMinutes: UsageWindow.monthMinutes(endingAt: resetsAt), resetsAt: resetsAt, limitStyle: .overage
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

    /// ISO 4217 minor-unit digits (USD 2, JPY 0, KWD 3). Amounts arrive in minor units of their currency.
    static func minorUnitDigits(_ currency: String) -> Int {
        #if canImport(Darwin)
        var digits: Int32 = 2
        var rounding: Double = 0
        guard CFNumberFormatterGetDecimalInfoForCurrencyCode(currency as CFString, &digits, &rounding) else { return 2 }
        return Int(digits)
        #else
        // swift-corelibs-foundation's NumberFormatter reports 2 digits for every currency, but its formatted output
        // follows ICU's per-currency digits, so count them there.
        let zero = Decimal(0).formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
        guard let point = zero.lastIndex(of: ".") else { return 0 }
        return zero[zero.index(after: point)...].prefix(while: \.isNumber).count
        #endif
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
