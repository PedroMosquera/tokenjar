import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct PercentWorthTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400
    private var week: TimeInterval { 7 * day }

    private func at(_ days: Double) -> Date { t0.addingTimeInterval(days * day) }

    private func sample(_ days: Double, _ used: Double, resetsAt reset: Date?) -> WindowSample {
        WindowSample(accountID: "a", windowID: "weekly", timestamp: at(days), usedPercent: used, resetsAt: reset)
    }

    private func priced(model: String = "claude-opus-5-5", tokens: Int, cost: Double?) -> PricedUsageRow {
        let row = DailyUsageRow(
            day: t0, accountID: "a", harness: .claudeCode, model: model, project: "p", requests: 1,
            inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: tokens, unpricedOutputTokens: 0,
            unpricedCacheReadTokens: 0, unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: row, costUSD: cost, isEstimate: cost != nil)
    }

    private func cycle(start: Double, reset: Double, peak: Double, peakAt: Double) -> PercentWorth.Cycle {
        PercentWorth.Cycle(start: at(start), resetsAt: at(reset), peakPercent: peak, peakAt: at(peakAt))
    }

    // MARK: Cycles

    @Test func aCycleRunsFromAWindowBeforeItsResetToItsLatestPeakSample() {
        let samples = [
            sample(1, 5, resetsAt: at(7)),
            sample(3, 30, resetsAt: at(7).addingTimeInterval(20)),
            sample(6, 42, resetsAt: at(7).addingTimeInterval(-5)),
            sample(6.5, 42, resetsAt: at(7)),
            sample(8, 12, resetsAt: at(14)),
        ]
        let cycles = PercentWorth.cycles(samples: samples, length: { _ in week })
        #expect(cycles == [
            cycle(start: 0, reset: 7, peak: 42, peakAt: 6.5),
            cycle(start: 7, reset: 14, peak: 12, peakAt: 8),
        ])
    }

    /// A reset the provider moved forward would otherwise reach back over usage the previous cycle already counted.
    @Test func aCycleNeverStartsBeforeThePreviousCyclesLastSample() {
        let samples = [
            sample(1, 20, resetsAt: at(7)),
            sample(5, 35, resetsAt: at(7)),
            sample(6, 15, resetsAt: at(10)),
        ]
        let cycles = PercentWorth.cycles(samples: samples, length: { _ in week })
        #expect(cycles.map(\.start) == [at(0), at(5)])
    }

    @Test func samplesWithoutAResetTimeBelongToNoCycle() {
        let cycles = PercentWorth.cycles(samples: [sample(1, 50, resetsAt: nil)], length: { _ in week })
        #expect(cycles.isEmpty)
    }

    @Test func aMonthlyWindowStartsOneUTCCalendarMonthBeforeEachReset() {
        let march1 = Date(timeIntervalSince1970: 1_772_323_200)
        let monthly = UsageWindow(
            id: "monthly", label: "Month", usedPercent: 20, windowMinutes: UsageWindow.monthMinutes(endingAt: march1), resetsAt: march1
        )
        let length = PercentWorth.cycleLength(of: monthly)
        #expect(length(march1) == 28 * day)
        #expect(length(march1.addingTimeInterval(31 * day)) == 31 * day)
        let weekly = UsageWindow(id: "weekly", label: "Week", usedPercent: 20, windowMinutes: 10_080, resetsAt: march1)
        #expect(PercentWorth.cycleLength(of: weekly)(march1) == week)
    }

    // MARK: Rows

    @Test func tokensAndCostAreDividedByThePeakAndCountedUpToIt() {
        var asked: [DateInterval] = []
        let rows = PercentWorth.rows(cycles: [cycle(start: 0, reset: 7, peak: 40, peakAt: 6)], now: at(9)) { interval in
            asked.append(interval)
            return [priced(tokens: 1_500_000, cost: 30), priced(model: "claude-sonnet-5", tokens: 500_000, cost: 10)]
        }
        #expect(asked == [DateInterval(start: at(0), end: at(6))])
        let row = rows.first
        #expect(row?.tokensPerPercent == 50_000)
        #expect(row?.costPerPercent == 1)
        #expect(row?.isEstimate == true)
        #expect(row?.isCurrent == false)
    }

    @Test func cyclesUnderTheFloorShowNothing() {
        let rows = PercentWorth.rows(
            cycles: [cycle(start: 0, reset: 7, peak: 9.9, peakAt: 6), cycle(start: 7, reset: 14, peak: 10, peakAt: 13)], now: at(15)
        ) { _ in [priced(tokens: 1_000, cost: 1)] }
        #expect(rows.map(\.cycle.peakPercent) == [10])
    }

    /// Nothing in this Mac's logs means the use happened elsewhere; 0 tokens per 1% would read as a broken limit.
    @Test func aCycleWithNoLocalUsageShowsNothing() {
        let rows = PercentWorth.rows(cycles: [cycle(start: 0, reset: 7, peak: 50, peakAt: 6)], now: at(9)) { _ in [] }
        #expect(rows.isEmpty)
    }

    @Test func anUnpricedModelLeavesTheCostOutButKeepsTheTokens() {
        let rows = PercentWorth.rows(cycles: [cycle(start: 0, reset: 7, peak: 20, peakAt: 6)], now: at(9)) { _ in
            [priced(tokens: 1_000, cost: 4), priced(model: "mystery", tokens: 1_000, cost: nil)]
        }
        #expect(rows.first?.tokensPerPercent == 100)
        #expect(rows.first?.cost == nil)
        #expect(rows.first?.costPerPercent == nil)
    }

    @Test func rowsAreNewestFirstLimitedAndMarkTheCycleNotYetReset() {
        let cycles = (0..<5).map { cycle(start: Double($0) * 7, reset: Double($0 + 1) * 7, peak: 50, peakAt: Double($0) * 7 + 6) }
        let rows = PercentWorth.rows(cycles: cycles, now: at(30), limit: 3) { _ in [priced(tokens: 1_000, cost: 1)] }
        #expect(rows.map(\.cycle.resetsAt) == [at(35), at(28), at(21)])
        #expect(rows.map(\.isCurrent) == [true, false, false])
    }

    @Test func aCycleIsNamedByItsDaysAndTheCurrentOneRunsToNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        var row = PercentWorth.Row(cycle: cycle(start: 0, reset: 7, peak: 40, peakAt: 6), tokens: 1, cost: nil, isEstimate: false, isCurrent: false)
        #expect(PercentWorth.cycleText(row, calendar: calendar, locale: locale) == "Sep 21 to Sep 28")
        row.isCurrent = true
        #expect(PercentWorth.cycleText(row, calendar: calendar, locale: locale) == "Sep 21 to now")
    }

    // MARK: Which windows

    @Test func onlyWholeAccountWindowsOfADayOrMoreWithLocalHistoryQualify() {
        let account = AccountConfig(id: "a", provider: .claude, label: "A")
        let snapshot = UsageSnapshot(accountID: "a", provider: .claude, windows: [
            UsageWindow(id: "session", label: "5-hour", usedPercent: 40, windowMinutes: 300, resetsAt: at(1)),
            UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: at(3)),
            UsageWindow(id: "weekly:Opus", label: "Week · Opus", usedPercent: 40, windowMinutes: 10_080, resetsAt: at(3)),
            UsageWindow(id: "monthly_all", label: "Monthly all", usedPercent: 40, windowMinutes: nil, resetsAt: at(20)),
            UsageWindow(id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: 40, windowMinutes: 43_200, resetsAt: at(20)),
        ], fetchedAt: t0, source: "test")
        #expect(PercentWorth.windows(account: account, snapshot: snapshot, sharesLocalSource: false).map(\.id) == ["weekly"])
        #expect(PercentWorth.windows(account: account, snapshot: snapshot, sharesLocalSource: true).isEmpty)

        let copilot = AccountConfig(id: "c", provider: .copilot, label: "C")
        let monthly = UsageSnapshot(accountID: "c", provider: .copilot, windows: [
            UsageWindow(id: "monthly", label: "Month", usedPercent: 40, windowMinutes: 43_200, resetsAt: at(20)),
        ], fetchedAt: t0, source: "test")
        #expect(PercentWorth.windows(account: copilot, snapshot: monthly, sharesLocalSource: false).isEmpty)
    }

    /// Events are stored under whichever account scanned a shared folder first, so neither account's figure is its own.
    @Test func accountsReadingOneFolderShareTheirSource() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/someone"))
        let main = AccountConfig(id: "main", provider: .claude, label: "Main")
        let named = AccountConfig(id: "named", provider: .claude, label: "Named", profileDir: "~/.claude")
        let work = AccountConfig(id: "work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        let codex = AccountConfig(id: "codex", provider: .codex, label: "Codex")
        #expect(PercentWorth.sharesLocalSource(main, among: [main, named, work, codex], paths: paths))
        #expect(!PercentWorth.sharesLocalSource(work, among: [main, named, work, codex], paths: paths))
        #expect(!PercentWorth.sharesLocalSource(main, among: [main, work, codex], paths: paths))
    }
}
