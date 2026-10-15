import Foundation
import Testing
@testable import TokenjarCore

struct MonthlyBudgetTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!

    func gateway(windows: [UsageWindow] = [], money: [MoneyLine] = [], billing: Billing? = .payAsYouGo) -> UsageSnapshot {
        UsageSnapshot(accountID: "claude", provider: .claude, billing: billing, windows: windows, money: money, fetchedAt: now, source: "test")
    }

    func apply(_ budget: Double?, spent: Double, to snapshot: UsageSnapshot) -> UsageSnapshot {
        MonthlyBudget.apply(budget, spent: spent, to: snapshot, now: now, calendar: Self.calendar)
    }

    @Test func aBudgetBecomesASpendLimitForTheLocalMonth() throws {
        let snapshot = apply(200, spent: 67.38, to: gateway())
        let window = try #require(snapshot.windows.first)
        #expect(window.id == UsageWindow.spendCapID)
        #expect(window.label == "Monthly budget")
        #expect(abs(window.usedPercent - 33.69) < 0.001)
        #expect(window.limitStyle == .overage)
        #expect(window.resetsAt == Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        // October in Madrid has an extra hour, when summer time ends.
        #expect(window.windowMinutes == 31 * 24 * 60 + 60)
        #expect(snapshot.spendLimitMoney == MoneyLine(label: "Monthly budget", amount: 67.38, limit: 200))
    }

    @Test func noBudgetOrANonPositiveOneChangesNothing() {
        #expect(apply(nil, spent: 10, to: gateway()) == gateway())
        #expect(apply(0, spent: 10, to: gateway()) == gateway())
    }

    /// A plan's limits, or a seat's own spend limit, are the provider's numbers; a budget would sit beside them.
    @Test func anAccountNotPricedFromHistoryIsLeftAlone() {
        let plan = gateway(windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: 40)], billing: nil)
        #expect(apply(200, spent: 10, to: plan) == plan)
        let seat = gateway(windows: [UsageWindow(id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: 20)],
                           money: [MoneyLine(label: "Extra usage", amount: 40, limit: 200)], billing: .usageBased)
        #expect(apply(500, spent: 10, to: seat) == seat)
    }

    @Test func applyingTwiceKeepsOneBar() {
        let once = apply(200, spent: 10, to: gateway())
        #expect(apply(200, spent: 10, to: once) == once)
    }
}
