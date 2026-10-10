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
}
