import Foundation
import Testing
@testable import TokenjarCore

/// The fixtures are synthetic. No answer from a real agy account has been captured, so they follow the field names
/// of CodexBar's agy test fixture.
final class AntigravityUsageFetcherTests {
    let home: URL
    let account = AccountConfig(id: "agy-test", provider: .antigravity, label: "Google")
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "tokenjar-agy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    // MARK: Version gate

    @Test(arguments: [
        ("1.1.11\n", [1, 1, 11]),
        ("agy version 1.2 (abc1234)", [1, 2, 0]),
        ("agy/1.1.10 darwin-arm64", [1, 1, 10]),
        ("Antigravity CLI v1.3.0-beta.2", [1, 3, 0]),
        ("Node.js v22.3.0\nagy 1.0.4\n", [1, 0, 4]),
        ("v22.3.0\nagy 1.0.4\n", [1, 0, 4]),
    ])
    func readsTheAgyVersionNotOtherNumbers(text: String, version: [Int]) {
        #expect(AntigravityUsageFetcher.version(in: text) == version)
    }

    @Test(arguments: [
        "agy (dev build)",
        "agy (dev build) node 22.3.0",
        "error: unknown option '--version' (see docs v2.0)",
        "Node.js v22.3.0",
        "agy 1.1.11abc",
    ])
    func refusesTextWithoutAnAnchoredAgyVersion(text: String) {
        #expect(AntigravityUsageFetcher.version(in: text) == nil)
    }

    @Test(arguments: [
        ([1, 1, 11], true), ([1, 1, 12], true), ([1, 2, 0], true), ([2, 0, 0], true),
        ([1, 1, 10], false), ([1, 0, 99], false), ([0, 9, 0], false),
    ])
    func requiresAtLeast1_1_11(version: [Int], supported: Bool) {
        #expect(AntigravityUsageFetcher.isSupported(version) == supported)
    }

    @Test(arguments: [
        (output("agy 1.1.10"), "Update agy to 1.1.11 or later"),
        (output("Node.js v22.3.0\nagy 1.0.4\n"), "Update agy to 1.1.11 or later"),
        (output("agy (dev build)"), "Could not read the agy version"),
        (output("", stderr: "agy 1.2.0\n"), "Could not read the agy version"),
        (output("agy 1.2.0\n", stderr: "error: unknown option '--version' (see docs v2.0)\n", exitCode: 2), "Could not read the agy version"),
    ])
    func refusesOldOrUnknownVersionsBeforeAskingForUsage(version: ProcessResult, message: String) async throws {
        let runner = try FakeAgy(version: version, usage: output(fixture("usage-snake.json")))
        await #expect(throws: FetchError.unsupported(message)) { try await self.fetch(runner) }
        #expect(runner.calls.map(\.arguments) == [["--version"]])
    }

    // MARK: Invocation

    @Test func missingBinaryIsCLINotFoundWithoutRunningAnything() async throws {
        let runner = try FakeAgy(usage: output(fixture("usage-snake.json")))
        let context = try context(runner, agyPath: home.appending(path: "bin/not-installed").path)
        await #expect(throws: FetchError.cliNotFound("agy")) {
            try await AntigravityUsageFetcher().fetch(self.account, context: context)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func runsReadOnlyUsageCommandFromTheProbeDirectory() async throws {
        let runner = try FakeAgy(usage: output(fixture("usage-snake.json")))
        let context = try context(runner)
        try makeWorldReadableDirectory(context.paths.supportDirectory)
        _ = try await AntigravityUsageFetcher().fetch(account, context: context)

        #expect(try posixMode(context.paths.supportDirectory) == 0o700)
        #expect(try posixMode(context.paths.probeDirectory) == 0o700)
        #expect(runner.calls.map(\.arguments) == [["--version"], ["-p", "/usage", "--output-format", "json"]])
        let usage = try #require(runner.calls.last)
        #expect(usage.executable.path == home.appending(path: "bin/agy").path)
        #expect(usage.currentDirectory == context.paths.probeDirectory)
        #expect(FileManager.default.fileExists(atPath: context.paths.probeDirectory.path))
        #expect(usage.environment == context.cli.baseEnvironment())
        #expect(usage.timeout == 100)
        #expect(usage.outputLimit == 1 << 20)
    }

    @Test func signInFailureIsNotSignedIn() async throws {
        let runner = FakeAgy(usage: output("", stderr: "You are not signed in. Run agy and log in.\n", exitCode: 1))
        await #expect(throws: FetchError.notSignedIn) { try await self.fetch(runner) }
    }

    @Test func otherFailureCarriesOnlyTheExitStatus() async throws {
        let runner = FakeAgy(usage: output("", stderr: "internal error: placeholder detail\n", exitCode: 2))
        await #expect(throws: FetchError.parse("agy exited with status 2")) { try await self.fetch(runner) }
    }

    @Test func timeoutIsReported() async throws {
        let runner = FakeAgy(usage: output("", exitCode: 15, timedOut: true))
        await #expect(throws: FetchError.timeout) { try await self.fetch(runner) }
    }

    // MARK: Parsing

    @Test func snakeCaseReportBecomesOneWindowPerPoolAndLimit() async throws {
        let snapshot = try await fetch(FakeAgy(usage: output(fixture("usage-snake.json"))))
        #expect(summary(snapshot.windows) == [
            "gemini:session | Gemini · 5-hour | 38.0 | 300 | 2026-10-10T22:30:00Z",
            "gemini:weekly | Gemini · Week | 10.0 | 10080 | 2026-10-12T00:00:00Z",
            "claude-and-gpt:weekly | Claude and GPT · Week | 75.0 | 10080 | 2026-10-14T08:00:00Z",
        ])
        #expect(snapshot.accountID == "agy-test")
        #expect(snapshot.provider == .antigravity)
        #expect(snapshot.source == "agy CLI")
        #expect(snapshot.plan == nil)
        #expect(snapshot.notes.isEmpty)
        #expect(snapshot.fetchedAt == now)
    }

    @Test func camelCaseReportParsesTheSameFields() async throws {
        let snapshot = try await fetch(FakeAgy(usage: output(fixture("usage-camel.json"))))
        #expect(summary(snapshot.windows) == [
            "gemini:session | Gemini · 5-hour | 50.0 | 300 | 2026-10-10T22:30:00Z",
            "gemini:weekly | Gemini · Week | 20.0 | 10080 | 2026-10-12T00:00:00Z",
            "claude-and-gpt:session | Claude and GPT · 5-hour | 100.0 | 300 | 2026-10-11T00:00:00Z",
            "claude-and-gpt:weekly | Claude and GPT · Week | 60.0 | 10080 | -",
        ])
    }

    @Test func findsGroupsNestedInsideArraysPastABannerLine() async throws {
        let stdout = """
        Update available: run agy update
        {"meta":{"groups":"n/a"},"payload":{"reports":[{"kind":"quota","detail":{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":0.7,"reset_time":"2026-10-12T00:00:00Z"}]}]}}]}}
        """
        let snapshot = try await fetch(FakeAgy(usage: output(stdout)))
        #expect(summary(snapshot.windows) == ["gemini:weekly | Gemini · Week | 30.0 | 10080 | 2026-10-12T00:00:00Z"])
    }

    @Test func skipsDisabledBuckets() async throws {
        let stdout = #"{"groups":[{"name":"Gemini models","buckets":[{"window":"five_hour","remaining_fraction":0.1,"disabled":true},{"window":"weekly","remaining_fraction":0.5,"disabled":false}]}]}"#
        let snapshot = try await fetch(FakeAgy(usage: output(stdout)))
        #expect(snapshot.windows.map(\.id) == ["gemini:weekly"])
    }

    @Test func unknownWindowKeepsItsNameWithoutALength() async throws {
        let stdout = #"{"groups":[{"name":"Gemini models","buckets":[{"window":"Daily_Requests","remaining_fraction":0.75}]}]}"#
        let snapshot = try await fetch(FakeAgy(usage: output(stdout)))
        #expect(summary(snapshot.windows) == ["gemini:dailyrequests | Gemini · Daily_Requests | 25.0 | - | -"])
    }

    @Test(arguments: [
        ("seven_day", "weekly", 10_080), ("7_day", "weekly", 10_080), ("WEEKLY", "weekly", 10_080), ("7d", "weekly", 10_080),
        ("five_hours", "session", 300), ("5h", "session", 300), ("Session", "session", 300),
        ("Daily_Requests", "dailyrequests", nil),
    ])
    func classifiesWindowSpellings(raw: String, id: String, minutes: Int?) throws {
        let kind = try #require(AntigravityUsageFetcher.windowKind(raw))
        #expect(kind.id == id)
        #expect(kind.minutes == minutes)
    }

    @Test(arguments: [
        #"{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining":0.4,"reset_time":"2026-10-12T00:00:00Z"}]}]}"#,
        #"{"groups":[{"name":"Gemini models","buckets":[{"limit":"weekly","remaining_fraction":0.4}]}]}"#,
        #"{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":62}]}]}"#,
        #"{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":-0.2}]}]}"#,
        #"{"groups":[{"name":"Gemini models","limits":[{"window":"weekly","remaining_fraction":0.4}]}]}"#,
    ])
    func unrecognizedBucketsAreAParseErrorNotAnEmptyAccount(stdout: String) async throws {
        let runner = FakeAgy(usage: output(stdout))
        await #expect(throws: FetchError.parse("agy /usage buckets not recognized")) { try await self.fetch(runner) }
    }

    @Test func oneUnrecognizedBucketBesideAGoodOneIsSkipped() async throws {
        let stdout = #"{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":0.5},{"window":"five_hour","remaining_percent":40}]}]}"#
        let snapshot = try await fetch(FakeAgy(usage: output(stdout)))
        #expect(snapshot.windows.map(\.id) == ["gemini:weekly"])
    }

    @Test func errorPayloadAboutSignInIsNotSignedIn() async throws {
        let runner = FakeAgy(usage: output(#"{"error":{"code":"UNAUTHENTICATED","message":"Please sign in"}}"#))
        await #expect(throws: FetchError.notSignedIn) { try await self.fetch(runner) }
    }

    @Test(arguments: [
        #"{"command":{"name":"usage","error":{"code":"UNAVAILABLE","message":"placeholder detail"}}}"#,
        #"{"result":{"error":"placeholder detail"}}"#,
    ])
    func otherErrorPayloadIsAParseError(stdout: String) async throws {
        let runner = FakeAgy(usage: output(stdout))
        await #expect(throws: FetchError.parse("agy /usage reported an error")) { try await self.fetch(runner) }
    }

    @Test(arguments: [
        #"{"command":{"data":{"groups":[]}}}"#,
        #"{"command":{"data":{"message":"Usage is not available for this account type"}}}"#,
        #"{"command":{"error":null,"data":{"message":"Usage is not available for this account type"}}}"#,
        #"{"command":{"data":{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":1,"disabled":true}]}]}}}"#,
        #"{"command":{"data":{"groups":[{"name":"Gemini models","buckets":[]}]}}}"#,
        #"{"response":"Usage is not available for this account type","num_turns":0,"usage":{"total_tokens":0},"command":{"name":"usage","data":{"message":"Usage is not available for this account type"}}}"#,
        #"{"response":"Usage is not available for this account type","command":{"data":{"message":"Usage is not available for this account type"}}}"#,
    ])
    func emptyReportShowsANoteInsteadOfWindows(stdout: String) async throws {
        let snapshot = try await fetch(FakeAgy(usage: output(stdout)))
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No usage limits reported for this account"])
        #expect(snapshot.source == "agy CLI")
    }

    /// "No limits" needs positive evidence, so a renamed field shows as a broken source instead of a blank account.
    @Test(arguments: [
        #"{"command":{"data":{"pools":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":0.5}]}]}}}"#,
        #"{"command":{"data":{}}}"#,
        #"{}"#,
        #"{"response":"Synthetic quota report","num_turns":0,"usage":{"total_tokens":0},"command":{"name":"usage","data":{}}}"#,
    ])
    func outputWithoutGroupsOrAReasonIsAParseError(stdout: String) async throws {
        let runner = FakeAgy(usage: output(stdout))
        await #expect(throws: FetchError.parse("agy /usage has no groups")) { try await self.fetch(runner) }
    }

    @Test(arguments: [
        #"{"type":"result","response":"Sure, here is a summary of your usage.","stats":{"tokens":812}}"#,
        #"{"response":"Here is your usage.","stats":{"models":{"gemini-3-pro":{"tokens":{"total":640}}}}}"#,
        #"{"response":"Here is your usage.","num_turns":1,"command":{"name":"usage"}}"#,
        #"{"response":"Here is your usage.","num_turns":0}"#,
        #"{"response":"Here is your usage.","num_turns":0,"stats":{"tokens":812},"command":{"name":"usage"}}"#,
        #"{"response":"Here is your usage.","num_turns":0,"usage":{"input_tokens":0,"total_tokens":120},"command":{"name":"usage"}}"#,
    ])
    func aModelReplySaysTheProbeSpentQuota(stdout: String) async throws {
        let runner = FakeAgy(usage: output(stdout))
        await #expect(throws: FetchError.unsupported(AntigravityUsageFetcher.modelTurnMessage)) { try await self.fetch(runner) }
    }

    /// agy wraps a local slash command's answer in the same envelope as a model reply (`response`, `num_turns`), so
    /// those keys alone must not latch the account and pause its checks.
    @Test func aLocalUsageAnswerWithoutGroupsIsNotAModelTurn() async throws {
        let local = FakeAgy(usage: output(try fixture("enterprise-no-quota.stdout.json")))
        let noQuota = try? await fetch(local)
        #expect(noQuota?.windows == [])
        #expect(noQuota?.notes == ["No usage limits reported for this account"])

        let renamed = FakeAgy(usage: output(try fixture("renamed-groups-envelope.stdout.json")))
        await #expect(throws: FetchError.parse("agy /usage has no groups")) { try await self.fetch(renamed) }

        let turn = FakeAgy(usage: output(try fixture("model-turn.stdout.json")))
        await #expect(throws: FetchError.unsupported(AntigravityUsageFetcher.modelTurnMessage)) { try await self.fetch(turn) }
    }

    @Test func nonJSONOutputIsAParseError() async throws {
        let runner = FakeAgy(usage: output("Usage: agy [options] [prompt]\n"))
        await #expect(throws: FetchError.parse("agy /usage output is not JSON")) { try await self.fetch(runner) }
    }

    // MARK: Helpers

    private func context(_ runner: FakeAgy, agyPath: String? = nil) throws -> FetchContext {
        let agy = home.appending(path: "bin/agy")
        try Data().write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        let now = self.now
        return FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: ["agy": agyPath ?? agy.path], searchDirectories: []),
            paths: AppPaths(home: home), now: { now }
        )
    }

    private func fetch(_ runner: FakeAgy) async throws -> UsageSnapshot {
        try await AntigravityUsageFetcher().fetch(account, context: context(runner))
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/Antigravity/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func summary(_ windows: [UsageWindow]) -> [String] {
        let iso = ISO8601DateFormatter()
        return windows.map { w in
            let minutes = w.windowMinutes.map(String.init) ?? "-"
            let reset = w.resetsAt.map(iso.string(from:)) ?? "-"
            return "\(w.id) | \(w.label) | \(String(format: "%.1f", w.usedPercent)) | \(minutes) | \(reset)"
        }
    }
}

private func output(_ stdout: String, stderr: String = "", exitCode: Int32 = 0, timedOut: Bool = false) -> ProcessResult {
    ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
}

/// Answers `--version` with `version` and anything else with `usage`, and records every call. Never spawns a process.
private final class FakeAgy: ProcessRunning, @unchecked Sendable {
    struct Call {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL?
        var timeout: TimeInterval
        var outputLimit: Int
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let version: ProcessResult
    private let usage: ProcessResult

    init(version: ProcessResult = output("agy 1.1.11"), usage: ProcessResult) {
        self.version = version
        self.usage = usage
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        lock.withLock {
            recorded.append(Call(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout, outputLimit: outputLimit))
        }
        return arguments == ["--version"] ? version : usage
    }
}
