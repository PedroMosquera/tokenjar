import AppKit
import Foundation
import Testing
@testable import Headroom
import HeadroomCore

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func window(_ id: String, _ label: String, used: Double, minutes: Int = 300, resetIn: TimeInterval?, notStarted: Bool = false) -> UsageWindow {
    UsageWindow(id: id, label: label, usedPercent: used, windowMinutes: minutes, resetsAt: resetIn.map { now.addingTimeInterval($0) }, notStarted: notStarted)
}

private func snapshot(_ accountID: String, _ windows: [UsageWindow], plan: String? = nil) -> UsageSnapshot {
    UsageSnapshot(accountID: accountID, provider: .claude, plan: plan, windows: windows, fetchedAt: now, source: "test")
}

@MainActor
struct PaceVerdictTests {
    @Test func evenUsageIsOnPace() throws {
        let verdict = try #require(PaceVerdict.make(windows: [window("session", "5-hour", used: 52, resetIn: 150 * 60)], config: MenuBarConfig(), now: now))
        #expect(verdict.kind == .onPace)
        #expect(verdict.text == "On pace")
    }

    @Test func earlyOveruseBelowHalfIsAheadNotRunsOut() throws {
        let verdict = try #require(PaceVerdict.make(windows: [window("session", "5-hour", used: 40, resetIn: 225 * 60)], config: MenuBarConfig(), now: now))
        #expect(verdict.kind == .ahead(15))
        #expect(verdict.text == "Ahead of pace +15%")
    }

    @Test func projectedExhaustionPastHalfReportsTheGap() throws {
        // 88 % after 250 of 300 minutes: 100 % lands at about 34 m, the reset is in 50 m.
        let verdict = try #require(PaceVerdict.make(windows: [window("session", "5-hour", used: 88, resetIn: 50 * 60)], config: MenuBarConfig(), now: now))
        guard case .runsOut(let gap) = verdict.kind else {
            Issue.record("expected runsOut, got \(verdict.kind)")
            return
        }
        #expect(abs(gap - 954.5) < 1)
        #expect(verdict.text == "Runs out ~15m before reset")
        #expect(verdict.window.label == "5-hour")
    }

    @Test func fullWindowSaysLimitReachedInsteadOfAProjection() throws {
        let verdict = try #require(PaceVerdict.make(windows: [window("session", "5-hour", used: 100, resetIn: 25 * 60)], config: MenuBarConfig(), now: now))
        #expect(verdict.kind == .exhausted(25 * 60))
        #expect(verdict.text == "Limit reached, resets in 25m")
    }

    @Test func underuseIsUnderPace() throws {
        let verdict = try #require(PaceVerdict.make(windows: [window("session", "5-hour", used: 20, resetIn: 150 * 60)], config: MenuBarConfig(), now: now))
        #expect(verdict.text == "Under pace -30%")
    }

    @Test func skipsWindowsTooEarlyOrIdleToProject() throws {
        let windows = [
            window("session", "5-hour", used: 99, resetIn: 299 * 60),
            window("idle", "Idle", used: 0, resetIn: 300 * 60, notStarted: true),
            window("weekly", "Week", used: 30, minutes: 10_080, resetIn: 3 * 86_400),
            window("monthly", "Month", used: 70, minutes: 43_200, resetIn: 15 * 86_400),
        ]
        let verdict = try #require(PaceVerdict.make(windows: windows, config: MenuBarConfig(), now: now))
        #expect(verdict.window.label == "Month")
    }

    @Test func aWindowThatRunsOutOutranksAMoreUsedWindowOnPace() throws {
        // 60 % at half time reaches 100 % at 100 m, 50 m before its reset; the week is on pace at a higher %.
        let windows = [
            window("session", "5-hour", used: 60, resetIn: 150 * 60),
            window("weekly", "Week", used: 70, minutes: 10_080, resetIn: 2 * 86_400),
        ]
        let verdict = try #require(PaceVerdict.make(windows: windows, config: MenuBarConfig(), now: now))
        #expect(verdict.window.label == "5-hour")
        #expect(verdict.text == "Runs out ~50m before reset")
    }

    @Test func aFullWindowOutranksOneThatRunsOut() throws {
        let windows = [
            window("session", "5-hour", used: 88, resetIn: 50 * 60),
            window("weekly", "Week", used: 100, minutes: 10_080, resetIn: 2 * 86_400),
        ]
        let verdict = try #require(PaceVerdict.make(windows: windows, config: MenuBarConfig(), now: now))
        #expect(verdict.window.label == "Week")
        #expect(verdict.kind == .exhausted(2 * 86_400))
    }

    /// A projection that runs out less than 15 minutes early is noise; it must not turn a bar amber.
    @Test func shortProjectedShortfallIsNotAmber() {
        let window = window("session", "5-hour", used: 55, resetIn: 140 * 60)
        #expect(Severity.of(window, config: MenuBarConfig(), now: now) == .ok)
    }

    @Test func noVerdictWithoutAPace() {
        #expect(PaceVerdict.make(windows: [window("session", "5-hour", used: 10, resetIn: nil)], config: MenuBarConfig(), now: now) == nil)
        #expect(PaceVerdict.make(windows: [], config: MenuBarConfig(), now: now) == nil)
    }
}

@MainActor
struct PopoverSummaryTests {
    private let accounts = [
        AccountConfig(id: "personal", provider: .claude, label: "Personal"),
        AccountConfig(id: "work", provider: .claude, label: "Work"),
    ]

    @Test func namesTheWorstAccountAndWindow() {
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [window("session", "5-hour", used: 42, resetIn: 130 * 60)])),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: MenuBarConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .warning, text: "Claude · Work: 5-hour at 88%"))
    }

    @Test func criticalTone() {
        let statuses = ["personal": AccountStatus(snapshot: snapshot("personal", [window("weekly", "Week", used: 96, minutes: 10_080, resetIn: 3 * 86_400)]))]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: MenuBarConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .critical, text: "Claude · Personal: Week at 96%"))
    }

    @Test func severityOutranksAHigherPercent() {
        // 75 % with a day left is under pace (ok); 60 % at half time projects exhaustion (warning).
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [window("weekly", "Week", used: 75, minutes: 10_080, resetIn: 86_400)])),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 60, resetIn: 150 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: MenuBarConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .warning, text: "Claude · Work: 5-hour at 60%"))
    }

    @Test func fullWindowShowsTheResetCountdown() {
        let statuses = ["work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 100, resetIn: 50 * 60)]))]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: MenuBarConfig(), now: now)
        #expect(summary.text == "Claude · Work: 5-hour full, resets in 50m")
    }

    @Test func allClearNamesTheNextResetOfAWindowInUse() {
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [
                window("session", "5-hour", used: 0, resetIn: 60 * 60, notStarted: true),
                window("weekly", "Week", used: 20, minutes: 10_080, resetIn: 6 * 86_400),
            ])),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 10, resetIn: 130 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: MenuBarConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .clear, text: "All clear · next reset in 2h 10m"))
    }

    @Test func errorsWithoutPressureNeedAttention() {
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [window("session", "5-hour", used: 10, resetIn: 130 * 60)])),
            "work": AccountStatus(error: .notSignedIn),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: MenuBarConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .problem, text: "1 account needs attention"))
    }

    @Test func emptyStates() {
        #expect(PopoverSummary.make(accounts: [], statuses: [:], config: MenuBarConfig(), now: now) == PopoverSummary(tone: .empty, text: "No accounts yet"))
        #expect(PopoverSummary.make(accounts: accounts, statuses: [:], config: MenuBarConfig(), now: now) == PopoverSummary(tone: .empty, text: "Waiting for usage data"))
    }
}

@MainActor
struct AccountTitleTests {
    @Test func dropsLabelsAndPlansThatRepeatTheName() {
        let go = AccountTitle(provider: .opencodeGo, label: "Go", plan: "Go")
        #expect(go.name == "OpenCode Go")
        #expect(go.plan == nil)
        let codex = AccountTitle(provider: .codex, label: "Plus", plan: "Plus")
        #expect(codex.name == "Codex · Plus")
        #expect(codex.plan == nil)
        let work = AccountTitle(provider: .claude, label: "Work", plan: "Enterprise")
        #expect(work.name == "Claude · Work")
        #expect(work.plan == "Enterprise")
    }
}

@MainActor
struct BurnUpChartTests {
    @Test func dropsTheBoundarySampleFromThePreviousCycle() {
        let weekly = window("weekly", "Week", used: 40, minutes: 10_080, resetIn: 3 * 86_400)
        let start = weekly.resetsAt!.addingTimeInterval(-7 * 86_400)
        let samples = [
            WindowSample(accountID: "a", windowID: "weekly", timestamp: start, usedPercent: 97, resetsAt: start),
            WindowSample(accountID: "a", windowID: "weekly", timestamp: start.addingTimeInterval(3600), usedPercent: 1, resetsAt: weekly.resetsAt),
            WindowSample(accountID: "a", windowID: "weekly", timestamp: now.addingTimeInterval(-3600), usedPercent: 39, resetsAt: weekly.resetsAt),
        ]
        let points = BurnUpChart.points(samples: samples, window: weekly, start: start, now: now)
        #expect(points.map(\.used) == [1, 39, 40])
        #expect(points.last?.date == now)
    }

    @Test func aFreshSampleTakesTheLiveValueInsteadOfAddingAPoint() {
        let weekly = window("weekly", "Week", used: 40, minutes: 10_080, resetIn: 3 * 86_400)
        let start = weekly.resetsAt!.addingTimeInterval(-7 * 86_400)
        let samples = [WindowSample(accountID: "a", windowID: "weekly", timestamp: now.addingTimeInterval(-10), usedPercent: 38, resetsAt: weekly.resetsAt)]
        #expect(BurnUpChart.points(samples: samples, window: weekly, start: start, now: now).map(\.used) == [40])
    }

    @Test func prefersTheWeeklyWindowElseTheLongest() {
        let session = window("session", "5-hour", used: 10, resetIn: 3600)
        let weekly = window("weekly", "Week", used: 10, minutes: 10_080, resetIn: 86_400)
        let monthly = window("monthly", "Month", used: 10, minutes: 43_200, resetIn: 86_400)
        #expect(BurnUpChart.chartWindow(in: [session, monthly, weekly])?.id == "weekly")
        #expect(BurnUpChart.chartWindow(in: [session, monthly])?.id == "monthly")
        let idleWeekly = window("weekly", "Week", used: 0, minutes: 10_080, resetIn: 7 * 86_400, notStarted: true)
        #expect(BurnUpChart.chartWindow(in: [session, idleWeekly])?.id == "session")
    }
}

@MainActor
struct StatusIconRendererTests {
    private func entry(_ id: String, used: Double?, severity: Severity = .ok, resetIn: TimeInterval? = 50 * 60, stale: Bool = false, error: Bool = false) -> MenuBarState.Entry {
        MenuBarState.Entry(
            accountID: id, provider: .claude, label: id,
            tightest: used.map { window("session", "5-hour", used: $0, resetIn: resetIn) },
            severity: severity, isStale: stale, hasError: error
        )
    }

    private func state(_ entries: [MenuBarState.Entry], mode: MenuBarMode = .worst, countdown: Bool = true) -> MenuBarState {
        MenuBarState(mode: mode, entries: entries, showResetCountdownWhenFull: countdown, now: now)
    }

    private func color(_ rendered: RenderedStatusIcon) -> NSColor? {
        guard rendered.attributedTitle.length > 0 else { return nil }
        return rendered.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    @Test func showsTheTightestPercentInTheMenuBarColor() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: 42), entry("b", used: 63)]))
        #expect(rendered.title == "63%")
        #expect(rendered.attributedTitle.string == "63%")
        #expect(color(rendered) == nil)
        #expect(rendered.image?.isTemplate == true)
    }

    @Test func fullWindowShowsTheCountdownOnlyWhenEnabled() {
        #expect(StatusIconRenderer.render(state([entry("a", used: 100, severity: .critical)])).title == "50m")
        #expect(StatusIconRenderer.render(state([entry("a", used: 100, severity: .critical)], countdown: false)).title == "100%")
        #expect(StatusIconRenderer.render(state([entry("a", used: 100, severity: .critical, resetIn: nil)])).title == "100%")
    }

    @Test func severityTintsTextAndLogo() {
        let warning = StatusIconRenderer.render(state([entry("a", used: 85, severity: .warning)]))
        #expect(color(warning) == .systemOrange)
        #expect(warning.image?.isTemplate == false)
        let critical = StatusIconRenderer.render(state([entry("a", used: 97, severity: .critical)]))
        #expect(color(critical) == .systemRed)
    }

    @Test func staleDataIsDimmed() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: 42, stale: true)]))
        #expect(color(rendered) == .secondaryLabelColor)
        let warning = StatusIconRenderer.render(state([entry("a", used: 85, severity: .warning, stale: true)]))
        #expect(color(warning) == NSColor.systemOrange.withAlphaComponent(0.5))
    }

    @Test func errorAddsADotBesideTheGlyph() {
        let plain = StatusIconRenderer.render(state([entry("a", used: 42)]))
        let failing = StatusIconRenderer.render(state([entry("a", used: 42, error: true)]))
        #expect((failing.image?.size.width ?? 0) > (plain.image?.size.width ?? 0))
    }

    @Test func noDataShowsTheNeutralGaugeWithoutText() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: nil)]))
        #expect(rendered.title.isEmpty)
        #expect(rendered.attributedTitle.length == 0)
        #expect(rendered.image?.isTemplate == true)
        #expect(rendered.image?.accessibilityDescription == "Headroom")
    }

    @Test func barsModeDrawsOneBarPerEntry() {
        let ok = StatusIconRenderer.render(state([entry("a", used: 10), entry("b", used: 20), entry("c", used: 30)], mode: .bars))
        #expect(ok.title.isEmpty)
        #expect(ok.image?.size == NSSize(width: 3 * 3 + 2 * 2, height: 18))
        #expect(ok.image?.isTemplate == true)
        let colored = StatusIconRenderer.render(state([entry("a", used: 10), entry("b", used: 90, severity: .warning)], mode: .bars))
        #expect(colored.image?.isTemplate == false)
    }

    @Test func iconModeHasNoText() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: 97, severity: .critical)], mode: .icon))
        #expect(rendered.title.isEmpty)
        #expect(rendered.image?.isTemplate == false)
    }

    @Test func toolTipListsEveryAccount() {
        let tip = StatusIconRenderer.render(state([entry("Personal", used: 42), entry("Work", used: nil, error: true)])).toolTip ?? ""
        #expect(tip == "Claude · Personal: 5-hour 42%, resets in 50m\nClaude · Work: no data (last check failed)")
    }
}
