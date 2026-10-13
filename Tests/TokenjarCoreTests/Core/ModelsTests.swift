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
            .devin: "https://app.devin.ai/settings/usage",
        ]
        for provider in ProviderID.allCases {
            #expect(provider.defaultDashboardURL.absoluteString == expected[provider], "\(provider)")
        }
    }

    /// Each is the final URL, with no redirect: status.devin.ai and devinstatus.com both redirect to Devin's.
    @Test func statusPagesArePinned() {
        let expected: [ProviderID: String] = [
            .claude: "https://status.claude.com",
            .codex: "https://status.openai.com",
            .opencodeGo: "https://status.opencode.ai",
            .opencodeZen: "https://status.opencode.ai",
            .copilot: "https://www.githubstatus.com",
            .devin: "https://www.devinstatus.com",
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

    @Test func onlyZenAndDevinReportNoWindows() {
        let expected: [ProviderID: Bool] = [
            .claude: true, .codex: true, .opencodeGo: true, .opencodeZen: false, .antigravity: true, .copilot: true, .devin: false,
        ]
        for provider in ProviderID.allCases {
            #expect(provider.reportsWindows == expected[provider], "\(provider)")
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

    @Test func aWindowHasResetOnceItsResetTimeHasPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageWindow(id: "session", label: "5-hour", usedPercent: 100, resetsAt: now.addingTimeInterval(-60)).hasReset(now: now))
        #expect(UsageWindow(id: "session", label: "5-hour", usedPercent: 100, resetsAt: now).hasReset(now: now))
        #expect(!UsageWindow(id: "session", label: "5-hour", usedPercent: 100, resetsAt: now.addingTimeInterval(60)).hasReset(now: now))
        #expect(!UsageWindow(id: "session", label: "5-hour", usedPercent: 100).hasReset(now: now))
    }

    /// A full 5-hour window that reset a minute ago no longer limits anything; the live 40 % one does.
    @Test func tightestWindowAtATimeSkipsWindowsThatHaveReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(accountID: "a", provider: .claude, windows: [
            UsageWindow(id: "session", label: "5-hour", usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60)),
            UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400)),
        ], fetchedAt: now.addingTimeInterval(-600), source: "test")
        #expect(snapshot.tightestWindow(now: now)?.id == "weekly")
        #expect(snapshot.tightestWindow(now: now.addingTimeInterval(-120))?.id == "session")
    }

    /// Every surface reads this to decide whether an account needs a look, so each case is pinned.
    @Test func attentionClassifiesEveryFetchError() {
        let expected: [(FetchError, FetchError.Attention)] = [
            (.noSubscription("No active OpenCode Go subscription for this key"), .calm),
            (.network("offline"), .transient),
            (.timeout, .transient),
            (.rateLimited(retryAfter: 60), .transient),
            (.cliNotFound("claude"), .actionable),
            (.notSignedIn, .actionable),
            (.unauthorized, .actionable),
            (.parse("shape"), .actionable),
            (.unsupported("model turn"), .actionable),
            (.keychainDenied, .actionable),
        ]
        for (error, attention) in expected {
            #expect(error.attention == attention, "\(error)")
        }
    }

    /// Each message names the cause and what happens next, as one or two whole sentences.
    @Test func errorMessagesSayWhatHappenedAndWhatHappensNext() {
        let expected: [(FetchError, String)] = [
            (.cliNotFound("claude"), "Can't find the claude command on this Mac."),
            (.notSignedIn, "Signed out. Sign in again to see limits."),
            (.unauthorized, "The sign-in or API key was rejected."),
            (.network("URLError"), "Can't reach the server. Tokenjar tries again at the next refresh."),
            (.timeout, "No answer in time. Tokenjar tries again at the next refresh."),
            (.parse("unrecognized output"), "Couldn't read the usage answer. An update may have changed it."),
            (.rateLimited(retryAfter: 60), "Checking too often. Tokenjar waits before the next check."),
            (.keychainDenied, "Keychain access was denied. Tokenjar won't ask again on its own."),
        ]
        for (error, message) in expected {
            #expect(error.userMessage == message)
        }
        for message in [ClaudeUsageFetcher.modelTurnMessage, AntigravityUsageFetcher.modelTurnMessage] {
            #expect(message.hasSuffix("click Try Once More."))
            #expect(!message.contains("CLI"))
        }
    }

    /// The quota sits on Usage & limits; Settings > Plans only lists plans.
    @Test func devinOpensItsUsagePage() {
        #expect(ProviderID.devin.defaultDashboardURL.absoluteString == "https://app.devin.ai/settings/usage")
        #expect(AccountConfig(id: "devin", provider: .devin, label: "Devin").resolvedDashboardURL.absoluteString == "https://app.devin.ai/settings/usage")
    }

    @Test func anOutdatedCLINamesItsMinimumVersion() {
        #expect(FetchError.cliTooOld(name: "agy", minimum: "1.1.11").userMessage == "Update agy to 1.1.11 or later.")
        #expect(FetchError.cliTooOld(name: "codex", minimum: nil).userMessage == "Update codex: this version answers in a format Tokenjar can't read.")
    }

    /// Updating the CLI is the user's move; waiting for the next check changes nothing.
    @Test func outdatedCLIIsActionable() {
        #expect(FetchError.cliTooOld(name: "codex", minimum: "0.50.0").attention == .actionable)
        #expect(FetchError.cliTooOld(name: "codex", minimum: nil).attention == .actionable)
    }

    /// Tokenjar runs claude outside the user's shell, so a key or cloud switch exported only there reads as signed out.
    @Test func claudeSignedOutCopyNamesTheAPIKeyAndCloudRoutes() {
        let message = FetchError.notSignedIn.userMessage(provider: .claude)
        for route in ["Sign in", "claude", "API key", "LiteLLM", "Bedrock", "Vertex", "settings.json", "shell"] {
            #expect(message.contains(route), "\(route) missing from \(message)")
        }
        #expect(message.hasSuffix("."))
    }

    /// "The server" told the user nothing about which of several providers was down.
    @Test func connectionMessagesNameTheProvider() {
        #expect(FetchError.network("dial tcp").userMessage(provider: .copilot) == "Can't reach GitHub Copilot. Tokenjar tries again at the next refresh.")
        #expect(FetchError.timeout.userMessage(provider: .copilot) == "No answer from GitHub Copilot in time. Tokenjar tries again at the next refresh.")
        #expect(FetchError.network("HTTP 503").userMessage(provider: .opencodeGo) == "Can't reach OpenCode Go. Tokenjar tries again at the next refresh.")
        #expect(FetchError.timeout.userMessage(provider: .opencodeGo) == "No answer from OpenCode Go in time. Tokenjar tries again at the next refresh.")
        // Notifications read the provider-free copy, which stays as it was.
        #expect(FetchError.timeout.userMessage == "No answer in time. Tokenjar tries again at the next refresh.")
    }

    @Test func otherProvidersKeepTheSignedOutCopy() {
        for provider in ProviderID.allCases where provider != .claude {
            #expect(FetchError.notSignedIn.userMessage(provider: provider) == FetchError.notSignedIn.userMessage, "\(provider)")
        }
        let others: [FetchError] = [.unauthorized, .cliNotFound("claude"), .parse("shape"), .cliTooOld(name: "claude", minimum: nil), .keychainDenied]
        for error in others {
            #expect(error.userMessage(provider: .claude) == error.userMessage, "\(error)")
        }
    }

    /// `latestSnapshots` shows each account's last snapshot at launch, so a field the stored JSON drops is gone until
    /// the next check.
    @Test func billingRoundTripsThroughStoredJSON() throws {
        let temp = TemporaryDirectory()
        let store = try SQLiteUsageStore(url: temp.url.appending(path: "tokenjar.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for billing in Billing.allCases {
            try store.record(UsageSnapshot(accountID: billing.rawValue, provider: .claude, billing: billing, fetchedAt: now, source: "test"))
        }
        let stored = Dictionary(uniqueKeysWithValues: try store.latestSnapshots().map { ($0.accountID, $0.billing) })
        #expect(stored.count == Billing.allCases.count)
        for billing in Billing.allCases {
            #expect(stored[billing.rawValue] == billing, "\(billing)")
        }
        // Raw values are stored, so renaming a case would orphan every row written before.
        #expect(Billing.allCases.map(\.rawValue) == ["free", "subscription", "pooled", "usageBased", "payAsYouGo"])
    }

    /// A row written before `billing` and `limitStyle` existed. `latestSnapshots` drops a row that fails to decode, so a
    /// required field would blank every account at the first launch after an update.
    @Test func aStoredSnapshotWithoutBillingStillDecodes() throws {
        let json = """
            {"accountID":"max","provider":"claude","plan":"Max 20x","windows":[{"id":"session","label":"5-hour","usedPercent":40,\
            "windowMinutes":300,"resetsAt":800000000,"notStarted":false}],"money":[],"fetchedAt":799990000,"source":"claude CLI","notes":[]}
            """
        let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        let snapshot = try #require(decoded)
        #expect(snapshot.billing == nil)
        #expect(snapshot.windows.map(\.limitStyle) == [nil])
        #expect(snapshot.plan == "Max 20x")
    }

    /// An offline Mac holds only checks that contact a server: Zen reads opencode.db and Devin is a link.
    @Test func providersThatNeedTheNetworkAreTheOnesThatContactOne() {
        let expected: [ProviderID: Bool] = [
            .claude: true, .codex: true, .opencodeGo: true, .opencodeZen: false, .antigravity: true, .copilot: true, .devin: false,
        ]
        for provider in ProviderID.allCases {
            #expect(provider.checkUsesNetwork == expected[provider], "\(provider)")
        }
    }

    /// A row from a newer build may carry a reason this one does not know. `latestSnapshots` drops a row that fails to
    /// decode, which would blank the account's card until its next check.
    @Test func anUnknownLiveCheckFailureReadsAsOther() throws {
        let json = #"{"accountID":"a","provider":"claude","windows":[],"money":[],"fetchedAt":799990000,"source":"Claude Code cache","notes":[],"liveCheckFailure":"captivePortal"}"#
        let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        #expect(decoded?.liveCheckFailure == .other)
        // Stored rows hold the raw values, so renaming a case would misread every saved copy written before.
        #expect([LiveCheckFailure.network, .timeout, .other].map(\.rawValue) == ["network", "timeout", "other"])
    }

    /// Every row stored before the field existed must still decode, as a live answer.
    @Test func aSnapshotWithoutTheFieldStillDecodes() throws {
        let json = #"{"accountID":"a","provider":"claude","windows":[],"money":[],"fetchedAt":799990000,"source":"claude CLI","notes":[]}"#
        let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        let snapshot = try #require(decoded)
        #expect(snapshot.liveCheckFailure == nil)
        let saved = UsageSnapshot(accountID: "a", provider: .codex, fetchedAt: Date(timeIntervalSince1970: 0), source: "Codex session log", liveCheckFailure: .timeout)
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(saved)).liveCheckFailure == .timeout)
    }

    @Test func limitStyleRoundTripsAndDefaultsToHard() throws {
        let windows = [
            UsageWindow(id: "monthly", label: "AI credits", usedPercent: 120, limitStyle: .overage),
            UsageWindow(id: "share", label: "Seat share", usedPercent: 80, limitStyle: .share),
            UsageWindow(id: "session", label: "5-hour", usedPercent: 40),
        ]
        let decoded = try JSONDecoder().decode([UsageWindow].self, from: JSONEncoder().encode(windows))
        #expect(decoded.map(\.limitStyle) == [.overage, .share, nil])
        #expect(LimitStyle.allCases.map(\.rawValue) == ["overage", "share"])
    }

    @Test func monthLengthFollowsTheMonthEndingAtReset() {
        #expect(UsageWindow.monthMinutes(endingAt: DateParsing.iso8601("2026-03-01T00:00:00Z")) == 28 * 1_440)
        #expect(UsageWindow.monthMinutes(endingAt: DateParsing.iso8601("2026-05-15T08:00:00Z")) == 30 * 1_440)
        #expect(UsageWindow.monthMinutes(endingAt: nil) == nil)
    }

    @Test func dateParsingAcceptsMixedFractionsAndOffsets() throws {
        let a = try #require(DateParsing.iso8601("2026-10-10T22:29:59.123456+00:00"))
        let b = try #require(DateParsing.iso8601("2026-10-12T09:00:00+00:00"))
        let c = try #require(DateParsing.iso8601("2026-10-12T11:00:00+02:00"))
        #expect(abs(a.timeIntervalSince1970 - 1_791_671_399.123456) < 0.000_01)
        #expect(b == c)
        #expect(DateParsing.iso8601("2026-10-12 09:00:00") == nil)
        #expect(DateParsing.epoch(1_791_660_000_500) == DateParsing.epoch(1_791_660_000.5))
    }
}
