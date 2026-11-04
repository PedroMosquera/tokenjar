import Foundation
import Testing
@testable import TokenjarCore

struct UpdateFetcherTests {
    private func fetch(_ transport: HealthFakeTransport) async throws -> ReleaseInfo {
        try await UpdateFetcher(http: HTTPClient(transport: transport)).fetch()
    }

    private func body(tag: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://example.com/elsewhere"}"#.utf8)
    }

    @Test func parsesVersions() {
        #expect(AppVersion("v0.4.0")?.description == "0.4.0")
        #expect(AppVersion("0.10.0")! > AppVersion("v0.9.0")!)
        #expect(AppVersion("0.4") == AppVersion("0.4.0"))
        #expect(AppVersion("v1.0.0-beta") == nil)
        #expect(AppVersion("") == nil)
    }

    /// The release link is rebuilt from the parsed number, so a tag that only parses by dropping a zero would link
    /// to a tag that does not exist.
    @Test func refusesLeadingZeros() {
        #expect(AppVersion("v0.04.0") == nil)
        #expect(AppVersion("01.0") == nil)
        #expect(AppVersion("0.0.1")?.description == "0.0.1")
        #expect(AppVersion("10.20.0")?.description == "10.20.0")
    }

    @Test func sendsOneGETWithNoKeyOrCookie() async throws {
        let transport = HealthFakeTransport(HTTPResponse(status: 200, body: body(tag: "v0.4.0")))
        let release = try await fetch(transport)
        #expect(release.version == AppVersion("0.4.0"))
        #expect(release.pageURL == URL(string: "https://github.com/PedroMosquera/tokenjar/releases/tag/v0.4.0"))
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url == URL(string: "https://api.github.com/repos/PedroMosquera/tokenjar/releases/latest"))
        #expect(request.httpMethod == "GET")
        #expect(request.allHTTPHeaderFields == ["User-Agent": "Tokenjar", "Accept": "application/vnd.github+json"])
        #expect(request.timeoutInterval == 10)
    }

    @Test func a403IsANetworkError() async {
        let transport = HealthFakeTransport(HTTPResponse(status: 403, body: Data()))
        await #expect(throws: FetchError.network("HTTP 403")) { try await fetch(transport) }
    }

    @Test func a302IsANetworkError() async {
        let transport = HealthFakeTransport(HTTPResponse(status: 302, body: Data()))
        await #expect(throws: FetchError.network("HTTP 302")) { try await fetch(transport) }
    }

    @Test func aTimeoutIsATimeout() async {
        let transport = HealthFakeTransport(error: URLError(.timedOut))
        await #expect(throws: FetchError.timeout) { try await fetch(transport) }
    }

    private func expectParseError(_ transport: HealthFakeTransport) async {
        do {
            _ = try await fetch(transport)
            Issue.record("expected a parse error")
        } catch let error as FetchError {
            if case .parse = error { return }
            Issue.record("expected .parse, got \(error)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func anUnparseableTagIsAParseError() async {
        await expectParseError(HealthFakeTransport(HTTPResponse(status: 200, body: body(tag: "v1.0.0-beta"))))
    }

    @Test func aBodyWithoutATagIsAParseError() async {
        await expectParseError(HealthFakeTransport(HTTPResponse(status: 200, body: Data("{}".utf8))))
    }
}
