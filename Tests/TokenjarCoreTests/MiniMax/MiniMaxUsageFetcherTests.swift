import Foundation
import Testing
@testable import TokenjarCore

/// The fixtures are written by hand from CodexBar's reading of MiniMax's Token Plan answer until a live one is captured.
/// Its `*_usage_count` fields count what remains, not what was used.
struct MiniMaxUsageFetcherTests {
    let now = DateParsing.iso8601("2026-11-02T12:00:00Z")!
    let account = AccountConfig(id: "minimax", provider: .minimax, label: "MiniMax", credential: .keychain(account: "minimax"))

    private func snapshot(_ fixture: String) throws -> UsageSnapshot {
        try MiniMaxUsageFetcher.snapshot(from: HTTPResponse(status: 200, body: try MiniMaxFixtures.data(fixture)), account: account, now: now)
    }

    private func error(_ fixture: String, status: Int, headers: [String: String] = [:]) throws -> FetchError? {
        let response = HTTPResponse(status: status, headers: headers, body: try MiniMaxFixtures.data(fixture))
        do {
            _ = try MiniMaxUsageFetcher.snapshot(from: response, account: account, now: now)
            return nil
        } catch {
            return error as? FetchError
        }
    }

    @Test func oneTextModelUsesPlainIDs() throws {
        let s = try snapshot("minimax-remains.json")
        #expect(s.windows.map(\.id) == ["session", "weekly"])
        #expect(s.windows.map(\.label) == ["5-hour", "Week"])
        #expect(s.windows.map(\.usedPercent) == [25, 10])
        #expect(s.windows.map(\.windowMinutes) == [300, 10_080])
        #expect(s.windows.map(\.resetsAt) == [DateParsing.iso8601("2026-11-02T15:00:00Z"), DateParsing.iso8601("2026-11-09T00:00:00Z")])
        #expect(s.plan == "Token Plan")
        #expect(s.source == "minimax API")
        #expect(s.provider == .minimax)
        #expect(s.fetchedAt == now)
    }

    /// An explicit percent wins over the counts.
    @Test func twoTextModelsArePools() throws {
        let s = try snapshot("minimax-remains-two-models.json")
        #expect(s.windows.map(\.id) == ["minimaxm2:session", "minimaxm2:weekly", "minimaxm25:session", "minimaxm25:weekly"])
        #expect(s.windows.map(\.label) == ["MiniMax-M2 · 5-hour", "MiniMax-M2 · Week", "MiniMax-M2.5 · 5-hour", "MiniMax-M2.5 · Week"])
        #expect(s.windows.map(\.usedPercent) == [25, 10, 10, 30])
    }

    /// A boost raises what can be spent, so used is measured against the boosted total and never passes 100 %.
    @Test func boostRaisesTheTotal() throws {
        let s = try snapshot("minimax-remains-boost.json")
        let used = try #require(s.windows.first?.usedPercent)
        #expect(abs(used - 750.0 / 900.0 * 100) < 0.001)
    }

    @Test func modelExcludedFromThePlanIsSkipped() throws {
        let s = try snapshot("minimax-remains-excluded.json")
        #expect(s.windows.map(\.id) == ["session"])
    }

    @Test func missingEndTimeLeavesNoReset() throws {
        let s = try snapshot("minimax-remains-no-end.json")
        #expect(s.windows.first?.resetsAt == nil)
        #expect(s.windows.first?.usedPercent == 25)
    }

    @Test(arguments: [
        ("minimax-error-key.json", 200, [String: String](), FetchError.unauthorized),
        ("minimax-error-plan.json", 200, [:], .noSubscription("No active MiniMax Token Plan for this key")),
        ("minimax-error-key.json", 401, [:], .unauthorized),
        ("minimax-error-key.json", 429, ["Retry-After": "30"], .rateLimited(retryAfter: 30)),
        ("minimax-error-key.json", 503, [:], .network("MiniMax API unavailable (HTTP 503)")),
    ] as [(String, Int, [String: String], FetchError)])
    func errorsInTheBodyAndStatus(fixture: String, status: Int, headers: [String: String], expected: FetchError) throws {
        #expect(try error(fixture, status: status, headers: headers) == expected)
    }

    @Test func nonJSONAnswerIsANetworkError() throws {
        guard case .network = try error("minimax-block-page.html", status: 200) else {
            Issue.record("a block page must read as unreachable, not as a broken answer")
            return
        }
    }

    @Test func sendsBearerOnlyToTheAllowlistedPath() async throws {
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: try MiniMaxFixtures.data("minimax-remains.json")))
        let context = FetchContext(
            http: HTTPClient(transport: transport), secrets: InMemorySecretStore(["minimax": "k-123\n"]),
            paths: AppPaths(home: URL(fileURLWithPath: "/nonexistent")), now: { [now] in now }
        )
        _ = try await MiniMaxUsageFetcher().fetch(account, context: context)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url == URL(string: "https://api.minimax.io/v1/token_plan/remains"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-123")
    }
}

enum MiniMaxFixtures {
    static func data(_ name: String) throws -> Data {
        try fixture("MiniMax/\(name)")
    }
}
