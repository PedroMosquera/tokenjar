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

public struct PriceTable: Sendable {
    public var prices: [String: ModelPrice]

    public init(prices: [String: ModelPrice] = [:]) {
        self.prices = prices
    }

    /// Bundled table overlaid with the user's override file, entry by entry.
    public static func load(bundled: URL?, override: URL?) -> PriceTable { PriceTable() }

    public func price(for model: String) -> ModelPrice? { nil }

    public func priced(_ row: DailyUsageRow) -> PricedUsageRow {
        PricedUsageRow(row: row, costUSD: row.reportedCostUSD, isEstimate: false)
    }
}
