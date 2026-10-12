import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

// Paths come from `networkPathChanged` or a FakeNetworkStatus: nothing here reads or changes the Mac's network.

/// What each fake fetch returns, changed by the test between checks; a live answer unless set.
private nonisolated final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: Result<UsageSnapshot, FetchError>] = [:]

    subscript(id: String) -> Result<UsageSnapshot, FetchError>? {
        get { lock.withLock { byID[id] } }
        set { lock.withLock { byID[id] = newValue } }
    }
}

@MainActor
struct AppModelNetworkTests {
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
    private let zen = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen", profileDir: "~/oc")
    private let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")

    private struct Rig {
        let home: ModelHome
        let model: AppModel
        let log: FetchLog
        let clock: TestClock
        let outcomes: Outcomes
        let network: FakeNetworkStatus

        func counts(_ ids: String...) -> [Int] { ids.map(log.count) }
    }

    /// `prepare` writes what the accounts need in the home and returns the config's `cliPaths`.
    private func rig(_ accounts: [AccountConfig], gate: Gate? = nil, prepare: (ModelHome) throws -> [String: String] = { _ in [:] }) throws -> Rig {
        let home = try ModelHome()
        try home.makeDirectory(".claude")
        try home.makeDirectory(".config/gh")
        try home.write("oc/opencode.db", "")
        let cliPaths = try prepare(home)
        try home.writeConfig(AppConfig(accounts: accounts, cliPaths: cliPaths))
        let log = FetchLog(), clock = TestClock(), outcomes = Outcomes(), network = FakeNetworkStatus()
        let model = AppModel(
            paths: home.paths,
            fetcher: { _ in FakeFetcher(log: log, gate: gate) { account in outcomes[account.id] ?? .success(usageSnapshot(account)) } },
            clock: { clock.now }, network: network
        )
        model.loadState()
        return Rig(home: home, model: model, log: log, clock: clock, outcomes: outcomes, network: network)
    }

    private func goOffline(_ rig: Rig) {
        rig.model.networkPathChanged(.unusable)
        rig.clock.advance(NetworkWatch.offlineSettle)
        rig.model.settleNetwork()
    }

    private func comeBack(_ rig: Rig) async {
        rig.model.networkPathChanged(.usable)
        rig.clock.advance(NetworkWatch.onlineSettle)
        await rig.model.settleNetwork()?.value
    }

    @Test func offlineSkipsChecksThatNeedTheNetwork() async throws {
        let rig = try rig([claude, copilot, zen])
        defer { rig.home.remove() }
        rig.model.networkPathChanged(.unusable)

        await rig.model.refresh(force: true)?.value
        rig.clock.advance(11 * 60)
        await rig.model.tick()?.value
        rig.model.systemWillSleep()
        await rig.model.systemDidWake(networkDelay: .zero)?.value
        rig.model.updateAccount("claude") { $0.label = "Renamed" }
        try await waitUntil { !rig.model.isRefreshing }

        #expect(rig.log.count("claude") == 0)
        #expect(rig.log.count("copilot") == 0)
        #expect(rig.log.count("zen") == 3)
    }

    /// Zen reads opencode.db, Devin is a link, and history comes from local logs: none of them needs the network.
    @Test func localSourcesAndHistoryStillRunWhileOffline() async throws {
        let transcript = #"{"type":"assistant","message":{"id":"msg_A","model":"claude-opus-5-5","usage":{"input_tokens":3,"output_tokens":10}},"requestId":"req_A","timestamp":"2026-10-09T10:00:01.250Z","cwd":"/tmp/demo","sessionId":"S"}"#
        let rig = try rig([claude, zen, devin]) { home in
            try home.write(".claude/projects/demo/S.jsonl", transcript + "\n")
            return [:]
        }
        defer { rig.home.remove() }
        goOffline(rig)
        let before = rig.model.historyRevision

        await rig.model.tick()?.value

        #expect(rig.log.count("zen") == 1)
        #expect(rig.log.count("devin") == 1)
        #expect(rig.log.count("claude") == 0)
        try await waitUntil { rig.model.historyRevision > before }
    }

    /// Accounts that failed in the seconds before offline was declared were pushed a full interval out; coming back
    /// checks them anyway. A 429 backoff and a latched probe still hold.
    @Test func backOnlineChecksEveryAccountOnce() async throws {
        let agy = AccountConfig(id: "agy", provider: .antigravity, label: "Google")
        let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/auth.json", key: "opencode-go"))
        let rig = try rig([claude, go, agy, zen]) { home in
            try home.write("auth.json", "{}")
            return ["agy": try home.makeExecutable("bin/agy").path]
        }
        defer { rig.home.remove() }
        rig.outcomes["go"] = .failure(.rateLimited(retryAfter: 3_600))
        rig.outcomes["agy"] = .failure(.unsupported(AntigravityUsageFetcher.modelTurnMessage))
        await rig.model.refresh(force: true)?.value
        rig.clock.advance(60)
        #expect(rig.counts("claude", "go", "agy") == [1, 1, 1])

        goOffline(rig)
        rig.clock.advance(60)
        await comeBack(rig)

        #expect(rig.log.count("claude") == 2)
        #expect(rig.log.count("go") == 1)
        #expect(rig.log.count("agy") == 1)
    }

    /// A network that drops and returns every few seconds must not respawn every CLI each time.
    @Test func aSecondReturnWithinTwoMinutesChecksOnlyWhatIsDue() async throws {
        let fast = AccountConfig(id: "fast", provider: .copilot, label: "GitHub", refreshMinutes: 1)
        let rig = try rig([claude, fast])
        defer { rig.home.remove() }
        await rig.model.refresh(force: true)?.value
        goOffline(rig)
        await comeBack(rig)
        #expect(rig.counts("claude", "fast") == [2, 2])

        rig.clock.advance(30)
        goOffline(rig)
        rig.clock.advance(30)
        await comeBack(rig)

        #expect(rig.log.count("claude") == 2)
        #expect(rig.log.count("fast") == 3)

        rig.clock.advance(2 * 60)
        goOffline(rig)
        await comeBack(rig)
        #expect(rig.log.count("claude") == 3)
    }

    /// A drop shorter than the settle never showed offline; only what it skipped is checked, at once.
    @Test func aBlipRechecksOnlyWhatItSkipped() async throws {
        let rig = try rig([claude, copilot])
        defer { rig.home.remove() }
        rig.model.networkPathChanged(.usable)
        await rig.model.refresh(force: true)?.value
        rig.clock.advance(5 * 60)
        rig.model.updateAccount("copilot") { $0.label = "Work" }
        try await waitUntil { !rig.model.isRefreshing }
        #expect(rig.counts("claude", "copilot") == [1, 2])

        rig.model.networkPathChanged(.unusable)
        rig.model.updateAccount("copilot") { $0.label = "GitHub" }
        try await waitUntil { !rig.model.isRefreshing }
        #expect(rig.log.count("copilot") == 2)
        rig.clock.advance(4)
        await rig.model.networkPathChanged(.usable)?.value

        #expect(rig.model.connectivity == .online)
        #expect(rig.log.count("claude") == 1)
        #expect(rig.log.count("copilot") == 3)
    }

    /// Path status is advice: what the user asks for always runs.
    @Test func userChecksRunWhileOffline() async throws {
        let rig = try rig([claude, copilot])
        defer { rig.home.remove() }
        goOffline(rig)

        await PopoverHeader.refreshNow(rig.model)?.value
        #expect(rig.counts("claude", "copilot") == [1, 1])
        await rig.model.refresh(accountID: "claude")?.value
        await rig.model.retryProbe(accountID: "copilot")?.value
        #expect(rig.counts("claude", "copilot") == [2, 2])
    }

    /// A VPN macOS reports as unusable would otherwise stop every automatic check for good.
    @Test func aLiveAnswerWhileOfflineLiftsTheHold() async throws {
        let rig = try rig([claude, copilot])
        defer { rig.home.remove() }
        goOffline(rig)
        #expect(rig.model.connectivity == .offline)

        await rig.model.refresh(accountID: "claude")?.value

        #expect(rig.model.connectivity == .online)
        rig.clock.advance(11 * 60)
        await rig.model.tick()?.value
        #expect(rig.log.count("copilot") == 1)
    }

    /// Only a check that ran while held proves anything about the path macOS reports now.
    @Test func aResultFromBeforeTheDropDoesNotLiftTheHold() async throws {
        let gate = Gate()
        let rig = try rig([claude, copilot], gate: gate)
        defer { rig.home.remove() }
        rig.model.networkPathChanged(.usable)
        let running = rig.model.refresh(accountID: "claude")
        try await waitUntil { rig.log.count("claude") == 1 }

        goOffline(rig)
        await gate.open()
        await running?.value

        #expect(rig.model.connectivity == .offline)
        rig.clock.advance(11 * 60)
        await rig.model.tick()?.value
        #expect(rig.log.count("copilot") == 0)
    }

    /// A launch while offline spawns nothing that needs the network.
    @Test func launchWaitsForTheFirstPathReport() async throws {
        let rig = try rig([claude, zen])
        defer { rig.home.remove() }

        let launch = Task { await rig.model.launchRefresh(firstPathWait: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.log.count("zen") == 0)
        rig.model.networkPathChanged(.unusable)
        await launch.value?.value

        #expect(rig.log.count("claude") == 0)
        #expect(rig.log.count("zen") == 1)

        let silent = try self.rig([claude])
        defer { silent.home.remove() }
        await silent.model.launchRefresh(firstPathWait: .milliseconds(20))?.value
        #expect(silent.log.count("claude") == 1)
    }

    /// Between sleep and the wake refresh, a path report only updates what the UI shows.
    @Test func pathReportsDuringSleepWaitForTheWakeRefresh() async throws {
        let rig = try rig([claude])
        defer { rig.home.remove() }
        await rig.model.refresh(force: true)?.value
        rig.model.systemWillSleep()

        goOffline(rig)
        await comeBack(rig)
        #expect(rig.log.count("claude") == 1)
        #expect(rig.model.connectivity == .online)

        await rig.model.systemDidWake(networkDelay: .zero)?.value
        #expect(rig.log.count("claude") == 2)
    }

    /// "Updated" means the last time numbers arrived, not the last time a check was tried.
    @Test func lastUpdatedIsTheNewestSuccessNotTheLastAttempt() async throws {
        let rig = try rig([claude, copilot, zen])
        defer { rig.home.remove() }
        let checkedAt = rig.clock.now
        for account in [claude, copilot, zen] { rig.outcomes[account.id] = .success(usageSnapshot(account, fetchedAt: checkedAt)) }
        await rig.model.refresh(force: true)?.value
        #expect(rig.model.lastUpdated == checkedAt)

        rig.outcomes["claude"] = .failure(.timeout)
        rig.outcomes["copilot"] = .failure(.network("dial tcp"))
        rig.clock.advance(25 * 60)
        await rig.model.refresh(force: true)?.value

        #expect(rig.model.lastRefreshAt == rig.clock.now)
        #expect(rig.model.lastUpdated == checkedAt)
    }

    /// The monitor belongs to the running app alone.
    @Test func onlyStartRunsTheMonitor() throws {
        let rig = try rig([claude])
        defer { rig.home.remove() }
        #expect(!rig.network.isStarted)
    }
}
