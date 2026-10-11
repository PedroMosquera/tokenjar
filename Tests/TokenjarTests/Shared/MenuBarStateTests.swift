import AppKit
import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func window(_ id: String, used: Double, minutes: Int, resetIn: TimeInterval) -> UsageWindow {
    UsageWindow(id: id, label: id, usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetIn))
}

/// 75 % of a week with a day left is on pace (ok); 60 % of a 5-hour window halfway through runs out about 50
/// minutes early (warning).
private let weeklyOnPace = window("weekly", used: 75, minutes: 10_080, resetIn: 86_400)
private let sessionRunsOut = window("session", used: 60, minutes: 300, resetIn: 150 * 60)

private func status(_ windows: [UsageWindow], fetchedAgo: TimeInterval = 60, error: FetchError? = nil) -> AccountStatus {
    AccountStatus(snapshot: UsageSnapshot(accountID: "x", provider: .claude, windows: windows, fetchedAt: now.addingTimeInterval(-fetchedAgo), source: "test"), error: error)
}

@MainActor
struct MenuBarStateTests {
    private let personal = AccountConfig(id: "personal", provider: .claude, label: "Personal")
    private let work = AccountConfig(id: "work", provider: .claude, label: "Work")

    private func color(_ rendered: RenderedStatusIcon) -> NSColor? {
        guard rendered.attributedTitle.length > 0 else { return nil }
        return rendered.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    @Test func aProjectedRunOutOutranksAHigherPercent() {
        let state = MenuBarState.make(
            accounts: [personal, work], statuses: ["personal": status([weeklyOnPace]), "work": status([sessionRunsOut])],
            config: AppConfig(), now: now
        )
        #expect(state.worst?.accountID == "work")
        let rendered = StatusIconRenderer.render(state)
        #expect(rendered.title == "60%")
        #expect(color(rendered) == .systemOrange)
    }

    /// The number is the tightest window's, but a lower window projected to run out still colors it.
    @Test func everyWindowCountsTowardTheColor() {
        let state = MenuBarState.make(accounts: [personal], statuses: ["personal": status([weeklyOnPace, sessionRunsOut])], config: AppConfig(), now: now)
        #expect(state.entries.first?.tightest?.id == "weekly")
        #expect(state.entries.first?.severity == .warning)
        let rendered = StatusIconRenderer.render(state)
        #expect(rendered.title == "75%")
        #expect(color(rendered) == .systemOrange)
    }

    @Test func staleUsesTheAccountsOwnInterval() {
        var fast = personal
        fast.refreshMinutes = 1
        let state = MenuBarState.make(
            accounts: [fast, work], statuses: ["personal": status([weeklyOnPace], fetchedAgo: 180), "work": status([weeklyOnPace], fetchedAgo: 180)],
            config: AppConfig(refreshMinutes: 10), now: now
        )
        #expect(state.entries.map(\.isStale) == [true, false])
    }

    /// A Devin link card has no window: in the menu bar it would be an empty bar and a "no data" line that reads
    /// like a failure, even when showInMenuBar was set by hand.
    @Test func aLinkOnlyAccountStaysOutOfTheMenuBar() {
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin", showInMenuBar: true)
        let link = AccountStatus(snapshot: UsageSnapshot(accountID: "devin", provider: .devin, fetchedAt: now, source: "plan page", notes: ["note"]))
        let calm = window("weekly", used: 3, minutes: 10_080, resetIn: 6 * 86_400)
        let state = MenuBarState.make(accounts: [devin, personal], statuses: ["devin": link, "personal": status([calm])], config: AppConfig(), now: now)
        #expect(state.entries.map(\.accountID) == ["personal"])
        #expect(!StatusIconRenderer.toolTip(for: state).contains("Devin"))
        #expect(StatusIconRenderer.render(state).title == "3%")

        let alone = MenuBarState.make(accounts: [devin], statuses: ["devin": link], config: AppConfig(), now: now)
        #expect(alone.entries.isEmpty)
        #expect(StatusIconRenderer.toolTip(for: alone) == "Tokenjar: no accounts in the menu bar")
    }

    /// A full window whose reset has passed would read "<1m" in red until the next check lands.
    @Test func aWindowPastItsResetIsNotTheTightest() {
        let reset = window("session", used: 100, minutes: 300, resetIn: -60)
        let alone = MenuBarState.make(accounts: [personal], statuses: ["personal": status([reset])], config: AppConfig(), now: now)
        #expect(StatusIconRenderer.render(alone).title != "<1m")
        #expect(alone.entries.first?.severity == .ok)

        let calm = window("weekly", used: 30, minutes: 10_080, resetIn: 5 * 86_400)
        let beside = MenuBarState.make(accounts: [personal], statuses: ["personal": status([reset, calm])], config: AppConfig(), now: now)
        #expect(StatusIconRenderer.render(beside).title == "30%")
    }

    @Test func theIconComesFromTheConfig() {
        #expect(MenuBarState.make(accounts: [personal], statuses: [:], config: AppConfig(), now: now).icon == .app)
        let picked = AppConfig(menuBar: MenuBarConfig(icon: .symbolGauge))
        #expect(MenuBarState.make(accounts: [personal], statuses: [:], config: picked, now: now).icon == .symbolGauge)
    }

    @Test func aFailedCheckIsFlagged() {
        let state = MenuBarState.make(
            accounts: [personal, work], statuses: ["personal": status([weeklyOnPace], error: .timeout), "work": status([weeklyOnPace])],
            config: AppConfig(), now: now
        )
        #expect(state.entries.map(\.hasError) == [true, false])
    }
}

struct AccountStatusTests {
    @Test func dataTurnsStaleAfterTwiceTheInterval() {
        #expect(!status([], fetchedAgo: 1_199).isStale(now: now, refreshMinutes: 10))
        #expect(status([], fetchedAgo: 1_201).isStale(now: now, refreshMinutes: 10))
        #expect(!status([], fetchedAgo: 119).isStale(now: now, refreshMinutes: 0))
        #expect(status([], fetchedAgo: 121).isStale(now: now, refreshMinutes: 0))
        #expect(!AccountStatus().isStale(now: now, refreshMinutes: 10))
    }
}
