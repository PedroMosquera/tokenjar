import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private nonisolated final class Asks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    private var outcome: Result<ReleaseInfo, FetchError>

    init(_ outcome: Result<ReleaseInfo, FetchError>) { self.outcome = outcome }

    var total: Int { lock.withLock { asked } }

    func answer(_ next: Result<ReleaseInfo, FetchError>) { lock.withLock { outcome = next } }

    func fetch() async throws -> ReleaseInfo {
        try lock.withLock { () -> Result<ReleaseInfo, FetchError> in
            asked += 1
            return outcome
        }.get()
    }
}

@MainActor
struct UpdateCheckerTests {
    private let v030 = AppVersion("0.3.0")!
    private let v040 = AppVersion("0.4.0")!

    private func release(_ version: AppVersion) -> ReleaseInfo { UpdateFetcher.releaseInfo(for: version)! }

    private func make(
        _ outcome: Result<ReleaseInfo, FetchError>, installed: AppVersion? = AppVersion("0.3.0"),
        defaults: MemoryDefaults = MemoryDefaults(), clock: TestClock = TestClock()
    ) -> (checker: UpdateChecker, asks: Asks, defaults: MemoryDefaults, clock: TestClock) {
        let asks = Asks(outcome)
        let checker = UpdateChecker(defaults: defaults, installed: installed, clock: { clock.now }, fetch: { try await asks.fetch() })
        return (checker, asks, defaults, clock)
    }

    @Test func defaultsToManualAndNeverFetchesOnItsOwn() {
        let rig = make(.success(release(v040)))
        #expect(rig.checker.mode == .manual)
        #expect(rig.checker.checkIfDue(holdsChecks: false) == nil)
        #expect(rig.asks.total == 0)
    }

    @Test func automaticFetchesOnceADay() async {
        let rig = make(.success(release(v030)))
        rig.checker.mode = .automatic
        await rig.checker.checkIfDue(holdsChecks: false)?.value
        #expect(rig.asks.total == 1)
        rig.clock.advance(3600)
        #expect(rig.checker.checkIfDue(holdsChecks: false) == nil)
        rig.clock.advance(23 * 3600)
        await rig.checker.checkIfDue(holdsChecks: false)?.value
        #expect(rig.asks.total == 2)
    }

    @Test func automaticHoldsWhileOffline() {
        let rig = make(.success(release(v040)))
        rig.checker.mode = .automatic
        #expect(rig.checker.checkIfDue(holdsChecks: true) == nil)
        #expect(rig.asks.total == 0)
    }

    @Test func notifiesANewVersionOnceAcrossRelaunch() async {
        let rig = make(.success(release(v040)))
        var notified: [(AppVersion, AppVersion)] = []
        rig.checker.mode = .automatic
        rig.checker.onNewVersion = { notified.append(($0, $1)) }
        await rig.checker.checkIfDue(holdsChecks: false)?.value
        #expect(notified.count == 1)
        #expect(notified.first?.0 == v030 && notified.first?.1 == v040)

        rig.clock.advance(25 * 3600)
        let second = make(.success(release(v040)), defaults: rig.defaults, clock: rig.clock)
        var again = 0
        second.checker.onNewVersion = { _, _ in again += 1 }
        await second.checker.checkIfDue(holdsChecks: false)?.value
        #expect(second.asks.total == 1)
        #expect(again == 0)
    }

    @Test func checkNowRunsOnManualAndNeverNotifies() async {
        let rig = make(.success(release(v040)))
        var notified = 0
        rig.checker.onNewVersion = { _, _ in notified += 1 }
        await rig.checker.checkNow()?.value
        #expect(rig.checker.status == .available(release(v040)))
        #expect(notified == 0)
    }

    @Test func aFailedCheckIsSilent() async {
        let rig = make(.failure(.network("HTTP 403")))
        var notified = 0
        rig.checker.onNewVersion = { _, _ in notified += 1 }
        let started = rig.clock.now
        await rig.checker.checkNow()?.value
        #expect(rig.checker.status == .failed(at: started))
        #expect(notified == 0)
    }

    @Test func aFailedCheckKeepsAKnownUpdateVisible() async {
        let rig = make(.success(release(v040)))
        await rig.checker.checkNow()?.value
        rig.asks.answer(.failure(.network("HTTP 403")))
        await rig.checker.checkNow()?.value
        #expect(rig.checker.status == .available(release(v040)))
    }

    @Test func aFailedCheckKeepsAStoredUpdateVisible() async {
        let defaults = MemoryDefaults()
        defaults.set("0.4.0", forKey: "updateLatestVersion")
        let rig = make(.failure(.timeout), defaults: defaults)
        await rig.checker.checkNow()?.value
        #expect(rig.checker.status == .available(release(v040)))
    }

    @Test func aCheckNowThatFoundTheVersionSilencesALaterAutomaticCheck() async {
        let rig = make(.success(release(v040)))
        var notified = 0
        rig.checker.onNewVersion = { _, _ in notified += 1 }
        await rig.checker.checkNow()?.value
        rig.checker.mode = .automatic
        rig.clock.advance(25 * 3600)
        await rig.checker.checkIfDue(holdsChecks: false)?.value
        #expect(rig.asks.total == 2)
        #expect(notified == 0)
    }

    @Test func aFailedAutomaticCheckWaitsADay() async {
        let rig = make(.failure(.timeout))
        rig.checker.mode = .automatic
        await rig.checker.checkIfDue(holdsChecks: false)?.value
        rig.clock.advance(3600)
        #expect(rig.checker.checkIfDue(holdsChecks: false) == nil)
        #expect(rig.asks.total == 1)
    }

    @Test func upToDateRecordsWhenTheCheckStarted() async {
        let rig = make(.success(release(v030)))
        let started = rig.clock.now
        await rig.checker.checkNow()?.value
        #expect(rig.checker.status == .upToDate(checkedAt: started))
    }

    @Test func noInstalledVersionMeansNoCheck() {
        let rig = make(.success(release(v040)), installed: nil)
        rig.checker.mode = .automatic
        #expect(!rig.checker.canCheck)
        #expect(rig.checker.checkNow() == nil)
        #expect(rig.checker.checkIfDue(holdsChecks: false) == nil)
        #expect(rig.asks.total == 0)
    }

    @Test func oneCheckInFlightAtATime() async {
        let rig = make(.success(release(v040)))
        let first = rig.checker.checkNow()
        #expect(rig.checker.status == .checking)
        #expect(rig.checker.checkNow() == nil)
        await first?.value
        #expect(rig.asks.total == 1)
    }

    @Test func aKnownNewerVersionShowsAfterRelaunch() {
        let defaults = MemoryDefaults()
        defaults.set("0.4.0", forKey: "updateLatestVersion")
        let rig = make(.success(release(v040)), defaults: defaults)
        #expect(rig.checker.status == .available(release(v040)))
        #expect(rig.asks.total == 0)
    }

    @Test func aStoredVersionThatIsNoLongerNewerReadsUnknown() {
        let defaults = MemoryDefaults()
        defaults.set("0.3.0", forKey: "updateLatestVersion")
        let rig = make(.success(release(v040)), defaults: defaults)
        #expect(rig.checker.status == .unknown)
    }

    @Test func switchingModesPersists() {
        let rig = make(.success(release(v040)))
        rig.checker.mode = .automatic
        let second = make(.success(release(v040)), defaults: rig.defaults)
        #expect(second.checker.mode == .automatic)
    }
}
