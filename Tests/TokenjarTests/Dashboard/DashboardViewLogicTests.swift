import AppKit
import Foundation
import SwiftUI
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

/// The same failed check reads the same in the sidebar as in the popover's error row.
@MainActor
struct SidebarErrorIconTests {
    @Test func aFailureToFixIsOrangeAsInThePopover() {
        for error in [FetchError.notSignedIn, .unauthorized, .cliNotFound("claude")] {
            let failed = AccountStatus(error: error)
            #expect(failed.failureNeedsAttention(now: now, refreshMinutes: 10))
            #expect(
                SidebarErrorIcon.make(status: failed, provider: .claude, now: now, refreshMinutes: 10, connectivity: .online)
                    == SidebarErrorIcon(symbol: ErrorRow.symbol(for: error, needsAttention: true), isWarning: true)
            )
        }
    }

    /// A spend-only snapshot has no window to badge, so its blip shows here as the popover's gray Wi-Fi mark.
    @Test func aBlipOverFreshDataStaysGrayWithThePopoversSymbol() {
        let snapshot = UsageSnapshot(accountID: "zen", provider: .opencodeZen, fetchedAt: now.addingTimeInterval(-60), source: "opencode.db")
        let blip = AccountStatus(snapshot: snapshot, error: .network("offline"))
        #expect(SidebarErrorIcon.make(status: blip, provider: .claude, now: now, refreshMinutes: 10, connectivity: .online) == SidebarErrorIcon(symbol: "wifi.exclamationmark", isWarning: false))
    }

    /// A connection failure with nothing fresh to show is not the user's to fix, so it stays gray there too.
    @Test func aConnectionFailureWithoutDataStaysGray() {
        #expect(SidebarErrorIcon.make(status: AccountStatus(error: .timeout), provider: .claude, now: now, refreshMinutes: 10, connectivity: .online) == SidebarErrorIcon(symbol: "clock.arrow.circlepath", isWarning: false))
        #expect(SidebarErrorIcon.make(status: AccountStatus(error: .network("offline")), provider: .claude, now: now, refreshMinutes: 10, connectivity: .online) == SidebarErrorIcon(symbol: "wifi.exclamationmark", isWarning: false))
    }

    /// The header says a Mac-wide cause once, as the popover's cards drop their connection row.
    @Test func aMacWideCauseHidesTheSidebarIcon() {
        for connectivity in [Connectivity.offline, .noAnswer] {
            #expect(SidebarErrorIcon.make(status: AccountStatus(error: .timeout), provider: .copilot, now: now, refreshMinutes: 10, connectivity: connectivity) == nil)
            #expect(SidebarErrorIcon.make(status: AccountStatus(error: .network("x")), provider: .claude, now: now, refreshMinutes: 10, connectivity: connectivity) == nil)
        }
        #expect(SidebarErrorIcon.make(status: AccountStatus(error: .notSignedIn), provider: .codex, now: now, refreshMinutes: 10, connectivity: .offline)?.isWarning == true)
        #expect(SidebarErrorIcon.make(status: AccountStatus(error: .network("locked")), provider: .opencodeZen, now: now, refreshMinutes: 10, connectivity: .offline) != nil)
    }

    @Test func notSubscribedHasNoMark() {
        #expect(SidebarErrorIcon.make(status: AccountStatus(error: .noSubscription("none")), provider: .claude, now: now, refreshMinutes: 10, connectivity: .online) == nil)
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

struct LimitsTimeAxisTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let gb = Locale(identifier: "en_GB")

    /// Saturday 10 October 2026, 15:30 in New York.
    private var saturday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 30))! }

    private func axis(hours: Double) -> LimitsTimeAxis {
        LimitsTimeAxis(saturday.addingTimeInterval(-hours * 3600)...saturday, calendar: calendar, locale: gb)
    }

    /// History from Thursday afternoon at 7d: Thursday shows less than half a day, so it goes unnamed.
    @Test func newHistoryOverDaysNamesEachDayOnce() {
        let texts = axis(hours: 50).labels.map(\.text)
        #expect(texts == ["Fri 9", "Sat 10"])
        #expect(Set(texts).count == texts.count)
        #expect(axis(hours: 84).labels.map(\.text) == ["Wed 7", "Thu 8", "Fri 9", "Sat 10"])
    }

    @Test func eachDayLabelSitsInsideTheDayItNames() {
        let shown = axis(hours: 50)
        let domain = saturday.addingTimeInterval(-50 * 3600)...saturday
        for label in shown.labels {
            #expect(domain.contains(label.date))
            #expect(label.date.formatted(Date.FormatStyle(locale: gb, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).day()) == label.text)
        }
        #expect(shown.grid == [9, 10].map { calendar.date(from: DateComponents(year: 2026, month: 10, day: $0))! })
        #expect(!shown.spansHours)
    }

    /// A bare "19 01 07" under a 7d picker reads like dates of the month.
    @Test func aDayAndAHalfOrLessNamesTheDayAtMidnightAndTheTimeOtherwise() {
        #expect(axis(hours: 30).labels.map(\.text) == ["12:00", "18:00", "Sat 10", "06:00", "12:00"])
        #expect(axis(hours: 24).labels.map(\.text) == ["18:00", "Sat 10", "06:00", "12:00"])
        #expect(axis(hours: 24).spansHours)
    }

    /// Hours of new history get a label every hour or two, not a single one in the middle.
    @Test func aShortSpanLabelsEveryHourOrTwo() {
        #expect(axis(hours: 5).labels.map(\.text) == ["11:00", "12:00", "13:00", "14:00", "15:00"])
        #expect(axis(hours: 12).labels.map(\.text) == ["06:00", "08:00", "10:00", "12:00", "14:00"])
    }

    /// Centred on its tick, a label this close to either end would run past the plot.
    @Test func ticksNearEitherEndKeepTheirGridLineButNoLabel() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 11, minute: 30))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 13))!
        let shown = LimitsTimeAxis(start...end, calendar: calendar, locale: gb)
        #expect(shown.grid.map { $0.formatted(Date.FormatStyle(locale: gb, calendar: calendar, timeZone: calendar.timeZone).hour().minute()) } == ["12:00", "18:00", "00:00", "06:00", "12:00"])
        #expect(shown.labels.map(\.text) == ["18:00", "Sat 10", "06:00"])
    }
}

@MainActor
struct DashboardSidebarFocusTests {
    /// Never ordered in, and parked off every display in case anything orders it in. Reports itself key, as the window
    /// renderer's capture window does, so SwiftUI treats it as the active window.
    private final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Without focus the sidebar draws its selection in gray and ignores the arrow keys.
    @Test func theSidebarTakesFocusWhenTheWindowIsLeftWithNone() async throws {
        let model = AppModel.preview()
        model.secrets = SessionSecretStore(InMemorySecretStore())
        let window = OffscreenWindow(contentViewController: NSHostingController(rootView: DashboardSidebar().environment(model)))
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let content = try #require(window.contentView)
        let list = try #require(views(in: content).first { $0 is NSTableView })
        // Where AppKit puts the focus when the window becomes key, before anything takes it away.
        #expect(window.makeFirstResponder(list))

        window.makeFirstResponder(nil)
        // Generous because a full parallel run of main-actor tests has stretched this test to nearly 7 s.
        try await waitUntil({ window.firstResponder === list }, turns: 2_000)
    }
}

struct LimitsThresholdLabelTests {
    /// Guards against a color name returning to the label; the rule is already drawn in that color.
    @Test func theLabelIsTheLevelAlone() {
        #expect(LimitsChart.thresholdLabel(80) == "80%")
        #expect(LimitsChart.thresholdLabel(95) == "95%")
    }

    @Test func voiceOverHearsWhatEachRuleMeans() {
        #expect(LimitsChart.thresholdAccessibilityLabel(80, severity: .warning) == "Turns amber at 80%")
        #expect(LimitsChart.thresholdAccessibilityLabel(95, severity: .critical) == "Turns red at 95%")
    }
}

@MainActor
struct HeaderSubtitleTests {
    /// "Updated" is the newest success, and a Mac-wide cause is said once, in the subtitle.
    @Test func allSubtitleShowsTheLastSuccessAndTheState() {
        let updated = now.addingTimeInterval(-25 * 60)
        #expect(HeaderSubtitle.allText(accountCount: 3, lastUpdated: updated, connectivity: .online, now: now) == "3 accounts · updated 25m ago")
        #expect(HeaderSubtitle.allText(accountCount: 3, lastUpdated: updated, connectivity: .offline, now: now) == "3 accounts · updated 25m ago · offline")
        #expect(HeaderSubtitle.allText(accountCount: 1, lastUpdated: updated, connectivity: .noAnswer, now: now) == "1 account · updated 25m ago · can't reach any provider")
    }

    @Test func anAccountSubtitleSaysTheCauseOnce() {
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let stale = AccountStatus(
            snapshot: UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: now.addingTimeInterval(-25 * 60), source: "claude CLI"),
            error: .network("offline")
        )
        #expect(HeaderSubtitle.accountText(account: claude, status: stale, connectivity: .offline, now: now) == "claude CLI · updated 25m ago · offline")
        #expect(HeaderSubtitle.accountText(account: claude, status: stale, connectivity: .noAnswer, now: now) == "claude CLI · updated 25m ago · can't reach any provider")
        #expect(HeaderSubtitle.accountText(account: claude, status: stale, connectivity: .online, now: now)
            == "claude CLI · updated 25m ago · \(FetchError.network("offline").userMessage(provider: .claude))")
        #expect(HeaderSubtitle.accountText(account: claude, status: AccountStatus(error: .notSignedIn), connectivity: .offline, now: now)
            == FetchError.notSignedIn.userMessage(provider: .claude))
    }
}

struct TileRowsLayoutTests {
    /// Two rows when one does not fit, the longer first, so the cost tiles share a row and no row ends in an empty cell.
    @Test func tilesSplitIntoTwoRowsWithTheLongerFirst() {
        let layout = TileRowsLayout()
        #expect(layout.rows(width: 600, count: 5) == [0..<3, 3..<5])
        #expect(layout.rows(width: 600, count: 7) == [0..<4, 4..<7])
        #expect(layout.rows(width: 600, count: 8) == [0..<4, 4..<8])
        #expect(layout.rows(width: 600, count: 3) == [0..<3])
        #expect(layout.rows(width: 2_000, count: 7) == [0..<7])
    }
}
