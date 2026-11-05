import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

nonisolated final class FakeUpdateRunner: UpdateRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var builds: [UpdateStep] = []
    private var installs: [UpdateStep] = []
    private var exit: (@Sendable (Int32) -> Void)?
    private var logAtBuild: String?
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    let buildStatus: Int32
    let installThrows: Bool
    /// A held build ends only at `releaseBuild()`, so a test can act while it runs.
    let holdsBuild: Bool
    /// Read while the install starts, to see what was stored before it.
    let onInstall: @Sendable () -> Void

    init(
        buildStatus: Int32 = 0, installThrows: Bool = false, holdsBuild: Bool = false,
        onInstall: @escaping @Sendable () -> Void = {}
    ) {
        self.buildStatus = buildStatus
        self.installThrows = installThrows
        self.holdsBuild = holdsBuild
        self.onInstall = onInstall
    }

    func releaseBuild() {
        let waiting = lock.withLock {
            released = true
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }

    var built: [UpdateStep] { lock.withLock { builds } }
    var installed: [UpdateStep] { lock.withLock { installs } }
    var logSeenByBuild: String? { lock.withLock { logAtBuild } }

    func build(_ step: UpdateStep, log: URL) async -> Int32 {
        let text = try? String(contentsOf: log, encoding: .utf8)
        lock.withLock {
            builds.append(step)
            logAtBuild = text
        }
        if holdsBuild {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if released { return true }
                    held = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return buildStatus
    }

    func install(_ step: UpdateStep, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws {
        onInstall()
        lock.withLock { installs.append(step) }
        if installThrows { throw CocoaError(.fileNoSuchFile) }
        lock.withLock { exit = onExit }
    }

    func endInstall(_ status: Int32) { lock.withLock { exit }?(status) }
}

private nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

@MainActor
struct UpdaterTests {
    private let v030 = AppVersion("0.3.0")!
    private let v040 = AppVersion("0.4.0")!

    private struct Rig {
        let updater: Updater
        let runner: FakeUpdateRunner
        let defaults: MemoryDefaults
        let home: ModelHome
    }

    private func make(
        runner: FakeUpdateRunner = FakeUpdateRunner(), installed: AppVersion? = AppVersion("0.3.0"), homebrew: Bool = false,
        keg: AppVersion? = nil, writable: Bool = true, defaults: MemoryDefaults = MemoryDefaults(), autoInstall: Bool = false,
        folderWritable: ((String) -> Bool)? = nil, swift: String? = "Apple Swift version 6.3.2"
    ) throws -> Rig {
        if autoInstall { defaults.set(true, forKey: Updater.autoInstallKey) }
        let home = try ModelHome()
        let updater = Updater(
            defaults: defaults, installed: installed, appBundle: home.url.appending(path: "Applications/Tokenjar.app").path,
            paths: home.paths, temporaryDirectory: nil,
            fileExists: { homebrew && $0 == "/opt/homebrew/opt/tokenjar/Tokenjar.app" }, folderWritable: folderWritable ?? { _ in writable },
            kegVersion: { _ in keg }, runner: runner, toolsInstalled: { true }, swiftVersion: { swift }, userName: "jdoe"
        )
        return Rig(updater: updater, runner: runner, defaults: defaults, home: home)
    }

    private func swappingTo(_ defaults: MemoryDefaults) -> String? { defaults.object(forKey: Updater.swappingToKey) as? String }
    private func tried(_ defaults: MemoryDefaults) -> [String]? { defaults.object(forKey: Updater.autoInstallTriedKey) as? [String] }

    @Test func aFailedBuildNeverStartsTheSwap() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1))
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        #expect(rig.updater.progress == .failed(v040, .build))
        #expect(rig.runner.installed.isEmpty)
        #expect(swappingTo(rig.defaults) == nil)
    }

    @Test func aBuiltVersionIsRecordedBeforeTheSwapStarts() async throws {
        let defaults = MemoryDefaults()
        let seen = Locked<String?>(nil)
        // The updater starts the install from the main actor.
        let runner = FakeUpdateRunner(onInstall: {
            MainActor.assumeIsolated { seen.set(defaults.object(forKey: Updater.swappingToKey) as? String) }
        })
        let rig = try make(runner: runner, defaults: defaults)
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        #expect(seen.value == "0.4.0")
        #expect(rig.updater.progress == .installing(v040))
        #expect(rig.runner.built.map(\.executable) == ["/bin/bash"])
        #expect(rig.runner.installed.first?.arguments.last == rig.home.url.appending(path: "Applications").path)
    }

    @Test func eachAttemptStartsWithAnEmptyLogAndStage() async throws {
        let rig = try make()
        defer { rig.home.remove() }
        let stale = rig.home.paths.updateStageDirectory.appending(path: "Tokenjar.app")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("old attempt\n".utf8).write(to: rig.home.paths.updateLogFile)
        await rig.updater.start(v040)?.value
        #expect(rig.runner.logSeenByBuild == "")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func homebrewThatHasNotSeenTheReleaseFailsWithoutSwapping() async throws {
        let rig = try make(homebrew: true, keg: AppVersion("0.3.0"))
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        #expect(rig.runner.built.first?.arguments == ["upgrade", "tokenjar"])
        #expect(rig.updater.progress == .failed(v040, .homebrewBehind))
        #expect(rig.runner.installed.isEmpty)
        #expect(swappingTo(rig.defaults) == nil)
    }

    @Test func homebrewWithTheReleaseSwapsWithItsInstaller() async throws {
        let rig = try make(homebrew: true, keg: v040)
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        #expect(rig.runner.installed.map(\.executable) == ["/opt/homebrew/bin/tokenjar-install-app"])
        #expect(rig.updater.progress == .installing(v040))
    }

    @Test func aSwapThatEndsWhileTheAppRunsIsAFailure() async throws {
        let rig = try make()
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        rig.runner.endInstall(1)
        try await waitUntil { rig.updater.progress != .installing(v040) }
        #expect(rig.updater.progress == .failed(v040, .install))
        #expect(swappingTo(rig.defaults) == nil)
    }

    @Test func aSwapThatSucceedsWithoutQuittingTheAppQuitsIt() async throws {
        let rig = try make()
        defer { rig.home.remove() }
        var quits = 0
        rig.updater.quit = { quits += 1 }
        await rig.updater.start(v040)?.value
        rig.runner.endInstall(0)
        try await waitUntil { quits > 0 }
        #expect(quits == 1)
        #expect(rig.updater.progress == .installing(v040))
    }

    @Test func aSwapThatCannotStartIsAFailure() async throws {
        let rig = try make(runner: FakeUpdateRunner(installThrows: true))
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        #expect(rig.updater.progress == .failed(v040, .install))
        #expect(swappingTo(rig.defaults) == nil)
    }

    @Test func anUnwritableFolderCannotStart() async throws {
        let rig = try make(writable: false)
        defer { rig.home.remove() }
        #expect(rig.updater.start(v040) == nil)
        #expect(rig.runner.built.isEmpty)
        #expect(rig.updater.progress == .idle)
    }

    @Test func aVersionNoNewerThanTheInstalledOneDoesNotStart() async throws {
        let rig = try make(installed: v040)
        defer { rig.home.remove() }
        #expect(rig.updater.start(v040) == nil)
        #expect(rig.updater.start(v030) == nil)
        #expect(rig.runner.built.isEmpty)
    }

    @Test func aSecondStartWhileBuildingIsIgnored() async throws {
        let rig = try make()
        defer { rig.home.remove() }
        let first = rig.updater.start(v040)
        #expect(rig.updater.start(v040) == nil)
        await first?.value
        #expect(rig.runner.built.count == 1)
    }

    @Test func theLaunchAfterASwapReportsTheUpdateOnce() throws {
        let defaults = MemoryDefaults()
        defaults.set("0.4.0", forKey: Updater.swappingToKey)
        let rig = try make(installed: v040, defaults: defaults)
        defer { rig.home.remove() }
        try FileManager.default.createDirectory(at: rig.home.paths.updateStageDirectory, withIntermediateDirectories: true)
        var updated: [AppVersion] = []
        rig.updater.onUpdated = { updated.append($0) }
        rig.updater.finishPendingSwap()
        rig.updater.finishPendingSwap()
        #expect(updated == [v040])
        #expect(swappingTo(defaults) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.home.paths.updateStageDirectory.path))
        #expect(rig.updater.progress == .idle)
    }

    @Test func theLaunchAfterAFailedSwapShowsTheFailure() throws {
        let defaults = MemoryDefaults()
        defaults.set("0.4.0", forKey: Updater.swappingToKey)
        let rig = try make(installed: v030, defaults: defaults)
        defer { rig.home.remove() }
        var updated: [AppVersion] = []
        rig.updater.onUpdated = { updated.append($0) }
        rig.updater.finishPendingSwap()
        #expect(updated.isEmpty)
        #expect(rig.updater.progress == .failed(v040, .install))
        #expect(swappingTo(defaults) == nil)
    }

    // MARK: Install updates automatically

    @Test func nothingInstallsByItselfUntilTheBoxIsTicked() async throws {
        let rig = try make()
        defer { rig.home.remove() }
        #expect(rig.updater.autoInstall == false)
        #expect(rig.defaults.object(forKey: Updater.autoInstallKey) == nil)
        #expect(rig.updater.found(v040) == nil)
        #expect(rig.runner.built.isEmpty)
        #expect(tried(rig.defaults) == nil)
        #expect(rig.updater.progress == .idle)
    }

    @Test func theBoxIsKeptInThisMacsPreferences() throws {
        let rig = try make()
        defer { rig.home.remove() }
        rig.updater.autoInstall = true
        #expect(rig.defaults.object(forKey: Updater.autoInstallKey) as? Bool == true)
        let again = try make(defaults: rig.defaults)
        defer { again.home.remove() }
        #expect(again.updater.autoInstall)
    }

    @Test func aFoundVersionBuildsAndWaitsUntilNoWindowIsOpen() async throws {
        let rig = try make(autoInstall: true)
        defer { rig.home.remove() }
        let build = rig.updater.found(v040)
        #expect(tried(rig.defaults) == ["0.4.0"])
        #expect(rig.updater.progress == .building(v040, waitsForIdle: true))
        await build?.value
        #expect(rig.updater.progress == .ready(v040))
        #expect(rig.runner.installed.isEmpty)
        #expect(swappingTo(rig.defaults) == nil)

        #expect(rig.updater.installIfIdle(windowOpen: true, automatic: true) == false)
        #expect(rig.runner.installed.isEmpty)
        #expect(rig.updater.installIfIdle(windowOpen: false, automatic: true))
        #expect(rig.runner.installed.count == 1)
        #expect(swappingTo(rig.defaults) == "0.4.0")
        #expect(rig.updater.progress == .installing(v040))
    }

    @Test func aBuiltVersionWaitsForAClickOnceSilentInstallsAreOff() async throws {
        let rig = try make(autoInstall: true)
        defer { rig.home.remove() }
        await rig.updater.found(v040)?.value
        #expect(rig.updater.installIfIdle(windowOpen: false, automatic: false) == false)
        rig.updater.autoInstall = false
        #expect(rig.updater.installIfIdle(windowOpen: false, automatic: true) == false)
        #expect(rig.runner.installed.isEmpty)

        // Update Now installs what was built, without building it again.
        await rig.updater.start(v040)?.value
        #expect(rig.runner.built.count == 1)
        #expect(rig.runner.installed.count == 1)
        #expect(rig.updater.progress == .installing(v040))
    }

    @Test func eachVersionIsTriedByItselfOnce() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1), autoInstall: true)
        defer { rig.home.remove() }
        await rig.updater.found(v040)?.value
        #expect(rig.updater.found(v040) == nil)
        #expect(rig.runner.built.count == 1)
        // Update Now stays available.
        await rig.updater.start(v040)?.value
        #expect(rig.runner.built.count == 2)
    }

    @Test func anInterruptedSilentAttemptCountsAsTried() async throws {
        let defaults = MemoryDefaults()
        let first = try make(runner: FakeUpdateRunner(holdsBuild: true), defaults: defaults, autoInstall: true)
        defer { first.home.remove() }
        _ = first.updater.found(v040)
        // Tokenjar quits mid-build; the next launch finds the same version.
        let next = try make(defaults: defaults, autoInstall: true)
        defer { next.home.remove() }
        #expect(next.updater.found(v040) == nil)
        #expect(next.runner.built.isEmpty)
        first.runner.releaseBuild()
    }

    @Test func aFailedSilentAttemptNotifiesOncePerVersion() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1), autoInstall: true)
        defer { rig.home.remove() }
        var notices: [AppVersion] = []
        rig.updater.onCouldNotUpdate = { notices.append($0) }
        await rig.updater.found(v040)?.value
        await rig.updater.found(v040)?.value
        #expect(notices == [v040])
        #expect(rig.updater.progress == .failed(v040, .build))
    }

    @Test func aSilentSwapThatFailsWhileTheAppRunsNotifies() async throws {
        let rig = try make(autoInstall: true)
        defer { rig.home.remove() }
        var notices: [AppVersion] = []
        rig.updater.onCouldNotUpdate = { notices.append($0) }
        await rig.updater.found(v040)?.value
        rig.updater.installIfIdle(windowOpen: false, automatic: true)
        rig.runner.endInstall(1)
        try await waitUntil { rig.updater.progress != .installing(v040) }
        #expect(notices == [v040])
        #expect(rig.updater.progress == .failed(v040, .install))
    }

    @Test func aSilentSwapThatFailedIsNotifiedOnTheNextLaunch() throws {
        let defaults = MemoryDefaults()
        defaults.set("0.4.0", forKey: Updater.swappingToKey)
        defaults.set(["0.4.0"], forKey: Updater.autoInstallTriedKey)
        let rig = try make(installed: v030, defaults: defaults)
        defer { rig.home.remove() }
        var notices: [AppVersion] = []
        rig.updater.onCouldNotUpdate = { notices.append($0) }
        rig.updater.finishPendingSwap()
        #expect(notices == [v040])
    }

    @Test func aFailedUpdateNowNeverPostsTheCouldNotUpdateNotice() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1), autoInstall: true)
        defer { rig.home.remove() }
        var notices: [AppVersion] = []
        rig.updater.onCouldNotUpdate = { notices.append($0) }
        await rig.updater.start(v040)?.value
        #expect(rig.updater.progress == .failed(v040, .build))

        let defaults = MemoryDefaults()
        defaults.set("0.4.0", forKey: Updater.swappingToKey)
        let relaunched = try make(installed: v030, defaults: defaults)
        defer { relaunched.home.remove() }
        relaunched.updater.onCouldNotUpdate = { notices.append($0) }
        relaunched.updater.finishPendingSwap()
        #expect(notices.isEmpty)
    }

    @Test func homebrewNotCaughtUpLeavesTheVersionForTheNextCheck() async throws {
        let rig = try make(homebrew: true, keg: v030, autoInstall: true)
        defer { rig.home.remove() }
        var notices: [AppVersion] = []
        rig.updater.onCouldNotUpdate = { notices.append($0) }
        await rig.updater.found(v040)?.value
        #expect(rig.updater.progress == .failed(v040, .homebrewBehind))
        #expect(notices.isEmpty)
        #expect(tried(rig.defaults) == [])
        await rig.updater.found(v040)?.value
        #expect(rig.runner.built.count == 2)
    }

    @Test func updateNowDuringASilentBuildInstallsWithoutWaiting() async throws {
        let rig = try make(runner: FakeUpdateRunner(holdsBuild: true), autoInstall: true)
        defer { rig.home.remove() }
        let build = rig.updater.found(v040)
        #expect(rig.updater.start(v040) == nil)
        #expect(rig.updater.progress == .building(v040, waitsForIdle: false))
        rig.runner.releaseBuild()
        await build?.value
        #expect(rig.runner.built.count == 1)
        #expect(rig.runner.installed.count == 1)
        #expect(rig.updater.progress == .installing(v040))
    }

    @Test func aCopyThatCannotUpdateNeverSpendsItsTry() async throws {
        let rig = try make(writable: false, autoInstall: true)
        defer { rig.home.remove() }
        #expect(rig.updater.found(v040) == nil)
        #expect(tried(rig.defaults) == nil)
        #expect(rig.runner.built.isEmpty)
    }

    @Test func aFoundVersionNoNewerThanTheInstalledOneIsIgnored() async throws {
        let rig = try make(installed: v040, autoInstall: true)
        defer { rig.home.remove() }
        #expect(rig.updater.found(v040) == nil)
        #expect(tried(rig.defaults) == nil)
    }

    @Test func aWithdrawnVersionThatComesBackIsNotTriedAgain() async throws {
        let v050 = AppVersion("0.5.0")!
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1), autoInstall: true)
        defer { rig.home.remove() }
        var notices: [AppVersion] = []
        rig.updater.onCouldNotUpdate = { notices.append($0) }
        await rig.updater.found(v050)?.value
        await rig.updater.found(v040)?.value
        #expect(rig.updater.found(v050) == nil)
        #expect(rig.runner.built.count == 2)
        #expect(notices == [v050, v040])
    }

    @Test func triedVersionsNoNewerThanTheInstalledOneAreDropped() async throws {
        let defaults = MemoryDefaults()
        defaults.set(["0.2.0", "0.3.0"], forKey: Updater.autoInstallTriedKey)
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1), defaults: defaults, autoInstall: true)
        defer { rig.home.remove() }
        await rig.updater.found(v040)?.value
        #expect(tried(defaults) == ["0.4.0"])
    }

    @Test func aCopyBlockedAfterItsBuildNeverSwaps() async throws {
        let writable = Locked(true)
        let rig = try make(autoInstall: true, folderWritable: { _ in writable.value })
        defer { rig.home.remove() }
        await rig.updater.found(v040)?.value
        #expect(rig.updater.progress == .ready(v040))
        writable.set(false)
        #expect(rig.updater.installIfIdle(windowOpen: false, automatic: true) == false)
        #expect(rig.updater.start(v040) == nil)
        #expect(rig.runner.installed.isEmpty)
        #expect(swappingTo(rig.defaults) == nil)
    }

    @Test func homebrewNotCaughtUpGivesBackTheTryEvenAfterUpdateNowWasClicked() async throws {
        let rig = try make(runner: FakeUpdateRunner(holdsBuild: true), homebrew: true, keg: v030, autoInstall: true)
        defer { rig.home.remove() }
        let build = rig.updater.found(v040)
        rig.updater.start(v040)
        rig.runner.releaseBuild()
        await build?.value
        #expect(rig.updater.progress == .failed(v040, .homebrewBehind))
        #expect(tried(rig.defaults) == [])
    }

    // MARK: Report This Problem

    private func fields(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func thereIsNothingToReportWithoutAFailure() async throws {
        let rig = try make()
        defer { rig.home.remove() }
        #expect(await rig.updater.report() == nil)
        await rig.updater.start(v040)?.value
        #expect(rig.updater.progress == .installing(v040))
        #expect(await rig.updater.report() == nil)
    }

    @Test func aReportNamesTheFailedUpdateAndEndsWithTheRedactedLog() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1))
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        let home = rig.home.paths.home.path
        try Data("$ /bin/bash \(home)/Applications/Tokenjar.app/Contents/Resources/get.sh\nerror: jdoe cannot build\n".utf8)
            .write(to: rig.home.paths.updateLogFile)
        let values = fields(await rig.updater.report())
        #expect(values["from"] == "0.3.0")
        #expect(values["to"] == "0.4.0")
        #expect(values["method"] == "Release archive")
        #expect(values["swift"] == "Apple Swift version 6.3.2")
        #expect(values["macos"] == ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(values["log"] == "$ /bin/bash ~/Applications/Tokenjar.app/Contents/Resources/get.sh\nerror: <user> cannot build")
    }

    @Test func aReportEndsWithTheLastLinesOfALongLog() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1))
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        let filler = String(repeating: "f", count: 200)
        let log = (1...5000).map { "\($0) \(filler)" }.joined(separator: "\n") + "\nthe last line\n"
        try Data(log.utf8).write(to: rig.home.paths.updateLogFile)
        let sent = fields(await rig.updater.report())["log"] ?? ""
        #expect(sent.hasSuffix("4999 \(filler)\n5000 \(filler)\nthe last line"))
    }

    @Test func aMissingSwiftVersionSaysSo() async throws {
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1), swift: nil)
        defer { rig.home.remove() }
        await rig.updater.start(v040)?.value
        #expect(fields(await rig.updater.report())["swift"] == "unknown")
    }

    @Test func theAppWiresChecksNoticesAndTheUpdaterTogether() async throws {
        let defaults = MemoryDefaults()
        let rig = try make(runner: FakeUpdateRunner(buildStatus: 1, holdsBuild: true), defaults: defaults, autoInstall: true)
        defer { rig.home.remove() }
        let checker = UpdateChecker(defaults: MemoryDefaults(), installed: v030, fetch: { UpdateFetcher.releaseInfo(for: AppVersion("0.4.0")!)! })
        let notices = FakeNotices()
        AppDelegate.connectUpdates(checker, rig.updater, notices)

        checker.onNewVersion(v030, v040)
        #expect(notices.posted == ["available 0.3.0 0.4.0"])
        checker.onFound(v040)
        #expect(rig.updater.progress == .building(v040, waitsForIdle: true))
        notices.onUpdateNow(v040)
        #expect(rig.updater.progress == .building(v040, waitsForIdle: false))
        rig.runner.releaseBuild()
        try await waitUntil { rig.updater.progress == .failed(v040, .build) }

        let failed = MemoryDefaults()
        failed.set("0.4.0", forKey: Updater.swappingToKey)
        failed.set(["0.4.0"], forKey: Updater.autoInstallTriedKey)
        let relaunched = try make(installed: v030, defaults: failed)
        defer { relaunched.home.remove() }
        AppDelegate.connectUpdates(checker, relaunched.updater, notices)
        relaunched.updater.finishPendingSwap()

        let updated = MemoryDefaults()
        updated.set("0.4.0", forKey: Updater.swappingToKey)
        let current = try make(installed: v040, defaults: updated)
        defer { current.home.remove() }
        AppDelegate.connectUpdates(checker, current.updater, notices)
        current.updater.finishPendingSwap()
        #expect(notices.posted == ["available 0.3.0 0.4.0", "couldn't 0.4.0", "updated 0.4.0"])
    }
}

private final class FakeNotices: UpdateNotifying {
    var onUpdateNow: (AppVersion) -> Void = { _ in }
    private(set) var posted: [String] = []
    func postUpdate(installed: AppVersion, latest: AppVersion) { posted.append("available \(installed) \(latest)") }
    func postUpdated(_ version: AppVersion) { posted.append("updated \(version)") }
    func postCouldNotUpdate(_ version: AppVersion) { posted.append("couldn't \(version)") }
}
