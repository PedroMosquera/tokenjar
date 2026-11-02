import Foundation

/// The currency cost estimates are shown in, resolved against the latest rates.
public struct CostCurrency: Hashable, Sendable {
    public let code: String
    public let perUSD: Double
    public let rateDate: String?
    /// True when a non-USD currency was wanted but no rate is cached yet, so amounts are still USD.
    public let awaitingRate: Bool

    public static let usd = CostCurrency(code: "USD", perUSD: 1, rateDate: nil, awaitingRate: false)

    public static func resolve(_ wanted: String, rates: ExchangeRates?) -> CostCurrency {
        if wanted == "USD" { return .usd }
        guard let rates, let perUSD = rates.perUSD(wanted) else {
            return CostCurrency(code: "USD", perUSD: 1, rateDate: nil, awaitingRate: true)
        }
        return CostCurrency(code: wanted, perUSD: perUSD, rateDate: rates.date, awaitingRate: false)
    }

    public func amount(_ usd: Double) -> Double { usd * perUSD }

    public func converted(_ rows: [PricedUsageRow]) -> [PricedUsageRow] {
        rows.map { row in
            var copy = row
            copy.cost = row.cost.map(amount)
            return copy
        }
    }
}

public enum DisplayCurrency {
    /// Currencies the ECB publishes that the picker offers.
    public static let supported = ["USD", "EUR", "GBP", "CHF", "JPY", "CAD", "AUD"]

    public static func regionDefault(_ locale: Locale) -> String {
        guard let code = locale.currency?.identifier, supported.contains(code) else { return "USD" }
        return code
    }

    public static func effective(pick: String?, locale: Locale) -> String {
        if let pick, supported.contains(pick) { return pick }
        return regionDefault(locale)
    }

    /// ISO 4217 minor-unit digits (USD 2, JPY 0, KWD 3).
    public static func minorUnitDigits(_ currency: String) -> Int {
        var digits: Int32 = 2
        var rounding: Double = 0
        guard CFNumberFormatterGetDecimalInfoForCurrencyCode(currency as CFString, &digits, &rounding) else { return 2 }
        return Int(digits)
    }
}
