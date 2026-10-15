import Foundation
import Testing
@testable import TokenjarCore

/// The fixtures are the filtered `gh api` output, not the raw `copilot_internal/user` body.
final class CopilotUsageFetcherTests {
    let temp = TemporaryDirectory()
    var home: URL { temp.url }
    let account = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
    let now = DateParsing.iso8601("2026-10-11T12:00:00Z")!
    let cycleEnd = DateParsing.iso8601("2026-11-01T00:00:00Z")!

    init() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    // MARK: Invocation

    /// docs/privacy.md quotes this command. Any field flag would turn the request into a POST, --cache would write the
    /// answer to disk, and the filter is what keeps the login, ids and organizations inside gh.
    @Test func runsAPinnedReadOnlyGETThroughGh() async throws {
        let runner = FakeRunner(output(try fixtureText("Copilot/user-enterprise.json")))
        let context = try context(runner)
        try makeWorldReadableDirectory(context.paths.supportDirectory)
        _ = try await CopilotUsageFetcher().fetch(account, context: context)

        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable.path == home.appending(path: "bin/gh").path)
        #expect(call.arguments == [
            "api", "--method", "GET", "-H", "X-GitHub-Api-Version: 2025-04-01", "copilot_internal/user", "--jq",
            #"{copilot_plan, access_type_sku, token_based_billing, quota_reset_date, quota_reset_date_utc, quota_snapshots: ((.quota_snapshots // {}) | map_values({entitlement, remaining, quota_remaining, percent_remaining, unlimited, has_quota, overage_count, overage_permitted, credits_used, token_based_billing})), monthly_quotas: (.monthly_quotas | if type == "object" then {chat, completions} else null end), limited_user_quotas: (.limited_user_quotas | if type == "object" then {chat, completions} else null end)}"#,
        ])
        let methodIndex = try #require(call.arguments.firstIndex(of: "--method"))
        #expect(call.arguments[methodIndex + 1] == "GET")
        for flag in ["-f", "-F", "--field", "--raw-field", "--input", "--cache", "--paginate", "-X", "--hostname"] {
            #expect(!call.arguments.contains { $0 == flag || $0.hasPrefix("\(flag)=") }, "\(flag)")
        }
        #expect(call.currentDirectory == context.paths.probeDirectory)
        #expect(try posixMode(context.paths.probeDirectory) == 0o700)
        #expect(try posixMode(context.paths.supportDirectory) == 0o700)
        #expect(call.stdin == nil)
        #expect(call.timeout == 20)
    }

    @Test func environmentIsTheMinimalOneWithGhTelemetryAndPromptsOff() async throws {
        let runner = FakeRunner(output(try fixtureText("Copilot/user-enterprise.json")))
        let context = try context(runner)
        _ = try await CopilotUsageFetcher().fetch(account, context: context)

        var expected = context.cli.baseEnvironment()
        expected["GH_TELEMETRY"] = "false"
        expected["DO_NOT_TRACK"] = "1"
        expected["GH_NO_UPDATE_NOTIFIER"] = "1"
        expected["GH_PROMPT_DISABLED"] = "1"
        #expect(runner.calls.first?.environment == expected)
        #expect(runner.calls.first?.environment["GH_CONFIG_DIR"] == nil)
    }

    @Test func profileFolderBecomesGhConfigDir() async throws {
        let runner = FakeRunner(output(try fixtureText("Copilot/user-enterprise.json")))
        let work = AccountConfig(id: "copilot-work", provider: .copilot, label: "Work", profileDir: "~/.config/gh-work")
        _ = try await CopilotUsageFetcher().fetch(work, context: context(runner))
        #expect(runner.calls.first?.environment["GH_CONFIG_DIR"] == home.appending(path: ".config/gh-work").path)
    }

    /// Runs the pinned filter through the system jq on a full response, so a filter edit that lets an identity field
    /// through fails here even if the pinned string above is updated with it.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func filterKeepsNoLoginIdOrOrganization() throws {
        let full = """
        {"login":"placeholder-login","id":1234,"analytics_tracking_id":"placeholder","assigned_date":"2026-01-01",
         "organization_login_list":["placeholder-org"],"organization_list":[{"id":5,"login":"placeholder-org","name":"Placeholder"}],
         "enterprise_list":[{"id":6}],"endpoints":{"api":"https://api.example.invalid"},"copilot_plan":"enterprise",
         "access_type_sku":"copilot_enterprise_seat_quota","token_based_billing":true,"quota_reset_date":"2026-11-01",
         "quota_reset_date_utc":"2026-11-01T00:00:00.000Z","quota_snapshots":{"premium_interactions":{"entitlement":1000,
         "remaining":750,"quota_remaining":750.5,"percent_remaining":75.0,"unlimited":false,"has_quota":true,"overage_count":0,
         "overage_permitted":true,"overage_entitlement":0,"credits_used":250,"token_based_billing":true,"quota_id":"placeholder",
         "quota_reset_at":0,"timestamp_utc":"2026-10-11T12:00:00Z"}},
         "monthly_quotas":{"chat":50,"completions":2000,"organization_login":"placeholder-org","id":7},
         "limited_user_quotas":{"chat":40,"completions":1500,"login":"placeholder-login"}}
        """
        let (status, filtered) = try runFilter(full)

        #expect(status == 0)
        for leaked in ["placeholder", "1234", "login", "\"id\"", "organization", "enterprise_list", "endpoints", "assigned_date", "quota_id", "timestamp_utc"] {
            #expect(!filtered.contains(leaked), "\(leaked)")
        }
        #expect(filtered.contains("\"credits_used\":250"))
        #expect(filtered.contains(#""monthly_quotas":{"chat":50,"completions":2000}"#))
        #expect(filtered.contains(#""limited_user_quotas":{"chat":40,"completions":1500}"#))
    }

    /// Free's quota objects are read only for chat and completions. A value that is not an object must not make the
    /// filter fail, since that fails the whole check and hides the numbers that did arrive.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")), arguments: [
        #"{"copilot_plan":"free"}"#,
        #"{"copilot_plan":"free","monthly_quotas":null,"limited_user_quotas":null}"#,
        #"{"copilot_plan":"free","monthly_quotas":"unexpected","limited_user_quotas":[1]}"#,
    ])
    func filterTurnsMissingOrOddFreeQuotasIntoNull(response: String) throws {
        let (status, filtered) = try runFilter(response)
        #expect(status == 0)
        #expect(filtered.contains(#""monthly_quotas":null"#))
        #expect(filtered.contains(#""limited_user_quotas":null"#))
    }

    // MARK: Mapping

    @Test func enterpriseSeatShowsItsMonthlyAICredits() async throws {
        let snapshot = try await fetch(output(try fixtureText("Copilot/user-enterprise.json")))
        #expect(snapshot.windows == [
            UsageWindow(id: "monthly", label: "AI credits", usedPercent: (1000 - 750.5) / 1000 * 100, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
        ])
        #expect(snapshot.plan == "Enterprise")
        #expect(snapshot.source == "gh CLI")
        #expect(snapshot.money.isEmpty)
        #expect(snapshot.notes.isEmpty)
        #expect(snapshot.provider == .copilot)
        #expect(snapshot.accountID == "copilot")
        #expect(snapshot.fetchedAt == now)
    }

    @Test func freePlanDerivesChatAndCompletionsFromItsMonthlyQuotas() async throws {
        let snapshot = try await fetch(output(try fixtureText("Copilot/user-free.json")))
        #expect(snapshot.windows == [
            UsageWindow(id: "chat:monthly", label: "Chat", usedPercent: 20, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
            UsageWindow(id: "completions:monthly", label: "Completions", usedPercent: 25, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
        ])
        #expect(snapshot.plan == "Free")
        #expect(snapshot.notes.isEmpty)
    }

    @Test func freePlanPrefersAMeteredSnapshotOverTheMonthlyQuotas() throws {
        let json = """
        {"access_type_sku":"free_limited_copilot","copilot_plan":"free","quota_reset_date_utc":"2026-11-01T00:00:00Z",
         "monthly_quotas":{"chat":50,"completions":2000},"limited_user_quotas":{"chat":40,"completions":"1000"},
         "quota_snapshots":{"chat":{"entitlement":50,"quota_remaining":10,"unlimited":false}}}
        """
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.windows.map(\.id) == ["chat:monthly", "completions:monthly"])
        #expect(snapshot.windows.map(\.usedPercent) == [80, 50])
    }

    @Test func monthlyQuotasAreIgnoredOutsideTheFreePlan() throws {
        let json = """
        {"access_type_sku":"monthly_subscriber_quota","copilot_plan":"individual","quota_reset_date_utc":"2026-11-01T00:00:00Z",
         "monthly_quotas":{"chat":50,"completions":2000},"limited_user_quotas":{"chat":40,"completions":1500},
         "quota_snapshots":{"chat":{"entitlement":0,"unlimited":true},"completions":{"entitlement":0,"unlimited":true}}}
        """
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.windows.isEmpty)
    }

    @Test func pooledSeatWithoutAPerUserBudgetShowsCreditsUsedAsANote() async throws {
        let snapshot = try await fetch(output(try fixtureText("Copilot/user-pooled-unlimited.json")))
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["31 AI credits used this cycle (no per-user limit)"])
        #expect(snapshot.plan == "Business")
    }

    @Test func premiumModelsIsTheSameAllowanceAsPremiumInteractions() async throws {
        let snapshot = try await fetch(output(try fixtureText("Copilot/user-premium-models.json")))
        #expect(snapshot.windows == [
            UsageWindow(id: "monthly", label: "AI credits", usedPercent: 25, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
        ])
        #expect(snapshot.plan == "Pro+")
    }

    /// The filter turns a null premium_models into an object of nulls, and VS Code reads `premium_models ??
    /// premium_interactions`, so an empty premium_models must not hide the real allowance.
    @Test(arguments: [
        #"{"entitlement":null,"remaining":null,"quota_remaining":null,"percent_remaining":null,"unlimited":null,"has_quota":null,"overage_count":null,"overage_permitted":null,"credits_used":null,"token_based_billing":null}"#,
        "null",
    ])
    func anEmptyPremiumModelsFallsBackToPremiumInteractions(premiumModels: String) throws {
        let json = """
        {"copilot_plan":"individual","quota_reset_date_utc":"2026-11-01T00:00:00Z","quota_snapshots":{"premium_models":\(premiumModels),
         "premium_interactions":{"entitlement":300,"quota_remaining":150,"unlimited":false}}}
        """
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.windows == [
            UsageWindow(id: "monthly", label: "Premium requests", usedPercent: 50, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
        ])
        #expect(snapshot.notes.isEmpty)
    }

    /// A token-billed Business seat can arrive as a zero-entitlement placeholder without `unlimited`. The count is
    /// still the only number there is.
    @Test func aTokenBilledPlaceholderWithoutTheUnlimitedFlagKeepsItsCreditsUsed() throws {
        let json = """
        {"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,
         "remaining":0,"quota_remaining":0,"percent_remaining":100,"credits_used":31,"unlimited":false}}}
        """
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["31 AI credits used this cycle (no per-user limit)"])
    }

    /// Outside token billing a zero entitlement is Free's placeholder, not a pooled seat, so a zero count is no news.
    @Test func aRequestBilledPlaceholderGetsNoCreditsNote() throws {
        let json = """
        {"copilot_plan":"free","token_based_billing":false,"quota_snapshots":{"premium_interactions":{"entitlement":0,
         "quota_remaining":0,"percent_remaining":0,"credits_used":0,"unlimited":false}}}
        """
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.notes == ["No per-user limits for this account"])
    }

    @Test func aPooledSeatOnPremiumRequestsCountsPremiumRequests() throws {
        let json = #"{"copilot_plan":"business","token_based_billing":false,"quota_snapshots":{"premium_interactions":{"entitlement":0,"unlimited":true,"credits_used":5}}}"#
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.notes == ["5 premium requests used this cycle (no per-user limit)"])
    }

    @Test func legacyPremiumRequestsFallBackToPercentRemainingAndTheResetDate() async throws {
        let snapshot = try await fetch(output(try fixtureText("Copilot/user-legacy-premium.json")))
        #expect(snapshot.windows == [
            UsageWindow(id: "monthly", label: "Premium requests", usedPercent: 40, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
            UsageWindow(id: "codereview:monthly", label: "Code review", usedPercent: 10, windowMinutes: 31 * 1_440, resetsAt: cycleEnd),
        ])
        #expect(snapshot.plan == "Pro")
    }

    @Test func overageGoesPast100AndAddsANote() async throws {
        let snapshot = try await fetch(output(try fixtureText("Copilot/user-overage.json")))
        #expect(snapshot.windows.map(\.usedPercent) == [110.75])
        #expect(snapshot.notes == ["2,150 AI credits over the allowance this cycle"])
        #expect(snapshot.plan == "Max")
    }

    @Test(arguments: [
        (#"{"entitlement":100,"quota_remaining":-5,"overage_count":0,"unlimited":false}"#, 100.0),
        (#"{"entitlement":100,"quota_remaining":120,"unlimited":false}"#, 0.0),
        (#"{"entitlement":100,"percent_remaining":"35","unlimited":false}"#, 65.0),
    ])
    func usedPercentStaysInRangeWithoutRealOverage(snapshot: String, used: Double) throws {
        let json = #"{"copilot_plan":"individual","quota_reset_date":"2026-11-01","quota_snapshots":{"premium_interactions":\#(snapshot)}}"#
        let result = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(result.windows.map(\.usedPercent) == [used])
    }

    @Test func unlimitedEverywhereSaysThereIsNoPerUserLimit() throws {
        let json = #"{"copilot_plan":"enterprise","quota_snapshots":{"chat":{"entitlement":0,"unlimited":true},"premium_interactions":{"entitlement":0,"unlimited":true}}}"#
        let snapshot = try CopilotUsageFetcher.snapshot(from: Data(json.utf8), account: account, now: now)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No per-user limits for this account"])
    }

    /// The individual names are inferred from VS Code's Copilot extension.
    @Test(arguments: [
        ("free", "Free"), ("individual", "Pro"), ("individual_pro", "Pro+"), ("individual_max", "Max"),
        ("business", "Business"), ("enterprise", "Enterprise"), ("Enterprise", "Enterprise"), ("some_new_plan", "Some New Plan"),
    ])
    func planNamesFollowGitHubsMarketing(raw: String, label: String) {
        #expect(CopilotUsageFetcher.planLabel(raw) == label)
    }

    // MARK: Failures

    @Test func missingGhIsCLINotFoundWithoutRunningAnything() async throws {
        let runner = FakeRunner(output("{}"))
        let context = try context(runner, ghPath: home.appending(path: "bin/not-installed").path)
        await #expect(throws: FetchError.cliNotFound("gh")) { try await CopilotUsageFetcher().fetch(self.account, context: context) }
        #expect(runner.calls.isEmpty)
    }

    @Test func ghThatCannotStartIsCLINotFound() async throws {
        let runner = FakeRunner { _ in throw CocoaError(.executableNotLoadable) }
        await #expect(throws: FetchError.cliNotFound("gh")) { try await self.fetch(runner) }
    }

    /// gh exits 4 when it has no login and 1 with "gh: <message> (HTTP <status>)" when the API refuses. stderr is only
    /// matched, never kept, since it can name the account.
    @Test(arguments: [
        (output("", stderr: "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n", exitCode: 4), FetchError.notSignedIn),
        (output("", stderr: "gh: Bad credentials (HTTP 401)\n", exitCode: 1), FetchError.unauthorized),
        (output("", stderr: "gh: Resource not accessible by integration (HTTP 403)\n", exitCode: 1), FetchError.noSubscription("No Copilot access for this GitHub account")),
        (output("", stderr: "gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization. (HTTP 403)\n", exitCode: 1), FetchError.noSubscription("No Copilot access for this GitHub account")),
        (output("", stderr: "gh: Not Found (HTTP 404)\n", exitCode: 1), FetchError.noSubscription("No Copilot access for this GitHub account")),
        (output("", stderr: "gh: API rate limit exceeded for user ID 0. (HTTP 403)\n", exitCode: 1), FetchError.rateLimited(retryAfter: nil)),
        (output("", stderr: "gh: Too Many Requests (HTTP 429)\n", exitCode: 1), FetchError.rateLimited(retryAfter: nil)),
        (output("", stderr: "gh: Server Error (HTTP 502)\n", exitCode: 1), FetchError.network("GitHub API unavailable")),
        (output("", stderr: "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n", exitCode: 1), FetchError.network("gh could not reach GitHub")),
        (output("", stderr: "Get \"https://api.github.com/copilot_internal/user\": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused\n", exitCode: 1), FetchError.network("gh could not reach GitHub")),
        (output("", stderr: "placeholder-login: something unexpected happened\n", exitCode: 2), FetchError.parse("gh exited with status 2")),
        (output("", exitCode: 15, timedOut: true), FetchError.timeout),
    ])
    func failuresAreClassifiedWithoutKeepingStderr(result: ProcessResult, expected: FetchError) async throws {
        await #expect(throws: expected) { try await self.fetch(result) }
    }

    @Test(arguments: ["not json at all", "[]", #"{"copilot_plan":null,"quota_snapshots":{}}"#])
    func outputWithoutAPlanOrQuotasIsAParseError(stdout: String) async throws {
        let error = await #expect(throws: FetchError.self) { try await self.fetch(output(stdout)) }
        guard case .parse = error else {
            Issue.record("expected a parse error, got \(String(describing: error))")
            return
        }
    }

    // MARK: Helpers

    private func context(_ runner: FakeRunner, ghPath: String? = nil) throws -> FetchContext {
        let gh = home.appending(path: "bin/gh")
        try Data().write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let now = self.now
        return FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: ["gh": ghPath ?? gh.path], searchDirectories: []),
            paths: AppPaths(home: home), now: { now }
        )
    }

    private func fetch(_ result: ProcessResult) async throws -> UsageSnapshot {
        try await fetch(FakeRunner(result))
    }

    private func fetch(_ runner: FakeRunner) async throws -> UsageSnapshot {
        try await CopilotUsageFetcher().fetch(account, context: context(runner))
    }

    private func runFilter(_ response: String) throws -> (status: Int32, output: String) {
        let filter = try #require(CopilotUsageFetcher.arguments.last)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/jq")
        process.arguments = ["-c", filter]
        let input = Pipe(), out = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(response.utf8))
        try input.fileHandleForWriting.close()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
