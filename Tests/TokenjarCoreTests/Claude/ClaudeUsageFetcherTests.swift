import Foundation
import Testing
@testable import TokenjarCore

/// The ways a run can fail that make the fetcher fall back to Claude Code's cache.
private enum FailedRun: CustomTestStringConvertible, Sendable {
    case timeout, unrecognized, missingCLI

    var runner: FakeRunner {
        switch self {
        case .timeout: FakeRunner(output(timedOut: true))
        case .unrecognized: FakeRunner(output("Error: something went wrong\n", exitCode: 1))
        case .missingCLI: FakeRunner()
        }
    }

    var testDescription: String { "\(self)" }
}

private extension TemporaryDirectory {
    /// Uses this directory as home and system root, so nothing touches the real ~/.claude.json or ~/Library.
    func context(_ runner: FakeRunner, cli: String = anyProgram.path, now: Date) -> FetchContext {
        FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: url, overrides: ["claude": cli], searchDirectories: []),
            paths: AppPaths(home: url, environment: [:], systemRoot: url), now: { now }
        )
    }
}

struct ClaudeUsageFetcherTests {
    /// A stored property, so the home outlives every fetch a test runs in it.
    let box = TemporaryDirectory()
    let now = DateParsing.iso8601("2026-10-10T20:00:00Z")!
    let account = AccountConfig(id: "claude-personal", provider: .claude, label: "Personal")

    @Test func mapsAllThreeLimitKindsFromTheCLI() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows == [
            UsageWindow(id: "session", label: "5-hour", usedPercent: 20, windowMinutes: 300, resetsAt: DateParsing.iso8601("2026-10-10T22:29:59.750000+00:00")),
            UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-12T08:59:59.750000+00:00")),
            UsageWindow(id: "weekly:Fable", label: "Week · Fable", usedPercent: 0, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-12T09:00:00+00:00")),
        ])
        #expect(snapshot.windows[0].resetsAt != nil && snapshot.windows[2].resetsAt != nil)
        #expect(snapshot.money.isEmpty, "extra usage is disabled in this capture")
        #expect(snapshot.plan == "Max 20x")
        #expect(snapshot.source == "claude CLI")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.notes.isEmpty)
        #expect(snapshot.accountID == "claude-personal")
    }

    @Test func extraUsageIsInMinorUnitsOfItsCurrency() async throws {
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-extra-usage-jpy.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        // JPY has no minor unit, so 1234 is ¥1234, not ¥12.34.
        #expect(snapshot.money == [MoneyLine(label: "Extra usage", amount: 1234, limit: 5000, currency: "JPY")])
        #expect(ClaudeRateLimits.minorUnitDigits("USD") == 2)
        #expect(ClaudeRateLimits.minorUnitDigits("EUR") == 2)
        #expect(ClaudeRateLimits.minorUnitDigits("JPY") == 0)
        #expect(ClaudeRateLimits.minorUnitDigits("KWD") == 3)
    }

    @Test func decimalPlacesOverridesTheCurrencyDefault() throws {
        let json = #"{"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000,"currency":"USD","decimal_places":0}}"#
        let limits = try JSONDecoder().decode(ClaudeRateLimits.self, from: Data(json.utf8))

        #expect(limits.money == [MoneyLine(label: "Extra usage", amount: 1234, limit: 5000, currency: "USD")])
    }

    /// Only an explicit `is_enabled: true` shows money; a capture without the flag is not evidence extra usage is on.
    @Test func extraUsageWithoutTheEnabledFlagIsHidden() throws {
        let json = #"{"extra_usage":{"used_credits":100,"monthly_limit":500,"currency":"USD"}}"#
        let limits = try JSONDecoder().decode(ClaudeRateLimits.self, from: Data(json.utf8))

        #expect(limits.money.isEmpty)
    }

    @Test func unknownLimitKindKeepsItsKindAsID() async throws {
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-extra-usage-jpy.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        let monthly = try #require(snapshot.windows.first { $0.id == "monthly_all" })
        #expect(monthly.label == "Monthly all")
        #expect(monthly.windowMinutes == nil)
        #expect(monthly.usedPercent == 37.5)
        #expect(monthly.resetsAt == DateParsing.iso8601("2026-11-01T00:00:00Z"))
    }

    @Test func malformedLimitsAreSkippedAndWindowIDsStayUnique() throws {
        let json = #"""
        {"limits":[
          {"kind":"session","percent":"n/a","resets_at":"2026-10-10T22:00:00Z"},
          {"percent":12},
          {"kind":"weekly_scoped","percent":5,"resets_at":"2026-10-12T09:00:00Z","scope":{"model":{"display_name":"Fable"},"surface":"unexpected"}},
          {"kind":"weekly_scoped","percent":7,"resets_at":"2026-10-12T09:00:00Z","scope":{"model":{"display_name":"Fable"},"surface":null}},
          {"kind":"monthly_scoped","percent":2,"resets_at":null,"scope":{"model":null,"surface":{"display_name":"Design"}}}
        ],"extra_usage":"unexpected"}
        """#
        let limits = try JSONDecoder().decode(ClaudeRateLimits.self, from: Data(json.utf8))

        #expect(limits.windows.map(\.id) == ["weekly:Fable", "monthly_scoped:Design"])
        #expect(limits.windows.map(\.usedPercent) == [5, 2])
        #expect(limits.windows.last?.label == "Monthly scoped · Design")
        #expect(limits.money.isEmpty)
    }

    @Test func signedOutConfigThrowsNotSignedIn() async throws {
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        await #expect(throws: FetchError.notSignedIn) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }
    }

    @Test(arguments: [nil, "claude-json-max.json"])
    func apiKeyLoginHasNoPlanLimits(globalConfig: String?) async throws {
        if let globalConfig { try box.copyFixture("Claude/\(globalConfig)", to: ".claude.json") }
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-api-key.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.source == "claude CLI")
        #expect(snapshot.plan == nil, "an API key does not bill the subscription saved in .claude.json")
        #expect(snapshot.billing == .payAsYouGo)
    }

    @Test func apiKeyReportWithoutRateLimitsIgnoresTheSubscriptionCache() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let stream = try fixtureText("Claude/stream-plan-limits.jsonl")
            .replacingOccurrences(of: #""apiKeySource":"none""#, with: #""apiKeySource":"apiKeyHelper""#)
            .replacingOccurrences(of: #""rate_limits":"#, with: #""rate_limits_removed":"#)

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stream)), now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.source == "claude CLI")
    }

    @Test func malformedUsageCacheKeepsPlanAndSignIn() async throws {
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise"},"cachedUsageUtilization":{"fetchedAtMs":"soon"}}"#, to: ".claude.json")

        let reported = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl"))), now: now))
        #expect(reported.plan == "Enterprise")

        let unreported = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl"))), now: now))
        #expect(unreported.plan == "Enterprise")
        #expect(unreported.notes == ["No plan limits for this login"])
    }

    @Test(arguments: [
        #""num_turns":1,"total_cost_usd":0.0123"#,
        #""num_turns":1,"total_cost_usd":0"#,
        #""num_turns":0,"total_cost_usd":0.0123"#,
    ])
    func usageAnsweredByAModelTurnFailsInsteadOfServingTheCache(resultFields: String) async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let stream = """
        {"type":"system","subtype":"init","apiKeySource":"none","model":"claude-opus-5-5"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"MODEL_TEXT"}],"usage":{"input_tokens":12,"output_tokens":40}}}
        {"type":"result","subtype":"success","is_error":false,\(resultFields),"result":"MODEL_TEXT"}
        """

        await #expect(throws: FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stream)), now: now))
        }
    }

    /// A run killed mid-turn has no result line to count its turns, but the model reply it printed already spent tokens.
    /// Serving the cache, or calling it a timeout, would let every refresh spend tokens again.
    @Test(arguments: [true, false])
    func aModelReplyWithoutAResultLineIsAModelTurn(timedOut: Bool) async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let stream = """
        {"type":"system","subtype":"init","apiKeySource":"none","model":"claude-opus-5-5"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"MODEL_TEXT"}],"usage":{"input_tokens":12,"output_tokens":40}}}

        """
        let runner = FakeRunner(output(stream, exitCode: timedOut ? 0 : 1, timedOut: timedOut))

        await #expect(throws: FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }
    }

    /// The local `/usage` answer is an assistant line too, so a run that hangs after printing it is only a timeout.
    @Test func aTimeoutAfterTheLocalUsageAnswerIsStillATimeout() async throws {
        let lines = try fixtureText("Claude/stream-signed-out.jsonl").split(separator: "\n")
        let partial = Data((lines.prefix(2).joined(separator: "\n") + "\n").utf8)

        await #expect(throws: FetchError.timeout) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stdout: partial, timedOut: true)), now: now))
        }
    }

    @Test func usageBasedEnterpriseSeatHasNoPlanLimits() async throws {
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise","seatTier":"enterprise_usage_based"}}"#, to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.plan == "Enterprise (usage-based)")
        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test func aSpendCapIsTheOnlyLimitOfASeatWithoutPlanLimits() async throws {
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise","seatTier":"enterprise_usage_based"}}"#, to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/enterprise-usage-based-spend-cap.stream.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        let window = try #require(snapshot.windows.first)
        #expect(snapshot.windows.count == 1)
        #expect(window.id == "spend-cap")
        #expect(window.label == "Spend limit")
        // Spending past the limit is allowed, so 100 % is not a stop.
        #expect(window.limitStyle == .overage)
        #expect(abs(window.usedPercent - 4.132) < 0.0001)
        #expect(snapshot.money == [MoneyLine(label: "Extra usage", amount: 41.32, limit: 1000, currency: "USD")])
        // The bar says what the note would: there are no plan limits, only this one.
        #expect(snapshot.notes.isEmpty)
    }

    /// A usage-based seat as `.claude.json` holds it after Claude Code fetched its usage: no plan limits, a spend cap.
    private func usageBasedSeat(cacheFetchedAt: String, cacheAccount: String = "ACCOUNT_UUID_C") -> String {
        let ms = Int(DateParsing.iso8601(cacheFetchedAt)!.timeIntervalSince1970 * 1000)
        return #"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise","seatTier":"enterprise_usage_based"},"#
            + #""cachedUsageUtilization":{"fetchedAtMs":\#(ms),"accountUuid":"\#(cacheAccount)","utilization":{"five_hour":null,"seven_day":null,"#
            + #""extra_usage":{"is_enabled":true,"monthly_limit":300000,"used_credits":47856,"utilization":15.952,"currency":"USD","decimal_places":2},"#
            + #""limits":[]}}}"#
    }

    /// Runs seconds apart can answer with only the local cost summary, while Claude Code's cache holds the spend it
    /// fetched moments before. Without the cache the bar would come and go between refreshes.
    @Test func aSeatWithoutPlanLimitsReadsItsSpendLimitFromTheCacheWhenTheReportIsMissing() async throws {
        try box.write(usageBasedSeat(cacheFetchedAt: "2026-10-10T19:59:30Z"), to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.map(\.id) == ["spend-cap"])
        #expect(abs((snapshot.windows.first?.usedPercent ?? 0) - 15.952) < 0.0001)
        #expect(snapshot.money == [MoneyLine(label: "Extra usage", amount: 478.56, limit: 3000, currency: "USD")])
        #expect(snapshot.source == ClaudeUsageFetcher.cacheSource)
        #expect(snapshot.fetchedAt == DateParsing.iso8601("2026-10-10T19:59:30Z"))
        #expect(snapshot.notes.isEmpty)
        #expect(snapshot.liveCheckFailure == nil)
    }

    /// Last month's spend says nothing about this month's cap.
    @Test func aCachedSpendLimitFromAnEarlierMonthIsNotShown() async throws {
        try box.write(usageBasedSeat(cacheFetchedAt: "2026-09-30T23:00:00Z"), to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.isEmpty)
        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test func anotherAccountsCachedSpendIsNotShown() async throws {
        try box.write(usageBasedSeat(cacheFetchedAt: "2026-10-10T19:59:30Z", cacheAccount: "ACCOUNT_UUID_OTHER"), to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.isEmpty)
    }

    /// Claude's /usage gives no reset for the cap. Claude's own usage page shows it resetting at midnight UTC on the
    /// 1st, so the window is the UTC calendar month, which gives the bar its countdown and pace.
    @Test(arguments: [
        ("2026-10-10T20:00:00Z", "2026-11-01T00:00:00Z", 31 * 1440),
        ("2026-12-31T23:59:00Z", "2027-01-01T00:00:00Z", 31 * 1440),
        ("2027-02-01T00:00:00Z", "2027-03-01T00:00:00Z", 28 * 1440),
    ])
    func aSpendLimitResetsAtTheStartOfTheNextUTCMonth(_ at: String, _ resets: String, _ minutes: Int) async throws {
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise","seatTier":"enterprise_usage_based"}}"#, to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/enterprise-usage-based-spend-cap.stream.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: DateParsing.iso8601(at)!))

        #expect(snapshot.windows.first?.resetsAt == DateParsing.iso8601(resets))
        #expect(snapshot.windows.first?.windowMinutes == minutes)
    }

    @Test func spendWithNoCapHasNoWindow() async throws {
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise","seatTier":"enterprise_usage_based"}}"#, to: ".claude.json")
        let stream = try fixtureText("Claude/enterprise-usage-based-spend-cap.stream.jsonl")
            .replacingOccurrences(of: #""monthly_limit":100000"#, with: #""monthly_limit":null"#)
        let runner = FakeRunner(output(stream))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.first?.limit == nil)
    }

    /// Extra usage starts only once a plan limit is hit, so the plan's own limits stay the account's number.
    @Test func planLimitsKeepExtraUsageOutOfTheWindows() async throws {
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-extra-usage-jpy.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(!snapshot.money.isEmpty)
        #expect(!snapshot.windows.isEmpty)
        #expect(!snapshot.windows.contains { $0.id == "spend-cap" })
    }

    @Test func bedrockSettingsAreNotMistakenForSignedOut() async throws {
        try box.write(#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-east-1"}}"#, to: ".claude/settings.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test(arguments: [
        "llm-gateway-auth-token.settings.json", "gateway-env.settings.json", "gateway-env-with-token.settings.json",
        "api-key-in-settings.settings.json", "anthropic-aws.settings.json", "anthropic-google-cloud.settings.json", "mantle.settings.json",
    ])
    func aLoginBilledOutsideThePlanIsNotMistakenForSignedOut(settings: String) async throws {
        try box.copyFixture("Claude/\(settings)", to: ".claude/settings.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.billing == .payAsYouGo)
    }

    @Test func aBaseURLAloneIsAGateway() async throws {
        try box.write(#"{"env":{"ANTHROPIC_BASE_URL":"https://llm-gateway.example.invalid"}}"#, to: ".claude/settings.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test func emptyGatewayVariablesStillReadAsSignedOut() async throws {
        try box.write(#"{"env":{"ANTHROPIC_BASE_URL":"","ANTHROPIC_AUTH_TOKEN":"","CLAUDE_CODE_USE_GATEWAY":"0"}}"#, to: ".claude/settings.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        await #expect(throws: FetchError.notSignedIn) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }
    }

    @Test(arguments: ["bedrock-managed.managed-settings.json", "gateway.managed-settings.json"])
    func managedSettingsRouteTheLoginToo(managed: String) async throws {
        try box.copyFixture("Claude/\(managed)", to: TestPaths.managedSettings)
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test func aGatewayWinsOverAnOldSubscriptionLogin() async throws {
        try box.copyFixture("Claude/bedrock-with-old-max-login.claude.json", to: ".claude.json")
        try box.copyFixture("Claude/llm-gateway-auth-token.settings.json", to: ".claude/settings.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.isEmpty, "the old login's saved limits are not this gateway's")
        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.source == "claude CLI")
        #expect(snapshot.plan == nil)
    }

    @Test func reportedPlanLimitsWinOverABaseURLInTheSettings() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        try box.write(#"{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.invalid"}}"#, to: ".claude/settings.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(!snapshot.windows.isEmpty)
        #expect(snapshot.plan == "Max 20x", "a proxy in front of a subscription still bills the plan")
        #expect(snapshot.billing == nil)
    }

    @Test func aGatewayNeverFallsBackToAnOldSubscriptionLoginsCache() async throws {
        try box.copyFixture("Claude/bedrock-with-old-max-login.claude.json", to: ".claude.json")
        try box.copyFixture("Claude/llm-gateway-auth-token.settings.json", to: ".claude/settings.json")

        await #expect(throws: FetchError.timeout) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(timedOut: true)), now: now))
        }
    }

    @Test func runsTheCLIWithHooksOffFromTheProbeDirectory() async throws {
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl")))
        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")

        _ = try await ClaudeUsageFetcher().fetch(work, context: box.context(runner, now: now))
        _ = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        let calls = runner.calls
        try #require(calls.count == 2)
        let probe = AppPaths(home: box.url, environment: [:]).probeDirectory
        #expect(calls[0].executable.path == anyProgram.path)
        #expect(calls[0].arguments == [
            "-p", "/usage", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
        ])
        #expect(calls[0].environment["CLAUDE_CONFIG_DIR"] == box.url.appending(path: ".claude-work").path)
        #expect(calls[1].environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(calls[0].environment["HOME"] == box.url.path)
        #expect(calls[0].currentDirectory?.path == probe.path)
        #expect(FileManager.default.fileExists(atPath: probe.path))
        #expect(calls[0].stdin == nil)
        #expect(calls[0].timeout == 45)
        #expect(calls[0].outputLimit == 2 * 1024 * 1024)
    }

    @Test func probeFolderAndItsParentAreOwnerOnlyEvenIfTheyExisted() async throws {
        let paths = AppPaths(home: box.url)
        try makeWorldReadableDirectory(paths.probeDirectory)
        try makeWorldReadableDirectory(paths.supportDirectory)

        _ = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl"))), now: now))

        #expect(try posixMode(paths.supportDirectory) == 0o700)
        #expect(try posixMode(paths.probeDirectory) == 0o700)
    }

    @Test func profileDirReadsItsOwnConfigAndLegacyFileWins() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        try box.write(#"{"oauthAccount":{"organizationType":"claude_pro"}}"#, to: ".claude-work/.claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl")))
        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")

        let fromProfile = try await ClaudeUsageFetcher().fetch(work, context: box.context(runner, now: now))
        #expect(fromProfile.plan == "Pro")

        try box.write(#"{"oauthAccount":{"organizationType":"claude_team"}}"#, to: ".claude-work/.config.json")
        let fromLegacy = try await ClaudeUsageFetcher().fetch(work, context: box.context(runner, now: now))
        #expect(fromLegacy.plan == "Team")
    }

    // MARK: Cache fallback

    @Test func missingCLIFallsBackToClaudeCodeCache() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let runner = FakeRunner(output())

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, cli: "/nonexistent/claude", now: now))

        #expect(runner.calls.isEmpty)
        #expect(snapshot.source == "Claude Code cache")
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 1_791_660_000.5))
        #expect(snapshot.plan == "Max 20x")
        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "weekly:Fable"])
        #expect(snapshot.windows.map(\.usedPercent) == [30, 40, 10])
        #expect(snapshot.money == [MoneyLine(label: "Extra usage", amount: 25.5, limit: 50, currency: "GBP")])
        #expect(snapshot.notes == ["Can't find the claude command on this Mac. Showing the last values Claude Code saved."])
    }

    @Test func cacheOfAnotherAccountIsIgnored() async throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("Claude/claude-json-max.json")) as? [String: Any])
        var cache = try #require(json["cachedUsageUtilization"] as? [String: Any])
        cache["accountUuid"] = "ACCOUNT_UUID_OTHER"
        json["cachedUsageUtilization"] = cache
        try JSONSerialization.data(withJSONObject: json).write(to: box.url.appending(path: ".claude.json"))

        await #expect(throws: FetchError.cliNotFound("claude")) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output()), cli: "/nonexistent/claude", now: now))
        }
    }

    @Test func timeoutFallsBackToCacheOrReportsTimeout() async throws {
        let runner = FakeRunner(output(timedOut: true))

        await #expect(throws: FetchError.timeout) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }

        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        #expect(snapshot.source == "Claude Code cache")
    }

    @Test func cacheWithoutLimitsUsesBucketsAndDropsPastResets() async throws {
        try box.copyFixture("Claude/claude-json-pro-buckets.json", to: ".claude.json")

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output()), cli: "/nonexistent/claude", now: now))

        #expect(snapshot.plan == "Pro")
        #expect(snapshot.windows == [
            UsageWindow(id: "session", label: "5-hour", usedPercent: 55.5, windowMinutes: 300, resetsAt: DateParsing.iso8601("2026-10-10T21:00:00+00:00")),
            UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-14T09:00:00.5+00:00")),
            UsageWindow(id: "weekly:Opus", label: "Week · Opus", usedPercent: 12, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-14T09:00:00+00:00")),
        ])
        #expect(snapshot.money.isEmpty)
    }

    @Test func subscriptionWithoutReportedLimitsUsesCacheInsteadOfClaimingNone() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")
        let runner = FakeRunner(output(stdout: try fixture("Claude/stream-signed-out.jsonl")))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.source == "Claude Code cache")
        #expect(!snapshot.notes.contains("No plan limits for this login"))
    }

    /// The cache looks like a live answer except for its note, so the snapshot itself says why it stands in: an offline
    /// Mac and a broken CLI must not read alike.
    @Test(arguments: [
        (FailedRun.timeout, LiveCheckFailure.timeout),
        (.unrecognized, .other),
        (.missingCLI, .other),
    ])
    fileprivate func aSavedCopyRecordsWhyTheLiveCheckFailed(_ run: FailedRun, _ expected: LiveCheckFailure) async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(run.runner, cli: run == .missingCLI ? "/nonexistent/claude" : anyProgram.path, now: now))

        #expect(snapshot.source == ClaudeUsageFetcher.cacheSource)
        #expect(snapshot.liveCheckFailure == expected)
    }

    /// The card says why a network error or a timeout made the copy stand in, in the provider's name and only when the
    /// cause is not Mac-wide, so the note says only where the numbers come from.
    @Test func aConnectionFailureLeavesItsReasonToTheCard() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(timedOut: true)), now: now))

        #expect(snapshot.notes == ["Showing the last values Claude Code saved."])
    }

    @Test func aLiveAnswerHasNoLiveCheckFailure() async throws {
        try box.copyFixture("Claude/claude-json-max.json", to: ".claude.json")

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeRunner(output(stdout: try fixture("Claude/stream-plan-limits.jsonl"))), now: now))

        #expect(snapshot.source == ClaudeUsageFetcher.source)
        #expect(snapshot.liveCheckFailure == nil)
    }

    @Test func unrecognizedOutputIsAParseError() async throws {
        let runner = FakeRunner(output(stdout: Data("Error: something went wrong\n".utf8), exitCode: 1))

        await #expect {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        } throws: { error in
            if case FetchError.parse = error { return true }
            return false
        }
    }

    // MARK: Plan labels

    @Test(arguments: [
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_max", organizationRateLimitTier: "default_claude_max_20x"), "Max 20x"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_max", userRateLimitTier: "default_claude_max_5x"), "Max 5x"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_max"), "Max"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_pro", organizationRateLimitTier: "default_claude_pro"), "Pro"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_team"), "Team"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_team", userRateLimitTier: "default_claude_max_5x"), "Team Premium"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_enterprise"), "Enterprise"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_enterprise", seatTier: "enterprise_usage_based"), "Enterprise (usage-based)"),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: "claude_free"), nil),
        (ClaudeGlobalConfig.OAuthAccount(organizationType: nil), nil),
    ])
    func planLabel(account: ClaudeGlobalConfig.OAuthAccount, expected: String?) {
        #expect(ClaudeGlobalConfig.planLabel(account) == expected)
    }
}
