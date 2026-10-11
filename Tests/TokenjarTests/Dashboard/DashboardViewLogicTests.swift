import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

private let now = Date(timeIntervalSince1970: 1_791_660_000)

/// A window `elapsed` of the way through, so pace can judge it.
private func window(_ id: String, used: Double, minutes: Int, elapsed: Double) -> UsageWindow {
    let length = Double(minutes) * 60
    return UsageWindow(id: id, label: id, usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(length * (1 - elapsed)))
}

private func status(_ windows: [UsageWindow]) -> AccountStatus {
    AccountStatus(snapshot: UsageSnapshot(accountID: "a", provider: .claude, windows: windows, fetchedAt: now, source: "test"))
}

struct SidebarBadgeTests {
    private let config = MenuBarConfig()

    @Test func theNumberIsTheTightestWindowAndTheTintTheWorst() {
        // Week is the tightest and on pace; the 5-hour window is lower but projected to run out.
        let badge = SidebarBadge.make(
            status: status([window("Week", used: 70, minutes: 10_080, elapsed: 0.7), window("5-hour", used: 55, minutes: 300, elapsed: 0.4)]),
            config: config, now: now
        )
        #expect(badge?.percent == "70%")
        #expect(badge?.severity == .warning)
        #expect(badge?.detail == "5-hour 55%, runs out ~1h 21m before reset")
    }

    @Test func aWindowWithoutPaceSaysHowMuchIsUsed() {
        let unpaced = UsageWindow(id: "credits", label: "AI credits", usedPercent: 40)
        #expect(SidebarBadge.make(status: status([unpaced]), config: config, now: now)?.detail == "AI credits 40% used")
    }

    @Test func aWindowPastItsResetDoesNotSetTheNumber() {
        let reset = UsageWindow(id: "session", label: "5-hour", usedPercent: 96, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60))
        let badge = SidebarBadge.make(status: status([reset, window("Week", used: 30, minutes: 10_080, elapsed: 0.5)]), config: config, now: now)
        #expect(badge?.percent == "30%")
    }

    @Test func noLiveWindowGivesNoBadge() {
        #expect(SidebarBadge.make(status: AccountStatus(error: .timeout), config: config, now: now) == nil)
    }
}

struct WindowTileTextTests {
    private let config = MenuBarConfig()

    @Test func voiceOverHearsUseCountdownAndVerdict() {
        // 88 % with 50 minutes left of a 5-hour window runs out about 15 minutes early.
        let session = UsageWindow(id: "session", label: "5-hour", usedPercent: 88, windowMinutes: 300, resetsAt: now.addingTimeInterval(50 * 60))
        #expect(WindowTileText.accessibilityValue(session, config: config, now: now) == "88% used, resets in 50 minutes, runs out ~15m before reset")
    }

    @Test func aWindowPastItsResetSaysItIsUpdating() {
        let reset = UsageWindow(id: "session", label: "5-hour", usedPercent: 96, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60))
        #expect(WindowTileText.accessibilityValue(reset, config: config, now: now) == "reset, updating")
        #expect(WindowTileText.help(reset, now: now) == "5-hour has reset; the next check shows the new cycle.")
    }

    @Test func helpGivesTheEvenPaceAndTheResetTime() {
        let week = UsageWindow(id: "weekly", label: "Week", usedPercent: 40, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3.5 * 86_400))
        let help = WindowTileText.help(week, now: now)
        #expect(help.hasPrefix("40% used, even pace 50%, resets "))
    }

    @Test func aWindowThatHasNotStartedSaysSo() {
        let idle = UsageWindow(id: "session", label: "5-hour", usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(300 * 60), notStarted: true)
        #expect(WindowTileText.accessibilityValue(idle, config: config, now: now) == "not started")
    }
}

struct TopProjectsCostColumnTests {
    private let us = Locale(identifier: "en_US")

    @Test func oneRowWithCentsGivesTheWholeColumnCents() {
        #expect(TopProjectsTable.costColumn([351, 0.26], locale: us) == ["$351.00", "$0.26"])
    }

    @Test func aColumnOfWholeOrLargeAmountsDropsTheCents() {
        #expect(TopProjectsTable.costColumn([351, 120, 4], locale: us) == ["$351", "$120", "$4"])
    }

    @Test func unpricedRowsStayEmptyAndDoNotSetThePrecision() {
        #expect(TopProjectsTable.costColumn([210, nil], locale: us) == ["$210", nil])
    }
}
