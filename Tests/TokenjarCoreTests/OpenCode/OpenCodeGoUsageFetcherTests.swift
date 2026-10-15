import Foundation
import Testing
@testable import TokenjarCore

struct OpenCodeGoUsageFetcherTests {
    let now = DateParsing.iso8601("2026-10-10T12:00:00Z")!
    let account = AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: .keychain(account: "go"))

    private func snapshot(_ fixture: String, status: Int = 200) throws -> UsageSnapshot {
        let response = HTTPResponse(status: status, body: try OpenCodeFixtures.data(fixture))
        return try OpenCodeGoUsageFetcher.snapshot(from: response, account: account, now: now)
    }

    private func error(status: Int, body: String, headers: [String: String] = [:]) -> FetchError? {
        let response = HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        do {
            _ = try OpenCodeGoUsageFetcher.snapshot(from: response, account: account, now: now)
            return nil
        } catch {
            return error as? FetchError
        }
    }

    @Test func mapsAllThreeWindowsByKind() throws {
        let s = try snapshot("go-usage.json")
        #expect(s.windows.map(\.id) == ["session", "weekly", "monthly"])
        #expect(s.windows.map(\.label) == ["5-hour", "Week", "Month"])
        #expect(s.windows.map(\.usedPercent) == [40, 50, 60])
        #expect(s.windows.map(\.windowMinutes) == [300, 10_080, 31 * 1_440])
        #expect(s.windows.map(\.resetsAt) == [
            DateParsing.iso8601("2026-10-10T14:20:00Z"), DateParsing.iso8601("2026-10-12T00:00:00Z"),
            DateParsing.iso8601("2026-11-05T12:00:00Z"),
        ])
        #expect(s.windows.allSatisfy { !$0.notStarted })
        #expect(s.plan == "Go")
        #expect(s.source == "opencode API")
        #expect(s.provider == .opencodeGo)
        #expect(s.accountID == "go")
        #expect(s.fetchedAt == now)
        #expect(s.notes.isEmpty)
    }

    @Test func idleWindowIsNotStarted() throws {
        let s = try snapshot("go-usage-idle.json")
        let byID = Dictionary(uniqueKeysWithValues: s.windows.map { ($0.id, $0) })
        #expect(byID["session"]?.notStarted == true)
        #expect(byID["session"]?.usedPercent == 0)
        #expect(byID["weekly"]?.notStarted == false)
        #expect(byID["monthly"]?.notStarted == false)
    }

    @Test func rateLimitedWindowAddsNote() throws {
        let s = try snapshot("go-usage-rate-limited.json")
        #expect(s.notes == ["5-hour limit reached"])
        #expect(s.windows.first?.usedPercent == 100)
        #expect(s.windows.first?.notStarted == false)
    }

    /// Captured classic error bodies. A 403 is a valid key without a Go plan, never a bad key.
    @Test(arguments: [
        ("go-error-403.json", 403, FetchError.noSubscription("No active OpenCode Go subscription for this key")),
        ("go-error-401.json", 401, FetchError.unauthorized),
        ("go-error-503.json", 503, FetchError.network("OpenCode API unavailable (HTTP 503)")),
    ])
    func capturedErrorBodiesAreClassified(fixture: String, status: Int, expected: FetchError) throws {
        let body = String(decoding: try OpenCodeFixtures.data(fixture), as: UTF8.self)
        #expect(error(status: status, body: body) == expected)
    }

    /// Migrated v2 workspaces answer `{"_tag": ...}`. A known name wins over the status; anything else falls through to it.
    @Test(arguments: [
        ("v2 entitlement tag", 403, #"{"_tag":"EntitlementError"}"#, [:], FetchError.noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage)),
        ("v2 subscription tag on a 404", 404, #"{"_tag":"SubscriptionNotFound"}"#, [:], .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage)),
        ("v2 unauthorized tag", 401, #"{"_tag":"Unauthorized"}"#, [:], .unauthorized),
        ("v2 auth tag on a 200", 200, #"{"_tag":"AuthError"}"#, [:], .unauthorized),
        ("v2 rate limit tag keeps retry-after", 429, #"{"_tag":"RateLimitError"}"#, ["retry-after": "30"], .rateLimited(retryAfter: 30)),
        ("unknown tag on a 5xx", 500, #"{"_tag":"InternalError"}"#, [:], .network("OpenCode API unavailable (HTTP 500)")),
        ("forbidden without a body", 403, "", [:], .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage)),
        ("forbidden with an unknown tag", 403, #"{"_tag":"Forbidden"}"#, [:], .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage)),
        ("200 without windows", 200, #"{"usage":{}}"#, [:], .parse("usage body has no rolling, weekly or monthly window")),
    ] as [(String, Int, String, [String: String], FetchError)])
    func errorsAreClassifiedByNameThenStatus(_ label: String, status: Int, body: String, headers: [String: String], expected: FetchError) {
        #expect(error(status: status, body: body, headers: headers) == expected)
    }

    @Test func fetchSendsOneAuthorizedGetToTheUsageEndpoint() async throws {
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: try OpenCodeFixtures.data("go-usage.json")))
        let context = FetchContext(
            http: HTTPClient(transport: transport), secrets: InMemorySecretStore(["go": "sk-test-placeholder"]),
            paths: AppPaths(home: URL(fileURLWithPath: "/nonexistent")), now: { [now] in now }
        )
        let s = try await OpenCodeGoUsageFetcher(environment: [:]).fetch(account, context: context)
        #expect(s.windows.count == 3)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url == URL(string: "https://opencode.ai/zen/go/v1/usage"))
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-placeholder")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Tokenjar")
    }

    @Test func missingKeyIsNotSignedInAndSendsNothing() async throws {
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: Data()))
        let context = FetchContext(http: HTTPClient(transport: transport), secrets: InMemorySecretStore(), paths: AppPaths(home: URL(fileURLWithPath: "/nonexistent")))
        await #expect(throws: FetchError.notSignedIn) {
            try await OpenCodeGoUsageFetcher(environment: [:]).fetch(account, context: context)
        }
        #expect(transport.requests.isEmpty)
    }
}
