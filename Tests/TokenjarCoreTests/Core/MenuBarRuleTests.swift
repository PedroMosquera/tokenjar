import Foundation
import Testing
@testable import TokenjarCore

struct MenuBarRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ windows: [UsageWindow] = []) -> UsageSnapshot {
        UsageSnapshot(accountID: "a", provider: .claude, windows: windows, fetchedAt: now, source: "test")
    }

    private var week: UsageWindow {
        UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))
    }

    /// An account not checked yet, or one whose failure needs a look, still has something to say.
    @Test func onlyACalmFailureWithNothingFetchedIsLeftOut() {
        let cases: [(snapshot: UsageSnapshot?, attention: FetchError.Attention?, included: Bool)] = [
            (snapshot([week]), nil, true),
            (snapshot(), nil, true),
            (nil, nil, true),
            (nil, .calm, false),
            (snapshot([week]), .calm, true),
            (nil, .transient, true),
            (nil, .actionable, true),
            (snapshot(), .actionable, true),
        ]
        for provider in ProviderID.allCases {
            for c in cases {
                let expected = provider.reportsWindows && c.included
                #expect(
                    MenuBarRule.includes(provider: provider, snapshot: c.snapshot, attention: c.attention) == expected,
                    "\(provider) snapshot \(c.snapshot != nil) \(String(describing: c.attention))"
                )
            }
        }
    }

    @Test func windowIsTheTightestUnresetWindow() {
        let full = snapshot([
            UsageWindow(id: "session", label: "5-hour", usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60)),
            week,
            UsageWindow(id: "weekly:Fable", label: "Week · Fable", usedPercent: 10),
        ])
        #expect(MenuBarRule.window(of: full, now: now)?.id == "weekly")
        #expect(MenuBarRule.window(of: snapshot(), now: now) == nil)
        #expect(MenuBarRule.window(of: nil, now: now) == nil)
    }
}
