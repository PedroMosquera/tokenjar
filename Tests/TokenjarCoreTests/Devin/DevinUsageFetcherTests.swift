import Foundation
import Testing
@testable import TokenjarCore

struct DevinUsageFetcherTests {
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    private func fetch(_ account: AccountConfig, runner: FakeRunner) async throws -> UsageSnapshot {
        let home = URL(fileURLWithPath: "/nonexistent-tokenjar-devin-home")
        let now = self.now
        let context = FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: ["devin": "/nonexistent/devin"], searchDirectories: []),
            paths: AppPaths(home: home), now: { now }
        )
        return try await DevinUsageFetcher().fetch(account, context: context)
    }

    /// A link card: no windows or money to judge, so nothing on it can read as a problem, and the notes say where to look.
    @Test func reportsAUsagePageLinkWithoutRunningAnything() async throws {
        let runner = refusingRunner()
        let snapshot = try await fetch(AccountConfig(id: "devin", provider: .devin, label: "Devin"), runner: runner)

        #expect(runner.calls.isEmpty)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.isEmpty)
        #expect(snapshot.plan == nil)
        #expect(snapshot.source == "usage page")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.provider == .devin)
        #expect(snapshot.notes == [
            "Devin doesn't share your quota with local apps yet. Open the usage page to see it.",
            "On a grandfathered Windsurf plan? Set this account's usage page to windsurf.com/subscription/manage-plan.",
        ])
    }

    @Test func dropsTheWindsurfHintOnceTheUsagePageIsSet() async throws {
        let account = AccountConfig(id: "devin", provider: .devin, label: "Windsurf", dashboardURL: "https://windsurf.com/subscription/manage-plan")
        let snapshot = try await fetch(account, runner: refusingRunner())
        #expect(snapshot.notes == ["Devin doesn't share your quota with local apps yet. Open the usage page to see it."])
    }
}

/// Fails the test if the fetcher tries to start any process.
private func refusingRunner() -> FakeRunner {
    FakeRunner { call in
        Issue.record("Devin must not run \(call.executable.lastPathComponent)")
        throw CocoaError(.executableNotLoadable)
    }
}
