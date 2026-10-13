import Foundation
import Testing
@testable import TokenjarCore

struct ProviderHealthFetcherTests {
    let arrival = Date(timeIntervalSince1970: 1_791_838_635)

    private func fetch(_ provider: ProviderID, _ transport: HealthFakeTransport) async throws -> ProviderHealthAnswer {
        let arrival = self.arrival
        return try await ProviderHealthFetcher(http: HTTPClient(transport: transport), now: { arrival }).fetch(provider)
    }

    private static func ok(_ fixture: String, headers: [String: String] = [:]) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: headers, body: try fixture == "openai" ? HealthFixtures.openAI() : HealthFixtures.data(fixture))
    }

    /// The status hosts get Tokenjar's User-Agent and Accept, and nothing else: no OpenCode key, no cookie.
    @Test(arguments: [(ProviderID.claude, "claude-console-only.json"), (.codex, "openai"), (.copilot, "github-code-review.json")])
    func sendsOneGETWithNoKeyOrCookie(provider: ProviderID, fixture: String) async throws {
        let transport = HealthFakeTransport(try Self.ok(fixture))
        _ = try await fetch(provider, transport)
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url == provider.statusFeedURL)
        #expect(request.httpMethod == "GET")
        #expect(request.allHTTPHeaderFields == ["User-Agent": "Tokenjar", "Accept": "application/json"])
        #expect(request.timeoutInterval == 10)
    }

    @Test(arguments: [ProviderID.opencodeGo, .opencodeZen, .antigravity, .devin])
    func providersWithoutAFeedSendNothing(provider: ProviderID) async {
        let transport = HealthFakeTransport(HTTPResponse(status: 200, body: Data()))
        await #expect(throws: FetchError.unsupported("\(provider.displayName) has no status feed")) { try await fetch(provider, transport) }
        #expect(transport.requests.isEmpty)
    }

    /// The feeds are the only endpoints on the list besides OpenCode's, and the status pages themselves cannot be fetched:
    /// they open in the browser.
    @Test func feedsAreTheOnlyOtherAllowedEndpointsAndPagesAreNeverFetched() {
        var expected: [String: Set<String>] = ["opencode.ai": [OpenCodeGoUsageFetcher.usageURL.path()]]
        for url in ProviderID.allCases.compactMap(\.statusFeedURL) { expected[url.host()!, default: []].insert(url.path()) }
        #expect(HTTPClient.allowedEndpoints == expected)
        for url in ProviderID.allCases.compactMap(\.statusPageURL) {
            #expect(throws: HTTPClientError.self) { try HTTPClient.validate(url) }
        }
    }

    // MARK: How old an answer is

    /// A CDN can serve an old copy with a 200, which `Age` reveals.
    @Test func theAgeHeaderDatesTheAnswer() async throws {
        let answer = try await fetch(.claude, HealthFakeTransport(try Self.ok("claude-console-only.json", headers: ["age": "2400"])))
        #expect(answer.answeredAt == arrival.addingTimeInterval(-2400))
        #expect(answer.showsAge(now: arrival))
    }

    /// A cache that drops `Age` still keeps the origin's `Date`.
    @Test func theDateHeaderDatesTheAnswer() async throws {
        let date = "Mon, 12 Oct 2026 20:17:15 GMT"
        #expect(arrival.timeIntervalSince(DateParsing.httpDate(date)!) == 2400)
        let answer = try await fetch(.copilot, HealthFakeTransport(try Self.ok("github-code-review.json", headers: ["date": date])))
        #expect(answer.answeredAt == arrival.addingTimeInterval(-2400))
    }

    /// `Date` is read against this Mac's clock, so it counts only when `Age` is missing: a clock 6 minutes fast must not
    /// give an answer that just arrived an age.
    @Test func aMacClockAheadOfTheHostDoesNotAgeAnAnswerThatHasAge() async throws {
        let sixMinutesBehind = "Mon, 12 Oct 2026 20:51:15 GMT"
        #expect(arrival.timeIntervalSince(DateParsing.httpDate(sixMinutesBehind)!) == 360)
        let headers = ["age": "0", "date": sixMinutesBehind]
        let answer = try await fetch(.claude, HealthFakeTransport(try Self.ok("claude-console-only.json", headers: headers)))
        #expect(answer.answeredAt == arrival)
        #expect(!answer.showsAge(now: arrival))
    }

    @Test func aFreshAnswerShowsNoAge() async throws {
        let headers = ["age": "17", "date": "Mon, 12 Oct 2026 20:57:00 GMT"]
        let answer = try await fetch(.claude, HealthFakeTransport(try Self.ok("claude-console-only.json", headers: headers)))
        #expect(answer.answeredAt == arrival.addingTimeInterval(-17))
        #expect(!answer.showsAge(now: arrival.addingTimeInterval(4 * 60)))
        #expect(answer.showsAge(now: arrival.addingTimeInterval(5 * 60)))
    }

    // MARK: Failures

    @Test func failuresSayWhatKindTheyWere() async throws {
        let cases: [(HealthFakeTransport, FetchError)] = [
            (HealthFakeTransport(HTTPResponse(status: 503, body: Data())), .network("HTTP 503")),
            (HealthFakeTransport(HTTPResponse(status: 301, headers: ["location": "https://status.claude.com/"], body: Data())), .network("HTTP 301")),
            (HealthFakeTransport(error: URLError(.timedOut)), .timeout),
            (HealthFakeTransport(error: URLError(.notConnectedToInternet)), .network("URLError -1009")),
            (HealthFakeTransport(HTTPResponse(status: 200, body: Data("<html></html>".utf8))), .parse("summary has no components, incidents or scheduled maintenances")),
        ]
        for (transport, expected) in cases {
            await #expect(throws: expected) { try await fetch(.claude, transport) }
        }
    }
}

struct ProviderHealthStateTests {
    let now = Date(timeIntervalSince1970: 1_791_838_635)

    /// A failed check learns nothing, which is not the same as learning the problem is over.
    @Test func aFailedCheckKeepsTheLastAnswer() {
        let answer = ProviderHealthAnswer(items: [ProviderHealthItem(level: .majorOutage, names: ["Copilot"], title: "Incident with GitHub.com")], answeredAt: now)
        var health = ProviderHealth()
        health.record(.success(answer))
        health.record(.failure(.timeout))
        #expect(health.answer == answer)
        #expect(health.lastFailure == .timeout)
        health.record(.success(ProviderHealthAnswer(items: [], answeredAt: now.addingTimeInterval(120))))
        #expect(health.answer?.items == [])
        #expect(health.lastFailure == nil)
    }

    /// Counted from the last request, answered or not, so a host that keeps failing is not asked on every popover open.
    @Test func popoverOpenAsksAgainOnlyAfterTwoMinutesEvenAfterAFailure() {
        var health = ProviderHealth()
        #expect(health.isDue(now: now))
        health.asked(at: now)
        health.record(.failure(.network("HTTP 503")))
        #expect(!health.isDue(now: now.addingTimeInterval(119)))
        #expect(health.isDue(now: now.addingTimeInterval(120)))
        #expect(ProviderHealth.askAgainAfter == 120)
    }
}
