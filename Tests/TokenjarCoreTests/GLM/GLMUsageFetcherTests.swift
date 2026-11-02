import Foundation
import Testing
@testable import TokenjarCore

/// The fixtures are written by hand from Z.ai's own client docs and CodexBar's notes until a live answer is captured.
struct GLMUsageFetcherTests {
    let now = DateParsing.iso8601("2026-11-02T12:00:00Z")!
    let account = AccountConfig(id: "glm", provider: .glm, label: "GLM", credential: .keychain(account: "glm"))

    private func snapshot(_ fixture: String, status: Int = 200) throws -> UsageSnapshot {
        let response = HTTPResponse(status: status, body: try GLMFixtures.data(fixture))
        return try GLMUsageFetcher.snapshot(from: response, account: account, now: now)
    }

    private func error(_ fixture: String, status: Int, headers: [String: String] = [:]) throws -> FetchError? {
        let response = HTTPResponse(status: status, headers: headers, body: try GLMFixtures.data(fixture))
        do {
            _ = try GLMUsageFetcher.snapshot(from: response, account: account, now: now)
            return nil
        } catch {
            return error as? FetchError
        }
    }

    @Test func mapsTheThreeWindowsByTypeUnitAndNumber() throws {
        let s = try snapshot("glm-quota.json")
        #expect(s.windows.map(\.id) == ["session", "weekly", "mcp:monthly"])
        #expect(s.windows.map(\.label) == ["5-hour", "Week", "Tools (MCP)"])
        #expect(s.windows.map(\.usedPercent) == [42, 18, 5])
        #expect(s.windows.map(\.windowMinutes) == [300, 10_080, 30 * 1_440])
        #expect(s.windows.map(\.resetsAt) == [
            DateParsing.iso8601("2026-11-02T14:00:00Z"), DateParsing.iso8601("2026-11-06T00:00:00Z"),
            DateParsing.iso8601("2026-12-01T00:00:00Z"),
        ])
        #expect(s.windows.allSatisfy { !$0.notStarted })
        #expect(s.plan == "Lite")
        #expect(s.source == "z.ai API")
        #expect(s.provider == .glm)
        #expect(s.accountID == "glm")
        #expect(s.fetchedAt == now)
    }

    /// Plan V3, sold since 2026-07-30, counts credits instead of tokens.
    @Test func readsCreditLimitsAndSkipsUnknownEntries() throws {
        let s = try snapshot("glm-quota-v3.json")
        #expect(s.windows.map(\.id) == ["session", "weekly", "mcp:monthly"])
        #expect(s.windows.map(\.usedPercent) == [61, 33, 12])
        #expect(s.plan == "pro")
        let tools = try #require(s.windows.last)
        #expect(tools.resetsAt == nil)
        #expect(tools.windowMinutes == nil)
    }

    @Test func idleWindowIsNotStarted() throws {
        let s = try snapshot("glm-quota-idle.json")
        #expect(s.windows.map(\.notStarted) == [true, false])
    }

    @Test func emptyLimitsMeanNoPlan() throws {
        #expect(try error("glm-quota-empty.json", status: 200) == .noSubscription("No active GLM Coding Plan for this key"))
    }

    @Test func onlyUnrecognizedEntriesIsAParseError() throws {
        guard case .parse = try error("glm-quota-unrecognized.json", status: 200) else {
            Issue.record("a list with no window Tokenjar knows must fail, not read as no plan")
            return
        }
    }

    @Test(arguments: [
        ("glm-error-401.json", 401, [String: String](), FetchError.unauthorized),
        ("glm-error-body.json", 200, [:], .unauthorized),
        ("glm-error-body.json", 429, ["Retry-After": "30"], .rateLimited(retryAfter: 30)),
        ("glm-error-body.json", 503, [:], .network("z.ai API unavailable (HTTP 503)")),
    ] as [(String, Int, [String: String], FetchError)])
    func statusAndBodyErrors(fixture: String, status: Int, headers: [String: String], expected: FetchError) throws {
        #expect(try error(fixture, status: status, headers: headers) == expected)
    }

    /// Only the bad-key code means the key was rejected: an expired plan or a spent quota must not send the user to change a
    /// working key.
    @Test func otherErrorCodesAreNotARejectedKey() throws {
        #expect(try error("glm-error-other.json", status: 200) == .network("z.ai API error 1113"))
    }

    /// The work laptop this was built on serves an HTML block page for api.z.ai.
    @Test func nonJSONAnswerIsANetworkError() throws {
        guard case .network = try error("glm-block-page.html", status: 200) else {
            Issue.record("a block page must read as unreachable, not as a broken answer")
            return
        }
    }

    @Test func sendsTheTrimmedBareKeyOnlyToTheAllowlistedPath() async throws {
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: try GLMFixtures.data("glm-quota.json")))
        let context = FetchContext(
            http: HTTPClient(transport: transport), secrets: InMemorySecretStore(["glm": "  k-123\n"]),
            paths: AppPaths(home: URL(fileURLWithPath: "/nonexistent")), now: { [now] in now }
        )
        _ = try await GLMUsageFetcher().fetch(account, context: context)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url == URL(string: "https://api.z.ai/api/monitor/usage/quota/limit"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "k-123")
    }

    @Test func missingKeyIsNotSignedInAndSendsNothing() async throws {
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: Data()))
        let context = FetchContext(http: HTTPClient(transport: transport), secrets: InMemorySecretStore(), paths: AppPaths(home: URL(fileURLWithPath: "/nonexistent")))
        await #expect(throws: FetchError.notSignedIn) { try await GLMUsageFetcher().fetch(account, context: context) }
        #expect(transport.requests.isEmpty)
    }
}

enum GLMFixtures {
    static func data(_ name: String) throws -> Data {
        try fixture("GLM/\(name)")
    }
}
