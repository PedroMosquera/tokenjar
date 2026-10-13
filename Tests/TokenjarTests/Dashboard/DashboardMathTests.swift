import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

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

    /// March 2026 holds New York's change to daylight saving time, so its days are not all 24 hours long.
    @Test func loadStartCoversTheWholeMonthLateInLongMonths() {
        let late = Self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 9))!
        let periods = DashboardPeriods(now: late, calendar: Self.calendar)
        #expect(periods.loadStart == Self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
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

    @Test func modelIdsReadWithoutTheirDateOrPriceTierSuffix() {
        #expect(DashboardMath.displayName("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(DashboardMath.displayName("claude-haiku-5-5>100k") == "claude-haiku-5-5 (long prompts)")
        #expect(DashboardMath.displayName("gpt-5.5-codex") == "gpt-5.5-codex")
        // Only an 8-digit date is a release suffix; a version number stays.
        #expect(DashboardMath.displayName("model-2025") == "model-2025")
    }

    @Test func spendGroupsShowDisplayNamesWithoutChangingTheirKeys() {
        let names: Set<String> = ["Claude · Work"]
        #expect(DashboardMath.displayGroup("claude-haiku-4-5-20251001", by: .model, accountNames: names) == "claude-haiku-4-5")
        #expect(DashboardMath.displayGroup("Claude · Work", by: .account, accountNames: names) == "Claude · Work")
        #expect(DashboardMath.displayGroup("old-account-id", by: .account, accountNames: names) == "Removed account")
        #expect(DashboardMath.displayGroup(DashboardMath.otherGroup, by: .account, accountNames: names) == DashboardMath.otherGroup)
        #expect(DashboardMath.displayGroup("tokenjar-20251001", by: .project, accountNames: names) == "tokenjar-20251001")
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

    @Test func resetDuringAGapCountsEvenWhenUsageEndsHigher() {
        // The old cycle ended at minute 60 and the new one was already busier by the next sample.
        let samples = [sample(0, 10, resetsAt: 60), sample(120, 40, resetsAt: 360)]
        #expect(DashboardMath.resets(in: samples) == [now.addingTimeInterval(60 * 60)])
    }

    @Test func idleWindowsAreNotResets() {
        func idle(_ minutes: Double) -> WindowSample { sample(minutes, 0, resetsAt: minutes + 300) }
        // Every ~10 minutes for three hours, then the Mac sleeps 3 hours, then 8 hours (longer than the window).
        let steady = stride(from: 0.0, through: 170, by: 10.03).map(idle)
        let samples = steady + [idle(360), idle(840)]
        #expect(DashboardMath.resets(in: samples).isEmpty)

        // The first sample after the overnight gap finds the window in use: it began, nothing reset.
        let started = steady + [idle(360), sample(840, 20, resetsAt: 1_100)]
        #expect(DashboardMath.resets(in: started).isEmpty)
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

    // MARK: Chart domains

    @Test func dayGrainedChartsShareOneDomainAndTicks() {
        let periods = DashboardPeriods(now: now, calendar: Self.calendar)
        #expect(periods.chartDomain(of: .week) == day(-6)...day(1))
        #expect(periods.chartDomain(of: .month) == day(-29)...day(1))
        #expect(periods.axisDays(of: .week) == (-6...0).map(day))
        #expect(periods.axisDays(of: .month) == [-28, -21, -14, -7, 0].map(day))
    }

    /// New history fills the chart: it starts just before the first sample instead of leaving most of a day empty.
    @Test func newHistoryClipsTheLimitsChartToItsFirstSample() {
        let periods = DashboardPeriods(now: now, calendar: Self.calendar)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        for range in [DashboardRange.day, .week] {
            let clipped = DashboardMath.limitsDomain(range: range, periods: periods, earliest: fiveHoursAgo, reachesBack: false)
            #expect(clipped.domain.lowerBound < fiveHoursAgo && clipped.domain.lowerBound >= fiveHoursAgo.addingTimeInterval(-3600))
            #expect(clipped.domain.upperBound == now)
            #expect(clipped.since == fiveHoursAgo)
        }

        // Minutes of history still get a readable axis.
        let justNow = now.addingTimeInterval(-10 * 60)
        let minimal = DashboardMath.limitsDomain(range: .week, periods: periods, earliest: justNow, reachesBack: false)
        #expect(minimal.domain.lowerBound == now.addingTimeInterval(-3 * 3600))

        // Two days of history at 7d: the chart starts just before the first sample.
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let short = DashboardMath.limitsDomain(range: .week, periods: periods, earliest: twoDaysAgo, reachesBack: false)
        #expect(short.domain.lowerBound < twoDaysAgo && short.domain.lowerBound > twoDaysAgo.addingTimeInterval(-3600))
    }

    @Test func historyThatReachesBackKeepsTheSharedDomain() {
        let periods = DashboardPeriods(now: now, calendar: Self.calendar)
        // A Mac asleep at midnight has its first in-range sample in the morning, but older samples exist.
        let morning = day(-6).addingTimeInterval(8 * 3600)
        let full = DashboardMath.limitsDomain(range: .week, periods: periods, earliest: morning, reachesBack: true)
        #expect(full.domain == periods.chartDomain(of: .week))
        #expect(full.since == nil)
        // Nothing to draw keeps the shared domain too.
        #expect(DashboardMath.limitsDomain(range: .month, periods: periods, earliest: nil, reachesBack: false).domain == periods.chartDomain(of: .month))
        // 24h is the last 24 hours, never the two calendar days the spend chart shows.
        #expect(DashboardMath.limitsDomain(range: .day, periods: periods, earliest: nil, reachesBack: false).domain == now.addingTimeInterval(-86_400)...now)
    }

    // MARK: Recorded spend

    private func spendSample(_ at: Date, _ percent: Double) -> WindowSample {
        WindowSample(accountID: "work", windowID: UsageWindow.spendCapID, timestamp: at, usedPercent: percent, resetsAt: nil)
    }

    /// $1,000 limit: $100, then $150 and $160 the next day, a reset to $10 on the 1st, then $40.
    @Test func recordedSpendCountsWhatEachPeriodAddedAcrossAReset() {
        let samples = [
            spendSample(day(-3).addingTimeInterval(20 * 3600), 10), spendSample(day(-2).addingTimeInterval(9 * 3600), 15),
            spendSample(day(-2).addingTimeInterval(18 * 3600), 16), spendSample(day(-1).addingTimeInterval(1 * 3600), 1),
            spendSample(day(0).addingTimeInterval(10 * 3600), 4),
        ]
        let periods = (-4...0).map { DateInterval(start: day($0), end: day($0 + 1)) }
        let spend = DashboardMath.recordedSpend(samples: samples, limit: 1_000, periods: periods, now: now)
        #expect(spend.map(\.amount) == [nil, 0, 60, 10, 30])
    }

    /// A month that ended with less spent than the rounding tolerance still resets, because the reset date moved.
    @Test func aMovedResetDateIsAResetEvenWithLittleSpent() {
        let october = day(10), november = day(40)
        let samples = [
            WindowSample(accountID: "work", windowID: UsageWindow.spendCapID, timestamp: day(-1), usedPercent: 0.3, resetsAt: october),
            WindowSample(accountID: "work", windowID: UsageWindow.spendCapID, timestamp: day(0).addingTimeInterval(3600), usedPercent: 0.1, resetsAt: november),
            WindowSample(accountID: "work", windowID: UsageWindow.spendCapID, timestamp: day(0).addingTimeInterval(7200), usedPercent: 0.25, resetsAt: november),
        ]
        let spend = DashboardMath.recordedSpend(samples: samples, limit: 200, periods: [DateInterval(start: day(0), end: day(1))], now: now)
        #expect(abs((spend.first?.amount ?? 0) - 0.5) < 0.0001)
    }

    /// A rounding dip of a hundredth of a point is not a reset that would count the whole month again.
    @Test func aTinyDipIsNotAReset() {
        let samples = [spendSample(day(0).addingTimeInterval(3600), 30), spendSample(day(0).addingTimeInterval(7200), 29.99), spendSample(day(0).addingTimeInterval(9000), 31)]
        let spend = DashboardMath.recordedSpend(samples: samples, limit: 1_000, periods: [DateInterval(start: day(0), end: day(1))], now: now)
        #expect(abs((spend.first?.amount ?? 0) - 10) < 0.001)
    }

    @Test func spendPeriodsFollowTheRange() {
        let periods = DashboardPeriods(now: now, calendar: Self.calendar)
        let hours = DashboardMath.spendPeriods(range: .day, weekly: false, periods: periods)
        #expect(hours.count == 24)
        #expect(hours.last?.start == Self.calendar.dateInterval(of: .hour, for: now)?.start)
        #expect(DashboardMath.spendPeriods(range: .week, weekly: false, periods: periods).map(\.start) == (-6...0).map(day))
        let weeks = DashboardMath.spendPeriods(range: .month, weekly: true, periods: periods)
        #expect(weeks.first?.contains(day(-29)) == true)
        #expect(weeks.last?.contains(now) == true)
        #expect(zip(weeks, weeks.dropFirst()).allSatisfy { $0.end == $1.start })
    }
}

