import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

private func row(_ id: String, _ provider: ProviderID, history: Bool = false) -> PreviewPlanRow {
    let snapshot = UsageSnapshot(accountID: id, provider: provider, plan: "Plan \(id)", fetchedAt: PreviewPlans.now, source: "test")
    return PreviewPlanRow(id: id, provider: provider, label: "Label \(id)", status: AccountStatus(snapshot: snapshot), history: history)
}

@MainActor
struct PreviewPlansTests {
    /// Every preview account's status as the pages hold it, keyed by account id.
    private static let previewStatuses: [String: AccountStatus] = {
        var statuses: [String: AccountStatus] = [:]
        for page in PreviewPlans.pages() {
            for account in page.model.config.accounts { statuses[account.id] = page.model.status(for: account) }
        }
        return statuses
    }()

    @Test func everyCaseWithAnExpectationHasAPreviewAccount() {
        let missing = PlanManifest.withExpectations.filter { $0.preview != false && Self.previewStatuses[$0.id] == nil }.map(\.id)
        #expect(missing == [], "cases with an expectation and no preview account")
    }

    @Test(arguments: PlanManifest.withExpectations.filter { $0.preview != false })
    func previewStatusMatchesTheManifest(_ planCase: PlanCase) throws {
        let status = try #require(Self.previewStatuses[planCase.id], "no preview account")
        let expected = planCase.expect?.snapshot
        var shown = status.snapshot
        if let expected { shown?.fetchedAt = expected.fetchedAt }
        #expect(shown == expected)
        #expect(status.error == planCase.expect?.error)
    }

    /// The renders name these pages before any provider area writes a row, and a reviewer compares them by name.
    @Test func everyPlanPageExistsBeforeAnyRowLands() {
        let pages = PreviewPlans.pages(now: PreviewPlans.now, rows: [])
        let expected = [("claude", 6), ("codex", 5), ("opencode-go", 3), ("opencode-zen", 3), ("antigravity", 4), ("copilot", 6), ("devin", 2)]
            .flatMap { provider, count in (1...count).map { "plans-\(provider)-\($0)" } }
        #expect(pages.map(\.name) == expected)
        #expect(pages.allSatisfy { $0.model.config.accounts.isEmpty })
    }

    @Test func rowsFillThePagesInOrderAndOverflowIntoPagesOfSix() throws {
        let rows = (1...20).map { row("opencode-zen.case-\($0)", .opencodeZen) }
        let zen = PreviewPlans.pages(now: PreviewPlans.now, rows: rows).filter { $0.name.hasPrefix("plans-opencode-zen-") }

        #expect(zen.map(\.name) == (1...5).map { "plans-opencode-zen-\($0)" })
        #expect(zen.map { $0.model.accounts.count } == [5, 4, 3, 6, 2])
        let first = try #require(zen.first?.model)
        #expect(first.previewMode, "a page model must never fetch, save or scan")
        #expect(first.accounts.map(\.id) == (1...5).map { "opencode-zen.case-\($0)" })
        #expect(first.accounts.first?.label == "Label opencode-zen.case-1")
        #expect(first.status(for: try #require(first.accounts.first)) == rows[0].status)
    }

    @Test func onlyHistoryRowsGetUsageAndItIsPricedTheSameEachTime() throws {
        let rows = [
            row("claude.a", .claude, history: true), row("claude.b", .claude),
            row("codex.c", .codex, history: true), row("opencode-zen.d", .opencodeZen, history: true),
        ]
        func usage() throws -> [(row: DailyUsageRow, cost: Double?)] {
            try PreviewPlans.pages(now: PreviewPlans.now, rows: rows).flatMap { page in
                try (page.model.store?.dailyUsage(accountIDs: nil, since: .distantPast) ?? []).map { ($0, page.model.priceTable.priced($0).costUSD) }
            }
        }
        let first = try usage()

        #expect(Set(first.map(\.row.accountID)) == ["claude.a", "codex.c", "opencode-zen.d"])
        #expect(first.allSatisfy { $0.cost != nil }, "unpriced: \(first.filter { $0.cost == nil }.map(\.row.model))")
        // Token counts, not the rows: the store sums recorded cost in hash order, so its last bits can vary.
        let counts = { (usage: [(row: DailyUsageRow, cost: Double?)]) in
            Set(usage.map { "\($0.row.accountID) \($0.row.day) \($0.row.requests) \($0.row.inputTokens) \($0.row.outputTokens)" })
        }
        #expect(counts(try usage()) == counts(first))
    }
}
