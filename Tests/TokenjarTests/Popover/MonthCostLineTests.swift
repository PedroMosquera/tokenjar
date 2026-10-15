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

    func text(_ billing: Billing?, _ rows: [PricedUsageRow], now: Date? = nil) -> MonthCostLine.Lines? {
        MonthCostLine.text(snapshot: snapshot(billing: billing), rows: rows, now: now ?? self.now, calendar: Self.calendar, locale: locale)
    }

    @Test func aPayAsYouGoLoginShowsThisMonthTodayAndWhereTheMonthIsHeaded() {
        let rows = [row(day(10, 1), cost: 4.5), row(day(10, 10), cost: 7.9), row(day(9, 30), cost: 100)]
        // 9 days 15.5 hours of October's 31 days have passed: $12.40 at that rate is about $40 by the 31st.
        #expect(text(.payAsYouGo, rows) == MonthCostLine.Lines(
            amounts: "$12.40 this month · $7.90 today", detail: "On pace for ~$40 this month, estimate at list price"
        ))
    }

    @Test func aDayWithoutUsageLeavesTodayOut() {
        #expect(text(.payAsYouGo, [row(day(10, 1), cost: 4.5)])?.amounts == "$4.50 this month")
    }

    /// Too little of the month has passed for a rate to mean anything, as with the bars' pace.
    @Test func theFirstHoursOfAMonthMakeNoProjection() {
        let early = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10))!
        #expect(text(.payAsYouGo, [row(day(10, 1), cost: 3)], now: early) == MonthCostLine.Lines(
            amounts: "$3 this month · $3 today", detail: "Estimate at list price"
        ))
    }

    @Test func aPlanLoginShowsNoCostLine() {
        #expect(text(nil, [row(day(10, 1), cost: 4.5)]) == nil)
        #expect(text(.subscription, [row(day(10, 1), cost: 4.5)]) == nil)
    }

    @Test func aMonthWithoutUsageSaysSo() {
        #expect(text(.payAsYouGo, [row(day(9, 30), cost: 3)]) == MonthCostLine.Lines(amounts: "No usage logged this month", detail: nil))
    }

    @Test func unpricedModelsAreNamedNotCountedAsFree() {
        #expect(text(.payAsYouGo, [row(day(10, 2), cost: 2), row(day(10, 3), cost: nil)])?.detail
            == "On pace for ~$6 this month, estimate at list price, some models unpriced")
        #expect(text(.payAsYouGo, [row(day(10, 3), cost: nil)]) == MonthCostLine.Lines(
            amounts: "No list price for the models used this month", detail: nil
        ))
    }

    /// The cost line already says the login is billed per use, so the note saying it has no plan limits repeats it.
    @Test func theCostLineReplacesTheNoLimitsNote() {
        let notes = [ClaudeUsageFetcher.noLimitsNote, "Other note"]
        #expect(MonthCostLine.notes(notes, besideCostLine: true) == ["Other note"])
        #expect(MonthCostLine.notes(notes, besideCostLine: false) == notes)
    }
}
