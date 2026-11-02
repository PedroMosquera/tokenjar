import Foundation
import Testing
@testable import TokenjarCore

struct PastedKeyTests {
    let directory = TemporaryDirectory()

    private func key(_ credential: CredentialRef?, stored: [String: String] = [:]) throws -> String {
        let account = AccountConfig(id: "a", provider: .glm, label: "x", credential: credential)
        return try PastedKey.apiKey(for: account, secrets: InMemorySecretStore(stored), paths: AppPaths(home: directory.url))
    }

    @Test func keychainKeyIsTrimmed() throws {
        #expect(try key(.keychain(account: "a"), stored: ["a": " k-1 \n"]) == "k-1")
    }

    @Test func noCredentialIsNotSignedInWithoutAFallback() {
        #expect(throws: FetchError.notSignedIn) { try key(nil) }
    }

    @Test func blankStoredKeyIsNotSignedIn() {
        #expect(throws: FetchError.notSignedIn) { try key(.keychain(account: "a"), stored: ["a": " \n"]) }
    }

    /// Only `--capture` sets a file credential for these providers; Settings never does.
    @Test func fileEntryIsReadForCaptures() throws {
        let file = try directory.write(#"{"glm":{"type":"api","key":"k-file"}}"#, to: "keys.json")
        #expect(try key(.file(path: file.path, key: "glm")) == "k-file")
    }
}
