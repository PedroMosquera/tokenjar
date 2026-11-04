import Foundation
import Testing
@testable import TokenjarCore

struct UpdateCommandTests {
    private let v040 = AppVersion("0.4.0")!
    private let app = "/Users/me/Applications/Tokenjar.app"
    private let folder = "/Users/me/Applications"

    @Test func detectsHomebrewFromItsKeg() {
        #expect(UpdateCommand.method(fileExists: { $0 == "/opt/homebrew/opt/tokenjar/Tokenjar.app" }) == .homebrew(prefix: "/opt/homebrew"))
        #expect(UpdateCommand.method(fileExists: { $0 == "/usr/local/opt/tokenjar/Tokenjar.app" }) == .homebrew(prefix: "/usr/local"))
        #expect(UpdateCommand.method(fileExists: { _ in false }) == .releaseArchive)
    }

    @Test func homebrewUpgradesThenInstallsIntoTheRunningAppsFolder() {
        let line = UpdateCommand.terminal(method: .homebrew(prefix: "/opt/homebrew"), version: v040, appBundle: app, installFolder: folder)
        #expect(line == "/opt/homebrew/bin/brew upgrade tokenjar && /opt/homebrew/bin/tokenjar-install-app /Users/me/Applications")
    }

    /// Contract C-3: the archive path runs the get.sh shipped inside the app, pinned to the version found, and never
    /// fetches a script at update time.
    @Test func releaseArchiveRunsTheBundledScriptPinnedToTheVersion() {
        let line = UpdateCommand.terminal(method: .releaseArchive, version: v040, appBundle: app, installFolder: folder)
        #expect(line == "TOKENJAR_VERSION=0.4.0 /bin/bash /Users/me/Applications/Tokenjar.app/Contents/Resources/get.sh /Users/me/Applications")
        #expect(!line.contains("curl"))
        #expect(!line.contains("raw.githubusercontent.com"))
    }

    @Test func quotesFoldersWithSpacesAndQuotes() {
        let line = UpdateCommand.terminal(
            method: .releaseArchive, version: v040, appBundle: "/Users/o'b/My Apps/Tokenjar.app", installFolder: "/Users/o'b/My Apps"
        )
        #expect(line == "TOKENJAR_VERSION=0.4.0 /bin/bash '/Users/o'\\''b/My Apps/Tokenjar.app/Contents/Resources/get.sh' '/Users/o'\\''b/My Apps'")
    }
}
