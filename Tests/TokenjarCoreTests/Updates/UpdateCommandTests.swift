import Foundation
import Testing
@testable import TokenjarCore

struct UpdateCommandTests {
    private let v040 = AppVersion("0.4.0")!
    private let home = "/Users/me"
    private let app = "/Users/me/Applications/Tokenjar.app"

    @Test func detectsHomebrewFromItsKeg() {
        #expect(UpdateCommand.method(fileExists: { $0 == "/opt/homebrew/opt/tokenjar/Tokenjar.app" }) == .homebrew(prefix: "/opt/homebrew"))
        #expect(UpdateCommand.method(fileExists: { $0 == "/usr/local/opt/tokenjar/Tokenjar.app" }) == .homebrew(prefix: "/usr/local"))
        #expect(UpdateCommand.method(fileExists: { _ in false }) == .releaseArchive)
    }

    @Test func installsIntoTheFolderOfTheRunningApp() {
        #expect(UpdateCommand.installFolder(appBundle: app, home: home) == "/Users/me/Applications")
        #expect(UpdateCommand.installFolder(appBundle: "/Applications/Tokenjar.app", home: home) == "/Applications")
    }

    @Test func aCopyRunningFromHomebrewInstallsIntoApplicationsInstead() {
        for bundle in ["/opt/homebrew/Cellar/tokenjar/0.3.0/Tokenjar.app", "/usr/local/opt/tokenjar/Tokenjar.app"] {
            #expect(UpdateCommand.installFolder(appBundle: bundle, home: home) == "/Users/me/Applications")
        }
    }

    @Test func homebrewUpgradesThenInstallsIntoTheRunningAppsFolder() {
        let line = UpdateCommand.terminal(method: .homebrew(prefix: "/opt/homebrew"), version: v040, appBundle: app, home: home)
        #expect(line == "/opt/homebrew/bin/brew upgrade tokenjar && /opt/homebrew/bin/tokenjar-install-app /Users/me/Applications")
    }

    @Test func theHomebrewLineForACellarCopyInstallsIntoApplications() {
        let line = UpdateCommand.terminal(
            method: .homebrew(prefix: "/opt/homebrew"), version: v040, appBundle: "/opt/homebrew/Cellar/tokenjar/0.3.0/Tokenjar.app", home: home
        )
        #expect(line == "/opt/homebrew/bin/brew upgrade tokenjar && /opt/homebrew/bin/tokenjar-install-app /Users/me/Applications")
    }

    @Test func releaseArchiveRunsTheBundledScriptPinnedToTheVersion() {
        let line = UpdateCommand.terminal(method: .releaseArchive, version: v040, appBundle: app, home: home)
        #expect(line == "TOKENJAR_VERSION=0.4.0 /bin/bash /Users/me/Applications/Tokenjar.app/Contents/Resources/get.sh /Users/me/Applications")
        #expect(!line.contains("curl"))
        #expect(!line.contains("raw.githubusercontent.com"))
    }

    @Test func quotesFoldersWithSpacesAndQuotes() {
        let line = UpdateCommand.terminal(method: .releaseArchive, version: v040, appBundle: "/Users/o'b/My Apps/Tokenjar.app", home: "/Users/o'b")
        #expect(line == "TOKENJAR_VERSION=0.4.0 /bin/bash '/Users/o'\\''b/My Apps/Tokenjar.app/Contents/Resources/get.sh' '/Users/o'\\''b/My Apps'")
    }
}
