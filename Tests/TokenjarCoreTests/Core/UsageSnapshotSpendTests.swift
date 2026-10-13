import Foundation
import Testing
@testable import TokenjarCore

struct UsageSnapshotSpendTests {
    private let extra = MoneyLine(label: "Extra usage", amount: 477.15, limit: 3000, currency: "USD")

    private func snapshot(_ windows: [UsageWindow], money: [MoneyLine]) -> UsageSnapshot {
        UsageSnapshot(accountID: "work", provider: .claude, windows: windows, money: money, fetchedAt: .distantPast, source: "test")
    }

    @Test func theCappedMoneyBelongsToASpendLimit() {
        let spendLimit = UsageWindow(id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: 15.9)
        #expect(snapshot([spendLimit], money: [extra]).spendLimitMoney == extra)
    }

    /// A Max plan's extra usage has a cap too, but its bars are plan limits, so its money keeps its own row.
    @Test func moneyBesidePlanLimitsBelongsToNoBar() {
        let weekly = UsageWindow(id: "weekly", label: "Week", usedPercent: 77)
        #expect(snapshot([weekly], money: [extra]).spendLimitMoney == nil)
    }

    /// Codex reports its workspace cap as a spend-cap window with no money line.
    @Test func aSpendCapWithoutMoneyHasNone() {
        let cap = UsageWindow(id: UsageWindow.spendCapID, label: "Spend cap", usedPercent: 40)
        #expect(snapshot([cap], money: []).spendLimitMoney == nil)
        #expect(snapshot([cap], money: [MoneyLine(label: "Spent", amount: 3)]).spendLimitMoney == nil)
    }
}
