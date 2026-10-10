import Foundation
import Testing
@testable import HeadroomCore

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
        #expect(s.windows.map(\.usedPercent) == [37, 45, 61])
        #expect(s.windows.map(\.windowMinutes) == [300, 10_080, 31 * 1_440])
        #expect(s.windows.map(\.resetsAt) == [
            DateParsing.iso8601("2026-10-10T14:20:00Z"), DateParsing.iso8601("2026-10-12T00:00:00Z"),
            DateParsing.iso8601("2026-11-03T09:15:00Z"),
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

    @Test func monthLengthFollowsTheMonthEndingAtReset() {
        #expect(OpenCodeGoUsageFetcher.monthMinutes(endingAt: DateParsing.iso8601("2026-03-01T00:00:00Z")) == 28 * 1_440)
        #expect(OpenCodeGoUsageFetcher.monthMinutes(endingAt: DateParsing.iso8601("2026-05-15T08:00:00Z")) == 30 * 1_440)
        #expect(OpenCodeGoUsageFetcher.monthMinutes(endingAt: nil) == nil)
    }

    @Test func missingWindowsIsAParseError() {
        guard case .parse = error(status: 200, body: #"{"usage":{}}"#) else {
            Issue.record("expected parse error")
            return
        }
    }

    @Test func entitlementErrorMeansNoSubscriptionNotABadKey() throws {
        let body = String(decoding: try OpenCodeFixtures.data("go-error-403.json"), as: UTF8.self)
        #expect(error(status: 403, body: body) == .noSubscription("No active OpenCode Go subscription for this key"))
    }

    @Test func authErrorIsUnauthorized() throws {
        let body = String(decoding: try OpenCodeFixtures.data("go-error-401.json"), as: UTF8.self)
        #expect(error(status: 401, body: body) == .unauthorized)
    }

    @Test func routingFailureIsNetwork() throws {
        let body = String(decoding: try OpenCodeFixtures.data("go-error-503.json"), as: UTF8.self)
        guard case .network = error(status: 503, body: body) else {
            Issue.record("expected network error")
            return
        }
    }

    @Test func taggedV2ErrorsAreClassifiedByName() {
        #expect(error(status: 403, body: #"{"_tag":"EntitlementError"}"#) == .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage))
        #expect(error(status: 404, body: #"{"_tag":"SubscriptionNotFound"}"#) == .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage))
        #expect(error(status: 401, body: #"{"_tag":"Unauthorized"}"#) == .unauthorized)
        #expect(error(status: 200, body: #"{"_tag":"AuthError"}"#) == .unauthorized)
        #expect(error(status: 429, body: #"{"_tag":"RateLimitError"}"#, headers: ["retry-after": "30"]) == .rateLimited(retryAfter: 30))
        guard case .network = error(status: 500, body: #"{"_tag":"InternalError"}"#) else {
            Issue.record("expected network error for an unknown tag on a 5xx")
            return
        }
    }

    @Test func forbiddenWithoutAKnownNameStillMeansNoSubscription() {
        #expect(error(status: 403, body: "") == .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage))
        #expect(error(status: 403, body: #"{"_tag":"Forbidden"}"#) == .noSubscription(OpenCodeGoUsageFetcher.noSubscriptionMessage))
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
