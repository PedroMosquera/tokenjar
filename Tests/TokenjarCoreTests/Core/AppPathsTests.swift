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
        #if os(macOS)
        #expect(paths.supportDirectory.path == "/Users/tester/Library/Application Support/Tokenjar")
        #expect(paths.databaseFile.path == "/Users/tester/Library/Application Support/Tokenjar/tokenjar.sqlite")
        #expect(paths.probeDirectory.path == "/Users/tester/Library/Application Support/Tokenjar/probe")
        #elseif os(Linux)
        #expect(paths.supportDirectory.path == "/Users/tester/.local/share/tokenjar")
        #expect(paths.databaseFile.path == "/Users/tester/.local/share/tokenjar/tokenjar.sqlite")
        #expect(paths.probeDirectory.path == "/Users/tester/.local/share/tokenjar/probe")
        #endif
    }

    #if os(Linux)
    @Test func xdgDataHomeHoldsTheSupportFolderOnlyWhenSet() {
        #expect(AppPaths(home: home, environment: ["XDG_DATA_HOME": "/Users/tester/data"]).supportDirectory.path == "/Users/tester/data/tokenjar")
        #expect(AppPaths(home: home, environment: ["XDG_DATA_HOME": ""]).supportDirectory.path == "/Users/tester/.local/share/tokenjar")
    }
    #endif

    #if os(Windows)
    @Test func localAppDataHoldsTheSupportFolder() {
        let paths = AppPaths(home: URL(fileURLWithPath: #"C:\Users\tester"#), environment: ["LOCALAPPDATA": #"D:\Data"#])
        #expect(paths.supportDirectory == URL(fileURLWithPath: #"D:\Data\Tokenjar"#))
        let fallback = AppPaths(home: URL(fileURLWithPath: #"C:\Users\tester"#), environment: [:])
        #expect(fallback.supportDirectory == URL(fileURLWithPath: #"C:\Users\tester\AppData\Local\Tokenjar"#))
    }
    #endif

    @Test func managedSettingsPathFollowsTheSystemRoot() {
        let root = URL(fileURLWithPath: "/private/var/empty/test-root")
        #if os(macOS)
        #expect(AppPaths(home: home, environment: [:]).claudeManagedSettingsFile.path == "/Library/Application Support/ClaudeCode/managed-settings.json")
        #expect(AppPaths(home: home, environment: [:], systemRoot: root).claudeManagedSettingsFile.path == "/private/var/empty/test-root/Library/Application Support/ClaudeCode/managed-settings.json")
        #elseif os(Linux)
        #expect(AppPaths(home: home, environment: [:]).claudeManagedSettingsFile.path == "/etc/claude-code/managed-settings.json")
        #expect(AppPaths(home: home, environment: [:], systemRoot: root).claudeManagedSettingsFile.path == "/private/var/empty/test-root/etc/claude-code/managed-settings.json")
        #else
        #expect(AppPaths(home: home, environment: [:], systemRoot: root).claudeManagedSettingsFile == root.appending(path: "Program Files/ClaudeCode/managed-settings.json"))
        #endif
    }

    @Test func xdgConfigHomeHoldsTheConfigFolderOnlyWhenSet() {
        #expect(AppPaths(home: home, environment: ["XDG_CONFIG_HOME": "/Users/tester/xdg"]).configDirectory.path == "/Users/tester/xdg/tokenjar")
        #expect(AppPaths(home: home, environment: ["XDG_CONFIG_HOME": ""]).configDirectory.path == "/Users/tester/.config/tokenjar")
    }
}
