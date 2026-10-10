import Foundation
import Testing
@testable import HeadroomCore

struct HTTPClientTests {
    /// Pins the privacy promise in docs/privacy.md. Changing it must be a deliberate, reviewed edit.
    @Test func allowlistIsExactlyOpenCode() {
        #expect(HTTPClient.allowedHosts == ["opencode.ai"])
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
