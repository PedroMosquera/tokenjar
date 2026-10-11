import Foundation
import Testing
@testable import TokenjarCore

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
            .copilot: "https://github.com/settings/copilot",
            .devin: "https://app.devin.ai/settings/plans",
        ]
        for provider in ProviderID.allCases {
            #expect(provider.defaultDashboardURL.absoluteString == expected[provider], "\(provider)")
        }
    }

    @Test func statusPagesArePinned() {
        let expected: [ProviderID: String] = [
            .claude: "https://status.claude.com",
            .codex: "https://status.openai.com",
            .copilot: "https://www.githubstatus.com",
        ]
        for provider in ProviderID.allCases {
            #expect(provider.statusPageURL?.absoluteString == expected[provider], "\(provider)")
        }
    }

    /// Raw values key config.json, storage and alert state, so they can never change once released.
    @Test func newProvidersHaveTheirPermanentIDsAndNames() {
        #expect(ProviderID(rawValue: "copilot") == .copilot)
        #expect(ProviderID.copilot.displayName == "GitHub Copilot")
        #expect(ProviderID.copilot.logoName == "copilot")
        #expect(ProviderID.copilot.harness == nil)
        #expect(ProviderID(rawValue: "devin") == .devin)
        #expect(ProviderID.devin.displayName == "Devin")
        #expect(ProviderID.devin.logoName == "windsurf")
        #expect(ProviderID.devin.harness == nil)
    }

    @Test func onlyDevinIsALinkOnlyProvider() {
        #expect(ProviderID.allCases.filter(\.isLinkOnly) == [.devin])
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

    @Test func monthLengthFollowsTheMonthEndingAtReset() {
        #expect(UsageWindow.monthMinutes(endingAt: DateParsing.iso8601("2026-03-01T00:00:00Z")) == 28 * 1_440)
        #expect(UsageWindow.monthMinutes(endingAt: DateParsing.iso8601("2026-05-15T08:00:00Z")) == 30 * 1_440)
        #expect(UsageWindow.monthMinutes(endingAt: nil) == nil)
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
