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

    /// `MenuBarState.make`'s rule before it moved to core, so adopting it there changes nothing.
    @Test func includesMatchesTodaysMenuBar() {
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

    /// An account not checked yet, or one whose failure needs a look, still has something to say.
    @Test func nothingToTrackForAWindowlessSuccessOrACalmError() {
        #expect(MenuBarRule.hasNothingToTrack(snapshot: snapshot(), attention: nil))
        #expect(MenuBarRule.hasNothingToTrack(snapshot: snapshot(), attention: .calm))
        #expect(MenuBarRule.hasNothingToTrack(snapshot: nil, attention: .calm))

        #expect(!MenuBarRule.hasNothingToTrack(snapshot: nil, attention: nil))
        #expect(!MenuBarRule.hasNothingToTrack(snapshot: snapshot(), attention: .transient))
        #expect(!MenuBarRule.hasNothingToTrack(snapshot: snapshot(), attention: .actionable))
        #expect(!MenuBarRule.hasNothingToTrack(snapshot: nil, attention: .actionable))
    }

    /// Dropping an account that still has a window would hide a real limit from the menu bar.
    @Test func anyWindowMeansSomethingToTrack() {
        let idle = UsageWindow(id: "session", label: "5-hour", usedPercent: 0, windowMinutes: 300, notStarted: true)
        let reset = UsageWindow(id: "session", label: "5-hour", usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60))
        for windows in [[week], [idle], [reset]] {
            for attention: FetchError.Attention? in [nil, .calm, .transient, .actionable] {
                #expect(
                    !MenuBarRule.hasNothingToTrack(snapshot: snapshot(windows), attention: attention),
                    "\(windows.map(\.id)) \(String(describing: attention))"
                )
            }
        }
    }
}
