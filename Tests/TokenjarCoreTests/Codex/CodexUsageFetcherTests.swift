import Foundation
import Testing
@testable import TokenjarCore

struct CodexUsageFetcherTests {
    let now = Date(timeIntervalSince1970: 1_791_658_800)

    private func context(_ temp: CodexTempDirectory, binary: URL?, now: Date? = nil) -> FetchContext {
        let missing = temp.url.appending(path: "no-such-codex").path
        let fixedNow = now ?? self.now
        return FetchContext(
            secrets: InMemorySecretStore(),
            cli: CLILocator(home: temp.url, overrides: ["codex": binary?.path ?? missing], searchDirectories: []),
            paths: AppPaths(home: temp.url),
            now: { fixedNow }
        )
    }

    private func account(_ temp: CodexTempDirectory) -> AccountConfig {
        AccountConfig(id: "codex-test", provider: .codex, label: "Test", profileDir: temp.url.appending(path: "codex-home").path)
    }

    @Test func spawnsTheUsersCLIReadOnlyAndMapsTheAnswer() async throws {
        let temp = try CodexTempDirectory()
        let binary = try temp.fakeCodexBinary()
        let launcher = RecordingCodexLauncher(.answering(rateLimits: try CodexFixtures.line("rate-limits-plus.json")))
        let fetcher = CodexUsageFetcher(launcher: launcher, clientVersion: "9.9.9")
        try makeWorldReadableDirectory(AppPaths(home: temp.url).supportDirectory)

        let snapshot = try await fetcher.fetch(account(temp), context: context(temp, binary: binary))

        #expect(snapshot.source == "codex app-server")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly"])
        let launch = try #require(launcher.launches.first)
        #expect(launch.executable == binary)
        #expect(launch.arguments == ["-s", "read-only", "-a", "never", "app-server"])
        #expect(launch.environment["CODEX_HOME"] == temp.url.appending(path: "codex-home").path)
        #expect(launch.environment["PATH"] != nil)
        #expect(launch.currentDirectory == AppPaths(home: temp.url).probeDirectory)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: launch.currentDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try posixMode(AppPaths(home: temp.url).supportDirectory) == 0o700)
        #expect(try posixMode(launch.currentDirectory) == 0o700)
        #expect(launcher.connection.terminated)
    }

    @Test func defaultProfileLeavesCodexHomeUnset() async throws {
        let temp = try CodexTempDirectory()
        let launcher = RecordingCodexLauncher(.answering(rateLimits: try CodexFixtures.line("rate-limits-plus.json")))
        let plain = AccountConfig(id: "codex-test", provider: .codex, label: "Test")

        _ = try await CodexUsageFetcher(launcher: launcher).fetch(plain, context: context(temp, binary: try temp.fakeCodexBinary()))

        #expect(launcher.launches.first?.environment["CODEX_HOME"] == nil)
    }

    @Test func apiKeyLoginHasNoPlanLimits() async throws {
        let temp = try CodexTempDirectory()
        let launcher = RecordingCodexLauncher(.answering(
            rateLimits: #"{"id":2,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}"#
        ))

        let snapshot = try await CodexUsageFetcher(launcher: launcher).fetch(account(temp), context: context(temp, binary: try temp.fakeCodexBinary()))

        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.notes == ["No plan limits for this login"])
        #expect(snapshot.source == "codex app-server")
    }

    @Test func signedOutIsReportedEvenWhenALogExists() async throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-a.jsonl")
        let launcher = RecordingCodexLauncher(.answering(
            rateLimits: #"{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#
        ))

        await #expect(throws: FetchError.notSignedIn) {
            _ = try await CodexUsageFetcher(launcher: launcher).fetch(account(temp), context: context(temp, binary: try temp.fakeCodexBinary()))
        }
    }

    @Test func missingCLIWithoutLogsIsCliNotFound() async throws {
        let temp = try CodexTempDirectory()
        let launcher = RecordingCodexLauncher(.answering(rateLimits: "{}"))

        await #expect(throws: FetchError.cliNotFound("codex")) {
            _ = try await CodexUsageFetcher(launcher: launcher).fetch(account(temp), context: context(temp, binary: nil))
        }
        #expect(launcher.launches.isEmpty)
    }

    @Test func missingCLIFallsBackToTheLastLoggedLimits() async throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-a.jsonl")
        let at = Date.codexFixture("2026-10-09T10:30:00Z")

        let snapshot = try await CodexUsageFetcher(launcher: RecordingCodexLauncher(.answering(rateLimits: "{}")))
            .fetch(account(temp), context: context(temp, binary: nil, now: at))

        #expect(snapshot.source == "Codex session log")
        #expect(snapshot.fetchedAt == Date.codexFixture("2026-10-09T10:20:00.500Z"))
        #expect(snapshot.windows.map(\.id) == ["session", "weekly"])
        #expect(snapshot.windows.map(\.usedPercent) == [41.5, 12])
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.notes == ["Credits: 7", CodexRollouts.sessionLogNote])
    }

    @Test func serverFailureFallsBackAndDropsWindowsThatHaveReset() async throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-a.jsonl")
        let launcher = RecordingCodexLauncher(.answering(
            rateLimits: #"{"id":2,"error":{"code":-32603,"message":"failed to fetch codex rate limits: placeholder"}}"#
        ))
        let afterSessionReset = Date.codexFixture("2026-10-09T14:00:00Z")

        let snapshot = try await CodexUsageFetcher(launcher: launcher)
            .fetch(account(temp), context: context(temp, binary: try temp.fakeCodexBinary(), now: afterSessionReset))

        #expect(snapshot.source == "Codex session log")
        #expect(snapshot.windows.map(\.id) == ["weekly"])
    }

    @Test func serverFailureWithoutLogsIsANetworkError() async throws {
        let temp = try CodexTempDirectory()
        let launcher = RecordingCodexLauncher(.answering(
            rateLimits: #"{"id":2,"error":{"code":-32603,"message":"failed to fetch codex rate limits: placeholder"}}"#
        ))

        await #expect(throws: FetchError.network("codex rate limit request failed")) {
            _ = try await CodexUsageFetcher(launcher: launcher).fetch(account(temp), context: context(temp, binary: try temp.fakeCodexBinary()))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func silentServerTimesOutAndIsTerminated() async throws {
        let temp = try CodexTempDirectory()
        let connection = ScriptedCodexConnection(replies: ["initialize": [#"{"id":1,"result":{}}"#]])
        let launcher = RecordingCodexLauncher(connection)

        await #expect(throws: FetchError.timeout) {
            _ = try await CodexUsageFetcher(launcher: launcher, timeout: 0.2).fetch(account(temp), context: context(temp, binary: try temp.fakeCodexBinary()))
        }
        #expect(connection.terminated)
    }

    /// The logged copy looks like a live answer except for its note, so the snapshot itself says why it stands in: an
    /// offline Mac and a missing CLI must not read alike.
    @Test(.timeLimit(.minutes(1)))
    func aLoggedCopyRecordsWhyTheLiveCheckFailed() async throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-a.jsonl")
        let at = Date.codexFixture("2026-10-09T10:30:00Z")
        let rpcFailure = RecordingCodexLauncher(.answering(
            rateLimits: #"{"id":2,"error":{"code":-32603,"message":"failed to fetch codex rate limits: placeholder"}}"#
        ))
        let silent = RecordingCodexLauncher(ScriptedCodexConnection(replies: ["initialize": [#"{"id":1,"result":{}}"#]]))
        let binary = try temp.fakeCodexBinary()

        let network = try await CodexUsageFetcher(launcher: rpcFailure).fetch(account(temp), context: context(temp, binary: binary, now: at))
        let timeout = try await CodexUsageFetcher(launcher: silent, timeout: 0.2).fetch(account(temp), context: context(temp, binary: binary, now: at))
        let missing = try await CodexUsageFetcher(launcher: RecordingCodexLauncher(.answering(rateLimits: "{}"))).fetch(account(temp), context: context(temp, binary: nil, now: at))

        #expect([network, timeout, missing].map(\.source) == Array(repeating: CodexRollouts.sessionLogSource, count: 3))
        #expect(network.liveCheckFailure == .network)
        #expect(timeout.liveCheckFailure == .timeout)
        #expect(missing.liveCheckFailure == .other)
    }

    @Test func aLiveAnswerHasNoLiveCheckFailure() async throws {
        let temp = try CodexTempDirectory()
        let launcher = RecordingCodexLauncher(.answering(rateLimits: try CodexFixtures.line("rate-limits-plus.json")))

        let snapshot = try await CodexUsageFetcher(launcher: launcher).fetch(account(temp), context: context(temp, binary: try temp.fakeCodexBinary()))

        #expect(snapshot.source == "codex app-server")
        #expect(snapshot.liveCheckFailure == nil)
    }

    @Test func fallbackPicksTheNewestLogThatHasLimits() throws {
        let temp = try CodexTempDirectory()
        let home = temp.url.appending(path: "codex-home")
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-old.jsonl", modified: .codexFixture("2026-10-09T10:21:00Z"))
        try temp.copyFixture("rollout-records.jsonl", to: "codex-home/sessions/2026/10/09/rollout-new.jsonl", modified: .codexFixture("2026-10-09T11:30:00Z"))
        try temp.copyFixture("rollout-imported.jsonl", to: "codex-home/sessions/2026/10/10/rollout-imported.jsonl", modified: .codexFixture("2026-10-10T09:00:00Z"))

        let snapshot = try #require(CodexRollouts.lastLoggedSnapshot(codexHome: home, accountID: "a", now: .codexFixture("2026-10-09T12:00:00Z")))

        #expect(snapshot.fetchedAt == .codexFixture("2026-10-09T11:29:10.010Z"))
        #expect(snapshot.windows.map(\.usedPercent) == [4, 1])
    }

    @Test(arguments: [
        ("chatgpt authentication required to read rate limits", CodexUsageFetcher.Outcome.noPlanLimits),
        ("codex account authentication required to read rate limits", .failed(.notSignedIn)),
        ("Your access token could not be refreshed. Please log in again.", .failed(.notSignedIn)),
        ("unexpected status 401 Unauthorized", .failed(.notSignedIn)),
        ("failed to fetch codex rate limits: no snapshots returned", .failed(.network("codex rate limit request failed"))),
    ])
    func classifiesServerErrors(message: String, outcome: CodexUsageFetcher.Outcome) {
        #expect(CodexUsageFetcher.classify(CodexAppServerError.rpc(method: "m", message: message)) == outcome)
    }
}
