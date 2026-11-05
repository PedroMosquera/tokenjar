import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private nonisolated final class FakeUpdateRunner: UpdateRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var builds: [UpdateStep] = []
    private var installs: [UpdateStep] = []
    private var exit: (@Sendable (Int32) -> Void)?
    private var logAtBuild: String?
    let buildStatus: Int32
    let installThrows: Bool
    /// Read while the install starts, to see what was stored before it.
    let onInstall: @Sendable () -> Void

    init(buildStatus: Int32 = 0, installThrows: Bool = false, onInstall: @escaping @Sendable () -> Void = {}) {
        self.buildStatus = buildStatus
        self.installThrows = installThrows
        self.onInstall = onInstall
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
        keg: AppVersion? = nil, writable: Bool = true, defaults: MemoryDefaults = MemoryDefaults()
    ) throws -> Rig {
        let home = try ModelHome()
        let updater = Updater(
            defaults: defaults, installed: installed, appBundle: home.url.appending(path: "Applications/Tokenjar.app").path,
            paths: home.paths, temporaryDirectory: nil,
            fileExists: { homebrew && $0 == "/opt/homebrew/opt/tokenjar/Tokenjar.app" }, folderWritable: { _ in writable },
            kegVersion: { _ in keg }, runner: runner, toolsInstalled: { true }
        )
        return Rig(updater: updater, runner: runner, defaults: defaults, home: home)
    }

    private func swappingTo(_ defaults: MemoryDefaults) -> String? { defaults.object(forKey: Updater.swappingToKey) as? String }

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
}
