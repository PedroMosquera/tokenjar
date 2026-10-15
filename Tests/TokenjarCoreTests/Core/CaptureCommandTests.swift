import Foundation
import Testing
@testable import TokenjarCore

/// `--capture` against fake CLIs and a fake transport in a throwaway home and system root. Nothing is spawned except
/// the system jq, which stands in for gh's own jq.
final class CaptureCommandTests {
    let home: URL
    let systemRoot: URL
    let runner = FakeRunner()

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "tokenjar-capture-\(UUID().uuidString)")
        home = base.appending(path: "home")
        systemRoot = base.appending(path: "root")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    // MARK: Claude

    @Test func claudeCaptureRunsTheProbeArguments() async throws {
        runner.answers = [output(String(decoding: try fixture("Claude/stream-plan-limits.jsonl"), as: UTF8.self))]
        try write(".claude.json", #"""
        {"oauthAccount": {"accountUuid": "123e4567-e89b-12d3-a456-426614174000", "emailAddress": "someone@example.com",
          "displayName": "Jane Placeholder", "organizationName": "Placeholder Org", "organizationType": "claude_enterprise",
          "seatTier": "enterprise_standard", "billingType": "stripe_subscription", "organizationRateLimitTier": "default_claude_enterprise",
          "userRateLimitTier": "default_claude_max_5x", "hasExtraUsageEnabled": true},
         "hasExtraUsageEnabled": false, "userID": "placeholder-user", "projects": {"/Users/placeholder/secret-project": {}}}
        """#)
        try write(".claude/settings.json", #"{"env": {"ANTHROPIC_BASE_URL": "https://gateway.example.invalid", "CLAUDE_CODE_USE_BEDROCK": "1", "OTHER_SETTING": "x"}}"#)
        try write("Library/Application Support/ClaudeCode/managed-settings.json", #"{"env": {"ANTHROPIC_AUTH_TOKEN": "sk-ant-placeholder-token", "CLAUDE_CODE_USE_VERTEX": "1"}, "forceLoginMethod": "console"}"#, under: systemRoot)

        let text = try document(await capture(.claude))

        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable.path == home.appending(path: "bin/claude").path)
        #expect(call.arguments == ClaudeUsageFetcher.arguments)
        #expect(call.currentDirectory == context().paths.probeDirectory)
        #expect(call.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(call.timeout == 45)

        let json = try object(text)
        let oauth = try #require((json["claudeJSON"] as? [String: Any])?["oauthAccount"] as? [String: Any])
        #expect(oauth["organizationType"] as? String == "claude_enterprise")
        #expect(oauth["seatTier"] as? String == "enterprise_standard")
        #expect(oauth["billingType"] as? String == "stripe_subscription")
        #expect(oauth["userRateLimitTier"] as? String == "default_claude_max_5x")
        #expect(oauth["hasExtraUsageEnabled"] as? Bool == true)
        #expect(Set(oauth.keys) == ["organizationType", "seatTier", "billingType", "organizationRateLimitTier", "userRateLimitTier", "hasExtraUsageEnabled"])
        #expect((json["claudeJSON"] as? [String: Any])?["hasExtraUsageEnabled"] as? Bool == false)
        #expect(json["settingsEnvKeys"] as? [String] == ["ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK"])
        #expect(json["managedSettingsEnvKeys"] as? [String] == ["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_VERTEX"])
        #expect(text.contains(#""display_name" : "Fable""#))
        for leaked in ["someone@example.com", "Jane", "Placeholder Org", "123e4567", "placeholder-user", "secret-project", "gateway.example.invalid", "sk-ant", "OTHER_SETTING", "forceLoginMethod", "LOCAL_TEXT", "SESSION_ID"] {
            #expect(!text.contains(leaked), "\(leaked)")
        }
    }

    @Test func claudeWithoutManagedSettingsReportsNone() async throws {
        runner.answers = [output(String(decoding: try fixture("Claude/stream-plan-limits.jsonl"), as: UTF8.self))]

        let json = try object(try document(await capture(.claude)))

        #expect(json["managedSettingsEnvKeys"] is NSNull)
        #expect(json["settingsEnvKeys"] is NSNull)
        #expect(json["claudeJSON"] is NSNull)
    }

    /// The capture writes nothing, so a turn here cannot latch the app; printing nothing keeps the reply out of a fixture.
    @Test func aClaudeModelTurnStopsTheCapture() async throws {
        runner.answers = [output("""
        {"type":"system","subtype":"init","apiKeySource":"none"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Here is how usage works"}]}}
        {"type":"result","num_turns":1,"total_cost_usd":0.01}
        """)]

        guard case .stopped(let message) = await capture(.claude) else {
            Issue.record("a model turn must stop the capture")
            return
        }
        #expect(message.contains("spends tokens"))
    }

    // MARK: Codex

    @Test func codexCaptureAsksForResetCreditDetails() async throws {
        let connection = ScriptedCodexConnection.answering(rateLimits: try CodexFixtures.line("rate-limits-plus.json"))
        let launcher = RecordingCodexLauncher(connection)

        let text = try document(await capture(.codex, codexLauncher: launcher))

        #expect(launcher.launches.first?.arguments == CodexUsageFetcher.arguments)
        #expect(connection.sentMethods == ["initialize", "initialized", "account/rateLimits/read"])
        #expect((connection.sentObjects[2]["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool == false)
        #expect(connection.terminated)
        #expect(text.contains(#""planType" : "plus""#))
        #expect(text.contains(#""availableCount" : 2"#))
        #expect(!text.contains("ACCOUNT_ID_PLACEHOLDER"))
    }

    @Test func theFetcherStillExcludesResetCreditDetails() async throws {
        let connection = ScriptedCodexConnection.answering(rateLimits: try CodexFixtures.line("rate-limits-plus.json"))
        let fetcher = CodexUsageFetcher(launcher: RecordingCodexLauncher(connection), timeout: 5, clientVersion: "dev")

        _ = try await fetcher.fetch(account(.codex), context: context())

        #expect((connection.sentObjects[2]["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool == true)
    }

    // MARK: Copilot

    /// The program gh runs is the only redaction the login and ids pass through before they could reach Tokenjar, so it
    /// is run here through the system jq over a full answer.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func copilotCaptureRedactsInsideGh() async throws {
        runner.answers = [output("{}")]
        _ = try document(await capture(.copilot))

        let call = try #require(runner.calls.first)
        #expect(Array(call.arguments.dropLast()) == Array(CopilotUsageFetcher.arguments.dropLast()))
        #expect(call.environment.filter { $0.key.hasPrefix("GH_") || $0.key == "DO_NOT_TRACK" } == CopilotUsageFetcher.ghEnvironment)
        let program = try #require(call.arguments.last)

        let raw = #"""
        {"login":"placeholder-login","id":1234,"user_id":4321,"orgId":8765,"enterpriseid":9753,"analytics_tracking_id":"0123456789abcdef0123456789abcdef",
         "assigned_date":"2026-01-01T00:00:00Z","organization_login_list":["placeholder-org"],
         "organization_list":[{"id":5,"login":"placeholder-org","name":"Placeholder Org"}],"enterprise_list":[{"id":6,"slug":"placeholder-ent"}],
         "endpoints":{"api":"https://api.example.invalid"},"copilot_plan":"enterprise","access_type_sku":"copilot_enterprise_seat_quota",
         "quota_reset_date_utc":"2026-11-01T00:00:00.000Z","someone@example.com":{"seen":true},
         "quota_snapshots":{"premium_interactions":{"entitlement":1000,"quota_remaining":750.5,"quota_id":"premium_interactions",
         "unlimited":false,"credits_used":250,"timestamp_utc":"2026-10-11T12:00:00Z"}}}
        """#
        let (status, filtered) = try jq(program, raw)

        #expect(status == 0)
        for leaked in ["placeholder", "Placeholder", "1234", "4321", "8765", "9753", "0123456789abcdef", "example", #""id":5"#, #""id":6"#, "2026-01-01", "2026-10-11"] {
            #expect(!filtered.contains(leaked), "\(leaked)")
        }
        for kept in [#""copilot_plan":"enterprise""#, #""access_type_sku":"copilot_enterprise_seat_quota""#, #""quota_id":"premium_interactions""#, #""entitlement":1000"#, #""credits_used":250"#, #""unlimited":false"#, #""login":"<redacted>""#] {
            #expect(filtered.contains(kept), "\(kept)")
        }
    }

    /// The Swift redactor's date rule, run as gh would run it: the reset dates survive in date form only.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func copilotCaptureKeepsTheResetDatesInsideGh() async throws {
        runner.answers = [output("{}")]
        _ = try document(await capture(.copilot))
        let program = try #require(runner.calls.first?.arguments.last)

        let (status, filtered) = try jq(program, #"""
        {"login":"placeholder-login","quota_reset_date_utc":"2026-11-01T00:00:00.000Z","quota_reset_date":"2026-11-01",
         "assigned_date":"2026-01-02T03:04:05Z","quota_snapshots":{"premium_interactions":{"timestamp_utc":"2026-10-11T12:00:00Z","quota_reset_date":"2026-10-13"}}}
        """#)

        #expect(status == 0)
        #expect(filtered.contains(#""quota_reset_date_utc":"2026-11-01T00:00:00.000Z""#))
        #expect(filtered.contains(#""quota_reset_date":"2026-11-01""#))
        for leaked in ["placeholder", "2026-01-02", "2026-10-11", "2026-10-13"] {
            #expect(!filtered.contains(leaked), "\(leaked)")
        }

        let (_, freeText) = try jq(program, #"{"quota_reset_date_utc":"2026-11-01T00:00:00Z for placeholder-login","quota_reset_date":"2026-11-01\n"}"#)
        #expect(freeText.contains(#""quota_reset_date_utc":"<redacted>""#))
        #expect(freeText.contains(#""quota_reset_date":"<redacted>""#))
    }

    /// gh skips `--jq` when an HTTP error body carries a message and prints that body as it came, so for an error the
    /// redaction here is the only one it passes through.
    @Test func aGhErrorBodyIsRedactedBeforeItIsPrinted() async throws {
        runner.answers = [output(
            #"{"message":"Not Found for placeholder-login","documentation_url":"https://docs.github.com/rest","status":"404","user_id":4321}"#,
            stderr: "gh: Not Found for placeholder-login (HTTP 404)\n", exitCode: 1
        )]

        let text = try document(await capture(.copilot))

        let json = try object(text)
        #expect(json["exitCode"] as? Int == 1)
        #expect((json["response"] as? [String: Any])?.keys.sorted() == ["documentation_url", "message", "status", "user_id"])
        #expect((json["stderr"] as? [String: Any])?["phrases"] as? [String] == ["http 404"])
        for leaked in ["placeholder", "4321", "docs.github.com", "Not Found"] {
            #expect(!text.contains(leaked), "\(leaked)")
        }
    }

    // MARK: Antigravity

    @Test func agyCaptureStopsBelowTheMinimumVersion() async throws {
        runner.answers = [output("agy 1.1.10\n")]

        guard case .stopped(let message) = await capture(.antigravity) else {
            Issue.record("an agy older than 1.1.11 must not be sent /usage")
            return
        }
        #expect(runner.calls.map(\.arguments) == [["--version"]])
        #expect(message.contains("1.1.11"))
    }

    /// The capture reads the fetcher's agy commands; this catches it going back to its own arguments, timeouts or limits,
    /// or sending a different environment or directory.
    @Test func agyCaptureRunsWhatTheFetcherRuns() async throws {
        let answers = [output("agy 1.3.0\n"), output(#"{"command":{"data":{"groups":[]}}}"#)]
        runner.answers = answers
        _ = try await AntigravityUsageFetcher().fetch(account(.antigravity), context: context())
        runner.answers = answers

        _ = try document(await capture(.antigravity))

        let calls = runner.calls
        #expect(calls.count == 4)
        #expect(Array(calls.suffix(2)) == Array(calls.prefix(2)))
    }

    @Test func agyStderrBecomesPhraseHitsOnly() async throws {
        runner.answers = [
            output("agy 1.3.0\n"),
            output("", stderr: "Please sign in as person@example.com\ndial tcp 10.1.2.3:443: connect: connection refused\n", exitCode: 1),
        ]

        let text = try document(await capture(.antigravity))

        #expect(runner.calls.map(\.arguments) == [["--version"], ["-p", "/usage", "--output-format", "json"]])
        let stderr = try #require((object(text)["usage"] as? [String: Any])?["stderr"] as? [String: Any])
        #expect(stderr["phrases"] as? [String] == ["sign in", "dial tcp"])
        #expect(stderr["lines"] as? Int == 2)
        for leaked in ["person@example.com", "10.1.2.3", "refused", "Please"] {
            #expect(!text.contains(leaked), "\(leaked)")
        }
    }

    @Test func anAgyModelTurnStopsTheCapture() async throws {
        runner.answers = [output("agy 1.3.0\n"), output(#"{"response":"Here is your usage","stats":{"models":{}}}"#)]

        guard case .stopped(let message) = await capture(.antigravity) else {
            Issue.record("a model turn must stop the capture")
            return
        }
        #expect(message.contains("spends quota"))
    }

    // MARK: OpenCode, Devin

    @Test func opencodeCaptureUsesTheAllowlistedEndpoint() async throws {
        try write(".local/share/opencode/auth.json", #"{"opencode-go": {"type": "api", "key": "oc_sk_placeholderkey1234567890"}}"#)
        let body = #"{"error": {"type": "NoSubscriptionError", "message": "key oc_sk_placeholderkey1234567890 of person@example.com"}}"#
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 403, body: Data(body.utf8)))

        let text = try document(await capture(.opencodeGo, transport: transport))

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url == OpenCodeGoUsageFetcher.usageURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oc_sk_placeholderkey1234567890")
        #expect(text.contains(#""status" : 403"#))
        #expect(text.contains(#""type" : "NoSubscriptionError""#))
        #expect(!text.contains("oc_sk_"))
        #expect(!text.contains("example.com"))
    }

    @Test func devinAndZenHaveNothingToCapture() async {
        for provider in [ProviderID.devin, .opencodeZen] {
            guard case .nothingToCapture = await capture(provider) else {
                Issue.record("\(provider) has no source to capture")
                continue
            }
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: Helpers

    private func account(_ provider: ProviderID) -> AccountConfig {
        AccountConfig(id: "dev-\(provider.rawValue)", provider: provider, label: "dev")
    }

    private func context(transport: OpenCodeFakeTransport = OpenCodeFakeTransport(HTTPResponse(status: 500, body: Data()))) -> FetchContext {
        var overrides: [String: String] = [:]
        for name in ["claude", "codex", "gh", "agy"] {
            let file = home.appending(path: "bin/\(name)")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try? Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            overrides[name] = file.path
        }
        return FetchContext(
            process: runner, http: HTTPClient(transport: transport), secrets: InMemorySecretStore(),
            cli: CLILocator(home: home, overrides: overrides, searchDirectories: []), paths: AppPaths(home: home, environment: [:], systemRoot: systemRoot)
        )
    }

    private func capture(
        _ provider: ProviderID, codexLauncher: any CodexAppServerLaunching = RecordingCodexLauncher(ScriptedCodexConnection(replies: [:])),
        transport: OpenCodeFakeTransport = OpenCodeFakeTransport(HTTPResponse(status: 500, body: Data()))
    ) async -> Capture.Outcome {
        await Capture.run(account(provider), context: context(transport: transport), codexLauncher: codexLauncher, environment: [:])
    }

    private func document(_ outcome: Capture.Outcome) throws -> String {
        guard case .document(let text) = outcome else {
            Issue.record("expected a document, got \(outcome)")
            throw CancellationError()
        }
        return text
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func write(_ relative: String, _ contents: String, under root: URL? = nil) throws {
        let file = (root ?? home).appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
    }

    private func jq(_ program: String, _ input: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/jq")
        process.arguments = ["-c", program]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
}
