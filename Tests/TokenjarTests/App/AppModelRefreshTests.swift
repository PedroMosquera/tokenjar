import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AppModelRefreshTests {
    private let modelTurn = FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)

    private func model(_ home: ModelHome, _ clock: TestClock, _ fetcher: @escaping (ProviderID) -> any UsageFetcher) -> AppModel {
        let model = AppModel(paths: home.paths, fetcher: fetcher, clock: { clock.now })
        model.loadState()
        return model
    }

    /// Hard rule 5: once `claude -p /usage` has run as a billed model turn, no path may run it again on its own.
    @Test func aProbeThatSpentTokensIsNotRepeated() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        let claude = try home.makeExecutable("bin/claude")
        let account = AccountConfig(id: "claude", provider: .claude, label: "Personal", refreshMinutes: 1)
        try home.writeConfig(AppConfig(accounts: [account], cliPaths: ["claude": claude.path]))
        let log = FetchLog(), clock = TestClock()
        let fetcher: (ProviderID) -> any UsageFetcher = { [modelTurn] _ in FakeFetcher(log: log) { _ in .failure(modelTurn) } }
        let model = model(home, clock, fetcher)

        await model.refresh(force: true)?.value
        #expect(log.count("claude") == 1)
        #expect(model.statuses["claude"]?.error == modelTurn)

        await model.refresh(force: true)?.value
        clock.advance(10 * 60)
        await model.refresh(force: false)?.value
        await model.refresh(accountID: "claude")?.value
        #expect(log.count("claude") == 1)

        let relaunched = self.model(home, clock, fetcher)
        #expect(relaunched.statuses["claude"]?.error == modelTurn)
        await relaunched.refresh(force: true)?.value
        #expect(log.count("claude") == 1)
    }

    @Test func forcedRefreshesWaitOutARateLimit() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.write("auth.json", "{}")
        let account = AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/auth.json", key: "opencode-go"))
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), clock = TestClock()
        let model = model(home, clock) { _ in FakeFetcher(log: log) { _ in .failure(.rateLimited(retryAfter: 3600)) } }

        await model.refresh(force: true)?.value
        #expect(log.count("go") == 1)
        // Popover open, wake and the header button all force a refresh.
        await model.refresh(force: true)?.value
        clock.advance(30 * 60)
        await model.refresh(force: true)?.value
        await model.refresh(force: false)?.value
        #expect(log.count("go") == 1)

        // Settings > Test is the explicit override.
        await model.refresh(accountID: "go")?.value
        #expect(log.count("go") == 2)
    }

    @Test func aFastAccountIsFreeAgainWhileASlowOneRuns() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        try home.makeDirectory(".codex")
        let slow = AccountConfig(id: "slow", provider: .claude, label: "Slow")
        let fast = AccountConfig(id: "fast", provider: .codex, label: "Fast")
        try home.writeConfig(AppConfig(accounts: [slow, fast]))
        let log = FetchLog(), gate = Gate(), clock = TestClock()
        let model = model(home, clock) { provider in
            FakeFetcher(log: log, gate: provider == .claude ? gate : nil) { .success(usageSnapshot($0)) }
        }

        let first = model.refresh(force: true)
        try await waitUntil { model.statuses["fast"]?.snapshot != nil }
        #expect(model.statuses["fast"]?.isRefreshing == false)
        await model.refresh(accountID: "fast")?.value
        #expect(log.count("fast") == 2)

        await gate.open()
        await first?.value
        #expect(log.count("slow") == 1)
    }

    @Test func aResultFetchedBeforeAnEditIsDroppedAndRefetched() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude-a")
        try home.makeDirectory(".claude-b")
        let account = AccountConfig(id: "work", provider: .claude, label: "Work", profileDir: "~/.claude-a")
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), gate = Gate(), clock = TestClock()
        // The plan carries the profile dir the fetch ran with, so the test can tell an old result from a new one.
        let model = model(home, clock) { _ in FakeFetcher(log: log, gate: gate) { .success(usageSnapshot($0, plan: $0.profileDir)) } }

        let first = model.refresh(force: true)
        try await waitUntil { log.count("work") == 1 }
        model.updateAccount("work") { $0.profileDir = "~/.claude-b" }
        await gate.open()
        await first?.value
        try await waitUntil { !model.isRefreshing }

        #expect(log.count("work") == 2)
        #expect(model.statuses["work"]?.snapshot?.plan == "~/.claude-b")
    }

    @Test func aNewClaudeBuildOrAnExplicitRetryProbesOnceMore() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        let claude = try home.makeExecutable("bin/claude")
        let account = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        try home.writeConfig(AppConfig(accounts: [account], cliPaths: ["claude": claude.path]))
        let log = FetchLog(), clock = TestClock()
        let model = model(home, clock) { [modelTurn] _ in FakeFetcher(log: log) { _ in .failure(modelTurn) } }
        await model.refresh(force: true)?.value
        await model.refresh(force: true)?.value
        #expect(log.count("claude") == 1)

        try home.makeExecutable("bin/claude", contents: "#!/bin/sh\n# a newer build\nexit 1\n")
        await model.refresh(force: true)?.value
        #expect(log.count("claude") == 2)
        await model.refresh(force: true)?.value
        #expect(log.count("claude") == 2)

        await model.retryProbe(accountID: "claude")?.value
        #expect(log.count("claude") == 3)
        await model.refresh(force: true)?.value
        #expect(log.count("claude") == 3)
    }

    /// agy can send `/usage` to the model too. Its latch follows the agy binary, so a claude update does not lift it.
    @Test func anAntigravityProbeThatSpentQuotaIsLatchedOnTheAgyBinary() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let agy = try home.makeExecutable("bin/agy")
        let claude = try home.makeExecutable("bin/claude")
        let account = AccountConfig(id: "agy", provider: .antigravity, label: "Google", refreshMinutes: 1)
        try home.writeConfig(AppConfig(accounts: [account], cliPaths: ["agy": agy.path, "claude": claude.path]))
        let log = FetchLog(), clock = TestClock()
        let quotaTurn = FetchError.unsupported(AntigravityUsageFetcher.modelTurnMessage)
        let fetcher: (ProviderID) -> any UsageFetcher = { _ in FakeFetcher(log: log) { _ in .failure(quotaTurn) } }
        let model = model(home, clock, fetcher)

        await model.refresh(force: true)?.value
        await model.refresh(force: true)?.value
        clock.advance(10 * 60)
        await model.refresh(force: false)?.value
        await model.refresh(accountID: "agy")?.value
        #expect(log.count("agy") == 1)

        let relaunched = self.model(home, clock, fetcher)
        #expect(relaunched.statuses["agy"]?.error == quotaTurn)
        await relaunched.refresh(force: true)?.value
        #expect(log.count("agy") == 1)

        try home.makeExecutable("bin/claude", contents: "#!/bin/sh\n# a newer build\nexit 1\n")
        await relaunched.refresh(force: true)?.value
        #expect(log.count("agy") == 1)

        try home.makeExecutable("bin/agy", contents: "#!/bin/sh\n# a newer build\nexit 1\n")
        await relaunched.refresh(force: true)?.value
        #expect(log.count("agy") == 2)
        await relaunched.refresh(force: true)?.value
        #expect(log.count("agy") == 2)

        await relaunched.retryProbe(accountID: "agy")?.value
        #expect(log.count("agy") == 3)
        await relaunched.refresh(force: true)?.value
        #expect(log.count("agy") == 3)
    }

    /// No store is opened, so nothing else tightens the support folder before the state files are written.
    @Test func persistedStateIsOwnerOnly() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        let claude = try home.makeExecutable("bin/claude")
        let account = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        try home.writeConfig(AppConfig(accounts: [account], cliPaths: ["claude": claude.path]))
        let support = home.paths.supportDirectory
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let log = FetchLog(), clock = TestClock()
        let model = AppModel(paths: home.paths, fetcher: { [modelTurn] _ in FakeFetcher(log: log) { _ in .failure(modelTurn) } }, clock: { clock.now })
        model.loadConfig()

        await model.refresh(force: true)?.value

        #expect(try home.mode(support) == 0o700)
        #expect(try home.mode(support.appending(path: "alert-state.json")) == 0o600)
        #expect(try home.mode(support.appending(path: "probe-latch.json")) == 0o600)
    }

    /// A refresh that changes nothing the alert engine tracks writes nothing to disk.
    @Test func alertStateIsWrittenOnlyWhenItChanges() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".codex")
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus")
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), clock = TestClock()
        let fetchedAt = clock.now
        let model = model(home, clock) { _ in FakeFetcher(log: log) { .success(usageSnapshot($0, fetchedAt: fetchedAt)) } }
        await model.refresh(force: true)?.value
        let file = home.paths.supportDirectory.appending(path: "alert-state.json")
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: file.path)

        await model.refresh(force: true)?.value
        await model.refresh(force: true)?.value

        #expect(log.count("codex") == 3)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == baseline)
    }

    @Test func ticksWaitForTheWakeRefreshAfterSleep() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".codex")
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus")
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), clock = TestClock()
        let model = model(home, clock) { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } }
        await model.refresh(force: true)?.value
        #expect(log.count("codex") == 1)

        model.systemWillSleep()
        clock.advance(3 * 3600)
        await model.tick()?.value
        #expect(log.count("codex") == 1)

        await model.systemDidWake(networkDelay: .zero)?.value
        #expect(log.count("codex") == 2)
        clock.advance(11 * 60)
        await model.tick()?.value
        #expect(log.count("codex") == 3)
    }

    /// The popover's views read `popoverNow`, so a closed popover does not redraw on every 30-second tick.
    @Test func thePopoverClockMovesOnlyWhileThePopoverIsShown() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.writeConfig(AppConfig())
        let log = FetchLog(), clock = TestClock()
        let model = model(home, clock) { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } }
        let start = clock.now
        #expect(model.popoverNow == start)

        clock.advance(30)
        await model.tick()?.value
        #expect(model.now == clock.now)
        #expect(model.popoverNow == start)

        clock.advance(30)
        model.popoverWillOpen()
        #expect(model.popoverNow == clock.now)
        model.isPopoverShown = true
        clock.advance(30)
        await model.tick()?.value
        #expect(model.now == clock.now)
        #expect(model.popoverNow == clock.now)
    }

    /// History views reload on every bump, so a refresh that stored nothing new must not bump.
    @Test func historyRevisionMovesOnlyWhenASampleIsStored() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".codex")
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus")
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), clock = TestClock(), used = UsedPercent()
        let fetchedAt = clock.now
        let model = model(home, clock) { _ in
            FakeFetcher(log: log) {
                .success(UsageSnapshot(
                    accountID: $0.id, provider: $0.provider,
                    windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: used.value, windowMinutes: 300, resetsAt: fetchedAt.addingTimeInterval(3600))],
                    fetchedAt: fetchedAt, source: "test"
                ))
            }
        }
        await model.refresh(force: true)?.value
        let first = model.historyRevision

        await model.refresh(force: true)?.value
        #expect(log.count("codex") == 2)
        #expect(model.historyRevision == first)

        used.value = 20
        await model.refresh(force: true)?.value
        #expect(model.historyRevision == first + 1)
    }

    /// The dashboard totals "today" as of its last reload. With every refresh a repeat the store skips, only the day
    /// turning over can tell it to reload.
    @Test func historyRevisionMovesWhenTheLocalDayTurnsOver() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".codex")
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus")
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), clock = TestClock()
        let calendar = Calendar.current
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now)))
        clock.now = midnight.addingTimeInterval(-45)
        let fetchedAt = clock.now
        let model = model(home, clock) { _ in FakeFetcher(log: log) { .success(usageSnapshot($0, fetchedAt: fetchedAt)) } }
        await model.refresh(force: true)?.value
        let first = model.historyRevision

        clock.advance(30)
        await model.tick()?.value
        #expect(model.historyRevision == first)

        clock.advance(30)
        await model.tick()?.value
        #expect(model.historyRevision == first + 1)

        clock.advance(30)
        await model.refresh(force: true)?.value
        await model.tick()?.value
        #expect(log.count("codex") == 2)
        #expect(model.historyRevision == first + 1)
    }

    /// Ticks land a little after their 30-second mark, by a different amount each time, and the clock moves between
    /// reads within a tick. A 10-minute account is still checked on the tick 10 minutes after its last check.
    @Test func aTenMinuteAccountIsCheckedOnTheTickTenMinutesLater() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".codex")
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus", refreshMinutes: 10)
        try home.writeConfig(AppConfig(accounts: [account]))
        let log = FetchLog(), clock = MovingClock()
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } }, clock: { clock.read() })
        model.loadState()

        var checkedAt: [TimeInterval] = []
        for mark in stride(from: 0.0, through: 1230, by: 30) {
            clock.fire(at: mark, late: mark == 0 ? 0.5 : 0.001)
            let before = log.count("codex")
            await model.tick()?.value
            if log.count("codex") > before { checkedAt.append(mark) }
        }

        #expect(checkedAt == [0, 600, 1200])
    }
}

/// A clock for timer ticks: each tick fires a little after its mark, and every read moves the clock on a little more.
@MainActor
private final class MovingClock {
    private let start = Date(timeIntervalSince1970: 1_791_660_000)
    private var firedAt: Date
    private var reads = 0

    init() { firedAt = start }

    func fire(at mark: TimeInterval, late: TimeInterval) {
        firedAt = start.addingTimeInterval(mark + late)
        reads = 0
    }

    func read() -> Date {
        reads += 1
        return firedAt.addingTimeInterval(Double(reads) * 0.0001)
    }
}

/// The used % a fake fetch reports, changed by the test between refreshes.
private nonisolated final class UsedPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 10.0

    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
