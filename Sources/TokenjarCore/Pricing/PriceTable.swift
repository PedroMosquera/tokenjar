import Foundation

/// USD per million tokens, and per 1,000 server-side web searches.
public struct ModelPrice: Codable, Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    /// nil leaves a row's web searches unpriced.
    public var webSearchPer1k: Double?
    public var source: String
    public var asOf: String

    public init(
        input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double, webSearchPer1k: Double? = nil,
        source: String, asOf: String
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.webSearchPer1k = webSearchPer1k
        self.source = source
        self.asOf = asOf
    }

    /// `webSearchPer1k`, `source` and `asOf` are optional so a hand-written override entry needs only the five token prices.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Double.self, forKey: .input)
        output = try c.decode(Double.self, forKey: .output)
        cacheRead = try c.decode(Double.self, forKey: .cacheRead)
        cacheWrite5m = try c.decode(Double.self, forKey: .cacheWrite5m)
        cacheWrite1h = try c.decode(Double.self, forKey: .cacheWrite1h)
        webSearchPer1k = try c.decodeIfPresent(Double.self, forKey: .webSearchPer1k)
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

    public init(prices: [String: ModelPrice] = [:], aliases: [String: String] = [:]) {
        self.prices = prices
        self.aliases = aliases
    }

    /// The bundled table overlaid with the user's override file: each model or alias in the override replaces
    /// the bundled entry of the same id whole. A missing or unreadable file contributes nothing.
    public static func load(bundled: URL?, override: URL?) -> PriceTable {
        var table = PriceTable()
        for url in [bundled, override].compactMap(\.self) {
            guard let data = try? Data(contentsOf: url), let file = try? PriceFile.decode(data) else { continue }
            table.prices.merge(file.models) { _, new in new }
            table.aliases.merge(file.aliases ?? [:]) { _, new in new }
        }
        return table
    }

    /// Exact id, then alias, then the normalized id (and its alias). Any other spelling is unpriced: sharing a priced
    /// prefix says nothing about the price (gpt-5.5-pro costs 6x gpt-5.5), so map such an id with an alias instead.
    public func price(for model: String) -> ModelPrice? {
        lookup(model) ?? lookup(Self.normalize(model))
    }

    /// The model id to record for one request, so that a daily row never mixes two rates of one model.
    /// A fast mode request becomes `<normalized id>+fast`, since fast mode has its own rates across the whole context window.
    /// Otherwise returns `model` unchanged unless the model bills every token of a request at a higher rate once its prompt
    /// is over a length; such a request gets that tier's own price table id. `promptTokens` is input plus cache reads and writes.
    public static func billedModel(_ model: String, promptTokens: Int, fast: Bool = false) -> String {
        if fast { return normalize(model) + fastModeSuffix }
        guard let tier = promptLengthTiers[normalize(model)], promptTokens > tier.over else { return model }
        return tier.model
    }

    /// https://platform.claude.com/docs/en/about-claude/pricing#long-context-pricing
    static let promptLengthTiers: [String: (over: Int, model: String)] = [
        "claude-haiku-5-5": (over: 100_000, model: "claude-haiku-5-5>100k"),
    ]

    /// https://platform.claude.com/docs/en/about-claude/pricing#fast-mode-pricing
    static let fastModeSuffix = "+fast"

    public func priced(_ row: DailyUsageRow) -> PricedUsageRow {
        guard let price = price(for: row.model) else {
            return PricedUsageRow(row: row, costUSD: row.reportedCostUSD, isEstimate: false)
        }
        let tokens = (
            Double(row.unpricedInputTokens) * price.input
                + Double(row.unpricedOutputTokens) * price.output
                + Double(row.unpricedCacheReadTokens) * price.cacheRead
                + Double(row.unpricedCacheWrite5mTokens) * price.cacheWrite5m
                + Double(row.unpricedCacheWrite1hTokens) * price.cacheWrite1h
        ) / 1_000_000
        let estimate = tokens + Double(row.unpricedWebSearchRequests) * (price.webSearchPer1k ?? 0) / 1_000
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

/// The on-disk format of Resources/pricing.json and the user's override. Unknown keys, such as an entry's `note`, are ignored.
struct PriceFile: Decodable {
    var version: Int?
    var currency: String?
    var unit: String?
    var models: [String: ModelPrice]
    var aliases: [String: String]?

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
