import Foundation
import Testing
import HeadroomCore
@testable import Headroom

struct DashboardMathTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 2026-10-10 15:30 in New York.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 30))!

    func day(_ offset: Int) -> Date {
        Self.calendar.date(byAdding: .day, value: offset, to: Self.calendar.startOfDay(for: now))!
    }

    func row(
        day: Date, account: String = "a", harness: Harness = .claudeCode, model: String, project: String? = "p",
        requests: Int = 1, tokens: Int = 100, cost: Double?, estimate: Bool = true
    ) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: day, accountID: account, harness: harness, model: model, project: project, requests: requests,
            inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: tokens, unpricedOutputTokens: 0,
            unpricedCacheReadTokens: 0, unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: daily, costUSD: cost, isEstimate: cost != nil && estimate)
    }

    func sample(_ minutes: Double, _ used: Double, resetsAt: Double?) -> WindowSample {
        WindowSample(
            accountID: "a", windowID: "session", timestamp: now.addingTimeInterval(minutes * 60), usedPercent: used,
            resetsAt: resetsAt.map { now.addingTimeInterval($0 * 60) }
        )
    }

    // MARK: Periods

    @Test func periodsUseLocalCalendarDays() {
        let periods = DashboardPeriods(now: now, calendar: Self.calendar)
        #expect(periods.today == day(0))
        #expect(periods.lastSevenDays == day(-6))
        #expect(periods.thisMonth == Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        // Early in the month the 30-day range reaches further back than the 1st, so it sets the load start.
        #expect(periods.loadStart == day(-29))
        #expect(periods.firstDay(of: .day) == day(-1))
        #expect(periods.days(of: .week) == (-6...0).map(day))
    }

    @Test func loadStartCoversTheWholeMonthLateInLongMonths() {
        let late = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
        let periods = DashboardPeriods(now: late, calendar: Self.calendar)
        #expect(periods.loadStart == Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
    }

    // MARK: Cost and totals

    @Test func costSumsPricedRowsAndCountsUnpricedOnes() {
        // The estimated row comes first so a recorded row after it cannot clear the flag.
        let rows = [
            row(day: day(0), model: "m2", cost: 3, estimate: true),
            row(day: day(0), model: "m1", cost: 2, estimate: false),
            row(day: day(0), model: "m3", cost: nil),
            row(day: day(-1), model: "m1", cost: 100),
        ]
        let today = DashboardMath.cost(rows, since: day(0))
        #expect(today.amount == 5)
        #expect(today.isEstimate)
        #expect(today.pricedRows == 2)
        #expect(today.unpricedRows == 1)

        let recordedOnly = DashboardMath.cost([row(day: day(0), model: "m1", cost: 2, estimate: false)], since: day(0))
        #expect(!recordedOnly.isEstimate)
        #expect(!DashboardMath.cost(rows, since: day(1)).hasUsage)
    }

    @Test func totalsCountTokensAndRequestsInRange() {
        let rows = [
            row(day: day(0), model: "m1", requests: 3, tokens: 1_000, cost: 1),
            row(day: day(-1), model: "m1", requests: 2, tokens: 500, cost: nil),
            row(day: day(-2), model: "m1", requests: 7, tokens: 9_000, cost: 1),
        ]
        #expect(DashboardMath.totals(rows, since: day(-1)) == UsageTotals(tokens: 1_500, requests: 5))
    }

    // MARK: Daily spend

    @Test func spendKeepsTopGroupsAndFoldsTheRestIntoOther() {
        // Eight models costing 1...8; limit 3 keeps m8, m7, m6 and folds the other five.
        let rows = (1...8).map { row(day: day(0), model: "m\($0)", cost: Double($0)) }
        let spend = DashboardMath.dailySpend(rows, by: .model, since: day(-6), limit: 3)
        #expect(spend.groups == ["m8", "m7", "m6", DashboardMath.otherGroup])
        #expect(spend.segments.map(\.group) == ["m8", "m7", "m6", DashboardMath.otherGroup])
        let other = spend.segments.first { $0.group == DashboardMath.otherGroup }
        #expect(other?.cost == 15)
        #expect(spend.segments.reduce(0) { $0 + $1.cost } == 36)
    }

    @Test func spendDoesNotFoldASingleGroup() {
        let rows = (1...4).map { row(day: day(0), model: "m\($0)", cost: Double($0)) }
        let spend = DashboardMath.dailySpend(rows, by: .model, since: day(-6), limit: 3)
        #expect(spend.groups == ["m4", "m3", "m2", "m1"])
    }

    @Test func spendRegroupsPricedRowsAndReportsUnpricedModels() {
        let rows = [
            row(day: day(-1), account: "work", model: "sonnet", project: "api", cost: 4),
            row(day: day(-1), account: "home", model: "opus", project: "api", cost: 1),
            row(day: day(0), account: "home", model: "opus", project: nil, cost: 2),
            row(day: day(0), account: "home", model: "glm", project: "web", cost: nil),
            row(day: day(-9), account: "home", model: "old", project: "web", cost: nil),
        ]
        let byProject = DashboardMath.dailySpend(rows, by: .project, since: day(-6), limit: 6)
        #expect(byProject.groups == ["api", DashboardMath.noProject])
        #expect(byProject.segments == [
            SpendSegment(day: day(-1), group: "api", cost: 5),
            SpendSegment(day: day(0), group: DashboardMath.noProject, cost: 2),
        ])
        #expect(byProject.unpricedModels == ["glm"])
        #expect(byProject.hasUsage)
        #expect(byProject.isEstimate)

        let byAccount = DashboardMath.dailySpend(rows, by: .account, since: day(-6), limit: 6, accountNames: ["work": "Claude · Work"])
        #expect(byAccount.groups == ["Claude · Work", "home"])
    }

    @Test func spendWithOnlyUnpricedRowsHasUsageButNoSegments() {
        let spend = DashboardMath.dailySpend([row(day: day(0), model: "glm", cost: nil)], by: .model, since: day(0), limit: 6)
        #expect(spend.hasUsage)
        #expect(spend.segments.isEmpty)
        #expect(spend.groups.isEmpty)
    }

    // MARK: Projects

    @Test func topProjectsSortByCostWithUnpricedLast() {
        let rows = [
            row(day: day(0), model: "m", project: "cheap", requests: 9, tokens: 9_000, cost: 1),
            row(day: day(0), model: "m", project: "dear", requests: 1, tokens: 10, cost: 7),
            row(day: day(-1), model: "m", project: "dear", requests: 1, tokens: 10, cost: 3),
            row(day: day(0), model: "glm", project: "free", requests: 4, tokens: 50_000, cost: nil),
            row(day: day(0), model: "m", project: nil, requests: 2, tokens: 20, cost: 2),
        ]
        let top = DashboardMath.topProjects(rows, since: day(-6), limit: 10)
        #expect(top.map(\.project) == ["dear", DashboardMath.noProject, "cheap", "free"])
        #expect(top[0].cost == 10)
        #expect(top[0].requests == 2)
        #expect(top[3].cost == nil)
        #expect(DashboardMath.topProjects(rows, since: day(-6), limit: 2).count == 2)
    }

    // MARK: Limit samples

    @Test func downsampleKeepsBucketPeaksAndTheLatestSample() {
        let samples = [
            sample(0, 10, resetsAt: 300), sample(10, 40, resetsAt: 300), sample(20, 30, resetsAt: 300),
            sample(70, 50, resetsAt: 300), sample(80, 45, resetsAt: 300),
        ]
        let thinned = DashboardMath.downsample(samples, bucket: 3600)
        #expect(thinned.map(\.usedPercent).contains(40))
        #expect(!thinned.map(\.usedPercent).contains(30))
        #expect(thinned.last == samples.last)
        #expect(DashboardMath.downsample(samples, bucket: 0) == samples)
    }

    @Test func resetsAreForwardJumpsBeyondJitter() {
        let samples = [
            sample(0, 80, resetsAt: 30),
            sample(10, 85, resetsAt: 30.05),
            sample(40, 2, resetsAt: 330),
            sample(50, 4, resetsAt: 330),
            sample(400, 1, resetsAt: 700),
        ]
        // The 3-second drift between the first two samples is jitter. Both real resets fall between two
        // samples, so each is marked at the old reset time.
        #expect(DashboardMath.resets(in: samples) == [now.addingTimeInterval(30.05 * 60), now.addingTimeInterval(330 * 60)])
    }

    @Test func resetMarkerFallsBackToTheNewSampleWhenTheOldResetIsOutsideTheGap() {
        // The provider moved the reset forward before the old one passed (a reset credit or a plan change).
        let samples = [sample(0, 50, resetsAt: 200), sample(10, 0, resetsAt: 500)]
        #expect(DashboardMath.resets(in: samples) == [now.addingTimeInterval(10 * 60)])
    }

    @Test func limitPointsBreakAtGapsAndClampToTheChart() {
        let samples = [sample(0, 10, resetsAt: nil), sample(10, 120, resetsAt: nil), sample(300, 20, resetsAt: nil), sample(310, -5, resetsAt: nil)]
        let points = DashboardMath.limitPoints(seriesID: "s", label: "S", samples: samples, bucket: 0, maxGap: 2 * 3600)
        #expect(points.map(\.segment) == [0, 0, 1, 1])
        #expect(points.map(\.usedPercent) == [10, 100, 20, 0])
        #expect(Set(points.map(\.lineID)).count == 2)
    }

    @Test func shortWindowsOverLongRangesShowPeaksPerCycle() {
        let fiveHourWeek = DashboardMath.sampling(for: .week, windowMinutes: 300)
        #expect(fiveHourWeek.peaksOnly)
        #expect(fiveHourWeek.bucket == 300 * 60)
        #expect(!DashboardMath.sampling(for: .day, windowMinutes: 300).peaksOnly)
        #expect(!DashboardMath.sampling(for: .month, windowMinutes: 10_080).peaksOnly)
        let unknown = DashboardMath.sampling(for: .month, windowMinutes: nil)
        #expect(!unknown.peaksOnly)
        #expect(unknown.bucket == DashboardRange.month.sampleBucket)
    }
}
