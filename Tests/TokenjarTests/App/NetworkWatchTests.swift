import Foundation
import Network
import Testing
@testable import Tokenjar
import TokenjarCore

// Every path here is a value handed in: nothing reads or changes the Mac's network.

private let t0 = Date(timeIntervalSince1970: 1_791_660_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

struct NetworkWatchTests {
    /// Wake and Wi-Fi roaming can drop the path for a few seconds; that must not flash the slash.
    @Test func aBlipShorterThanTheSettleNeverShowsOffline() {
        var watch = NetworkWatch()
        #expect(watch.report(.usable, at: at(0)) == nil)
        #expect(watch.report(.unusable, at: at(1)) == nil)
        #expect(watch.settle(at: at(10.9)) == nil)
        #expect(watch.report(.usable, at: at(10.95)) == .blipEnded)
        #expect(watch.settle(at: at(30)) == nil)
        #expect(!watch.isOffline)
    }

    @Test func offlineShowsAfterTenSeconds() {
        var watch = NetworkWatch()
        _ = watch.report(.usable, at: at(0))
        _ = watch.report(.unusable, at: at(5))
        #expect(watch.nextSettle == at(15))
        #expect(watch.settle(at: at(14.9)) == nil)
        #expect(!watch.isOffline)
        #expect(watch.settle(at: at(15)) == .wentOffline)
        #expect(watch.isOffline)
        #expect(watch.settle(at: at(40)) == nil)
    }

    /// Skipping a check costs nothing and the account stays due, so the hold needs no settle.
    @Test func checksAreHeldFromTheFirstUnusableReport() {
        var watch = NetworkWatch()
        #expect(!watch.holdsChecks)
        _ = watch.report(.usable, at: at(0))
        #expect(!watch.holdsChecks)
        _ = watch.report(.unusable, at: at(1))
        #expect(watch.holdsChecks)
        #expect(!watch.isOffline)
        _ = watch.report(.usable, at: at(2))
        #expect(!watch.holdsChecks)
    }

    @Test func backOnlineAfterThreeUsableSeconds() {
        var watch = NetworkWatch()
        _ = watch.report(.unusable, at: at(0))
        _ = watch.settle(at: at(10))
        #expect(watch.report(.usable, at: at(20)) == nil)
        #expect(watch.isOffline)
        #expect(watch.nextSettle == at(23))
        #expect(watch.settle(at: at(22.9)) == nil)
        #expect(watch.isOffline)
        #expect(watch.settle(at: at(23)) == .cameBackOnline)
        #expect(!watch.isOffline)
        #expect(watch.nextSettle == nil)
    }

    /// A path that comes back for a second while offline must not clear the slash.
    @Test func aFlickerWhileOfflineKeepsItOffline() {
        var watch = NetworkWatch()
        _ = watch.report(.unusable, at: at(0))
        _ = watch.settle(at: at(10))
        _ = watch.report(.usable, at: at(20))
        #expect(watch.report(.unusable, at: at(21)) == nil)
        #expect(watch.settle(at: at(24)) == nil)
        #expect(watch.settle(at: at(40)) == nil)
        #expect(watch.isOffline)
        #expect(watch.holdsChecks)
    }

    @Test func theFirstReportCanBeOffline() {
        var watch = NetworkWatch()
        #expect(watch.path == nil)
        #expect(watch.report(.unusable, at: at(0)) == nil)
        #expect(watch.holdsChecks)
        #expect(watch.settle(at: at(10)) == .wentOffline)
    }

    /// Path status has false positives, such as a VPN macOS reports as unusable. A live answer from a check that ran
    /// while held proves the network works, so nothing stays held for good.
    @Test func aLiveAnswerLiftsTheHoldUntilTheNextReport() {
        var watch = NetworkWatch()
        _ = watch.report(.unusable, at: at(0))
        _ = watch.settle(at: at(10))
        watch.trustAnswers()
        #expect(!watch.holdsChecks)
        #expect(!watch.isOffline)
        #expect(watch.settle(at: at(60)) == nil)
        #expect(!watch.isOffline)

        _ = watch.report(.unusable, at: at(70))
        #expect(watch.holdsChecks)
        #expect(!watch.isOffline)
        #expect(watch.settle(at: at(80)) == .wentOffline)
    }

    @Test func pathStatusMapsToUsability() {
        #expect(PathMonitorNetworkStatus.usability(of: .satisfied) == .usable)
        #expect(PathMonitorNetworkStatus.usability(of: .requiresConnection) == .usable)
        #expect(PathMonitorNetworkStatus.usability(of: .unsatisfied) == .unusable)
    }
}

struct ConnectivityTests {
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let claudeWork = AccountConfig(id: "claude-work", provider: .claude, label: "Work")
    private let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
    private let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go")
    private let zen = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen")
    private let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")

    private func offline() -> NetworkWatch {
        var watch = NetworkWatch()
        _ = watch.report(.unusable, at: at(0))
        _ = watch.settle(at: at(10))
        return watch
    }

    private func online() -> NetworkWatch {
        var watch = NetworkWatch()
        _ = watch.report(.usable, at: at(0))
        return watch
    }

    private func checked(_ error: FetchError? = nil, snapshot: UsageSnapshot? = nil) -> AccountStatus {
        AccountStatus(snapshot: snapshot, error: error, lastAttempt: at(0))
    }

    private func live(_ account: AccountConfig) -> AccountStatus {
        checked(snapshot: UsageSnapshot(accountID: account.id, provider: account.provider, fetchedAt: at(0), source: "test"))
    }

    private func make(_ watch: NetworkWatch, _ accounts: [AccountConfig], _ statuses: [String: AccountStatus], latched: Set<String> = []) -> Connectivity {
        Connectivity.make(watch: watch, accounts: accounts, statuses: statuses, isLatched: { latched.contains($0) })
    }

    /// Zen reads a local database and Devin is a link: nothing such a setup shows depends on the network.
    @Test func offlineOnlyWhenAnAccountNeedsTheNetwork() {
        #expect(make(offline(), [zen, devin], [:]) == .online)
        #expect(make(offline(), [zen, devin, claude], [:]) == .offline)
        #expect(make(offline(), [], [:]) == .online)
    }

    @Test func noAnswerNeedsTwoProvidersAndNoLiveAnswer() {
        let statuses = ["claude": checked(.timeout), "copilot": checked(.network("dial tcp"))]
        #expect(make(online(), [claude, copilot], statuses) == .noAnswer)
        #expect(make(NetworkWatch(), [claude, copilot], statuses) == .noAnswer)
        // A failure of another kind neither confirms nor blocks it.
        #expect(make(online(), [claude, copilot, go], statuses.merging(["go": checked(.notSignedIn)]) { $1 }) == .noAnswer)
    }

    /// One provider failing alone is that provider's problem, not the connection's.
    @Test func oneProviderDownIsNotNoAnswer() {
        #expect(make(online(), [claude, copilot], ["claude": checked(.timeout)]) == .online)
        #expect(make(online(), [claude, copilot], ["claude": checked(.timeout), "copilot": checked(.notSignedIn)]) == .online)
    }

    @Test func twoAccountsOfOneProviderAreOneProvider() {
        let statuses = ["claude": checked(.timeout), "claude-work": checked(.network("offline"))]
        #expect(make(online(), [claude, claudeWork], statuses) == .online)
        #expect(make(online(), [claude, claudeWork, copilot], statuses.merging(["copilot": checked(.timeout)]) { $1 }) == .noAnswer)
    }

    /// Claude Code's cache stands in for a timed-out check without an error on the card, and still counts.
    @Test func aSavedCopyShownForATimeoutCountsAsNoAnswer() {
        let saved = UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: at(-3_600), source: ClaudeUsageFetcher.cacheSource, liveCheckFailure: .timeout)
        let statuses = ["claude": checked(snapshot: saved), "copilot": checked(.network("dial tcp"))]
        #expect(make(online(), [claude, copilot], statuses) == .noAnswer)
        let broken = UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: at(-3_600), source: ClaudeUsageFetcher.cacheSource, liveCheckFailure: .other)
        #expect(make(online(), [claude, copilot], ["claude": checked(snapshot: broken), "copilot": checked(.network("dial tcp"))]) == .online)
    }

    @Test func aLiveAnswerEndsNoAnswer() {
        let statuses = ["claude": checked(.timeout), "copilot": checked(.network("dial tcp")), "go": live(go)]
        #expect(make(online(), [claude, copilot, go], statuses) == .online)
        // Zen answers without the network, so it proves nothing.
        #expect(make(online(), [claude, copilot, zen], statuses.merging(["zen": live(zen)]) { $1 }) == .noAnswer)
    }

    /// The store's snapshot at launch may be a saved copy from an earlier launch, which says nothing about now. The
    /// latest result wins over a saved copy shown before it.
    @Test func onlyACheckThisLaunchMakesAConnectionFailure() {
        let overNetwork = UsageSnapshot(accountID: "codex", provider: .codex, fetchedAt: at(-3_600), source: "Codex session log", liveCheckFailure: .network)
        let overTimeout = UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: at(-3_600), source: ClaudeUsageFetcher.cacheSource, liveCheckFailure: .timeout)
        #expect(AccountStatus(snapshot: overNetwork).connectionFailure == nil)
        #expect(checked(snapshot: overNetwork).connectionFailure == .network("saved copy"))
        #expect(checked(snapshot: overTimeout).connectionFailure == .timeout)
        #expect(checked(.timeout).connectionFailure == .timeout)
        #expect(checked(.rateLimited(retryAfter: 60)).connectionFailure == nil)
        #expect(checked(.parse("shape"), snapshot: overNetwork).connectionFailure == nil)
    }

    /// An account not checked this launch shows only what the store kept, and a latched one is never checked.
    @Test func uncheckedAndLatchedAccountsDoNotCount() {
        let seeded = UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: at(-3_600), source: ClaudeUsageFetcher.cacheSource, liveCheckFailure: .timeout)
        let statuses = ["claude": AccountStatus(snapshot: seeded), "copilot": checked(.network("dial tcp"))]
        #expect(make(online(), [claude, copilot], statuses) == .online)
        let both = ["claude": checked(.timeout), "copilot": checked(.network("dial tcp"))]
        #expect(make(online(), [claude, copilot], both, latched: ["claude"]) == .online)
        #expect(make(offline(), [claude], [:], latched: ["claude"]) == .online)
    }
}
