import Foundation
import Testing
@testable import TokenjarCore

struct CLILocatorTests {
    let temp = TemporaryDirectory()

    #if os(Windows)
    /// docs/privacy.md lists this environment. Windows spells some names its own way, such as Path, so the match ignores
    /// case; HOME is left out, since Windows programs find the home folder in USERPROFILE.
    @Test func baseEnvironmentPassesOnlyTheListedVariables() {
        let locator = CLILocator(home: URL(fileURLWithPath: #"C:\Users\placeholder"#), searchDirectories: [URL(fileURLWithPath: #"C:\tools"#)])
        let env = locator.baseEnvironment(inherited: [
            "SystemRoot": #"C:\Windows"#, "appdata": #"C:\Users\placeholder\AppData\Roaming"#, "Path": #"C:\evil"#,
            "HOME": #"C:\elsewhere"#, "ANTHROPIC_API_KEY": "x", "CLAUDE_CONFIG_DIR": #"C:\x"#, "https_proxy": "p",
        ])

        #expect(Set(env.keys) == ["SystemRoot", "APPDATA", "PATH", "NO_COLOR", "HTTPS_PROXY"])
        #expect(env["APPDATA"] == #"C:\Users\placeholder\AppData\Roaming"#)
        #expect(env["PATH"] == #"C:\tools;C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0"#)
    }
    #else
    /// docs/privacy.md lists this environment. Provider keys and config dirs in the app's own environment must not
    /// reach a CLI, or it could report another login's limits.
    @Test func baseEnvironmentPassesOnlyTheListedVariables() {
        let home = URL(fileURLWithPath: "/Users/placeholder")
        let locator = CLILocator(home: home)
        let inherited = [
            "HOME": "/elsewhere", "USER": "u", "LOGNAME": "u", "LANG": "en_US.UTF-8", "TMPDIR": "/tmp/x", "SHELL": "/bin/zsh",
            "PATH": "/evil", "HTTPS_PROXY": "p", "HTTP_PROXY": "p", "NO_PROXY": "p", "https_proxy": "p", "http_proxy": "p", "no_proxy": "p",
            "ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "x", "CLAUDE_CONFIG_DIR": "/x", "CODEX_HOME": "/y", "CLAUDECODE": "1",
        ]

        let env = locator.baseEnvironment(inherited: inherited)

        #expect(Set(env.keys) == [
            "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL", "PATH", "NO_COLOR",
            "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
        ])
        #expect(env["HOME"] == home.path)
        #expect(env["USER"] == "u")
        #expect(env["PATH"] == (locator.searchDirectories.map(\.path) + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"))
        #expect(env["NO_COLOR"] == "1")
    }
    #endif

    /// A CLI behind a proxy connects from Tokenjar as it would from a terminal, and only with the proxy Tokenjar itself
    /// was started with.
    @Test func proxyVariablesPassOnlyWhenSet() {
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/placeholder"))

        let without = locator.baseEnvironment(inherited: ["USER": "u"])
        let with = locator.baseEnvironment(inherited: [
            "HTTPS_PROXY": "http://proxy.example.invalid:8080", "HTTP_PROXY": "http://proxy.example.invalid:8081",
            "NO_PROXY": "localhost,.example.invalid",
        ])

        #expect(without.keys.filter { $0.lowercased().hasSuffix("proxy") }.isEmpty)
        #expect(with["HTTPS_PROXY"] == "http://proxy.example.invalid:8080")
        #expect(with["HTTP_PROXY"] == "http://proxy.example.invalid:8081")
        #expect(with["NO_PROXY"] == "localhost,.example.invalid")
    }

    /// Proxy setups often export only the lowercase spelling, and curl reads `http_proxy` only in lowercase, so each
    /// form passes as it was set, with no case folding. Windows has one variable whatever its case, which every program
    /// there reads whatever case it asks for, so it passes under one name.
    @Test func lowercaseProxyFormsPass() {
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/placeholder"))

        let env = locator.baseEnvironment(inherited: [
            "https_proxy": "http://proxy.example.invalid:8080", "http_proxy": "http://proxy.example.invalid:8081", "no_proxy": "localhost",
        ])

        #if os(Windows)
        #expect(env["HTTPS_PROXY"] == "http://proxy.example.invalid:8080")
        #expect(env["HTTP_PROXY"] == "http://proxy.example.invalid:8081")
        #expect(env["NO_PROXY"] == "localhost")
        #else
        #expect(env["https_proxy"] == "http://proxy.example.invalid:8080")
        #expect(env["http_proxy"] == "http://proxy.example.invalid:8081")
        #expect(env["no_proxy"] == "localhost")
        #endif
    }

    /// Only the HTTP proxy variables were decided. `ALL_PROXY` can route a CLI through a SOCKS proxy and a replaced
    /// certificate store changes which servers it trusts, so each needs its own decision.
    @Test func otherNetworkVariablesStillStayOut() {
        let locator = CLILocator(home: URL(fileURLWithPath: "/Users/placeholder"))
        let others = ["ALL_PROXY", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"]

        let env = locator.baseEnvironment(inherited: Dictionary(uniqueKeysWithValues: others.map { ($0, "x") }))

        for key in others { #expect(env[key] == nil, "\(key)") }
    }

    /// A `cliPaths` entry is how a user picks one install over another found earlier in the search folders.
    @Test func anExistingOverrideStillWins() throws {
        let home = temp.url
        try makeExecutable(home.appending(path: ".local/bin/\(cliFileName("claude"))"))
        try makeExecutable(home.appending(path: "tools/\(cliFileName("claude"))"))

        let locator = CLILocator(
            home: home, overrides: ["claude": home.appending(path: "tools/\(cliFileName("claude"))").path], searchDirectories: [home.appending(path: ".local/bin")]
        )

        #expect(locator.locate("claude")?.path == home.appending(path: "tools/\(cliFileName("claude"))").path)
    }

    /// config.json syncs between Macs, so a `cliPaths` entry set on one Mac can name a path that does not exist here.
    @Test func aMissingOverrideFallsBackToTheSearch() throws {
        let home = temp.url
        let found = home.appending(path: "fake-bin/\(cliFileName("claude"))")
        try makeExecutable(found)

        let locator = CLILocator(
            home: home, overrides: ["claude": home.appending(path: "other-mac/claude").path], searchDirectories: [found.deletingLastPathComponent()]
        )

        #expect(locator.locate("claude")?.path == found.path)
    }

    /// Every test that means "not installed" relies on this: /usr/bin/env exists on every Mac and /usr/bin is a
    /// standard folder, so only an honored list keeps it out.
    @Test func aFakeSearchFolderIsHonored() throws {
        let home = temp.url
        let fake = home.appending(path: "fake-bin")
        try makeExecutable(fake.appending(path: cliFileName("gh")))

        #expect(CLILocator(home: home, searchDirectories: [fake]).locate("gh")?.path == fake.appending(path: cliFileName("gh")).path)
        #expect(CLILocator(home: home, searchDirectories: [fake]).locate("env") == nil)
        #expect(CLILocator(home: home, searchDirectories: []).locate("env") == nil)
    }

    private func makeExecutable(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
}
