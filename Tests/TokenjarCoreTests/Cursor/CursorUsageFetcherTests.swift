import Foundation
import Testing
@testable import TokenjarCore

struct CursorUsageFetcherTests {
    let now = Date(timeIntervalSince1970: 1_791_660_000)

    @Test func reportsAUsagePageLinkWithoutRunningAnything() async throws {
        let runner = FakeRunner { call in
            Issue.record("Cursor must not run \(call.executable.lastPathComponent)")
            throw CocoaError(.executableNotLoadable)
        }
        let home = URL(fileURLWithPath: "/nonexistent-tokenjar-cursor-home")
        let now = self.now
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: Data()))
        let context = FetchContext(
            process: runner, http: HTTPClient(transport: transport), secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: [:], searchDirectories: []),
            paths: AppPaths(home: home), now: { now }
        )
        let snapshot = try await CursorUsageFetcher().fetch(AccountConfig(id: "cursor", provider: .cursor, label: "Cursor"), context: context)

        #expect(runner.calls.isEmpty)
        #expect(transport.requests.isEmpty)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.money.isEmpty)
        #expect(snapshot.plan == nil)
        #expect(snapshot.source == "usage page")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.provider == .cursor)
        #expect(snapshot.notes == ["Cursor doesn't share your usage with local apps. Open the usage page to see it."])
    }
}
