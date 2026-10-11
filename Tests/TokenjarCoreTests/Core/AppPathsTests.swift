import Foundation
import Testing
@testable import TokenjarCore

/// Literals, so a rename of the folders or the bundle id fails here and docs/privacy.md is updated with it.
struct AppPathsTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test func identityIsTokenjars() {
        #expect(AppPaths.bundleIdentifier == "com.pedromosquera.tokenjar")
        #expect(AppPaths.keychainService == "com.pedromosquera.tokenjar.apikeys")
    }

    @Test func foldersAreTokenjars() {
        let paths = AppPaths(home: home, environment: [:])
        #expect(paths.configDirectory.path == "/Users/tester/.config/tokenjar")
        #expect(paths.configFile.path == "/Users/tester/.config/tokenjar/config.json")
        #expect(paths.supportDirectory.path == "/Users/tester/Library/Application Support/Tokenjar")
        #expect(paths.databaseFile.path == "/Users/tester/Library/Application Support/Tokenjar/tokenjar.sqlite")
        #expect(paths.probeDirectory.path == "/Users/tester/Library/Application Support/Tokenjar/probe")
    }

    @Test func xdgConfigHomeHoldsTheConfigFolderOnlyWhenSet() {
        #expect(AppPaths(home: home, environment: ["XDG_CONFIG_HOME": "/Users/tester/xdg"]).configDirectory.path == "/Users/tester/xdg/tokenjar")
        #expect(AppPaths(home: home, environment: ["XDG_CONFIG_HOME": ""]).configDirectory.path == "/Users/tester/.config/tokenjar")
    }
}
