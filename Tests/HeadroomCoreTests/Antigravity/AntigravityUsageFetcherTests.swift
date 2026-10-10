import Foundation
import Testing
@testable import HeadroomCore

/// The fixtures are synthetic. agy is not installed on the build machine, so they follow the field names of
/// CodexBar's agy test fixture instead of captured output.
final class AntigravityUsageFetcherTests {
    let home: URL
    let account = AccountConfig(id: "agy-test", provider: .antigravity, label: "Google")
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "headroom-agy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    // MARK: Version gate

    @Test func readsVersionFromCommonFormats() {
        #expect(AntigravityUsageFetcher.version(in: "1.1.11\n") == [1, 1, 11])
        #expect(AntigravityUsageFetcher.version(in: "agy version 1.2 (abc1234)") == [1, 2, 0])
        #expect(AntigravityUsageFetcher.version(in: "agy/1.1.10 darwin-arm64") == [1, 1, 10])
        #expect(AntigravityUsageFetcher.version(in: "agy (dev build)") == nil)
    }

    @Test(arguments: [
        ([1, 1, 11], true), ([1, 1, 12], true), ([1, 2, 0], true), ([2, 0, 0], true),
        ([1, 1, 10], false), ([1, 0, 99], false), ([0, 9, 0], false),
    ])
    func requiresAtLeast1_1_11(version: [Int], supported: Bool) {
        #expect(AntigravityUsageFetcher.isSupported(version) == supported)
    }

    @Test(arguments: [
        ("agy 1.1.10", "Update agy to 1.1.11 or later"),
        ("agy (dev build)", "Could not read the agy version"),
    ])
    func refusesOldOrUnknownVersionsBeforeAskingForUsage(version: String, message: String) async throws {
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
        _ = try await AntigravityUsageFetcher().fetch(account, context: context)

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
        #"{"command":{"data":{"groups":[]}}}"#,
        #"{"command":{"data":{"message":"Usage is not available for this account type"}}}"#,
        #"{"command":{"data":{"groups":[{"name":"Gemini models","buckets":[{"window":"weekly","remaining_fraction":1,"disabled":true}]}]}}}"#,
    ])
    func emptyReportShowsANoteInsteadOfWindows(stdout: String) async throws {
        let snapshot = try await fetch(FakeAgy(usage: output(stdout)))
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No usage limits reported for this account"])
        #expect(snapshot.source == "agy CLI")
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
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: ["agy": agyPath ?? agy.path]),
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

    init(version: String = "agy 1.1.11", usage: ProcessResult) {
        self.version = output(version)
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
