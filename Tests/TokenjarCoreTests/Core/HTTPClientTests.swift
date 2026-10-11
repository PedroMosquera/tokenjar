import Foundation
import Testing
@testable import TokenjarCore

struct HTTPClientTests {
    /// Pins the privacy promise in docs/privacy.md. Changing it must be a deliberate, reviewed edit.
    @Test func allowlistIsExactlyOpenCode() {
        #expect(HTTPClient.allowedHosts == ["opencode.ai"])
        #expect(HTTPClient.allowedEndpoints == ["opencode.ai": ["/zen/go/v1/usage"]])
    }

    @Test func rejectsOtherHostsAndPlainHTTP() {
        #expect(throws: HTTPClientError.hostNotAllowed("api.anthropic.com")) {
            try HTTPClient.validate(URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        }
        #expect(throws: HTTPClientError.hostNotAllowed("opencode.ai.evil.example")) {
            try HTTPClient.validate(URL(string: "https://opencode.ai.evil.example/zen/go/v1/usage")!)
        }
        #expect(throws: HTTPClientError.insecureScheme) {
            try HTTPClient.validate(URL(string: "http://opencode.ai/zen/go/v1/usage")!)
        }
        #expect(throws: Never.self) {
            try HTTPClient.validate(URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        }
    }

    /// The Bearer key goes with every request, so a host match alone is not enough: any other path, port or query on
    /// opencode.ai is refused too.
    @Test(arguments: [
        "https://opencode.ai:8443/zen/go/v1/usage",
        "https://opencode.ai/zen/go/v1/other",
        "https://opencode.ai/zen/go/v1/usage/",
        "https://opencode.ai/zen/go/v1/usage?workspace=x",
        "https://opencode.ai/zen/go/v1/usage#x",
        "https://someone@opencode.ai/zen/go/v1/usage",
        "https://opencode.ai/",
    ])
    func onlyTheGoUsageEndpointIsAllowedOnTheHost(url: String) {
        #expect(throws: HTTPClientError.self) { try HTTPClient.validate(URL(string: url)!) }
    }

    @Test func theDefaultPortIsTheSameEndpoint() {
        #expect(throws: Never.self) { try HTTPClient.validate(URL(string: "https://opencode.ai:443/zen/go/v1/usage")!) }
    }

    @Test func getRejectsDisallowedURLsBeforeTheTransport() async {
        let transport = OpenCodeFakeTransport(HTTPResponse(status: 200, body: Data()))
        let client = HTTPClient(transport: transport)
        await #expect(throws: HTTPClientError.hostNotAllowed("api.anthropic.com")) { try await client.get(URL(string: "https://api.anthropic.com/x")!) }
        await #expect(throws: HTTPClientError.insecureScheme) { try await client.get(URL(string: "http://opencode.ai/zen/go/v1/usage")!) }
        #expect(transport.requests.isEmpty)
    }

    /// Checked again below `HTTPClient`, so a transport used directly cannot reach another host either. Port 9 on the
    /// loopback address never leaves the machine if the check is missing.
    @Test func transportRejectsDisallowedHostsWithoutConnecting() async {
        await #expect(throws: HTTPClientError.hostNotAllowed("127.0.0.1")) {
            try await URLSessionTransport().send(URLRequest(url: URL(string: "https://127.0.0.1:9/")!))
        }
    }

    /// A URLSession keeps its delegate alive until invalidated, so a transport per refresh would leak one session and
    /// its connection pool every time.
    @Test func clientsShareOneDefaultTransport() {
        #expect(HTTPClient().transport as AnyObject === HTTPClient().transport as AnyObject)
    }

    @Test func subdomainsAreNotAllowed() {
        #expect(throws: HTTPClientError.hostNotAllowed("api.opencode.ai")) {
            try HTTPClient.validate(URL(string: "https://api.opencode.ai/zen/go/v1/usage")!)
        }
    }

    @Test func transportRefusesAnythingButGET() async {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.httpMethod = "POST"
        await #expect(throws: HTTPClientError.methodNotAllowed("POST")) {
            try await URLSessionTransport().send(request)
        }
    }

    /// A redirect could carry the Authorization header to another host, so the delegate must cancel every one.
    @Test func transportNeverFollowsRedirects() async {
        let transport = URLSessionTransport()
        let task = URLSession.shared.dataTask(with: URL(string: "https://opencode.ai/")!)
        let response = HTTPURLResponse(url: URL(string: "https://opencode.ai/")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.com/"])!
        let followed = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            transport.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://example.com/")!)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil)
    }
}
