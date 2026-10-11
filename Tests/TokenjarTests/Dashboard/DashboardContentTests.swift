import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func window(_ id: String, used: Double, minutes: Int, resetIn: TimeInterval) -> UsageWindow {
    UsageWindow(id: id, label: id, usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetIn))
}

private func snapshot(_ accountID: String, provider: ProviderID = .claude, _ windows: [UsageWindow]) -> UsageSnapshot {
    UsageSnapshot(accountID: accountID, provider: provider, windows: windows, fetchedAt: now, source: "test")
}

struct OverviewWindowTests {
    private let work = snapshot("work", [
        window("session", used: 88, minutes: 300, resetIn: 50 * 60),
        window("weekly", used: 71, minutes: 10_080, resetIn: 3 * 86_400),
    ])

    @Test func longRangesSkipWindowsThatWouldOnlyShowPeaks() {
        #expect(DashboardMath.overviewWindow(of: work, range: .week)?.id == "weekly")
        #expect(DashboardMath.overviewWindow(of: work, range: .month)?.id == "weekly")
    }

    @Test func theDayRangeKeepsTheTightestWindow() {
        #expect(DashboardMath.overviewWindow(of: work, range: .day)?.id == "session")
    }

    @Test func anAccountWithOnlyAShortWindowStillGetsALine() {
        let only = snapshot("a", [window("session", used: 40, minutes: 300, resetIn: 3600)])
        #expect(DashboardMath.overviewWindow(of: only, range: .month)?.id == "session")
    }

    @Test func equalUseBreaksTiesOnTheSoonerReset() {
        let pools = snapshot("agy", [
            window("a:weekly", used: 50, minutes: 10_080, resetIn: 4 * 86_400),
            window("b:weekly", used: 50, minutes: 10_080, resetIn: 2 * 86_400),
        ])
        #expect(DashboardMath.overviewWindow(of: pools, range: .month)?.id == "b:weekly")
    }
}

struct ColorSlotTests {
    @Test func accountsWithoutWindowsTakeTheLastSlots() {
        let slots = DashboardMath.colorSlots(accountIDs: ["claude", "zen", "go", "agy"], withWindows: ["claude", "go", "agy"])
        #expect(slots == ["claude": 0, "go": 1, "agy": 2, "zen": 3])
    }
}

@MainActor
struct DashboardContentLoadTests {
    private let accounts = [
        AccountConfig(id: "claude-work", provider: .claude, label: "Work"),
        AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen"),
        AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go"),
        AccountConfig(id: "antigravity", provider: .antigravity, label: "Google"),
    ]

    private func model() -> AppModel {
        let model = AppModel()
        model.previewMode = true
        model.now = now
        model.config = AppConfig(accounts: accounts)
        let snapshots = [
            snapshot("claude-work", [
                window("session", used: 88, minutes: 300, resetIn: 50 * 60),
                window("weekly", used: 71, minutes: 10_080, resetIn: 3 * 86_400),
            ]),
            UsageSnapshot(accountID: "opencode-zen", provider: .opencodeZen, money: [MoneyLine(label: "Spent", amount: 8)], fetchedAt: now, source: "test"),
            snapshot("opencode-go", provider: .opencodeGo, [window("weekly", used: 45, minutes: 10_080, resetIn: 86_400)]),
            snapshot("antigravity", provider: .antigravity, [window("gemini:weekly", used: 38, minutes: 10_080, resetIn: 4 * 86_400)]),
        ]
        let store = InMemoryUsageStore()
        for snapshot in snapshots {
            model.statuses[snapshot.accountID] = AccountStatus(snapshot: snapshot)
            for window in snapshot.windows {
                store.addSamples([-3600.0, -1800].map {
                    WindowSample(
                        accountID: snapshot.accountID, windowID: window.id, timestamp: now.addingTimeInterval($0),
                        usedPercent: window.usedPercent - 1, resetsAt: window.resetsAt
                    )
                })
            }
        }
        model.store = store
        return model
    }

    private func load(_ model: AppModel, account: AccountConfig? = nil, range: DashboardRange) -> DashboardContent {
        DashboardContent.load(DashboardContent.Input(
            model: model, accounts: model.accounts, account: account, range: range, now: now,
            key: DashboardLoadKey(accountIDs: model.accounts.map(\.id), range: range, historyRevision: 0)
        ))
    }

    @Test func allAccountsDrawsReadableWindowsInStableColorsUnderShortNames() {
        let content = load(model(), range: .month)
        #expect(content.series.map(\.label) == ["Claude · Work", "OpenCode Go", "Antigravity · Google"])
        #expect(content.series.map(\.colorIndex) == [0, 1, 2])
        #expect(content.series.allSatisfy { !$0.peaksOnly })
        #expect(content.pointsBySeries["claude-work"]?.last?.usedPercent == 70)
        // Zen has no limit line, but its spend bar gets the next real slot instead of the gray "Other".
        #expect(content.accountSlotByName == ["Claude · Work": 0, "OpenCode Go": 1, "Antigravity · Google": 2, "OpenCode Zen": 3])
    }

    @Test func oneAccountMarksWindowsThatOnlyShowPeaks() {
        let model = model()
        let content = load(model, account: model.accounts.first, range: .month)
        #expect(content.series.map(\.id) == ["session", "weekly"])
        #expect(content.series.map(\.peaksOnly) == [true, false])
    }
}

struct DashboardDimTests {
    private let shown = DashboardLoadKey(accountIDs: ["claude"], range: .week, historyRevision: 4)

    @Test func newHistoryForTheSamePageKeepsItAtFullOpacity() {
        #expect(!DashboardLoadKey.dims(shown: shown, wanted: DashboardLoadKey(accountIDs: ["claude"], range: .week, historyRevision: 5)))
        #expect(!DashboardLoadKey.dims(shown: shown, wanted: shown))
    }

    @Test func anotherAccountOrRangeDimsUntilItsContentLands() {
        #expect(DashboardLoadKey.dims(shown: shown, wanted: DashboardLoadKey(accountIDs: ["codex"], range: .week, historyRevision: 4)))
        #expect(DashboardLoadKey.dims(shown: shown, wanted: DashboardLoadKey(accountIDs: ["claude"], range: .month, historyRevision: 4)))
        #expect(DashboardLoadKey.dims(shown: nil, wanted: shown))
    }
}

struct DashboardSectionsTests {
    private let antigravity = AccountConfig(id: "agy", provider: .antigravity, label: "Google")
    private let zen = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen")
    private let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go")
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Work")

    @Test func anAccountWithoutLocalLogsSkipsTheHistoryCards() {
        let status = AccountStatus(snapshot: snapshot("agy", [window("w", used: 1, minutes: 10_080, resetIn: 86_400)]))
        #expect(DashboardSections.make(account: antigravity, accounts: [antigravity, claude], status: status) == DashboardSections(history: false, limits: true))
    }

    @Test func aSpendOnlyAccountSkipsTheLimitsCard() {
        let spendOnly = AccountStatus(snapshot: UsageSnapshot(accountID: "zen", provider: .opencodeZen, fetchedAt: now, source: "test"))
        #expect(DashboardSections.make(account: zen, accounts: [zen], status: spendOnly) == DashboardSections(history: true, limits: false))
        // Before the first check nothing says it has no limits yet, so the card stays to explain the wait.
        #expect(DashboardSections.make(account: zen, accounts: [zen], status: AccountStatus()) == DashboardSections(history: true, limits: true))
    }

    /// No subscription is an answer, not a wait: there is no limit to chart, and nothing to explain in an empty card.
    @Test func anAccountWithoutASubscriptionSkipsTheLimitsCard() {
        let noSubscription = AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key"))
        #expect(DashboardSections.make(account: go, accounts: [go], status: noSubscription) == DashboardSections(history: true, limits: false))
        // A failure that needs the user keeps the card, which says what went wrong.
        #expect(DashboardSections.make(account: go, accounts: [go], status: AccountStatus(error: .unauthorized)) == DashboardSections(history: true, limits: true))
    }

    /// Devin is a link: no limits card, not even the one that explains the wait before the first check.
    @Test func aLinkOnlyAccountSkipsBothCards() {
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let link = AccountStatus(snapshot: UsageSnapshot(accountID: "devin", provider: .devin, fetchedAt: now, source: "plan page"))
        #expect(DashboardSections.make(account: devin, accounts: [devin, claude], status: link) == DashboardSections(history: false, limits: false))
        #expect(DashboardSections.make(account: devin, accounts: [devin, claude], status: AccountStatus()) == DashboardSections(history: false, limits: false))
    }

    @Test func allAccountsKeepsHistoryWhenAnyAccountHasLogs() {
        #expect(DashboardSections.make(account: nil, accounts: [antigravity, claude], status: nil) == DashboardSections(history: true, limits: true))
        #expect(DashboardSections.make(account: nil, accounts: [antigravity], status: nil) == DashboardSections(history: false, limits: true))
    }

    @Test func aFailedCheckReadsAsOneSentence() {
        func sentence(_ message: String) -> String { message.hasSuffix(".") ? message : message + "." }
        let signedOut = DashboardSections.limitsEmptyMessage(status: AccountStatus(error: .notSignedIn), anyAccountHasWindows: false)
        #expect(signedOut == "No limits yet. Last check: \(sentence(FetchError.notSignedIn.userMessage))")
        let timedOut = DashboardSections.limitsEmptyMessage(status: AccountStatus(error: .timeout), anyAccountHasWindows: false)
        #expect(timedOut == "No limits yet. Last check: \(sentence(FetchError.timeout.userMessage))")
        #expect(timedOut.hasSuffix(".") && !timedOut.hasSuffix(".."))
    }
}
