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

    private func spendStatus(_ amount: Double, of limit: Double) -> AccountStatus {
        let snapshot = UsageSnapshot(
            accountID: "work", provider: .claude, windows: [UsageWindow(id: UsageWindow.spendCapID, label: "Spend cap", usedPercent: amount / limit * 100)],
            money: [MoneyLine(label: "Extra usage", amount: amount, limit: limit, currency: "USD")], fetchedAt: now.addingTimeInterval(-60), source: "test"
        )
        return AccountStatus(snapshot: snapshot)
    }

    private func spendState(display: SpendDisplay) -> MenuBarState {
        var config = AppConfig()
        config.menuBar.spendDisplay = display
        let nearlyUnused = window("monthly", used: 0.04, minutes: 44_640, resetIn: 18 * 86_400)
        return MenuBarState.make(
            accounts: [personal, work], statuses: ["personal": status([nearlyUnused]), "work": spendStatus(473.81, of: 3000)],
            config: config, now: now
        )
    }

    private func pinnedState(_ pinned: String?, mode: MenuBarMode = .worst) -> MenuBarState {
        var config = AppConfig()
        config.menuBar.mode = mode
        let full = window("weekly", used: 100, minutes: 10_080, resetIn: 5 * 86_400)
        return MenuBarState.make(
            accounts: [personal, work], statuses: ["personal": status([full]), "work": spendStatus(473.81, of: 3000)],
            config: config, now: now, pinned: pinned
        )
    }

    /// The pinned account is the one the person cares about on this Mac, even with another account full.
    @Test func aPinnedAccountDrivesTheMenuBar() {
        let state = pinnedState("work")
        #expect(state.worst?.accountID == "work")
        let rendered = StatusIconRenderer.render(state)
        #expect(rendered.title == "16%")
        #expect(color(rendered) != .systemRed)
    }

    /// A pin on an account removed, turned off or not on this Mac falls back to the tightest account.
    @Test func aPinNotShownFallsBackToTheTightest() {
        #expect(pinnedState("gone").worst?.accountID == "personal")
        #expect(pinnedState(nil).worst?.accountID == "personal")
    }

    /// Bars draw every account, so a pin changes nothing there.
    @Test func barsIgnoreThePin() {
        #expect(pinnedState("work", mode: .bars).entries.map(\.accountID) == ["personal", "work"])
    }

    /// Past a spend limit the number is what matters; the reset countdown is for limits that stop the work.
    @Test func aSpendLimitPastFullKeepsItsPercent() {
        var status = spendStatus(3_240, of: 3000)
        status.snapshot?.windows[0].limitStyle = .overage
        status.snapshot?.windows[0].resetsAt = now.addingTimeInterval(18 * 86_400)
        let state = MenuBarState.make(accounts: [work], statuses: ["work": status], config: AppConfig(), now: now)
        #expect(StatusIconRenderer.render(state).title == "108%")
        #expect(color(StatusIconRenderer.render(state)) == .systemRed)
    }

    @Test func aSpendCapCompetesLikeAnyLimit() {
        let state = spendState(display: .percent)
        #expect(state.worst?.accountID == "work")
        #expect(StatusIconRenderer.render(state).title == "16%")
    }

    @Test func amountSpentReplacesThePercentForASpendAccount() {
        let state = spendState(display: .amount)
        #expect(state.worst?.accountID == "work")
        #expect(StatusIconRenderer.render(state).title == Format.money(473.81, currency: "USD", fractionDigits: 0, locale: .autoupdatingCurrent))
    }

    /// A Max plan with extra usage has money too, but its number is still a plan limit.
    @Test func amountSpentLeavesALimitAccountsPercent() {
        var config = AppConfig()
        config.menuBar.spendDisplay = .amount
        var max = status([weeklyOnPace])
        max.snapshot?.money = [MoneyLine(label: "Extra usage", amount: 25.5, limit: 50, currency: "USD")]
        let state = MenuBarState.make(
            accounts: [personal, work], statuses: ["personal": max, "work": spendStatus(473.81, of: 3000)], config: config, now: now
        )
        #expect(state.worst?.accountID == "personal")
        #expect(StatusIconRenderer.render(state).title == "75%")
    }

    @Test func aProjectedRunOutOutranksAHigherPercent() {
        let state = MenuBarState.make(
            accounts: [personal, work], statuses: ["personal": status([weeklyOnPace]), "work": status([sessionRunsOut])],
            config: AppConfig(), now: now
        )
        #expect(state.worst?.accountID == "work")
        #expect(state.entries.map(\.cause?.window.id) == [nil, "session"])
        let rendered = StatusIconRenderer.render(state)
        #expect(rendered.title == "60%")
        #expect(color(rendered) == .systemOrange)
    }

    /// The number is the tightest window's, but a lower window projected to run out still colors it.
    @Test func everyWindowCountsTowardTheColor() {
        let state = MenuBarState.make(accounts: [personal], statuses: ["personal": status([weeklyOnPace, sessionRunsOut])], config: AppConfig(), now: now)
        #expect(state.entries.first?.tightest?.id == "weekly")
        #expect(state.entries.first?.severity == .warning)
        #expect(state.entries.first?.cause?.window.id == "session")
        let tip = StatusIconRenderer.toolTip(for: state)
        #expect(tip == "Claude · Personal: weekly 75%, resets in 1d; session runs out ~50m before reset")
        let rendered = StatusIconRenderer.render(state)
        #expect(rendered.title == "75%")
        #expect(color(rendered) == .systemOrange)
    }

    /// At warnAt the number on the mark already explains the color.
    @Test func aWindowPastWarnAtNeedsNoCause() {
        let high = window("weekly", used: 85, minutes: 10_080, resetIn: 6 * 86_400)
        let state = MenuBarState.make(accounts: [personal], statuses: ["personal": status([high])], config: AppConfig(), now: now)
        #expect(state.entries.first?.severity == .warning)
        #expect(state.entries.first?.cause == nil)
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
        #expect(state.entries.map(\.attention) == [.transient, nil])
    }

    /// The dot and the popover header judge a failed check by one rule, so the menu bar never alarms over a blip the
    /// header calls all clear, and never stays quiet about a failure the header counts.
    @Test func theDotAndTheHeaderAgreeOnAFailedCheck() {
        func judged(_ statuses: [String: AccountStatus]) -> (dot: String?, tone: PopoverSummary.Tone) {
            let accounts = [personal, work]
            let state = MenuBarState.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
            return (state.failing?.accountID, PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now).tone)
        }
        let blipStatuses = ["personal": status([weeklyOnPace], error: .network("offline")), "work": status([weeklyOnPace])]
        let blip = judged(blipStatuses)
        #expect(blip.dot == nil)
        #expect(blip.tone == .clear)
        let bars = MenuBarState.make(accounts: [personal, work], statuses: blipStatuses, config: AppConfig(menuBar: MenuBarConfig(mode: .bars)), now: now)
        // Named as the tooltip names it, but never as a failed check.
        #expect(StatusIconRenderer.render(bars).image?.accessibilityDescription == "Tokenjar, Claude Personal 75%, Claude Work 75%, can't reach Claude Personal")

        // A connection failure is nothing for the user to fix: the header names it in gray and the dot stays off.
        let gone = judged(["personal": status([weeklyOnPace], fetchedAgo: 3_600, error: .network("offline")), "work": status([weeklyOnPace])])
        #expect(gone.dot == nil)
        #expect(gone.tone == .unreachable(onlyTimeouts: false))

        let elsewhere = judged(["personal": status([weeklyOnPace]), "work": AccountStatus(error: .timeout)])
        #expect(elsewhere.dot == nil)
        #expect(elsewhere.tone == .unreachable(onlyTimeouts: true))
    }

    @Test func offlineSlashesTheIcon() {
        let statuses = ["personal": status([weeklyOnPace], fetchedAgo: 3_600)]
        for connectivity in [Connectivity.offline, .noAnswer] {
            let state = MenuBarState.make(accounts: [personal], statuses: statuses, config: AppConfig(), now: now, connectivity: connectivity)
            #expect(state.isSlashed, "\(connectivity)")
            #expect(pixels(StatusIconRenderer.render(state).image) != pixels(StatusIconRenderer.render(MenuBarState.make(accounts: [personal], statuses: statuses, config: AppConfig(), now: now)).image))
        }
        #expect(!MenuBarState.make(accounts: [personal], statuses: statuses, config: AppConfig(), now: now).isSlashed)
        #expect(MenuBarState.make(accounts: [personal], statuses: statuses, config: AppConfig(), now: now).lastUpdated == now.addingTimeInterval(-3_600))
    }

    /// Settings that can't be read stop edits and may hold the wrong accounts: the user has to look.
    @Test func aSettingsProblemDrawsTheDot() {
        let problem = SettingsProblem(message: "Could not read config.json.", file: "config.json", nothingLoaded: false)
        let state = MenuBarState.make(accounts: [personal], statuses: ["personal": status([weeklyOnPace])], config: AppConfig(), now: now, settingsProblem: problem)
        #expect(state.showsDot)
        #expect(state.failing == nil)
        #expect(pixels(StatusIconRenderer.render(state).image) == pixels(StatusGlyph.image(.app, fraction: 0.75, tint: nil, alpha: 1, dot: true)))
        let unloaded = MenuBarState.make(accounts: [], statuses: [:], config: AppConfig(), now: now, settingsProblem: SettingsProblem(message: "x", file: "config.json", nothingLoaded: true))
        #expect(pixels(StatusIconRenderer.render(unloaded).image) == pixels(StatusGlyph.neutral(.app, dot: true)))
    }

    @Test func aConnectionFailureNeverDrawsTheDot() {
        let saved = UsageSnapshot(accountID: "work", provider: .claude, windows: [weeklyOnPace], fetchedAt: now.addingTimeInterval(-3 * 3_600), source: ClaudeUsageFetcher.cacheSource, liveCheckFailure: .timeout)
        for statuses in [
            ["personal": status([weeklyOnPace], fetchedAgo: 3_600, error: .network("offline"))],
            ["personal": AccountStatus(error: .timeout)],
            ["personal": AccountStatus(snapshot: saved, lastAttempt: now)],
        ] {
            let state = MenuBarState.make(accounts: [personal], statuses: statuses, config: AppConfig(), now: now)
            #expect(!state.showsDot)
            #expect(state.entries.first?.connectionFailure != nil)
        }
    }

    /// Zen only has spend and a Go key without a subscription has nothing at all: either would be an empty bar and a
    /// "no data" line that reads as a failure.
    @Test func accountsWithNoLimitsToShowStayOut() {
        let zen = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen", showInMenuBar: true)
        let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go")
        let spend = AccountStatus(snapshot: UsageSnapshot(accountID: "zen", provider: .opencodeZen, money: [MoneyLine(label: "Spent", amount: 3)], fetchedAt: now, source: "opencode.db"))
        let unsubscribed = AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key"))
        let calm = window("weekly", used: 3, minutes: 10_080, resetIn: 6 * 86_400)
        let state = MenuBarState.make(accounts: [zen, go, personal], statuses: ["zen": spend, "go": unsubscribed, "personal": status([calm])], config: AppConfig(), now: now)
        #expect(state.entries.map(\.accountID) == ["personal"])
        let tip = StatusIconRenderer.toolTip(for: state)
        #expect(!tip.contains("last check failed"))
        #expect(!tip.contains("OpenCode"))

        let withData = MenuBarState.make(accounts: [go], statuses: ["go": status([calm], error: .noSubscription("none"))], config: AppConfig(), now: now)
        #expect(withData.entries.map(\.attention) == [.calm])
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
