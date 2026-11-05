import Foundation
import Testing
@testable import TokenjarCore

struct UpdatePlanTests {
    private let v040 = AppVersion("0.4.0")!
    private let app = "/Users/me/Applications/Tokenjar.app"
    private let stage = "/Users/me/Library/Application Support/Tokenjar/update"

    private func plan(_ method: UpdateMethod, temporaryDirectory: String? = nil) -> UpdatePlan {
        UpdatePlan.make(method: method, version: v040, appBundle: app, home: "/Users/me", stageDirectory: stage, temporaryDirectory: temporaryDirectory)
    }

    @Test func theArchiveBuildRunsTheBundledScriptPinnedToTheVersionInStageMode() {
        let build = plan(.releaseArchive).build
        #expect(build.executable == "/bin/bash")
        #expect(build.arguments == ["/Users/me/Applications/Tokenjar.app/Contents/Resources/get.sh"])
        #expect(build.environment == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me",
            "TOKENJAR_VERSION": "0.4.0", "TOKENJAR_STAGE_DIR": stage,
        ])
    }

    @Test func theArchiveInstallRunsTheStagedScriptIntoTheRunningAppsFolder() {
        let install = plan(.releaseArchive).install
        #expect(install.executable == "/bin/bash")
        #expect(install.arguments == ["\(stage)/install.sh", "/Users/me/Applications"])
        #expect(install.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me", "TOKENJAR_APP": "\(stage)/Tokenjar.app"])
    }

    @Test func homebrewBuildsWithBrewThenInstallsWithItsOwnInstaller() {
        let homebrew = plan(.homebrew(prefix: "/opt/homebrew"))
        let environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me"]
        #expect(homebrew.build == UpdateStep(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "tokenjar"], environment: environment))
        #expect(homebrew.install == UpdateStep(
            executable: "/opt/homebrew/bin/tokenjar-install-app", arguments: ["/Users/me/Applications"], environment: environment
        ))
    }

    @Test func bothMethodsInstallIntoTheFolderTheAppRunsFrom() {
        for method in [UpdateMethod.releaseArchive, .homebrew(prefix: "/opt/homebrew")] {
            let install = UpdatePlan.make(
                method: method, version: v040, appBundle: "/Users/me/Tools/Tokenjar.app", home: "/Users/me", stageDirectory: stage,
                temporaryDirectory: nil
            ).install
            #expect(install.arguments.last == "/Users/me/Tools")
        }
    }

    @Test func keepsTheAppsTemporaryFolder() {
        let archive = plan(.releaseArchive, temporaryDirectory: "/var/folders/xy/T/")
        #expect(archive.build.environment["TMPDIR"] == "/var/folders/xy/T/")
        #expect(archive.install.environment["TMPDIR"] == "/var/folders/xy/T/")
    }

    @Test func nothingIsFetchedToRun() {
        let archive = plan(.releaseArchive)
        for step in [archive.build, archive.install] {
            let text = ([step.executable] + step.arguments + step.environment.values).joined(separator: " ")
            #expect(!text.contains("curl"))
            #expect(!text.contains("http"))
        }
    }

    @Test func aNormalCopyIsNotBlocked() {
        #expect(UpdateBlocker.check(appBundle: app, folderWritable: { _ in true }, commandLineTools: true) == nil)
        #expect(UpdateBlocker.check(appBundle: app, folderWritable: { _ in true }, commandLineTools: nil) == nil)
    }

    @Test func anUnwritableFolderBlocksUpdateNow() {
        var asked: [String] = []
        let blocker = UpdateBlocker.check(appBundle: app, folderWritable: { asked.append($0); return false }, commandLineTools: true)
        #expect(blocker == .folderNotWritable("/Users/me/Applications"))
        #expect(asked == ["/Users/me/Applications"])
    }

    @Test func missingCommandLineToolsBlockUpdateNow() {
        #expect(UpdateBlocker.check(appBundle: app, folderWritable: { _ in true }, commandLineTools: false) == .noCommandLineTools)
        #expect(UpdateBlocker.noCommandLineTools.message.contains("xcode-select --install"))
    }

    @Test func aCopyInHomebrewsFoldersOrRenamedIsBlocked() {
        for bundle in ["/opt/homebrew/Cellar/tokenjar/0.3.0/Tokenjar.app", "/usr/local/opt/tokenjar/Tokenjar.app"] {
            #expect(UpdateBlocker.check(appBundle: bundle, folderWritable: { _ in true }, commandLineTools: true) == .runsFromHomebrew)
        }
        let renamed = UpdateBlocker.check(appBundle: "/Applications/Tokenjar 2.app", folderWritable: { _ in true }, commandLineTools: true)
        #expect(renamed == .renamed("Tokenjar 2.app"))
    }

    @Test func aSwapIsJudgedByTheVersionNowRunning() {
        let v030 = AppVersion("0.3.0")!, v050 = AppVersion("0.5.0")!
        #expect(SwapOutcome.after(swappingTo: v040, installed: v040) == .updated(v040))
        #expect(SwapOutcome.after(swappingTo: v040, installed: v030) == .failed(v040))
        #expect(SwapOutcome.after(swappingTo: v040, installed: v050) == nil)
        #expect(SwapOutcome.after(swappingTo: nil, installed: v030) == nil)
        #expect(SwapOutcome.after(swappingTo: v040, installed: nil) == nil)
    }
}
