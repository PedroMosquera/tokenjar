import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct PlanValueTests {
    let monthStart = Date(timeIntervalSince1970: 1_790_000_000)
    let locale = Locale(identifier: "en_US")
    let table = PriceTable(plans: [
        "claude": ["Max 20x": PlanPrice(monthlyUSD: 200, source: "test", asOf: "2026-10-16")],
        "codex": ["Plus": PlanPrice(monthlyUSD: 20, source: "test", asOf: "2026-10-16")],
    ])
    let accounts = [
        AccountConfig(id: "claude", provider: .claude, label: "Personal"),
        AccountConfig(id: "codex-plus", provider: .codex, label: "Plus"),
        AccountConfig(id: "codex-pro", provider: .codex, label: "Pro"),
        AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen"),
    ]

    func snapshot(_ id: String, _ provider: ProviderID, plan: String?) -> UsageSnapshot {
        UsageSnapshot(accountID: id, provider: provider, plan: plan, fetchedAt: monthStart, source: "test")
    }

    var snapshots: [String: UsageSnapshot] {
        [
            "claude": snapshot("claude", .claude, plan: "Max 20x"),
            "codex-plus": snapshot("codex-plus", .codex, plan: "Plus"),
            "codex-pro": snapshot("codex-pro", .codex, plan: "Pro"),
            "zen": snapshot("zen", .opencodeZen, plan: "Pay as you go"),
        ]
    }

    func row(_ account: String, cost: Double?, daysIn: Double = 2) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: monthStart.addingTimeInterval(daysIn * 86_400), accountID: account, harness: .claudeCode, model: "m", project: nil,
            requests: 1, inputTokens: 1, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: 1, unpricedOutputTokens: 0, unpricedCacheReadTokens: 0,
            unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: daily, costUSD: cost, isEstimate: cost != nil)
    }

    func value(_ rows: [PricedUsageRow], accounts: [AccountConfig]? = nil) -> PlanValue? {
        PlanValue.make(rows: rows, since: monthStart, accounts: accounts ?? self.accounts, snapshots: snapshots, table: table)
    }

    @Test func oneAccountCoversItsPlanPriceManyTimes() throws {
        let plan = try #require(value([row("claude", cost: 1_000), row("claude", cost: 140)], accounts: [accounts[0]]))
        #expect(plan.spend == 1_140)
        #expect(plan.planPrice == 200)
        #expect(plan.plans == ["Max 20x"])
        #expect(abs(plan.multiple - 5.7) < 1e-9)
    }

    /// Only accounts on a plan the table prices count, both their spend and their price; last month's spend does not.
    @Test func allAccountsAddUpOnlyThePricedPlans() throws {
        let rows = [
            row("claude", cost: 1_000), row("codex-plus", cost: 140), row("codex-pro", cost: 500), row("zen", cost: 30),
            row("claude", cost: 900, daysIn: -3),
        ]
        let plan = try #require(value(rows))
        #expect(plan.spend == 1_140)
        #expect(plan.planPrice == 220)
        #expect(plan.plans == ["Max 20x", "Plus"])
    }

    @Test func nothingPricedOrNoPricedPlanShowsNothing() {
        #expect(value([row("claude", cost: nil)]) == nil)
        #expect(value([]) == nil)
        #expect(value([row("codex-pro", cost: 500), row("zen", cost: 30)]) == nil)
    }

    @Test @MainActor func textSaysWhatThePlanCovered() throws {
        let one = PlanValue(spend: 1_140, planPrice: 200, plans: ["Max 20x"], isEstimate: true)
        #expect(one.valueText(locale: locale) == "5.7x")
        #expect(one.caption(locale: locale) == "vs the $200 plan")
        #expect(one.help(locale: locale)
            == "Covered $1,140 of API usage this month, 5.7x the $200 Max 20x plan. API-equivalent estimate, not a bill; plan prices are US monthly list prices.")
        let two = PlanValue(spend: 2_640, planPrice: 220, plans: ["Max 20x", "Plus"], isEstimate: true)
        #expect(two.valueText(locale: locale) == "12x")
        #expect(two.caption(locale: locale) == "vs $220 in 2 plans")
        #expect(two.help(locale: locale).hasPrefix("Covered $2,640 of API usage this month, 12x the $220 of the Max 20x and Plus plans."))
    }
}
