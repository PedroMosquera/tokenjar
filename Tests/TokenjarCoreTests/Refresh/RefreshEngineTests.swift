import Foundation
import Testing
@testable import TokenjarCore

/// Answers every fetch from `answer` and counts the calls, so no CLI runs.
private final class FakeFetcher: UsageFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let answer: @Sendable (AccountConfig) throws -> UsageSnapshot

    init(_ answer: @escaping @Sendable (AccountConfig) throws -> UsageSnapshot) { self.answer = answer }

    var count: Int { lock.withLock { calls } }

    func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        lock.withLock { calls += 1 }
        return try answer(account)
    }
}

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func answer(_ account: AccountConfig, used: Double = 42) -> UsageSnapshot {
    UsageSnapshot(
        accountID: account.id, provider: account.provider,
        windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: used, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600))],
        fetchedAt: now, source: "test"
    )
}

struct RefreshEngineTests {
    private let home = TempHome()
    private var paths: AppPaths { AppPaths(home: home.url, environment: [:]) }

    init() throws {
        // Claude's account counts as present on this machine while its profile folder exists.
        try home.makeDirectory(".claude")
    }

    private func engine(_ fetcher: FakeFetcher, store: any UsageStore = InMemoryUsageStore()) -> RefreshEngine {
        RefreshEngine(paths: paths, store: store, fetcher: { _ in fetcher }, scanner: { _ in nil }, clock: { now })
    }

    private func writeConfig(_ accounts: [AccountConfig]) throws {
        var config = AppConfig()
        config.accounts = accounts
        try ConfigStore(paths: paths).write(config)
    }

    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")

    @Test func aDueAccountIsCheckedOnceAndItsAnswerReported() async throws {
        try writeConfig([claude])
        let fetcher = FakeFetcher { answer($0, used: 42) }
        let engine = engine(fetcher)

        await engine.tick()
        await engine.tick()

        #expect(fetcher.count == 1)
        let report = await engine.report()
        #expect(report.accounts.map(\.id) == ["claude"])
        #expect(report.accounts.first?.windows.map(\.usedPercent) == [42])
        #expect(await engine.checks["claude"] == RefreshEngine.Check(at: now, error: nil))
    }

    @Test func aForcedTickChecksAgainButAFailureIsKeptForTheTray() async throws {
        try writeConfig([claude])
        let fetcher = FakeFetcher { _ in throw FetchError.timeout }
        let engine = engine(fetcher)

        await engine.tick()
        await engine.tick(force: true)

        #expect(fetcher.count == 2)
        #expect(await engine.checks["claude"]?.error == .timeout)
    }

    /// Hard rule 5. The latch is written where the Mac app reads it, and an engine started later honors it too.
    @Test func aModelTurnLatchesTheAccountUntilRetried() async throws {
        try writeConfig([claude])
        let fetcher = FakeFetcher { _ in throw ProbeLatch.CLI.claude.modelTurnError }

        await engine(fetcher).tick()
        let restarted = engine(fetcher)
        await restarted.tick(force: true)

        #expect(fetcher.count == 1)
        #expect(await restarted.isLatched("claude"))
        #expect(FileManager.default.fileExists(atPath: paths.supportDirectory.appending(path: ProbeLatch.fileName).path))

        await restarted.retry(accountID: "claude")
        #expect(fetcher.count == 2)
    }

    @Test func accountsMissingHereOrDisabledAreNotChecked() async throws {
        let codex = AccountConfig(id: "codex", provider: .codex, label: "ChatGPT")
        let off = AccountConfig(id: "claude-off", provider: .claude, label: "Off", enabled: false)
        try writeConfig([claude, codex, off])
        let fetcher = FakeFetcher { answer($0) }
        let engine = engine(fetcher)

        await engine.tick()

        #expect(fetcher.count == 1)
        #expect(await engine.accounts.map(\.id) == ["claude"])
    }

    @Test func theFirstRunWritesTheAccountsFoundHere() async throws {
        let engine = engine(FakeFetcher { answer($0) })

        await engine.loadConfig()

        // Discovery also looks at this machine's own apps and PATH, so only the account this home holds is pinned.
        let written = try #require(try ConfigStore(paths: paths).load()).merged
        #expect(written.accounts.first?.id == "claude")
        #expect(await engine.configProblem == nil)
    }

    @Test func aConfigThatStopsParsingKeepsTheLastSettings() async throws {
        try writeConfig([claude])
        let engine = engine(FakeFetcher { answer($0) })
        await engine.loadConfig()

        try Data("{ not json".utf8).write(to: paths.configFile)
        await engine.loadConfig()

        #expect(await engine.config.accounts.map(\.id) == ["claude"])
        #expect(await engine.configProblem != nil)
    }
}
