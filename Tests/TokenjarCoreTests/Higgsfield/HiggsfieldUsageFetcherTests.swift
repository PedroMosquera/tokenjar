import Foundation
import Testing
@testable import TokenjarCore

/// The exit codes and stderr text are what the real CLI printed (hf 1.2.2), each forced from a temporary home.
final class HiggsfieldUsageFetcherTests {
    let temp = TemporaryDirectory()
    var home: URL { temp.url }
    let account = AccountConfig(id: "higgsfield", provider: .higgsfield, label: "Higgsfield")
    let now = DateParsing.iso8601("2026-11-06T12:00:00Z")!
    /// Recorded from `higgsfield account status --json` with the email replaced.
    static let answer = #"{"credits":10,"email":"person@example.com","subscription_plan_type":"free"}"#

    init() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    // MARK: Invocation

    /// docs/privacy.md quotes this command. `generate` spends credits, so nothing else in the CLI is ever run.
    @Test func runsOnlyTheReadOnlyStatusCommand() async throws {
        let runner = FakeRunner(output(Self.answer))
        let context = try context(runner)
        _ = try await HiggsfieldUsageFetcher().fetch(account, context: context)

        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable.path == home.appending(path: "bin/higgsfield").path)
        #expect(call.arguments == ["account", "status", "--json"])
        #expect(call.currentDirectory == context.paths.probeDirectory)
        #expect(call.stdin == nil)
        #expect(call.timeout == 20)
    }

    @Test func environmentIsTheMinimalOneWithTelemetryAndUpdateChecksOff() async throws {
        let runner = FakeRunner(output(Self.answer))
        let context = try context(runner)
        _ = try await HiggsfieldUsageFetcher().fetch(account, context: context)

        var expected = context.cli.baseEnvironment()
        expected["HIGGSFIELD_DISABLE_TELEMETRY"] = "1"
        expected["DO_NOT_TRACK"] = "1"
        expected["HIGGSFIELD_NO_UPDATE_CHECK"] = "1"
        #expect(runner.calls.first?.environment == expected)
    }

    /// `hf` is the binary's shortcut, and also Hugging Face's CLI, so only the full name is ever run.
    @Test func anHfCommandIsNotHiggsfield() async throws {
        let hf = home.appending(path: "bin/hf")
        try Data().write(to: hf)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hf.path)
        let runner = FakeRunner(output(Self.answer))
        let context = FetchContext(
            process: runner, cli: CLILocator(home: home, overrides: [:], searchDirectories: [home.appending(path: "bin")]), paths: AppPaths(home: home)
        )
        await #expect(throws: FetchError.cliNotFound("higgsfield")) {
            try await HiggsfieldUsageFetcher().fetch(self.account, context: context)
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: The answer

    @Test func showsTheCreditsAndPlanWithoutWindowsOrABill() async throws {
        let snapshot = try await fetch(output(Self.answer))
        #expect(snapshot.plan == "Free")
        #expect(snapshot.notes == ["Credits: 10"])
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.isEmpty)
        #expect(snapshot.billing == nil)
        #expect(snapshot.source == "higgsfield CLI")
        #expect(snapshot.provider == .higgsfield)
        #expect(snapshot.accountID == "higgsfield")
        #expect(snapshot.fetchedAt == now)
    }

    /// The snapshot is stored in SQLite, so the email must not survive into it in any field.
    @Test func theEmailNeverReachesTheSnapshot() async throws {
        let snapshot = try await fetch(output(Self.answer))
        let stored = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!stored.contains("person"))
        #expect(!stored.contains("example.com"))
    }

    @Test func creditsReadLikeACount() async throws {
        for (raw, shown) in [("0", "Credits: 0"), ("12.5", "Credits: 12.5"), ("1250", "Credits: 1,250"), ("1250.257", "Credits: 1,250.26")] {
            let snapshot = try await fetch(output(#"{"credits":\#(raw),"subscription_plan_type":"free"}"#))
            #expect(snapshot.notes == [shown], "\(raw)")
        }
    }

    /// Only the free plan has been seen, so a name this build has never met is shown rather than dropped.
    @Test func thePlanNameIsTitleCased() async throws {
        for (raw, shown) in [("plus", "Plus"), ("creator_pro", "Creator Pro")] {
            let snapshot = try await fetch(output(#"{"credits":1,"subscription_plan_type":"\#(raw)"}"#))
            #expect(snapshot.plan == shown, "\(raw)")
        }
    }

    @Test func aMissingOrBlankPlanStillShowsTheCredits() async throws {
        for json in [#"{"credits":3}"#, #"{"credits":3,"subscription_plan_type":""}"#, #"{"credits":3,"subscription_plan_type":null}"#] {
            let snapshot = try await fetch(output(json))
            #expect(snapshot.plan == nil, "\(json)")
            #expect(snapshot.notes == ["Credits: 3"], "\(json)")
        }
    }

    @Test func anAnswerWithoutACreditNumberCannotBeRead() async throws {
        for body in ["", "not json", "[]", #"{"email":"person@example.com"}"#, #"{"credits":"10"}"#, #"{"credits":true}"#, #"{"credits":null}"#] {
            await #expect(throws: FetchError.parse("higgsfield output has no credit number"), "\(body)") {
                try await self.fetch(output(body))
            }
        }
    }

    // MARK: Failures

    @Test func exitCodesFromTheRealCLI() {
        let cases: [(Int32, String, FetchError)] = [
            (2, "Error: Session expired.\nHint: Run: hf auth login\n", .notSignedIn),
            (2, "Error: higgsfield: request failed (no response received)\nHint: Run: hf auth login\n", .notSignedIn),
            (3, "Error: request failed (no response received)\n", .network("higgsfield could not reach its server")),
            (4, "Error: No workspace selected.\nHint: Run: hf workspace set <workspace_id>\n", .unsupported(HiggsfieldUsageFetcher.noWorkspaceMessage)),
            // An npm install's launcher, whose `env node` finds no Node outside the user's shell.
            (127, "env: node: No such file or directory\n", .cliNotFound("higgsfield")),
        ]
        for (code, stderr, expected) in cases {
            #expect(HiggsfieldUsageFetcher.failure(exitCode: code, stderr: Data(stderr.utf8)) == expected, "\(code)")
        }
    }

    /// The binary holds this wording, possibly only in library code. No real failure has shown it or its exit code.
    @Test func rateLimitAndServerWordingDecideBeforeTheExitCode() {
        #expect(HiggsfieldUsageFetcher.failure(exitCode: 2, stderr: Data("Error: rate limited\n".utf8)) == .rateLimited(retryAfter: nil))
        #expect(HiggsfieldUsageFetcher.failure(exitCode: 1, stderr: Data("Too many requests for \"x\"\n".utf8)) == .rateLimited(retryAfter: nil))
        #expect(HiggsfieldUsageFetcher.failure(exitCode: 1, stderr: Data("higgsfield: server error\n".utf8)) == .network("higgsfield could not reach its server"))
    }

    /// stderr can name the account, so it is only matched, never carried in the error.
    @Test func anUnknownFailureCarriesNothingFromStderr() {
        let failure = HiggsfieldUsageFetcher.failure(exitCode: 9, stderr: Data("person@example.com is not allowed\n".utf8))
        #expect(failure == .parse("higgsfield exited with status 9"))
    }

    @Test func aRunThatFailsReportsItsExitCodeNotItsOutput() async throws {
        await #expect(throws: FetchError.notSignedIn) {
            try await self.fetch(output("", stderr: "Error: Session expired.\n", exitCode: 2))
        }
    }

    @Test func aRunThatTimesOutIsATimeout() async throws {
        await #expect(throws: FetchError.timeout) {
            try await self.fetch(output("", timedOut: true))
        }
    }

    @Test func aMissingCLIIsReportedAndNothingRuns() async throws {
        let runner = FakeRunner(output(Self.answer))
        let context = try context(runner, cliPath: home.appending(path: "bin/missing").path)
        await #expect(throws: FetchError.cliNotFound("higgsfield")) {
            try await HiggsfieldUsageFetcher().fetch(self.account, context: context)
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: Helpers

    /// `searchDirectories` is empty, so a higgsfield installed on the Mac running this is never found.
    private func context(_ runner: FakeRunner, cliPath: String? = nil) throws -> FetchContext {
        let cli = home.appending(path: "bin/higgsfield")
        try Data().write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let now = self.now
        return FetchContext(
            process: runner, cli: CLILocator(home: home, overrides: ["higgsfield": cliPath ?? cli.path], searchDirectories: []),
            paths: AppPaths(home: home), now: { now }
        )
    }

    private func fetch(_ result: ProcessResult) async throws -> UsageSnapshot {
        try await HiggsfieldUsageFetcher().fetch(account, context: context(FakeRunner(result)))
    }
}
