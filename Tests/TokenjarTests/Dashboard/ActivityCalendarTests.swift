import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct ActivityCalendarTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    static let en = Locale(identifier: "en_US")

    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func row(_ day: Date, requests: Int = 1, tokens: Int = 100, cost: Double?) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: day, accountID: "a", harness: .claudeCode, model: "m", project: "p", requests: requests,
            inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: tokens, unpricedOutputTokens: 0,
            unpricedCacheReadTokens: 0, unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: daily, costUSD: cost, isEstimate: cost != nil)
    }

    /// Saturday 2026-10-10 sits in the week from Sunday the 4th; 52 weeks before that is Sunday 2025-10-05.
    @Test func theFirstColumnStartsFiftyTwoWeeksBeforeThisWeek() {
        #expect(ActivityCalendar.firstDay(today: date(2026, 10, 10), calendar: Self.calendar) == date(2025, 10, 5))
        var monday = Self.calendar
        monday.firstWeekday = 2
        #expect(ActivityCalendar.firstDay(today: date(2026, 10, 10), calendar: monday) == date(2025, 10, 6))
    }

    @Test func weeksAreColumnsOfSevenDaysEndingToday() {
        let activity = ActivityCalendar.make([], today: date(2026, 10, 7), calendar: Self.calendar, weeks: 2)
        #expect(activity.weeks.map(\.count) == [7, 4])
        #expect(activity.weeks.first?.first?.date == date(2026, 9, 27))
        #expect(activity.weeks.last?.last?.date == date(2026, 10, 7))
    }

    @Test func eachDaySumsItsRowsAndRowsBeforeTheFirstColumnAreLeftOut() throws {
        let rows = [
            row(date(2026, 10, 5), tokens: 100, cost: 2),
            row(date(2026, 10, 5), requests: 2, tokens: 50, cost: 3),
            row(date(2026, 10, 6), tokens: 70, cost: nil),
            row(date(2026, 10, 8), requests: 0, tokens: 0, cost: nil),
            row(date(2026, 9, 1), tokens: 999, cost: 99),
        ]
        let activity = ActivityCalendar.make(rows, today: date(2026, 10, 10), calendar: Self.calendar, weeks: 2)
        let days = activity.weeks.flatMap { $0 }
        let fifth = try #require(days.first { $0.date == date(2026, 10, 5) })
        #expect(fifth.cost == 5)
        #expect(fifth.tokens == 150)
        #expect(fifth.requests == 3)
        let sixth = try #require(days.first { $0.date == date(2026, 10, 6) })
        #expect(sixth.cost == nil)
        #expect(sixth.hasUsage)
        #expect(!(days.first { $0.date == date(2026, 10, 8) }?.hasUsage ?? true))
        #expect(activity.metric == .cost)
        #expect(activity.activeDays == 2)
        #expect(activity.total == 5)
        #expect(activity.isEstimate)
    }

    /// A day with usage but no price still shows as active, at the lowest level.
    @Test func anUnpricedDayIsTheLowestLevelWhenOtherDaysHaveACost() throws {
        let rows = [row(date(2026, 10, 5), cost: 2), row(date(2026, 10, 6), cost: 8), row(date(2026, 10, 7), cost: nil)]
        let days = ActivityCalendar.make(rows, today: date(2026, 10, 10), calendar: Self.calendar, weeks: 1).weeks.flatMap { $0 }
        #expect(days.map(\.level) == [0, 1, 4, 1, 0, 0, 0])
    }

    /// With nothing priced in the whole year, tokens set the colors instead.
    @Test func withNoPriceAnywhereTokensSetTheLevels() {
        let rows = [row(date(2026, 10, 5), tokens: 10, cost: nil), row(date(2026, 10, 6), tokens: 900, cost: nil)]
        let activity = ActivityCalendar.make(rows, today: date(2026, 10, 10), calendar: Self.calendar, weeks: 1)
        #expect(activity.metric == .tokens)
        #expect(activity.total == 910)
        #expect(activity.weeks.first?.map(\.level) == [0, 1, 4, 0, 0, 0, 0])
    }

    /// Quartiles of the days with usage, so each level holds about a quarter of them.
    @Test func levelsSplitActiveDaysIntoQuartiles() {
        let thresholds = ActivityCalendar.thresholds([0, 8, 1, 2, 3, 4, 5, 6, 7])
        #expect(thresholds == [2, 4, 6])
        #expect((1...8).map { ActivityCalendar.level(Double($0), hasUsage: true, thresholds: thresholds) } == [1, 1, 2, 2, 3, 3, 4, 4])
        #expect(ActivityCalendar.level(0, hasUsage: false, thresholds: thresholds) == 0)
        #expect(ActivityCalendar.level(0, hasUsage: true, thresholds: thresholds) == 1)
    }

    /// A month is named over the week that holds its first day.
    @Test func monthsAreNamedAtTheWeekHoldingTheirFirstDay() {
        let activity = ActivityCalendar.make([], today: date(2026, 10, 10), calendar: Self.calendar, weeks: 6)
        #expect(activity.weeks.first?.first?.date == date(2026, 8, 30))
        #expect(activity.monthStarts(calendar: Self.calendar) == [0, 4])
    }

    @Test @MainActor func theReadoutNamesTheDayAndItsValue() throws {
        let rows = [row(date(2026, 10, 5), cost: 12.4), row(date(2026, 10, 6), tokens: 1_200_000, cost: nil)]
        let activity = ActivityCalendar.make(rows, today: date(2026, 10, 10), calendar: Self.calendar, weeks: 1)
        let days = try #require(activity.weeks.first)
        try #require(days.count == 7)
        #expect(activity.readout(days[1], calendar: Self.calendar, locale: Self.en) == "Mon, Oct 5, 2026: $12.40")
        #expect(activity.readout(days[2], calendar: Self.calendar, locale: Self.en) == "Tue, Oct 6, 2026: 1.2M tokens, no price")
        #expect(activity.readout(days[3], calendar: Self.calendar, locale: Self.en) == "Wed, Oct 7, 2026: no usage")
        #expect(activity.summary(locale: Self.en) == "$12.40 over 2 days with usage")

        let tokens = ActivityCalendar.make([row(date(2026, 10, 6), tokens: 1_200_000, cost: nil)], today: date(2026, 10, 10), calendar: Self.calendar, weeks: 1)
        let sixth = try #require(tokens.weeks.first?.dropFirst(2).first)
        #expect(tokens.readout(sixth, calendar: Self.calendar, locale: Self.en) == "Tue, Oct 6, 2026: 1.2M tokens")
        #expect(tokens.summary(locale: Self.en) == "1.2M tokens over 1 day with usage")
        #expect(ActivityCalendar.make([], today: date(2026, 10, 10), calendar: Self.calendar).summary(locale: Self.en) == "No usage in the last 12 months")
    }
}

struct ActivityGridTests {
    @Test func cellsShareTheWidthLeftByTheWeekdayColumnUpToAMaximum() {
        let grid = ActivityGrid(width: ActivityGrid.labelWidth + 53 * 10, weeks: 53)
        #expect(grid.pitch == 10)
        #expect(grid.height == ActivityGrid.monthHeight + 70)
        #expect(grid.cell(week: 2, weekday: 3).minX == ActivityGrid.labelWidth + 20)
        #expect(grid.cell(week: 2, weekday: 3).minY == ActivityGrid.monthHeight + 30)
        #expect(grid.cell(week: 2, weekday: 3).width < 10)
        #expect(ActivityGrid(width: 5_000, weeks: 53).pitch == ActivityGrid.maxPitch)
    }

    @Test func thePointerFindsTheCellUnderItAndNothingOutsideTheGrid() {
        let grid = ActivityGrid(width: ActivityGrid.labelWidth + 53 * 10, weeks: 53)
        let inside = grid.position(at: CGPoint(x: ActivityGrid.labelWidth + 23, y: ActivityGrid.monthHeight + 35))
        #expect(inside?.week == 2)
        #expect(inside?.weekday == 3)
        #expect(grid.position(at: CGPoint(x: 10, y: ActivityGrid.monthHeight + 35)) == nil)
        #expect(grid.position(at: CGPoint(x: ActivityGrid.labelWidth + 23, y: 5)) == nil)
        #expect(grid.position(at: CGPoint(x: ActivityGrid.labelWidth + 535, y: ActivityGrid.monthHeight + 35)) == nil)
        #expect(grid.position(at: CGPoint(x: ActivityGrid.labelWidth + 23, y: ActivityGrid.monthHeight + 71)) == nil)
    }
}
