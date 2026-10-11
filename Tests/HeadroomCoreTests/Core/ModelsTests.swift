import Foundation
import Testing
@testable import HeadroomCore

struct ModelsTests {
    @Test(arguments: ["file:///Applications/Calculator.app", "smb://host/share", "javascript:alert(1)", "not a url"])
    func dashboardOverridesOutsideHTTPFallBackToTheProviderDefault(_ override: String) {
        let account = AccountConfig(id: "a", provider: .claude, label: "x", dashboardURL: override)
        #expect(account.resolvedDashboardURL == ProviderID.claude.defaultDashboardURL)
    }

    /// Each default must land on the provider's own usage page; the ChatGPT one used to point at a Codex-only page.
    @Test func defaultUsagePagesArePinned() {
        let expected: [ProviderID: String] = [
            .claude: "https://claude.ai/settings/usage",
            .codex: "https://chatgpt.com/settings/usage",
            .opencodeGo: "https://opencode.ai/auth",
            .opencodeZen: "https://opencode.ai/auth",
            .antigravity: "https://antigravity.google/docs/plans",
        ]
        for provider in ProviderID.allCases {
            #expect(provider.defaultDashboardURL.absoluteString == expected[provider], "\(provider)")
        }
    }

    @Test func httpsOverrideIsUsed() {
        let account = AccountConfig(id: "a", provider: .codex, label: "x", dashboardURL: "https://example.com/usage")
        #expect(account.resolvedDashboardURL.absoluteString == "https://example.com/usage")
    }

    @Test func tightestWindowPrefersHigherUseThenSoonerReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(accountID: "a", provider: .claude, windows: [
            UsageWindow(id: "weekly", label: "Week", usedPercent: 70, resetsAt: now.addingTimeInterval(86_400)),
            UsageWindow(id: "session", label: "5-hour", usedPercent: 70, resetsAt: now.addingTimeInterval(3_600)),
            UsageWindow(id: "weekly:Fable", label: "Week · Fable", usedPercent: 10),
        ], fetchedAt: now, source: "test")
        #expect(snapshot.tightestWindow?.id == "session")
    }

    @Test func dateParsingAcceptsMixedFractionsAndOffsets() throws {
        let a = try #require(DateParsing.iso8601("2026-10-10T22:19:59.526764+00:00"))
        let b = try #require(DateParsing.iso8601("2026-10-12T09:00:00+00:00"))
        let c = try #require(DateParsing.iso8601("2026-10-12T11:00:00+02:00"))
        #expect(abs(a.timeIntervalSince1970 - 1_791_670_799.526764) < 0.000_01)
        #expect(b == c)
        #expect(DateParsing.iso8601("2026-10-12 09:00:00") == nil)
        #expect(DateParsing.epoch(1_791_660_379_473) == DateParsing.epoch(1_791_660_379.473))
    }
}
