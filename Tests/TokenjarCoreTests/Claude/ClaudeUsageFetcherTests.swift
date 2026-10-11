import Foundation
import Testing
@testable import TokenjarCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/Claude")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appending(path: name))
}

/// Stands in for the claude CLI: returns canned output and records how it was invoked.
private final class FakeClaude: ProcessRunning, @unchecked Sendable {
    struct Call {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL?
        var stdin: Data?
        var timeout: TimeInterval
        var outputLimit: Int
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let result: ProcessResult

    init(stdout: Data = Data(), exitCode: Int32 = 0, timedOut: Bool = false) {
        result = ProcessResult(exitCode: exitCode, stdout: stdout, stderr: Data(), timedOut: timedOut)
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        lock.withLock {
            recorded.append(Call(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, stdin: stdin, timeout: timeout, outputLimit: outputLimit))
        }
        return result
    }
}

/// A throwaway home directory so nothing touches the real ~/.claude.json or ~/Library.
private struct Sandbox {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "tokenjar-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func install(_ fixtureName: String, as relativePath: String) throws {
        let target = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture(fixtureName).write(to: target)
    }

    func write(_ text: String, to relativePath: String) throws {
        let target = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }

    func context(_ runner: FakeClaude, cli: String = "/bin/sh", now: Date) -> FetchContext {
        FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: ["claude": cli]),
            paths: AppPaths(home: home), now: { now }
        )
    }
}

struct ClaudeUsageFetcherTests {
    let now = DateParsing.iso8601("2026-10-10T20:00:00Z")!
    let account = AccountConfig(id: "claude-personal", provider: .claude, label: "Personal")

    @Test func mapsAllThreeLimitKindsFromTheCLI() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        let runner = FakeClaude(stdout: try fixture("stream-plan-limits.jsonl"))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows == [
            UsageWindow(id: "session", label: "5-hour", usedPercent: 19, windowMinutes: 300, resetsAt: DateParsing.iso8601("2026-10-10T22:19:59.863707+00:00")),
            UsageWindow(id: "weekly", label: "Week", usedPercent: 14, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-12T08:59:59.863734+00:00")),
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
        let box = try Sandbox()
        defer { box.remove() }
        let runner = FakeClaude(stdout: try fixture("stream-extra-usage-jpy.jsonl"))

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
        let box = try Sandbox()
        defer { box.remove() }
        let runner = FakeClaude(stdout: try fixture("stream-extra-usage-jpy.jsonl"))

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
        let box = try Sandbox()
        defer { box.remove() }
        let runner = FakeClaude(stdout: try fixture("stream-signed-out.jsonl"))

        await #expect(throws: FetchError.notSignedIn) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }
    }

    @Test(arguments: [nil, "claude-json-max.json"])
    func apiKeyLoginHasNoPlanLimits(globalConfig: String?) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        if let globalConfig { try box.install(globalConfig, as: ".claude.json") }
        let runner = FakeClaude(stdout: try fixture("stream-api-key.jsonl"))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.source == "claude CLI")
        #expect(snapshot.plan == nil, "an API key does not bill the subscription saved in .claude.json")
    }

    @Test func apiKeyReportWithoutRateLimitsIgnoresTheSubscriptionCache() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        let stream = String(decoding: try fixture("stream-plan-limits.jsonl"), as: UTF8.self)
            .replacingOccurrences(of: #""apiKeySource":"none""#, with: #""apiKeySource":"apiKeyHelper""#)
            .replacingOccurrences(of: #""rate_limits":"#, with: #""rate_limits_removed":"#)

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(stdout: Data(stream.utf8)), now: now))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.source == "claude CLI")
    }

    @Test func malformedUsageCacheKeepsPlanAndSignIn() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise"},"cachedUsageUtilization":{"fetchedAtMs":"soon"}}"#, to: ".claude.json")

        let reported = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(stdout: try fixture("stream-plan-limits.jsonl")), now: now))
        #expect(reported.plan == "Enterprise")

        let unreported = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(stdout: try fixture("stream-signed-out.jsonl")), now: now))
        #expect(unreported.plan == "Enterprise")
        #expect(unreported.notes == ["No plan limits for this login"])
    }

    @Test(arguments: [
        #""num_turns":1,"total_cost_usd":0.0123"#,
        #""num_turns":1,"total_cost_usd":0"#,
        #""num_turns":0,"total_cost_usd":0.0123"#,
    ])
    func usageAnsweredByAModelTurnFailsInsteadOfServingTheCache(resultFields: String) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        let stream = """
        {"type":"system","subtype":"init","apiKeySource":"none","model":"claude-opus-5-5"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"MODEL_TEXT"}],"usage":{"input_tokens":12,"output_tokens":40}}}
        {"type":"result","subtype":"success","is_error":false,\(resultFields),"result":"MODEL_TEXT"}
        """

        await #expect(throws: FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(stdout: Data(stream.utf8)), now: now))
        }
    }

    /// A run killed mid-turn has no result line to count its turns, but the model reply it printed already spent tokens.
    /// Serving the cache, or calling it a timeout, would let every refresh spend tokens again.
    @Test(arguments: [true, false])
    func aModelReplyWithoutAResultLineIsAModelTurn(timedOut: Bool) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        let stream = """
        {"type":"system","subtype":"init","apiKeySource":"none","model":"claude-opus-5-5"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"MODEL_TEXT"}],"usage":{"input_tokens":12,"output_tokens":40}}}

        """
        let runner = FakeClaude(stdout: Data(stream.utf8), exitCode: timedOut ? 0 : 1, timedOut: timedOut)

        await #expect(throws: FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }
    }

    /// The local `/usage` answer is an assistant line too, so a run that hangs after printing it is only a timeout.
    @Test func aTimeoutAfterTheLocalUsageAnswerIsStillATimeout() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let lines = String(decoding: try fixture("stream-signed-out.jsonl"), as: UTF8.self).split(separator: "\n")
        let partial = Data((lines.prefix(2).joined(separator: "\n") + "\n").utf8)

        await #expect(throws: FetchError.timeout) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(stdout: partial, timedOut: true), now: now))
        }
    }

    @Test func usageBasedEnterpriseSeatHasNoPlanLimits() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(#"{"oauthAccount":{"accountUuid":"ACCOUNT_UUID_C","organizationType":"claude_enterprise","seatTier":"enterprise_usage_based"}}"#, to: ".claude.json")
        let runner = FakeClaude(stdout: try fixture("stream-signed-out.jsonl"))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.plan == "Enterprise (usage-based)")
        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test func bedrockSettingsAreNotMistakenForSignedOut() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write(#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-east-1"}}"#, to: ".claude/settings.json")
        let runner = FakeClaude(stdout: try fixture("stream-signed-out.jsonl"))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.notes == ["No plan limits for this login"])
    }

    @Test func runsTheCLIWithHooksOffFromTheProbeDirectory() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let runner = FakeClaude(stdout: try fixture("stream-plan-limits.jsonl"))
        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")

        _ = try await ClaudeUsageFetcher().fetch(work, context: box.context(runner, now: now))
        _ = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        let calls = runner.calls
        try #require(calls.count == 2)
        let probe = box.home.appending(path: "Library/Application Support/Tokenjar/probe")
        #expect(calls[0].executable.path == "/bin/sh")
        #expect(calls[0].arguments == [
            "-p", "/usage", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
        ])
        #expect(calls[0].environment["CLAUDE_CONFIG_DIR"] == box.home.appending(path: ".claude-work").path)
        #expect(calls[1].environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(calls[0].environment["HOME"] == box.home.path)
        #expect(calls[0].currentDirectory?.path == probe.path)
        #expect(FileManager.default.fileExists(atPath: probe.path))
        #expect(calls[0].stdin == nil)
        #expect(calls[0].timeout == 45)
        #expect(calls[0].outputLimit == 2 * 1024 * 1024)
    }

    @Test func probeFolderAndItsParentAreOwnerOnlyEvenIfTheyExisted() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let paths = AppPaths(home: box.home)
        try makeWorldReadableDirectory(paths.probeDirectory)
        try makeWorldReadableDirectory(paths.supportDirectory)

        _ = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(stdout: try fixture("stream-plan-limits.jsonl")), now: now))

        #expect(try posixMode(paths.supportDirectory) == 0o700)
        #expect(try posixMode(paths.probeDirectory) == 0o700)
    }

    @Test func profileDirReadsItsOwnConfigAndLegacyFileWins() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        try box.write(#"{"oauthAccount":{"organizationType":"claude_pro"}}"#, to: ".claude-work/.claude.json")
        let runner = FakeClaude(stdout: try fixture("stream-plan-limits.jsonl"))
        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")

        let fromProfile = try await ClaudeUsageFetcher().fetch(work, context: box.context(runner, now: now))
        #expect(fromProfile.plan == "Pro")

        try box.write(#"{"oauthAccount":{"organizationType":"claude_team"}}"#, to: ".claude-work/.config.json")
        let fromLegacy = try await ClaudeUsageFetcher().fetch(work, context: box.context(runner, now: now))
        #expect(fromLegacy.plan == "Team")
    }

    // MARK: Cache fallback

    @Test func missingCLIFallsBackToClaudeCodeCache() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        let runner = FakeClaude()

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, cli: "/nonexistent/claude", now: now))

        #expect(runner.calls.isEmpty)
        #expect(snapshot.source == "Claude Code cache")
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 1_791_661_279.383))
        #expect(snapshot.plan == "Max 20x")
        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "weekly:Fable"])
        #expect(snapshot.windows.map(\.usedPercent) == [17, 14, 3])
        #expect(snapshot.money == [MoneyLine(label: "Extra usage", amount: 25, limit: 50, currency: "USD")])
        #expect(snapshot.notes == ["claude CLI not found. Showing the last values Claude Code saved."])
    }

    @Test func cacheOfAnotherAccountIsIgnored() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("claude-json-max.json")) as? [String: Any])
        var cache = try #require(json["cachedUsageUtilization"] as? [String: Any])
        cache["accountUuid"] = "ACCOUNT_UUID_OTHER"
        json["cachedUsageUtilization"] = cache
        try JSONSerialization.data(withJSONObject: json).write(to: box.home.appending(path: ".claude.json"))

        await #expect(throws: FetchError.cliNotFound("claude")) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(), cli: "/nonexistent/claude", now: now))
        }
    }

    @Test func timeoutFallsBackToCacheOrReportsTimeout() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let runner = FakeClaude(timedOut: true)

        await #expect(throws: FetchError.timeout) {
            try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        }

        try box.install("claude-json-max.json", as: ".claude.json")
        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))
        #expect(snapshot.source == "Claude Code cache")
    }

    @Test func cacheWithoutLimitsUsesBucketsAndDropsPastResets() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-pro-buckets.json", as: ".claude.json")

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(FakeClaude(), cli: "/nonexistent/claude", now: now))

        #expect(snapshot.plan == "Pro")
        #expect(snapshot.windows == [
            UsageWindow(id: "session", label: "5-hour", usedPercent: 55.5, windowMinutes: 300, resetsAt: DateParsing.iso8601("2026-10-10T21:00:00+00:00")),
            UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-14T09:00:00.5+00:00")),
            UsageWindow(id: "weekly:Opus", label: "Week · Opus", usedPercent: 12, windowMinutes: 10_080, resetsAt: DateParsing.iso8601("2026-10-14T09:00:00+00:00")),
        ])
        #expect(snapshot.money.isEmpty)
    }

    @Test func subscriptionWithoutReportedLimitsUsesCacheInsteadOfClaimingNone() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.install("claude-json-max.json", as: ".claude.json")
        let runner = FakeClaude(stdout: try fixture("stream-signed-out.jsonl"))

        let snapshot = try await ClaudeUsageFetcher().fetch(account, context: box.context(runner, now: now))

        #expect(snapshot.source == "Claude Code cache")
        #expect(!snapshot.notes.contains("No plan limits for this login"))
    }

    @Test func unrecognizedOutputIsAParseError() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let runner = FakeClaude(stdout: Data("Error: something went wrong\n".utf8), exitCode: 1)

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
