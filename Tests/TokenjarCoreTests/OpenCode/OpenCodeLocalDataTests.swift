import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import TokenjarCore

struct OpenCodeLocalDataTests {
    private let openAIOAuth = #""openai":{"type":"oauth","access":"placeholder-access","refresh":"placeholder-refresh","expires":0}"#

    private func key(_ account: AccountConfig, in dir: TemporaryDirectory, secrets: any SecretStore = InMemorySecretStore()) throws -> String {
        try OpenCodeLocalData.apiKey(for: account, secrets: secrets, paths: AppPaths(home: dir.url), dataDirectory: dir.url)
    }

    private func account(_ credential: CredentialRef?) -> AccountConfig {
        AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: credential)
    }

    @Test func defaultPrefersTheGoEntryOverTheGenericOne() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{"opencode":{"type":"api","key":"sk-generic"},"opencode-go":{"type":"api","key":"sk-go"},\#(openAIOAuth)}"#, to: "auth.json")
        #expect(try key(account(nil), in: dir) == "sk-go")
    }

    @Test func defaultFallsBackToTheGenericEntry() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{\#(openAIOAuth),"opencode":{"type":"api","key":"sk-generic"}}"#, to: "auth.json")
        #expect(try key(account(nil), in: dir) == "sk-generic")
    }

    @Test func oauthEntriesAreNeverUsed() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{\#(openAIOAuth),"opencode-go":{"type":"oauth","access":"placeholder","refresh":"placeholder","expires":0}}"#, to: "auth.json")
        #expect(throws: FetchError.notSignedIn) { try key(account(nil), in: dir) }
        let file = dir.url.appending(path: "auth.json").path
        #expect(throws: FetchError.notSignedIn) { try key(account(.file(path: file, key: "openai")), in: dir) }
    }

    @Test func wellKnownEntryUsesItsToken() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{"opencode-go":{"type":"wellknown","key":"OPENCODE_API_KEY","token":"sk-wellknown"}}"#, to: "auth.json")
        #expect(try key(account(nil), in: dir) == "sk-wellknown")
    }

    @Test func explicitFileAndEntryWinOverTheDefault() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{"opencode-go":{"type":"api","key":"sk-default"}}"#, to: "auth.json")
        let custom = try dir.write(#"{"work":{"type":"api","key":"  sk-work\n"}}"#, to: "other/keys.json")
        #expect(try key(account(.file(path: custom.path, key: "work")), in: dir) == "sk-work")
    }

    @Test func explicitFileThatIsMissingDoesNotFallBack() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{"opencode-go":{"type":"api","key":"sk-default"}}"#, to: "auth.json")
        #expect(throws: FetchError.notSignedIn) {
            try key(account(.file(path: dir.url.appending(path: "missing.json").path, key: "opencode-go")), in: dir)
        }
    }

    @Test func keychainCredentialReadsOnlyTheAppStore() throws {
        let dir = TemporaryDirectory()
        _ = try dir.write(#"{"opencode-go":{"type":"api","key":"sk-default"}}"#, to: "auth.json")
        let secrets = InMemorySecretStore(["work-go": "sk-pasted"])
        #expect(try key(account(.keychain(account: "work-go")), in: dir, secrets: secrets) == "sk-pasted")
        #expect(throws: FetchError.notSignedIn) { try key(account(.keychain(account: "other")), in: dir, secrets: secrets) }
    }

    #if canImport(Security)
    /// Signed out would send the user to paste a key they already have.
    @Test func aRefusedKeychainReadIsDeniedNotSignedOut() throws {
        let dir = TemporaryDirectory()
        let keychain = CountingSecretStore(["go": "sk-pasted"])
        keychain.refuse(with: errSecAuthFailed)
        #expect(throws: FetchError.keychainDenied) { try key(account(.keychain(account: "go")), in: dir, secrets: keychain) }

        keychain.refuse(with: errSecDecode)
        #expect(throws: FetchError.notSignedIn) { try key(account(.keychain(account: "go")), in: dir, secrets: keychain) }
    }
    #endif

    @Test func noAuthFileIsNotSignedIn() throws {
        let dir = TemporaryDirectory()
        #expect(throws: FetchError.notSignedIn) { try key(account(nil), in: dir) }
    }

    @Test func dataDirectoryPrefersProfileDirThenXDGThenHome() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/placeholder"))
        var account = account(nil)
        #expect(OpenCodeLocalData.dataDirectory(for: account, paths: paths, environment: [:]).path == "/Users/placeholder/.local/share/opencode")
        #expect(OpenCodeLocalData.dataDirectory(for: account, paths: paths, environment: ["XDG_DATA_HOME": "/data"]).path == "/data/opencode")
        #expect(OpenCodeLocalData.dataDirectory(for: account, paths: paths, environment: ["XDG_DATA_HOME": "relative"]).path == "/Users/placeholder/.local/share/opencode")
        account.profileDir = "~/oc"
        #expect(OpenCodeLocalData.dataDirectory(for: account, paths: paths, environment: ["XDG_DATA_HOME": "/data"]).path == "/Users/placeholder/oc")
    }
}
