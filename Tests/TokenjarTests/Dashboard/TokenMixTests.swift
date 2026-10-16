import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct TokenMixTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!

    func day(_ offset: Int) -> Date {
        Self.calendar.date(byAdding: .day, value: offset, to: today)!
    }

    func row(
        day: Date, harness: Harness = .claudeCode, requests: Int = 1, input: Int = 0, output: Int = 0, reasoning: Int = 0,
        read: Int = 0, write5m: Int = 0, write1h: Int = 0
    ) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: day, accountID: "a", harness: harness, model: "m", project: "p", requests: requests,
            inputTokens: input, outputTokens: output, cacheReadTokens: read, cacheWrite5mTokens: write5m, cacheWrite1hTokens: write1h,
            reasoningTokens: reasoning, reportedCostUSD: nil, unpricedInputTokens: input, unpricedOutputTokens: output,
            unpricedCacheReadTokens: read, unpricedCacheWrite5mTokens: write5m, unpricedCacheWrite1hTokens: write1h
        )
        return PricedUsageRow(row: daily, costUSD: nil, isEstimate: false)
    }

    /// Codex's output already holds its reasoning; opencode stores reasoning beside output, so only there is it added.
    @Test func reasoningCountsOnceInOutputForEveryHarness() {
        #expect(DashboardMath.outputTokens(row(day: day(0), harness: .claudeCode, output: 50).row) == 50)
        #expect(DashboardMath.outputTokens(row(day: day(0), harness: .codex, output: 40, reasoning: 30).row) == 40)
        #expect(DashboardMath.outputTokens(row(day: day(0), harness: .opencode, output: 10, reasoning: 7).row) == 17)
        #expect(DashboardMath.tokens(row(day: day(0), harness: .opencode, input: 100, output: 10, reasoning: 7, read: 1_000).row) == 1_117)
    }

    @Test func theMixStacksEachKindPerDayCacheReadsFirst() {
        let rows = [
            row(day: day(-1), input: 100, output: 50, read: 1_000, write5m: 20, write1h: 5),
            row(day: day(0), harness: .codex, input: 10, output: 40, reasoning: 30, read: 300),
            row(day: day(0), harness: .opencode, output: 10, reasoning: 7),
            row(day: day(-9), input: 99_999),
        ]
        let mix = DashboardMath.tokenMix(rows, since: day(-6))
        #expect(mix.groups == ["cacheRead", "cacheWrite", "input", "output"])
        #expect(mix.segments == [
            SpendSegment(day: day(-1), group: "cacheRead", value: 1_000),
            SpendSegment(day: day(-1), group: "cacheWrite", value: 25),
            SpendSegment(day: day(-1), group: "input", value: 100),
            SpendSegment(day: day(-1), group: "output", value: 50),
            SpendSegment(day: day(0), group: "cacheRead", value: 300),
            SpendSegment(day: day(0), group: "input", value: 10),
            SpendSegment(day: day(0), group: "output", value: 57),
        ])
        #expect(mix.hasUsage)
    }

    /// A kind nobody used in range has no legend entry, and a range with no tokens has nothing to chart.
    @Test func kindsWithoutTokensAreLeftOut() {
        let mix = DashboardMath.tokenMix([row(day: day(0), input: 10, output: 5)], since: day(-6))
        #expect(mix.groups == ["input", "output"])
        let empty = DashboardMath.tokenMix([row(day: day(0), requests: 0, input: 10)], since: day(-6))
        #expect(!empty.hasUsage)
        #expect(empty.segments.isEmpty)
    }

    /// Output leads and keeps a readable share even when cache reads are almost everything.
    @Test @MainActor func theLineLeadsWithOutputAndKeepsSmallSharesReadable() {
        let rows = [row(day: day(0), input: 9_000, output: 4_000, read: 984_000, write5m: 2_000)]
        let line = DashboardMath.tokenMixLine(DashboardMath.tokenMix(rows, since: day(-6)), locale: Locale(identifier: "en_US"))
        #expect(line == "Output 4.0k (0.4%) · Input 9.0k (0.9%) · Cache write 2.0k (0.2%) · Cache read 984.0k (98%)")
        #expect(DashboardMath.tokenMixLine(SpendBreakdown()) == nil)
    }

    @Test func sharesUnderOnePercentKeepADecimal() {
        let en = Locale(identifier: "en_US")
        #expect(DashboardMath.share(0.0004, locale: en) == "<0.1%")
        #expect(DashboardMath.share(0.004, locale: en) == "0.4%")
        #expect(DashboardMath.share(0.25, locale: en) == "25%")
    }
}
