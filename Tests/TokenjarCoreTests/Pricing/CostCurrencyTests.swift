import Foundation
import Testing
@testable import TokenjarCore

struct CostCurrencyTests {
    static let rates = ExchangeRates(date: "2026-10-30", perEUR: ["USD": 1.087, "JPY": 162.5, "GBP": 0.84])

    static func row(cost: Double?) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: Date(timeIntervalSince1970: 0), accountID: "claude", harness: .claudeCode, model: "m", project: "p", requests: 1,
            inputTokens: 100, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: 100, unpricedOutputTokens: 0,
            unpricedCacheReadTokens: 0, unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: daily, cost: cost, isEstimate: cost != nil)
    }

    @Test func aMissingRateFallsBackToUSD() {
        let eur = CostCurrency.resolve("EUR", rates: nil)
        #expect(eur.code == "USD")
        #expect(eur.perUSD == 1)
        #expect(eur.awaitingRate)
        #expect(!CostCurrency.resolve("USD", rates: nil).awaitingRate)
    }

    @Test func resolvesWithTheRateAndItsDate() {
        let eur = CostCurrency.resolve("EUR", rates: Self.rates)
        #expect(eur.code == "EUR")
        #expect(eur.rateDate == "2026-10-30")
        #expect(!eur.awaitingRate)
        #expect(abs(eur.amount(100) - 91.9963) < 1e-3)
    }

    @Test func convertedRowsCarryTheCurrencyCode() {
        let eur = CostCurrency.resolve("EUR", rates: Self.rates)
        let input = [Self.row(cost: 10), Self.row(cost: nil)]
        let out = eur.converted(input)
        #expect(abs(out[0].cost! - 9.19963) < 1e-5)
        #expect(out[1].cost == nil)
        #expect(out[0].isEstimate == input[0].isEstimate)
        #expect(out[0].row == input[0].row)
    }

    @Test func theRegionPicksTheDefault() {
        #expect(DisplayCurrency.regionDefault(Locale(identifier: "es_ES")) == "EUR")
        #expect(DisplayCurrency.regionDefault(Locale(identifier: "en_GB")) == "GBP")
        #expect(DisplayCurrency.regionDefault(Locale(identifier: "ja_JP")) == "JPY")
        #expect(DisplayCurrency.regionDefault(Locale(identifier: "pt_BR")) == "USD")
        #expect(DisplayCurrency.regionDefault(Locale(identifier: "en_US")) == "USD")
        #expect(DisplayCurrency.regionDefault(Locale(identifier: "sv_SE")) == "USD")
    }

    @Test func thePickerOffersExactlyTheseCurrenciesInOrder() {
        #expect(DisplayCurrency.supported == ["USD", "EUR", "GBP", "CHF", "JPY", "CAD", "AUD"])
    }

    @Test func aPickWinsOverTheRegion() {
        let spain = Locale(identifier: "es_ES")
        #expect(DisplayCurrency.effective(pick: "USD", locale: spain) == "USD")
        #expect(DisplayCurrency.effective(pick: nil, locale: spain) == "EUR")
        #expect(DisplayCurrency.effective(pick: "XYZ", locale: spain) == "EUR")
    }
}
