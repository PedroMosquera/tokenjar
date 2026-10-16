import Foundation

/// USD per million tokens.
public struct ModelPrice: Codable, Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var source: String
    public var asOf: String

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double, source: String, asOf: String) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.source = source
        self.asOf = asOf
    }

    /// `source` and `asOf` are optional so a hand-written override entry needs only the five prices.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Double.self, forKey: .input)
        output = try c.decode(Double.self, forKey: .output)
        cacheRead = try c.decode(Double.self, forKey: .cacheRead)
        cacheWrite5m = try c.decode(Double.self, forKey: .cacheWrite5m)
        cacheWrite1h = try c.decode(Double.self, forKey: .cacheWrite1h)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf) ?? ""
    }
}

/// A subscription plan's monthly list price in USD.
public struct PlanPrice: Codable, Hashable, Sendable {
    public var monthlyUSD: Double
    public var source: String
    public var asOf: String

    public init(monthlyUSD: Double, source: String, asOf: String) {
        self.monthlyUSD = monthlyUSD
        self.source = source
        self.asOf = asOf
    }

    /// `source` and `asOf` are optional so a hand-written override entry needs only the price.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthlyUSD = try c.decode(Double.self, forKey: .monthlyUSD)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf) ?? ""
    }
}

public struct PricedUsageRow: Hashable, Sendable {
    public var row: DailyUsageRow
    /// Reported cost plus priced tokens; nil when the model has no price and nothing was reported.
    public var costUSD: Double?
    /// True when any part of the cost came from the price table rather than the harness.
    public var isEstimate: Bool

    public init(row: DailyUsageRow, costUSD: Double?, isEstimate: Bool) {
        self.row = row
        self.costUSD = costUSD
        self.isEstimate = isEstimate
    }
}

/// API list prices used to show an "API-equivalent estimate" for tokens whose harness did not record a cost.
/// Keys are lowercase canonical model ids; `aliases` maps other spellings onto them.
public struct PriceTable: Sendable {
    public var prices: [String: ModelPrice]
    public var aliases: [String: String]
    /// Keyed by `ProviderID` raw value, then by the plan name the plan pill shows.
    public var plans: [String: [String: PlanPrice]]

    public init(prices: [String: ModelPrice] = [:], aliases: [String: String] = [:], plans: [String: [String: PlanPrice]] = [:]) {
        self.prices = prices
        self.aliases = aliases
        self.plans = plans
    }

    /// The bundled table overlaid with the user's override file: each model, alias or plan in the override replaces
    /// the bundled entry of the same id whole. A missing or unreadable file contributes nothing.
    public static func load(bundled: URL?, override: URL?) -> PriceTable {
        var table = PriceTable()
        for url in [bundled, override].compactMap(\.self) {
            guard let data = try? Data(contentsOf: url), let file = try? PriceFile.decode(data) else { continue }
            table.prices.merge(file.models) { _, new in new }
            table.aliases.merge(file.aliases ?? [:]) { _, new in new }
            for (provider, plans) in file.plans ?? [:] {
                table.plans[provider, default: [:]].merge(plans) { _, new in new }
            }
        }
        return table
    }

    /// The US monthly list price of `plan` as the plan pill names it; nil for a plan the table does not price.
    public func planPrice(provider: ProviderID, plan: String) -> PlanPrice? {
        plans[provider.rawValue]?[plan]
    }

    /// Exact id, then alias, then the normalized id (and its alias). Any other spelling is unpriced: sharing a priced
    /// prefix says nothing about the price (gpt-5.5-pro costs 6x gpt-5.5), so map such an id with an alias instead.
    public func price(for model: String) -> ModelPrice? {
        lookup(model) ?? lookup(Self.normalize(model))
    }

    /// The model id to record for one request, so that a daily row never mixes two rates of one model.
    /// Returns `model` unchanged unless the model bills every token of a request at a higher rate once its prompt is
    /// over a length; such a request gets that tier's own price table id. `promptTokens` is input plus cache reads and writes.
    public static func billedModel(_ model: String, promptTokens: Int) -> String {
        guard let tier = promptLengthTiers[normalize(model)], promptTokens > tier.over else { return model }
        return tier.model
    }

    /// https://platform.claude.com/docs/en/about-claude/pricing#long-context-pricing
    static let promptLengthTiers: [String: (over: Int, model: String)] = [
        "claude-haiku-5-5": (over: 100_000, model: "claude-haiku-5-5>100k"),
    ]

    public func priced(_ row: DailyUsageRow) -> PricedUsageRow {
        guard let price = price(for: row.model) else {
            return PricedUsageRow(row: row, costUSD: row.reportedCostUSD, isEstimate: false)
        }
        let estimate = (
            Double(row.unpricedInputTokens) * price.input
                + Double(row.unpricedOutputTokens) * price.output
                + Double(row.unpricedCacheReadTokens) * price.cacheRead
                + Double(row.unpricedCacheWrite5mTokens) * price.cacheWrite5m
                + Double(row.unpricedCacheWrite1hTokens) * price.cacheWrite1h
        ) / 1_000_000
        return PricedUsageRow(row: row, costUSD: (row.reportedCostUSD ?? 0) + estimate, isEstimate: estimate != 0)
    }

    /// Lowercases and strips what providers and clouds wrap around a model id: a `vendor/` path,
    /// a Bedrock `[region.]anthropic.` prefix and `-v1:0` suffix, a Vertex `@date` suffix, a `[1m]` context tag,
    /// and a trailing release date (`-20251001` or `-2025-10-01`).
    static func normalize(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if let match = id.prefixMatch(of: #/(?:[a-z]{2,6}\.)?(?:anthropic|openai)\./#) { id.removeSubrange(match.range) }
        if let match = id.wholeMatch(of: #/(.+?)\[[^\]]*\]/#) { id = String(match.1) }
        if let match = id.wholeMatch(of: #/(.+?)@.*/#) { id = String(match.1) }
        if let match = id.wholeMatch(of: #/(.+?)-v\d+:\d+/#) { id = String(match.1) }
        if let match = id.wholeMatch(of: #/(.+?)-(?:\d{8}|\d{4}-\d{2}-\d{2})/#) { id = String(match.1) }
        return id
    }

    private func lookup(_ id: String) -> ModelPrice? {
        prices[id] ?? aliases[id].flatMap { prices[$0] }
    }
}

/// The on-disk format of Resources/pricing.json and the user's override. Unknown keys, such as an entry's `note`, are ignored,
/// and `models` may be left out of an override that only sets plan prices.
struct PriceFile: Decodable {
    var version: Int?
    var currency: String?
    var unit: String?
    var models: [String: ModelPrice]
    var aliases: [String: String]?
    var plans: [String: [String: PlanPrice]]?

    enum CodingKeys: String, CodingKey {
        case version, currency, unit, models, aliases, plans
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        models = try c.decodeIfPresent([String: ModelPrice].self, forKey: .models) ?? [:]
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases)
        plans = try c.decodeIfPresent([String: [String: PlanPrice]].self, forKey: .plans)
    }

    enum FormatError: Error {
        case unsupported
    }

    /// Rejects a file that declares a different version, currency or unit rather than misreading its numbers.
    static func decode(_ data: Data) throws -> PriceFile {
        let file = try JSONDecoder().decode(PriceFile.self, from: data)
        guard (file.version ?? 1) == 1, (file.currency ?? "USD") == "USD", (file.unit ?? "per_million_tokens") == "per_million_tokens" else {
            throw FormatError.unsupported
        }
        return file
    }
}
