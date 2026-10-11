import Foundation
import Testing
@testable import TokenjarCore

struct CLILocatorTests {
    /// docs/privacy.md lists this environment. Provider keys and config dirs in the app's own environment must not
    /// reach a CLI, or it could report another login's limits.
    @Test func baseEnvironmentPassesOnlyTheListedVariables() {
        let home = URL(fileURLWithPath: "/Users/placeholder")
        let locator = CLILocator(home: home)
        let inherited = [
            "HOME": "/elsewhere", "USER": "u", "LANG": "en_US.UTF-8", "PATH": "/evil",
            "ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "x", "CLAUDE_CONFIG_DIR": "/x", "CODEX_HOME": "/y", "CLAUDECODE": "1",
        ]

        let env = locator.baseEnvironment(inherited: inherited)

        #expect(Set(env.keys) == ["HOME", "USER", "LANG", "PATH", "NO_COLOR"])
        #expect(env["HOME"] == home.path)
        #expect(env["USER"] == "u")
        #expect(env["PATH"] == (locator.searchDirectories.map(\.path) + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"))
        #expect(env["NO_COLOR"] == "1")
    }
}
