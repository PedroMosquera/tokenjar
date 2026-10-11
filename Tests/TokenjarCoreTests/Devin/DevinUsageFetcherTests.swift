import Foundation
import Testing
@testable import TokenjarCore

struct DevinUsageFetcherTests {
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    private func fetch(_ account: AccountConfig, runner: RefusingRunner) async throws -> UsageSnapshot {
        let home = URL(fileURLWithPath: "/nonexistent-tokenjar-devin-home")
        let now = self.now
        let context = FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: ["devin": "/nonexistent/devin"]),
            paths: AppPaths(home: home), now: { now }
        )
        return try await DevinUsageFetcher().fetch(account, context: context)
    }

    /// A link card: no windows or money to judge, so nothing on it can read as a problem, and the notes say where to look.
    @Test func reportsAPlanPageLinkWithoutRunningAnything() async throws {
        let runner = RefusingRunner()
        let snapshot = try await fetch(AccountConfig(id: "devin", provider: .devin, label: "Devin"), runner: runner)

        #expect(runner.calls == 0)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.isEmpty)
        #expect(snapshot.plan == nil)
        #expect(snapshot.source == "plan page")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.provider == .devin)
        #expect(snapshot.notes == [
            "Devin doesn't share your quota with local apps yet. Open the plan page to see it.",
            "On a grandfathered Windsurf plan? Set this account's usage page to windsurf.com/subscription/manage-plan.",
        ])
    }

    @Test func dropsTheWindsurfHintOnceTheUsagePageIsSet() async throws {
        let account = AccountConfig(id: "devin", provider: .devin, label: "Windsurf", dashboardURL: "https://windsurf.com/subscription/manage-plan")
        let snapshot = try await fetch(account, runner: RefusingRunner())
        #expect(snapshot.notes == ["Devin doesn't share your quota with local apps yet. Open the plan page to see it."])
    }
}

/// Fails the test if the fetcher tries to start any process.
private final class RefusingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        lock.withLock { count += 1 }
        Issue.record("Devin must not run \(executable.lastPathComponent)")
        throw CocoaError(.executableNotLoadable)
    }
}
