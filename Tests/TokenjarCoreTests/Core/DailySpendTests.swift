import Foundation
import Testing
@testable import TokenjarCore

struct DailySpendTests {
    private static func at(_ text: String) -> Date { DateParsing.iso8601(text)! }

    /// Madrid is UTC+2 in October, so the local day starts at 22:00Z the evening before.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()
    private let now = at("2026-10-13T10:00:00Z")
    private let resetsAt = at("2026-11-01T00:00:00Z")

    private func snapshot(used: Double, resetsAt: Date? = nil) -> UsageSnapshot {
        let reset = resetsAt ?? self.resetsAt
        let window = UsageWindow(
            id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: used, windowMinutes: UsageWindow.monthMinutes(endingAt: reset), resetsAt: reset
        )
        return UsageSnapshot(
            accountID: "work", provider: .claude, windows: [window],
            money: [MoneyLine(label: "Extra usage", amount: used * 30, limit: 3000, currency: "USD")], fetchedAt: now, source: "test"
        )
    }

    private func sample(_ at: String, _ used: Double) -> WindowSample {
        WindowSample(accountID: "work", windowID: UsageWindow.spendCapID, timestamp: Self.at(at), usedPercent: used, resetsAt: resetsAt)
    }

    private func make(
        used: Double = 16, budget: DailyBudget = DailyBudget(), samples: [WindowSample], now: Date? = nil, resetsAt: Date? = nil,
        workWeek: WorkWeek = .everyDay
    ) -> DailySpend? {
        DailySpend.make(
            snapshot: snapshot(used: used, resetsAt: resetsAt), budget: budget, samples: samples, now: now ?? self.now, calendar: calendar,
            workWeek: workWeek
        )
    }

    /// The last check before local midnight is where today starts; 23:30 in Madrid is still yesterday.
    @Test func todayCountsFromTheLastCheckBeforeLocalMidnight() throws {
        let daily = try #require(make(samples: [sample("2026-10-12T20:00:00Z", 14), sample("2026-10-12T21:30:00Z", 15), sample("2026-10-13T08:00:00Z", 15.5)]))
        #expect(abs(daily.spent - 30) < 0.001)
        #expect(daily.countedFrom == nil)
        #expect(daily.dayStart == Self.at("2026-10-12T22:00:00Z"))
        #expect(daily.dayEnd == Self.at("2026-10-13T22:00:00Z"))
    }

    /// What is left at the start of today, spread over the days to the reset, so spending today does not shrink
    /// today's own budget.
    @Test func theRecommendedBudgetSpreadsWhatIsLeftOverTheDaysToTheReset() throws {
        let daily = try #require(make(samples: [sample("2026-10-12T21:30:00Z", 15)]))
        let days = Self.at("2026-11-01T00:00:00Z").timeIntervalSince(Self.at("2026-10-12T22:00:00Z")) / 86_400
        #expect(daily.isRecommended)
        #expect(abs(daily.budget - 2550 / days) < 0.001)
    }

    @Test func aFixedBudgetIsUsedAsIs() throws {
        let daily = try #require(make(budget: DailyBudget(amount: 100), samples: [sample("2026-10-12T21:30:00Z", 15)]))
        #expect(!daily.isRecommended)
        #expect(daily.budget == 100)
        #expect(abs(daily.usedPercent - 30) < 0.001)
        #expect(daily.currency == "USD")
    }

    /// Without a check from before today, today can only count from the first check today, and says so.
    @Test func withoutAnEarlierCheckTodayCountsFromTheFirstCheckToday() throws {
        let daily = try #require(make(samples: [sample("2026-10-13T07:00:00Z", 15.2), sample("2026-10-13T09:00:00Z", 15.6)]))
        #expect(abs(daily.spent - 24) < 0.001)
        #expect(daily.countedFrom == Self.at("2026-10-13T07:00:00Z"))
    }

    /// The month reset during today, so the old month's last check says nothing: today starts from zero.
    @Test func aCycleThatStartedTodayCountsFromZero() throws {
        let novemberReset = Self.at("2026-12-01T00:00:00Z")
        let old = WindowSample(accountID: "work", windowID: UsageWindow.spendCapID, timestamp: Self.at("2026-10-31T22:30:00Z"), usedPercent: 99, resetsAt: resetsAt)
        let daily = try #require(make(used: 2, samples: [old], now: Self.at("2026-11-01T10:00:00Z"), resetsAt: novemberReset))
        #expect(abs(daily.spent - 60) < 0.001)
        #expect(daily.countedFrom == nil)
    }

    /// The bar keeps counting past the budget, so it shows how far over today is.
    @Test func overTheBudgetKeepsCounting() throws {
        let daily = try #require(make(used: 20.83, budget: DailyBudget(amount: 133), samples: [sample("2026-10-12T21:30:00Z", 15)]))
        #expect(daily.isOver)
        #expect(daily.usedPercent > 130)
        #expect(daily.window.usedPercent == daily.usedPercent)
        #expect(daily.window.resetsAt == daily.dayEnd)
    }

    @Test func workingDaysSpreadWhatIsLeftOverFewerDays() throws {
        let samples = [sample("2026-10-12T21:30:00Z", 15)]
        let everyDay = try #require(make(samples: samples))
        let workingDays = try #require(make(samples: samples, workWeek: WorkWeek(.workingDays, calendar: calendar)))
        #expect(workingDays.budget > everyDay.budget * 1.3)
    }

    @Test func nothingLeftToSpendHasNoRecommendedBudget() {
        #expect(make(used: 100, samples: [sample("2026-10-12T21:30:00Z", 100)]) == nil)
    }

    @Test func aSnapshotWithoutASpendLimitHasNoDailySpend() {
        let plain = UsageSnapshot(accountID: "work", provider: .claude, windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: 50)], fetchedAt: now, source: "test")
        #expect(DailySpend.make(snapshot: plain, budget: DailyBudget(), samples: [], now: now, calendar: calendar, workWeek: .everyDay) == nil)
    }
}
