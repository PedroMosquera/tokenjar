import Foundation
import Testing
@testable import TokenjarCore

struct CostLineEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ provider: ProviderID, _ billing: Billing?, money: [MoneyLine] = [], windows: [UsageWindow] = []) -> UsageSnapshot {
        UsageSnapshot(accountID: "a", provider: provider, plan: "Plan", billing: billing, windows: windows, money: money, fetchedAt: now, source: "test")
    }

    /// nil means the fetcher could not tell, and a flat plan's own money row is already its bill, so neither may
    /// show an estimate.
    @Test func costLineFollowsBillingOnly() {
        let expected: [(Billing?, Bool)] = [
            (nil, false), (.free, false), (.subscription, false), (.pooled, true), (.usageBased, true), (.payAsYouGo, true),
        ]
        #expect(Set(expected.compactMap(\.0)) == Set(Billing.allCases))
        let extraUsage = [MoneyLine(label: "Extra usage", amount: 12, limit: 50)]
        let week = [UsageWindow(id: "weekly", label: "Week", usedPercent: 40)]
        for provider in ProviderID.allCases {
            for (billing, applies) in expected {
                for shape in [snapshot(provider, billing), snapshot(provider, billing, money: extraUsage, windows: week)] {
                    #expect(CostLine.applies(to: shape) == applies, "\(provider) \(String(describing: billing))")
                }
            }
        }
    }

    /// Credits drawn from an org pool are not on this person's bill.
    @Test func pooledCostIsNeverCalledBilled() throws {
        for provider in ProviderID.allCases {
            for money in [[], [MoneyLine(label: "AI credits used", amount: 0.31)]] {
                let label = try #require(CostLine.label(for: snapshot(provider, .pooled, money: money)), "\(provider)")
                #expect(!label.localizedCaseInsensitiveContains("bill"), "\(provider): \(label)")
            }
        }
    }

    /// One wording for every pooled seat, whether the figure is the provider's (Copilot) or priced history (Claude).
    @Test func pooledCostSaysListValueOfTheOrgsCredits() {
        for provider in [ProviderID.claude, .copilot, .codex] {
            #expect(CostLine.label(for: snapshot(provider, .pooled)) == "list value of the org's credits", "\(provider)")
        }
    }

    /// Zen's money row, Copilot's overage line and Codex's credit counts are the provider's own figures; pricing local
    /// history as well would show a second, different number.
    @Test func providerFiguresWinOverHistory() {
        let zenRow = [MoneyLine(label: "Spent this month (this Mac)", amount: 4.2)]
        let overage = [MoneyLine(label: "Past the included credits", amount: 3)]
        #expect(CostLine.source(for: snapshot(.opencodeZen, .payAsYouGo, money: zenRow)) == .snapshot)
        #expect(CostLine.source(for: snapshot(.copilot, .payAsYouGo, money: overage)) == .snapshot)
        #expect(CostLine.source(for: snapshot(.copilot, .pooled)) == .snapshot)
        #expect(CostLine.source(for: snapshot(.codex, .usageBased)) == .snapshot)
        #expect(CostLine.label(for: snapshot(.opencodeZen, .payAsYouGo, money: zenRow)) == nil)
        #expect(CostLine.label(for: snapshot(.codex, .usageBased)) == nil)

        // An API-key or cloud lane has no provider figure, and a Claude seat's spend row sits beside the estimate.
        let spend = [MoneyLine(label: "Spend this month", amount: 80, limit: 200)]
        #expect(CostLine.source(for: snapshot(.codex, .payAsYouGo)) == .history)
        #expect(CostLine.source(for: snapshot(.claude, .payAsYouGo)) == .history)
        #expect(CostLine.source(for: snapshot(.claude, .usageBased, money: spend)) == .history)
        #expect(CostLine.label(for: snapshot(.claude, .payAsYouGo)) == "estimate at list price")
        #expect(CostLine.label(for: snapshot(.codex, .payAsYouGo)) == "estimate at list price")
    }

    /// History is summed per local calendar month; a provider's own figure covers whatever cycle it bills on.
    @Test func historyLinesUseTheCalendarMonthAndSnapshotLinesTheProviderCycle() {
        let expected: [(UsageSnapshot, CostLine.Period)] = [
            (snapshot(.opencodeZen, .payAsYouGo), .providerCycle),
            (snapshot(.copilot, .payAsYouGo), .providerCycle),
            (snapshot(.copilot, .pooled), .providerCycle),
            (snapshot(.codex, .usageBased), .providerCycle),
            (snapshot(.codex, .payAsYouGo), .calendarMonth),
            (snapshot(.claude, .payAsYouGo), .calendarMonth),
            (snapshot(.claude, .usageBased), .calendarMonth),
            (snapshot(.claude, .pooled), .calendarMonth),
        ]
        for (shape, period) in expected {
            #expect(CostLine.period(for: shape) == period, "\(shape.provider) \(String(describing: shape.billing))")
        }
    }
}
