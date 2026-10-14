import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct MonthCostLineTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 2026-10-10 15:30 in New York.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 30))!
    let locale = Locale(identifier: "en_US")

    func day(_ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    func row(_ day: Date, cost: Double?) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: day, accountID: "claude", harness: .claudeCode, model: "m", project: "p", requests: 1,
            inputTokens: 100, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: 100, unpricedOutputTokens: 0,
            unpricedCacheReadTokens: 0, unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: daily, costUSD: cost, isEstimate: cost != nil)
    }

    func snapshot(billing: Billing?) -> UsageSnapshot {
        UsageSnapshot(accountID: "claude", provider: .claude, billing: billing, fetchedAt: now, source: "test")
    }

    func text(_ billing: Billing?, _ rows: [PricedUsageRow]) -> String? {
        MonthCostLine.text(snapshot: snapshot(billing: billing), rows: rows, now: now, calendar: Self.calendar, locale: locale)
    }

    @Test func aPayAsYouGoLoginShowsThisMonthsEstimate() {
        let rows = [row(day(10, 1), cost: 4.5), row(day(10, 10), cost: 7.9), row(day(9, 30), cost: 100)]
        #expect(text(.payAsYouGo, rows) == "$12.40 this month, estimate at list price")
    }

    @Test func aPlanLoginShowsNoCostLine() {
        #expect(text(nil, [row(day(10, 1), cost: 4.5)]) == nil)
        #expect(text(.subscription, [row(day(10, 1), cost: 4.5)]) == nil)
    }

    @Test func aMonthWithoutUsageSaysSo() {
        #expect(text(.payAsYouGo, [row(day(9, 30), cost: 3)]) == "No usage logged this month")
    }

    @Test func unpricedModelsAreNamedNotCountedAsFree() {
        #expect(text(.payAsYouGo, [row(day(10, 2), cost: 2), row(day(10, 3), cost: nil)])
            == "$2 this month, estimate at list price, some models unpriced")
        #expect(text(.payAsYouGo, [row(day(10, 3), cost: nil)]) == "No list price for the models used this month")
    }
}
