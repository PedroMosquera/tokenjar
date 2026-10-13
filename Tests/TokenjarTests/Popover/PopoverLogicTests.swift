import AppKit
import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func window(_ id: String, _ label: String, used: Double, minutes: Int = 300, resetIn: TimeInterval?, notStarted: Bool = false) -> UsageWindow {
    UsageWindow(id: id, label: label, usedPercent: used, windowMinutes: minutes, resetsAt: resetIn.map { now.addingTimeInterval($0) }, notStarted: notStarted)
}

private func snapshot(_ accountID: String, _ windows: [UsageWindow], plan: String? = nil, fetchedAgo: TimeInterval = 0) -> UsageSnapshot {
    UsageSnapshot(accountID: accountID, provider: .claude, plan: plan, windows: windows, fetchedAt: now.addingTimeInterval(-fetchedAgo), source: "test")
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

    /// Past its reset a window still carries the old cycle's use until the next check replaces it.
    @Test func aWindowPastItsResetIsOk() {
        #expect(Severity.of(window("session", "5-hour", used: 100, resetIn: -60), config: MenuBarConfig(), now: now) == .ok)
        #expect(Severity.of(window("session", "5-hour", used: 100, resetIn: 60), config: MenuBarConfig(), now: now) == .critical)
    }

    @Test func aWindowThatRunsOutOutranksAnAheadWindowOfEqualSeverity() throws {
        // Both are warnings: the 5-hour runs out 50 m early, the week is past warnAt but only 6 % elapsed, so it can
        // only be "ahead". The run-out has to win over the higher used %.
        let windows = [
            window("session", "5-hour", used: 60, resetIn: 150 * 60),
            window("weekly", "Week", used: 85, minutes: 10_080, resetIn: 0.94 * 604_800),
        ]
        let verdict = try #require(PaceVerdict.make(windows: windows, config: MenuBarConfig(), now: now))
        #expect(verdict.window.label == "5-hour")
        #expect(verdict.text == "Runs out ~50m before reset")
    }

    /// A week locked out for 41 hours explains an orange Week bar; a 5-hour that runs out 15 minutes early does not.
    @Test func theLongerLockoutWinsAmongRunOuts() throws {
        let windows = [
            window("session", "5-hour", used: 88, resetIn: 50 * 60),
            window("weekly", "Week", used: 71, minutes: 10_080, resetIn: 3 * 86_400 + 6 * 3_600),
        ]
        let verdict = try #require(PaceVerdict.make(windows: windows, config: MenuBarConfig(), now: now))
        #expect(verdict.window.label == "Week")
        guard case .runsOut(let gap) = verdict.kind else {
            Issue.record("expected runsOut, got \(verdict.kind)")
            return
        }
        #expect(abs(gap - 41.2 * 3_600) < 0.1 * 3_600)
    }

    @Test func aRunOutVerdictIsAtLeastAWarning() {
        let calm = window("session", "5-hour", used: 40, resetIn: 150 * 60)
        #expect(PaceVerdict(window: calm, kind: .runsOut(1_000)).severity(config: MenuBarConfig(), now: now) == .warning)
        #expect(PaceVerdict(window: calm, kind: .ahead(20)).severity(config: MenuBarConfig(), now: now) == .ok)
        let full = window("session", "5-hour", used: 100, resetIn: 25 * 60)
        #expect(PaceVerdict(window: full, kind: .exhausted(1_500)).severity(config: MenuBarConfig(), now: now) == .critical)
    }

    /// A card with one window already names it in the row above; with several the name leads, so a wrap never starts
    /// a line with "·" and never splits the label.
    @Test func theVerdictLeadsWithItsWindowOnlyOnACardWithSeveral() {
        let pooled = window("claude-and-gpt:weekly", "Claude and GPT · Week", used: 71, minutes: 10_080, resetIn: 4 * 86_400)
        let gemini = window("gemini:weekly", "Gemini · Week", used: 38, minutes: 10_080, resetIn: 4 * 86_400)
        let idle = window("session", "5-hour", used: 0, resetIn: 300 * 60, notStarted: true)
        #expect(!VerdictLine.namesWindow(among: [pooled]))
        #expect(!VerdictLine.namesWindow(among: [idle, pooled]))
        #expect(VerdictLine.namesWindow(among: [gemini, pooled]))
        #expect(VerdictLine.windowLead("Claude and GPT · Week") == "Claude\u{00A0}and\u{00A0}GPT\u{00A0}·\u{00A0}Week:")
    }

    /// 2 of 5,000 credits is "under pace" by any measure, and saying so is noise.
    @Test func noVerdictForAWindowUnderOnePercent() {
        let credits = window("monthly", "AI credits", used: 0.04, minutes: 44_640, resetIn: 20 * 86_400)
        #expect(PaceVerdict.make(windows: [credits], config: MenuBarConfig(), now: now) == nil)
        let used = window("monthly", "AI credits", used: 1, minutes: 44_640, resetIn: 20 * 86_400)
        #expect(PaceVerdict.make(windows: [used], config: MenuBarConfig(), now: now) != nil)
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
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .warning, text: "Claude · Work: 5-hour at 88%"))
    }

    @Test func criticalTone() {
        let statuses = ["personal": AccountStatus(snapshot: snapshot("personal", [window("weekly", "Week", used: 96, minutes: 10_080, resetIn: 3 * 86_400)]))]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .critical, text: "Claude · Personal: Week at 96%"))
    }

    @Test func severityOutranksAHigherPercent() {
        // 75 % with a day left is under pace (ok); 60 % at half time projects exhaustion (warning).
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [window("weekly", "Week", used: 75, minutes: 10_080, resetIn: 86_400)])),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 60, resetIn: 150 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .warning, text: "Claude · Work: 5-hour at 60%"))
    }

    @Test func fullWindowShowsTheResetCountdown() {
        let statuses = ["work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 100, resetIn: 50 * 60)]))]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.text == "Claude · Work: 5-hour full, resets in 50m")
    }

    @Test func aWindowPastItsResetIsNotFull() {
        let statuses = ["work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 100, resetIn: -60)]))]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.tone != .critical)
        #expect(!summary.text.contains("full"))
    }

    @Test func allClearNamesTheNextResetOfAWindowInUse() {
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [
                window("session", "5-hour", used: 0, resetIn: 60 * 60, notStarted: true),
                window("weekly", "Week", used: 20, minutes: 10_080, resetIn: 6 * 86_400),
            ])),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 10, resetIn: 130 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .clear, text: "All clear · next reset in 2h 10m"))
    }

    @Test func errorsWithoutPressureNeedAttention() {
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [window("session", "5-hour", used: 10, resetIn: 130 * 60)])),
            "work": AccountStatus(error: .notSignedIn),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .problem, text: "1 account needs attention"))
    }

    @Test func listsTheOtherAccountsThatAreLowInConfigOrder() {
        let accounts = [
            AccountConfig(id: "work", provider: .claude, label: "Work"),
            AccountConfig(id: "go", provider: .opencodeGo, label: "Go"),
            AccountConfig(id: "personal", provider: .claude, label: "Personal"),
            AccountConfig(id: "agy", provider: .antigravity, label: "Google"),
        ]
        let statuses = [
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
            "go": AccountStatus(snapshot: snapshot("go", [window("monthly", "Month", used: 61, minutes: 43_200, resetIn: 12 * 86_400)])),
            "personal": AccountStatus(snapshot: snapshot("personal", [window("session", "5-hour", used: 42, resetIn: 130 * 60)])),
            "agy": AccountStatus(snapshot: snapshot("agy", [window("pool:weekly", "Pool · Week", used: 71, minutes: 10_080, resetIn: 4 * 86_400)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.text == "Claude · Work: 5-hour at 88%")
        // Only accounts that share a provider need their label to tell them apart.
        #expect(summary.others == ["OpenCode Go", "Antigravity"])
    }

    @Test func aFailingAccountIsListedBesideAWarning() {
        let statuses = [
            "personal": AccountStatus(error: .notSignedIn),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.tone == .warning)
        #expect(summary.others == ["Claude · Personal"])
    }

    @Test func aLinkOnlyAccountNeverNeedsAttention() {
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let statuses = [
            "devin": AccountStatus(snapshot: UsageSnapshot(accountID: "devin", provider: .devin, fetchedAt: now, source: "plan page", notes: ["note"])),
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 10, resetIn: 130 * 60)])),
        ]
        let summary = PopoverSummary.make(accounts: [devin, accounts[1]], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .clear, text: "All clear · next reset in 2h 10m"))
    }

    /// Devin's card is ready the moment the app starts, so it cannot stand in for the accounts still being checked,
    /// and on its own it has no limits to call clear.
    @Test func aLinkOnlyAccountIsNotUsageData() {
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let statuses = ["devin": AccountStatus(snapshot: UsageSnapshot(accountID: "devin", provider: .devin, fetchedAt: now, source: "plan page", notes: ["note"]))]
        let waiting = PopoverSummary.make(accounts: [devin, accounts[1]], statuses: statuses, config: AppConfig(), now: now)
        #expect(waiting == PopoverSummary(tone: .empty, text: "Waiting for usage data"))
        let alone = PopoverSummary.make(accounts: [devin], statuses: statuses, config: AppConfig(), now: now)
        #expect(alone == PopoverSummary(tone: .empty, text: "No limits to track"))
    }

    @Test func emptyStates() {
        #expect(PopoverSummary.make(accounts: [], statuses: [:], config: AppConfig(), now: now) == PopoverSummary(tone: .empty, text: "No accounts yet"))
        #expect(PopoverSummary.make(accounts: accounts, statuses: [:], config: AppConfig(), now: now) == PopoverSummary(tone: .empty, text: "Waiting for usage data"))
    }

    /// With no accounts there is nothing to update, so "No accounts yet" stands alone instead of over "Not updated yet".
    @MainActor
    @Test func theUpdateLineIsLeftOutWithoutAccounts() {
        func line(_ hasAccounts: Bool, refreshing: Bool = false, updatedAgo: TimeInterval?) -> String? {
            PopoverHeader.updateLine(
                hasAccounts: hasAccounts, isRefreshing: refreshing, lastUpdated: updatedAgo.map { now.addingTimeInterval(-$0) },
                connectivity: .online, nextCheck: nil, now: now
            )
        }
        #expect(line(false, updatedAgo: nil) == nil)
        #expect(line(false, updatedAgo: 60) == nil)
        #expect(line(true, updatedAgo: nil) == "Not updated yet")
        #expect(line(true, refreshing: true, updatedAgo: nil) == "Updating")
        #expect(line(true, updatedAgo: 60) == "Updated 1m ago")
    }

    /// The second line says how old the numbers are and what happens next, so the title can stay one or two words.
    @MainActor
    @Test func updateLineSaysWhatHappensNext() {
        let ago25m = now.addingTimeInterval(-25 * 60)
        func line(_ connectivity: Connectivity, updated: Date? = ago25m, next: Date? = nil, refreshing: Bool = false) -> String? {
            PopoverHeader.updateLine(hasAccounts: true, isRefreshing: refreshing, lastUpdated: updated, connectivity: connectivity, nextCheck: next, now: now)
        }
        #expect(line(.offline) == "Updated 25m ago. Tokenjar checks again when the Mac is back online.")
        #expect(line(.offline, updated: nil) == "Tokenjar checks when the Mac is back online.")
        #expect(line(.noAnswer, next: now.addingTimeInterval(5 * 60)) == "Updated 25m ago. Tokenjar tries again in 5m.")
        #expect(line(.noAnswer, next: now.addingTimeInterval(20)) == "Updated 25m ago. Tokenjar tries again in under a minute.")
        #expect(line(.noAnswer, next: now.addingTimeInterval(-90)) == "Updated 25m ago. Tokenjar tries again in under a minute.")
        #expect(line(.noAnswer) == "Updated 25m ago. Tokenjar tries again at the next refresh.")
        #expect(line(.noAnswer, updated: nil) == "Tokenjar tries again at the next refresh.")
        #expect(line(.online) == "Updated 25m ago")
        #expect(line(.offline, refreshing: true) == "Updating")
    }

    /// Every number on screen is old while offline, so that comes first; the amber or red stays on its card and on the
    /// menu bar number.
    @Test func offlineOutranksTheLimitSummary() {
        let statuses = [
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
            "personal": AccountStatus(error: .notSignedIn),
        ]
        let kept = SettingsProblem(message: "Could not read config.local.json.", file: "config.local.json", nothingLoaded: false)
        // The near-limit account and the one to fix are still named, as the menu bar's color and dot point at them.
        #expect(PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now, connectivity: .offline, settings: kept)
            == PopoverSummary(tone: .offline, text: "Offline", others: ["Claude · Personal", "Claude · Work", "settings"]))
        #expect(PopoverSummary.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now, connectivity: .noAnswer).tone == .noAnswer)
        // A connection failure is what the title already says, so it is not named again.
        let unreachable = ["work": AccountStatus(error: .timeout, lastAttempt: now), "personal": AccountStatus(error: .network("dial tcp"), lastAttempt: now)]
        #expect(PopoverSummary.make(accounts: accounts, statuses: unreachable, config: AppConfig(), now: now, connectivity: .noAnswer).others.isEmpty)
    }

    @MainActor
    @Test func noAnswerSaysNoProviderIsAnswering() {
        let summary = PopoverSummary.make(accounts: accounts, statuses: ["work": AccountStatus(error: .timeout)], config: AppConfig(), now: now, connectivity: .noAnswer)
        #expect(summary == PopoverSummary(tone: .noAnswer, text: "Can't reach any provider"))
        #expect(PopoverHeader.help(for: summary) == "No provider answered the last check. A VPN, a proxy or a Wi-Fi sign-in page can cause this.")
        let offline = PopoverSummary(tone: .offline, text: "Offline")
        #expect(PopoverHeader.help(for: offline) == "Offline")
    }

    /// A config that failed at launch leaves no accounts; "No accounts yet" would say the install is fresh.
    @Test func settingsNotLoadedIsNotAnEmptyInstall() {
        let unloaded = SettingsProblem(message: "Could not read config.json.", file: "config.json", nothingLoaded: true)
        #expect(PopoverSummary.make(accounts: [], statuses: [:], config: AppConfig(), now: now, settings: unloaded) == PopoverSummary(tone: .problem, text: "Settings not loaded"))
        #expect(PopoverSummary.make(accounts: [], statuses: [:], config: AppConfig(), now: now, connectivity: .offline, settings: unloaded).text == "Settings not loaded")
        #expect(PopoverSummary.make(accounts: [], statuses: [:], config: AppConfig(), now: now).text == "No accounts yet")
    }

    @Test func aSettingsProblemReachesTheHeaderAndAlso() {
        let kept = SettingsProblem(message: "Could not save config.json.", file: "config.json", nothingLoaded: false)
        let fine = ["personal": AccountStatus(snapshot: snapshot("personal", [window("session", "5-hour", used: 10, resetIn: 130 * 60)]))]
        #expect(PopoverSummary.make(accounts: accounts, statuses: fine, config: AppConfig(), now: now, settings: kept) == PopoverSummary(tone: .problem, text: "Settings need attention"))
        let signedOut = fine.merging(["work": AccountStatus(error: .notSignedIn)]) { $1 }
        #expect(PopoverSummary.make(accounts: accounts, statuses: signedOut, config: AppConfig(), now: now, settings: kept).text == "Settings need attention")
        let warned = [
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
            "personal": AccountStatus(error: .notSignedIn),
        ]
        let summary = PopoverSummary.make(accounts: accounts, statuses: warned, config: AppConfig(), now: now, settings: kept)
        #expect(summary.tone == .warning)
        #expect(summary.others == ["Claude · Personal", "settings"])
    }

    @MainActor
    @Test func refreshIsOffWithNothingToCheck() {
        #expect(!PopoverHeader.canRefresh(hasAccounts: false, isRefreshing: false))
        #expect(!PopoverHeader.canRefresh(hasAccounts: true, isRefreshing: true))
        #expect(PopoverHeader.canRefresh(hasAccounts: true, isRefreshing: false))
    }

    private let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go")
    private let noSubscription = AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key"))

    /// Not being subscribed is a state, not a fault: there is nothing to fix and nothing to wait for.
    @Test func aMissingSubscriptionIsCalm() {
        let statuses = [
            "personal": AccountStatus(snapshot: snapshot("personal", [window("session", "5-hour", used: 10, resetIn: 130 * 60)])),
            "go": noSubscription,
        ]
        let summary = PopoverSummary.make(accounts: [accounts[0], go], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.tone == .clear)
        #expect(summary.text.hasPrefix("All clear"))
    }

    @Test func aMissingSubscriptionIsNotListedBesideAWarning() {
        let statuses = [
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
            "go": noSubscription,
        ]
        let summary = PopoverSummary.make(accounts: [accounts[1], go], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.tone == .warning)
        #expect(summary.others.isEmpty)
    }

    @Test func onlyAccountsWithoutASubscriptionHaveNoLimitsToTrack() {
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let link = AccountStatus(snapshot: UsageSnapshot(accountID: "devin", provider: .devin, fetchedAt: now, source: "plan page", notes: ["note"]))
        let summary = PopoverSummary.make(accounts: [go, devin], statuses: ["go": noSubscription, "devin": link], config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .empty, text: "No limits to track"))
    }

    /// One failed check over data that is still fresh will most likely pass on the next one.
    @Test func aNetworkErrorOverFreshDataIsNoAlarm() {
        let fresh = snapshot("personal", [window("session", "5-hour", used: 10, resetIn: 130 * 60)], fetchedAgo: 5 * 60)
        let summary = PopoverSummary.make(accounts: [accounts[0]], statuses: ["personal": AccountStatus(snapshot: fresh, error: .network("offline"))], config: AppConfig(), now: now)
        #expect(summary.tone == .clear)
    }

    /// Nothing for the user to fix, so not "needs attention": the header names the provider in gray instead.
    @Test func aConnectionFailureOverStaleDataNamesTheProvider() {
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let stale = snapshot("claude", [window("session", "5-hour", used: 10, resetIn: 130 * 60)], fetchedAgo: 50 * 60)
        let old = PopoverSummary.make(accounts: [claude], statuses: ["claude": AccountStatus(snapshot: stale, error: .network("offline"))], config: AppConfig(), now: now)
        #expect(old == PopoverSummary(tone: .unreachable(onlyTimeouts: false), text: "Can't reach Claude"))
        let saved = UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: now.addingTimeInterval(-3 * 3_600), source: ClaudeUsageFetcher.cacheSource, liveCheckFailure: .network)
        let copy = PopoverSummary.make(accounts: [claude], statuses: ["claude": AccountStatus(snapshot: saved, lastAttempt: now)], config: AppConfig(), now: now)
        #expect(copy == PopoverSummary(tone: .unreachable(onlyTimeouts: false), text: "Can't reach Claude"))
    }

    @Test func aTimeoutSaysTheProviderIsNotAnswering() {
        let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
        let none = PopoverSummary.make(accounts: [copilot], statuses: ["copilot": AccountStatus(error: .timeout)], config: AppConfig(), now: now)
        #expect(none == PopoverSummary(tone: .unreachable(onlyTimeouts: true), text: "No answer from GitHub Copilot"))
        // Two accounts of one provider need the label to tell them apart.
        let both = PopoverSummary.make(accounts: accounts, statuses: ["work": AccountStatus(error: .timeout)], config: AppConfig(), now: now)
        #expect(both.text == "No answer from Claude · Work")
    }

    @Test func severalAccountsThatCannotRefreshAreCounted() {
        let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
        let statuses = ["personal": AccountStatus(error: .timeout), "copilot": AccountStatus(error: .network("dial tcp"))]
        let summary = PopoverSummary.make(accounts: [accounts[0], copilot], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .unreachable(onlyTimeouts: false), text: "2 accounts can't refresh"))
        let timeouts = PopoverSummary.make(accounts: accounts, statuses: ["personal": AccountStatus(error: .timeout), "work": AccountStatus(error: .timeout)], config: AppConfig(), now: now)
        #expect(timeouts.tone == .unreachable(onlyTimeouts: true))
        // Beside a warning it joins the others, as a failed check did.
        let warned = PopoverSummary.make(accounts: [accounts[1], copilot], statuses: [
            "work": AccountStatus(snapshot: snapshot("work", [window("session", "5-hour", used: 88, resetIn: 50 * 60)])),
            "copilot": AccountStatus(error: .timeout),
        ], config: AppConfig(), now: now)
        #expect(warned.tone == .warning)
        #expect(warned.others == ["GitHub Copilot"])
    }

    /// Every failed-check icon in the popover, the menu bar and the sidebar reads this rule.
    @Test func onlyAnActionableFailureNeedsAttention() {
        for error in [FetchError.network("offline"), .timeout, .rateLimited(retryAfter: 60)] {
            #expect(!AccountStatus(error: error).failureNeedsAttention(now: now, refreshMinutes: 10), "\(error)")
        }
        #expect(AccountStatus(error: .notSignedIn).failureNeedsAttention(now: now, refreshMinutes: 10))
        #expect(!AccountStatus(error: .noSubscription("none")).failureNeedsAttention(now: now, refreshMinutes: 10))
    }
}

/// The caption under a red or full title that names the account with the most room left.
@MainActor
struct RoomHintTests {
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let codex = AccountConfig(id: "codex", provider: .codex, label: "Plus")
    private let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go")
    private let zen = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen")
    private let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
    private let noSubscription = FetchError.noSubscription("No active OpenCode Go subscription for this key")

    private var fullClaude: AccountStatus {
        AccountStatus(snapshot: snapshot("claude", [
            window("session", "5-hour", used: 100, resetIn: 87 * 60),
            window("weekly", "Week", used: 40, minutes: 10_080, resetIn: 3 * 86_400),
            window("weekly:fable", "Week · Fable", used: 56, minutes: 10_080, resetIn: 3 * 86_400),
        ]))
    }

    private func using(_ id: String, _ used: Double, label: String = "5-hour", minutes: Int = 300, fetchedAgo: TimeInterval = 60, error: FetchError? = nil) -> AccountStatus {
        AccountStatus(snapshot: snapshot(id, [window("main", label, used: used, minutes: minutes, resetIn: 2 * 3_600)], fetchedAgo: fetchedAgo), error: error, lastAttempt: now)
    }

    /// The owner's state: Claude's 5-hour window is full, Codex has barely started, Go has no subscription, Zen only
    /// spends and Copilot has used some premium requests.
    @Test func aFullWindowNamesTheAccountWithTheMostRoom() {
        let statuses = [
            "claude": fullClaude,
            "codex": AccountStatus(snapshot: snapshot("codex", [
                window("session", "5-hour", used: 2, resetIn: 4 * 3_600),
                window("weekly", "Week", used: 0, minutes: 10_080, resetIn: 7 * 86_400, notStarted: true),
            ], fetchedAgo: 60)),
            "go": AccountStatus(error: noSubscription, lastAttempt: now),
            "zen": AccountStatus(snapshot: UsageSnapshot(
                accountID: "zen", provider: .opencodeZen, plan: "Pay as you go", money: [MoneyLine(label: "Spent this month (this Mac)", amount: 8.17)],
                fetchedAt: now, source: "opencode.db"
            )),
            "copilot": using("copilot", 15, label: "Premium requests", minutes: 44_640),
        ]
        let summary = PopoverSummary.make(accounts: [claude, codex, go, zen, copilot], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary == PopoverSummary(tone: .critical, text: "Claude · Personal: 5-hour full, resets in 1h 27m", room: "Codex has room: 5-hour 2% used"))
    }

    /// At 85 % there is still room on the named account, so the header points nowhere else.
    @Test func anAmberTitleNamesNoOtherAccount() {
        let statuses = ["claude": using("claude", 85), "codex": using("codex", 2)]
        let summary = PopoverSummary.make(accounts: [claude, codex], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.tone == .warning)
        #expect(summary.room == nil)
    }

    /// Offline and with no provider answering every number is old, and all clear has nothing to work around.
    @Test func onlyALimitTitleGetsTheHint() {
        let calm = ["claude": using("claude", 10), "codex": using("codex", 2)]
        let clear = PopoverSummary.make(accounts: [claude, codex], statuses: calm, config: AppConfig(), now: now)
        #expect(clear.tone == .clear)
        #expect(clear.room == nil)
        let full = ["claude": fullClaude, "codex": using("codex", 2)]
        for connectivity in [Connectivity.offline, .noAnswer] {
            let summary = PopoverSummary.make(accounts: [claude, codex], statuses: full, config: AppConfig(), now: now, connectivity: connectivity)
            #expect(summary.room == nil, "\(connectivity)")
        }
    }

    /// Each of these has less used than Copilot, and none of them is somewhere the user can keep working right now.
    @Test func onlyAnAccountWithFreshCalmLimitsIsNamed() {
        let agy = AccountConfig(id: "agy", provider: .antigravity, label: "Google")
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let statuses = [
            "claude": fullClaude,
            "codex": using("codex", 1, fetchedAgo: 3 * 3_600),
            "agy": using("agy", 3, error: .notSignedIn),
            "go": using("go", 2, error: noSubscription),
            // Zen and Devin never report a window; one here would still not make either a place with room.
            "zen": using("zen", 0),
            "devin": using("devin", 0),
            "copilot": using("copilot", 15, label: "Premium requests", minutes: 44_640),
        ]
        let summary = PopoverSummary.make(accounts: [claude, codex, agy, go, zen, devin, copilot], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.room == "GitHub Copilot has room: Premium requests 15% used")
        #expect(summary.others == ["Antigravity"])
    }

    /// An amber account is already named after "Also:", and with nothing else left there is no hint at all.
    @Test func noCandidateMeansNoHint() {
        let statuses = [
            "claude": fullClaude,
            "codex": using("codex", 85),
            "go": AccountStatus(error: noSubscription, lastAttempt: now),
            "zen": AccountStatus(snapshot: UsageSnapshot(accountID: "zen", provider: .opencodeZen, fetchedAt: now, source: "opencode.db")),
        ]
        let summary = PopoverSummary.make(accounts: [claude, codex, go, zen], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.tone == .critical)
        #expect(summary.others == ["Codex"])
        #expect(summary.room == nil)
    }

    @Test func twoAccountsOfOneProviderAreToldApartByLabel() {
        let work = AccountConfig(id: "work", provider: .claude, label: "Work")
        let statuses = ["claude": fullClaude, "work": using("work", 30, label: "Week", minutes: 10_080), "codex": using("codex", 40)]
        let summary = PopoverSummary.make(accounts: [claude, work, codex], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.room == "Claude · Work has room: Week 30% used")
    }

    /// The user sets config order, so a tie never depends on anything they cannot see.
    @Test func aTieGoesToConfigOrder() {
        let statuses = ["claude": fullClaude, "codex": using("codex", 10), "copilot": using("copilot", 10, label: "Premium requests", minutes: 44_640)]
        let first = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: statuses, config: AppConfig(), now: now)
        #expect(first.room == "Codex has room: 5-hour 10% used")
        let swapped = PopoverSummary.make(accounts: [claude, copilot, codex], statuses: statuses, config: AppConfig(), now: now)
        #expect(swapped.room == "GitHub Copilot has room: Premium requests 10% used")
    }

    /// A window past its reset still shows the cycle that ended, which says nothing about the room left now.
    @Test func aWindowPastItsResetGivesNoRoom() {
        let reset = AccountStatus(snapshot: snapshot("codex", [window("session", "5-hour", used: 5, resetIn: -60)]), lastAttempt: now)
        let statuses = ["claude": fullClaude, "codex": reset, "copilot": using("copilot", 10, label: "Premium requests", minutes: 44_640)]
        let summary = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: statuses, config: AppConfig(), now: now)
        #expect(summary.room == "GitHub Copilot has room: Premium requests 10% used")
    }

    /// Red at can be hand-edited above 100, and a full window still stops the work.
    @Test func aFullWindowBelowRedAtStillGetsTheHint() {
        var config = AppConfig()
        config.menuBar.criticalAt = 110
        let summary = PopoverSummary.make(accounts: [claude, codex], statuses: ["claude": fullClaude, "codex": using("codex", 2)], config: config, now: now)
        #expect(summary.tone == .warning)
        #expect(summary.room == "Codex has room: 5-hour 2% used")
    }

    /// The seam provider status fills: a provider whose status page reports a major outage is not where to go.
    @Test func aProviderInMajorOutageIsSkipped() {
        let statuses = ["claude": fullClaude, "codex": using("codex", 2), "copilot": using("copilot", 15, label: "Premium requests", minutes: 44_640)]
        let summary = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: statuses, config: AppConfig(), now: now, majorOutages: [.codex])
        #expect(summary.room == "GitHub Copilot has room: Premium requests 15% used")
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
            WindowSample(accountID: "a", windowID: "weekly", timestamp: now.addingTimeInterval(-86_400), usedPercent: 39, resetsAt: weekly.resetsAt),
        ]
        let points = BurnUpChart.points(samples: samples, window: weekly, start: start, now: now)
        #expect(points.map(\.used) == [1, 39, 40])
        #expect(points.last?.date == now)
    }

    /// A week at the observed 10-minute cadence is about 1,000 samples, each one a mark Charts lays out on every draw.
    @Test func aLongCycleIsThinnedButKeepsItsPeakAndTheLiveValue() {
        let weekly = window("weekly", "Week", used: 60, minutes: 10_080, resetIn: 86_400)
        let start = weekly.resetsAt!.addingTimeInterval(-7 * 86_400)
        let elapsed = now.timeIntervalSince(start) - 120
        let samples = (0..<1_500).map { i in
            let used = i <= 700 ? 75 * Double(i) / 700 : 50 + 9 * Double(i - 700) / 799
            return WindowSample(accountID: "a", windowID: "weekly", timestamp: start.addingTimeInterval(elapsed * Double(i) / 1_499), usedPercent: used, resetsAt: weekly.resetsAt)
        }
        let points = BurnUpChart.points(samples: samples, window: weekly, start: start, now: now)
        #expect(points.count <= 121)
        #expect(points.map(\.used).max() == 75)
        #expect(points.last?.used == 60)
        #expect(points.last?.date == now)
    }

    /// A card's body re-runs on every model change it reads; only new history or a new cycle may reach SQLite.
    @Test func storedSamplesAreLoadedOncePerHistoryRevisionAndCycle() {
        let cache = BurnUpSamples()
        let start = now.addingTimeInterval(-3 * 86_400)
        let end = start.addingTimeInterval(7 * 86_400)
        var loads = 0
        func read(_ windowID: String = "weekly", start: Date = start, revision: Int = 1) -> [WindowSample] {
            cache.samples(accountID: "a", windowID: windowID, start: start, end: end, revision: revision) {
                loads += 1
                return [WindowSample(accountID: "a", windowID: windowID, timestamp: start, usedPercent: 1, resetsAt: end)]
            }
        }
        _ = read()
        _ = read()
        #expect(loads == 1)
        _ = read(revision: 2)
        #expect(loads == 2)
        _ = read(start: end, revision: 2)
        #expect(loads == 3)
        _ = read("session", revision: 2)
        #expect(loads == 4)
    }

    @Test func aFreshSampleTakesTheLiveValueInsteadOfAddingAPoint() {
        let weekly = window("weekly", "Week", used: 40, minutes: 10_080, resetIn: 3 * 86_400)
        let start = weekly.resetsAt!.addingTimeInterval(-7 * 86_400)
        let samples = [WindowSample(accountID: "a", windowID: "weekly", timestamp: now.addingTimeInterval(-10), usedPercent: 38, resetsAt: weekly.resetsAt)]
        #expect(BurnUpChart.points(samples: samples, window: weekly, start: start, now: now).map(\.used) == [40])
    }

    /// A stub at the right edge or a flat line on the floor says nothing the bar above it does not.
    @Test func aChartNeedsATenthOfTheCycleAndSomeUse() {
        let start = now.addingTimeInterval(-3 * 86_400)
        let end = start.addingTimeInterval(7 * 86_400)
        func point(_ at: Date, _ used: Double) -> BurnUpChart.Point { BurnUpChart.Point(date: at, used: used) }
        #expect(!BurnUpChart.isWorthDrawing([point(now.addingTimeInterval(-0.05 * 7 * 86_400), 3), point(now, 5)], start: start, end: end))
        #expect(!BurnUpChart.isWorthDrawing([point(start, 0), point(now, 0.04)], start: start, end: end))
        #expect(!BurnUpChart.isWorthDrawing([point(now, 40)], start: start, end: end))
        #expect(BurnUpChart.isWorthDrawing([point(start, 0), point(now, 40)], start: start, end: end))
        #expect(BurnUpChart.isWorthDrawing([point(start, 0), point(end, 97)], start: start, end: end))
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

    @Test func chartsTheWindowTheVerdictJudgesWhenItIsADayOrLonger() {
        let session = window("session", "5-hour", used: 10, resetIn: 3600)
        let weekly = window("weekly", "Week", used: 45, minutes: 10_080, resetIn: 86_400)
        let monthly = window("monthly", "Month", used: 61, minutes: 43_200, resetIn: 12 * 86_400)
        #expect(BurnUpChart.chartWindow(in: [session, weekly, monthly], verdictWindowID: "monthly")?.id == "monthly")
        // A 5-hour cycle is too short for a burn-up, so a verdict about it leaves the week on the chart.
        #expect(BurnUpChart.chartWindow(in: [session, weekly, monthly], verdictWindowID: "session")?.id == "weekly")
        let gemini = window("gemini:weekly", "Gemini · Week", used: 38, minutes: 10_080, resetIn: 4 * 86_400)
        let pooled = window("claude-and-gpt:weekly", "Claude and GPT · Week", used: 71, minutes: 10_080, resetIn: 4 * 86_400)
        #expect(BurnUpChart.chartWindow(in: [gemini, pooled], verdictWindowID: "claude-and-gpt:weekly")?.id == "claude-and-gpt:weekly")
    }
}

@MainActor
struct StatusIconRendererTests {
    /// An actionable failure always needs attention; a transient one only without fresh data, so a test says which.
    private func entry(
        _ id: String, used: Double?, severity: Severity = .ok, resetIn: TimeInterval? = 50 * 60, stale: Bool = false,
        attention: FetchError.Attention? = nil, needsAttention: Bool? = nil, provider: ProviderID = .claude,
        fetchedAgo: TimeInterval? = nil, connection: FetchError? = nil
    ) -> MenuBarState.Entry {
        MenuBarState.Entry(
            accountID: id, provider: provider, label: id,
            tightest: used.map { window("session", "5-hour", used: $0, resetIn: resetIn) },
            severity: severity, isStale: stale, attention: attention ?? connection.map { _ in .transient },
            failureNeedsAttention: needsAttention ?? (attention == .actionable),
            fetchedAt: fetchedAgo.map { now.addingTimeInterval(-$0) }, connectionFailure: connection
        )
    }

    private func state(
        _ entries: [MenuBarState.Entry], mode: MenuBarMode = .worst, icon: MenuBarIcon = .app, countdown: Bool = true,
        connectivity: Connectivity = .online, settings: SettingsProblem? = nil
    ) -> MenuBarState {
        MenuBarState(mode: mode, icon: icon, entries: entries, showResetCountdownWhenFull: countdown, now: now, connectivity: connectivity, settingsProblem: settings)
    }

    private let keptSettings = SettingsProblem(
        message: "Could not read config.local.json. Using the last good settings, and nothing is saved until it is fixed and reloaded.",
        file: "config.local.json", nothingLoaded: false
    )
    private let noSettings = SettingsProblem(
        message: "Could not read config.json. No settings are loaded, and nothing is saved until it is fixed and reloaded.",
        file: "config.json", nothingLoaded: true
    )

    private func color(_ rendered: RenderedStatusIcon) -> NSColor? {
        guard rendered.attributedTitle.length > 0 else { return nil }
        return rendered.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    /// A provider's logo would read as that provider's own menu bar app (Claude's spark sits right beside it), so the
    /// menu bar shows one only when the user picks it.
    @Test(arguments: [MenuBarMode.worst, .icon])
    func defaultIsTheAppMarkAndAProviderLogoOnlyWhenPicked(_ mode: MenuBarMode) {
        let logos = MenuBarIcon.allCases.filter { $0.group == .logos }
        for severity in [Severity.ok, .warning, .critical] {
            let tint = severity == .ok ? nil : severity.nsColor
            let entries = [entry("a", used: 90, severity: severity)]
            let byDefault = StatusIconRenderer.render(state(entries, mode: mode)).image
            #expect(pixels(byDefault) == pixels(StatusGlyph.image(.app, fraction: 0.9, tint: tint, alpha: 1, dot: false)))
            let logoPixels = logos.map { pixels(StatusGlyph.image($0, fraction: 0.9, tint: tint, alpha: 1, dot: false)) }
            for icon in MenuBarIcon.allCases {
                let picked = pixels(StatusIconRenderer.render(state(entries, mode: mode, icon: icon)).image)
                #expect(logoPixels.contains(picked) == logos.contains(icon), "\(icon.rawValue)")
            }
        }
        #expect(pixels(StatusIconRenderer.render(state([])).image) == pixels(StatusGlyph.neutral(.app, dot: false)))
        #expect(StatusIconRenderer.render(state([entry("a", used: 90)], mode: mode, icon: .logoClaude)).image?.accessibilityDescription == "Tokenjar, Claude 5-hour 90% used")
    }

    /// Icon mode has no title, so the image's description is all VoiceOver has to read the level from.
    @Test(arguments: [MenuBarMode.worst, .icon])
    func theIconDescribesTheTightestLevelForVoiceOver(_ mode: MenuBarMode) {
        func described(_ entries: [MenuBarState.Entry], icon: MenuBarIcon = .app) -> String? {
            StatusIconRenderer.render(state(entries, mode: mode, icon: icon)).image?.accessibilityDescription
        }
        #expect(described([entry("a", used: 42), entry("b", used: 85, severity: .warning, provider: .codex)]) == "Tokenjar, Codex 5-hour 85% used")
        // Two accounts of one provider need the label to tell them apart.
        #expect(described([entry("Personal", used: 42), entry("Work", used: 85, severity: .warning)]) == "Tokenjar, Claude Work 5-hour 85% used")
        #expect(described([entry("a", used: 85, severity: .warning)], icon: .symbolBrain) == "Tokenjar, Claude 5-hour 85% used")
        #expect(described([entry("a", used: 42, stale: true)]) == "Tokenjar, Claude 5-hour 42% used, out of date")
        #expect(described([entry("a", used: 42, stale: true, attention: .actionable)]) == "Tokenjar, Claude 5-hour 42% used, Claude check failed")
        #expect(described([entry("a", used: nil)]) == "Tokenjar")
        #expect(described([entry("a", used: nil, attention: .actionable)]) == "Tokenjar, Claude check failed")
        #expect(described([entry("a", used: 100, severity: .critical, resetIn: 47 * 60)]) == "Tokenjar, Claude 5-hour full, resets in 47 minutes")
    }

    /// Bars shows no number, so VoiceOver needs every account's level.
    @Test func barsDescribeEveryAccount() {
        let entries = [entry("a", used: 42), entry("b", used: 0, provider: .codex), entry("c", used: nil, provider: .copilot)]
        #expect(StatusIconRenderer.render(state(entries, mode: .bars)).image?.accessibilityDescription == "Tokenjar, Claude 42%, Codex 0%, GitHub Copilot no data")
        let troubled = [entry("a", used: 42, stale: true), entry("b", used: nil, attention: .actionable, provider: .codex)]
        #expect(StatusIconRenderer.render(state(troubled, mode: .bars)).image?.accessibilityDescription == "Tokenjar, Claude 42%, Codex no data, Claude out of date, Codex check failed")
    }

    /// The number is the tightest window's, so an amber mark at 75 % needs the window whose projection colored it.
    @Test func aProjectionNamesTheWindowThatColorsTheMark() {
        var projected = entry("a", used: 75, severity: .warning)
        projected.tightest = window("weekly", "Week", used: 75, minutes: 10_080, resetIn: 86_400)
        projected.cause = PaceVerdict(window: window("session", "5-hour", used: 60, resetIn: 150 * 60), kind: .runsOut(50 * 60))
        let rendered = StatusIconRenderer.render(state([projected]))
        #expect(rendered.image?.accessibilityDescription == "Tokenjar, Claude Week 75% used, 5-hour runs out about 50 minutes before reset")
        #expect(rendered.toolTip == "Claude · a: Week 75%, resets in 1d; 5-hour runs out ~50m before reset")

        var itself = entry("a", used: 60, severity: .warning, resetIn: 150 * 60)
        itself.cause = PaceVerdict(window: itself.tightest!, kind: .runsOut(50 * 60))
        #expect(StatusIconRenderer.render(state([itself])).toolTip == "Claude · a: 5-hour 60%, resets in 2h 30m; runs out ~50m before reset")
    }

    @Test(arguments: [MenuBarIcon.markMana, .logoClaude, .symbolBrain])
    func aStaticGlyphStillCarriesTheWarnings(_ icon: MenuBarIcon) {
        #expect(StatusIconRenderer.render(state([entry("a", used: 42)], icon: icon)).image?.isTemplate == true)
        #expect(StatusIconRenderer.render(state([entry("a", used: 85, severity: .warning)], icon: icon)).image?.isTemplate == false)
        let stale = StatusIconRenderer.render(state([entry("a", used: 42, stale: true)], icon: icon))
        #expect(abs(peakAlpha(stale.image) - 0.5) < 0.02)
        let failing = StatusIconRenderer.render(state([entry("a", used: 42, attention: .actionable)], icon: icon))
        #expect(pixels(failing.image) == pixels(StatusGlyph.image(icon, fraction: 0.42, tint: nil, alpha: 1, dot: true)))
        #expect(pixels(failing.image) != pixels(StatusGlyph.image(icon, fraction: 0.42, tint: nil, alpha: 1, dot: false)))
        let neutral = StatusIconRenderer.render(state([entry("a", used: nil)], icon: icon)).image
        #expect(pixels(neutral) == pixels(StatusGlyph.neutral(icon, dot: false)))
        #expect(pixels(neutral) != pixels(StatusGlyph.neutral(.app, dot: false)))
    }

    @Test(arguments: [MenuBarMode.worst, .icon])
    func theMarkFillsToTheWorstAccountsTightestShare(_ mode: MenuBarMode) {
        let quarter = StatusIconRenderer.render(state([entry("a", used: 10), entry("b", used: 25)], mode: mode)).image
        #expect(glyphAlpha(quarter, 11.5, 6.5) > 0.9)
        #expect(glyphAlpha(quarter, 11.5, 11.5) < 0.1)
        let threeQuarters = StatusIconRenderer.render(state([entry("a", used: 75), entry("b", used: 25)], mode: mode)).image
        #expect(glyphAlpha(threeQuarters, 6.5, 11.5) > 0.9)
        #expect(glyphAlpha(threeQuarters, 6.5, 6.5) < 0.1)
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

    @Test func staleDataDimsTheLogo() {
        for mode in [MenuBarMode.worst, .icon] {
            let fresh = StatusIconRenderer.render(state([entry("a", used: 42)], mode: mode))
            let stale = StatusIconRenderer.render(state([entry("a", used: 42, stale: true)], mode: mode))
            #expect(abs(peakAlpha(fresh.image) - 1) < 0.02)
            #expect(abs(peakAlpha(stale.image) - 0.5) < 0.02)
        }
    }

    private func peakAlpha(_ image: NSImage?) -> Double {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        var peak = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                peak = max(peak, Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0))
            }
        }
        return peak
    }

    @Test func errorAddsADotBesideTheGlyph() {
        let failing = StatusIconRenderer.render(state([entry("a", used: 42, attention: .actionable)]))
        #expect(pixels(failing.image) == pixels(dotted))
        #expect(pixels(StatusIconRenderer.render(state([entry("a", used: 42)])).image) == pixels(undotted))
    }

    private let dotted = StatusGlyph.image(.app, fraction: 0.42, tint: nil, alpha: 1, dot: true)
    private let undotted = StatusGlyph.image(.app, fraction: 0.42, tint: nil, alpha: 1, dot: false)

    /// The worst account can be healthy while another one is signed out; the dot must still say a check failed.
    @Test func anActionableFailureOnAnyAccountShowsTheDot() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: 42), entry("b", used: nil, attention: .actionable, provider: .codex)]))
        #expect(pixels(rendered.image) == pixels(dotted))
        #expect(rendered.image?.accessibilityDescription?.hasSuffix(", Codex check failed") == true)
    }

    /// A timeout over fresh data is likely gone by the next check, and a missing subscription is nothing to fix. A
    /// timeout with nothing fresh to show is not the user's to fix either: the header names it, the dot stays off.
    @Test func onlyAFailureThatNeedsAttentionShowsTheDot() {
        let blip = StatusIconRenderer.render(state([entry("a", used: 42, attention: .transient, needsAttention: false), entry("b", used: 12)]))
        #expect(pixels(blip.image) == pixels(undotted))
        let accounts = [AccountConfig(id: "a", provider: .claude, label: "a"), AccountConfig(id: "b", provider: .codex, label: "b")]
        let statuses = ["a": AccountStatus(snapshot: snapshot("a", [window("session", "5-hour", used: 42, resetIn: 50 * 60)])), "b": AccountStatus(error: .timeout)]
        let elsewhere = StatusIconRenderer.render(MenuBarState.make(accounts: accounts, statuses: statuses, config: AppConfig(), now: now))
        #expect(pixels(elsewhere.image) == pixels(undotted))
        let calm = StatusIconRenderer.render(state([entry("a", used: 42, attention: .calm)]))
        #expect(pixels(calm.image) == pixels(undotted))
        #expect(calm.toolTip?.contains("failed") == false)
    }

    @Test func noDataShowsTheNeutralGaugeWithoutText() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: nil)]))
        #expect(rendered.title.isEmpty)
        #expect(rendered.attributedTitle.length == 0)
        #expect(rendered.image?.isTemplate == true)
        #expect(rendered.image?.accessibilityDescription == "Tokenjar")
    }

    @Test func barsModeDrawsOneBarPerEntry() {
        let ok = StatusIconRenderer.render(state([entry("a", used: 10), entry("b", used: 20), entry("c", used: 30)], mode: .bars))
        #expect(ok.title.isEmpty)
        // Centered in the slot's 18 pt with the dot's room, so the slash has room to read as crossed out.
        #expect(ok.image?.size == NSSize(width: 18 + 3, height: 18))
        #expect(ok.image?.isTemplate == true)
        let colored = StatusIconRenderer.render(state([entry("a", used: 10), entry("b", used: 90, severity: .warning)], mode: .bars))
        #expect(colored.image?.isTemplate == false)
    }

    @Test func iconModeHasNoText() {
        let rendered = StatusIconRenderer.render(state([entry("a", used: 97, severity: .critical)], mode: .icon))
        #expect(rendered.title.isEmpty)
        #expect(rendered.image?.isTemplate == false)
    }

    /// Under a slash every number is old: an ok number goes secondary, and an amber or red one keeps its full color so a
    /// near-limit warning is never hidden.
    @Test func slashedNumbersFollowTheStaleRule() {
        let ok = StatusIconRenderer.render(state([entry("a", used: 16)], connectivity: .offline))
        #expect(color(ok) == .secondaryLabelColor)
        let amber = StatusIconRenderer.render(state([entry("a", used: 85, severity: .warning, stale: true)], connectivity: .offline))
        #expect(color(amber) == .systemOrange)
        let red = StatusIconRenderer.render(state([entry("a", used: 97, severity: .critical)], connectivity: .noAnswer))
        #expect(color(red) == .systemRed)
        #expect(color(StatusIconRenderer.render(state([entry("a", used: 16)]))) == nil)
    }

    @Test func tooltipLeadsWithTheState() {
        let old = entry("Personal", used: 16, stale: true, fetchedAgo: 25 * 60, connection: .network("offline"))
        let account = "Claude · Personal: 5-hour 16%, resets in 50m"
        let offline = "This Mac is offline. The usage shown was last updated 25m ago, and Tokenjar checks again when the Mac is back online."
        #expect(StatusIconRenderer.toolTip(for: state([old], connectivity: .offline)) == "\(offline)\n\(account) (out of date)")
        #expect(StatusIconRenderer.toolTip(for: state([entry("Personal", used: nil)], connectivity: .offline))
            == "This Mac is offline. Tokenjar checks usage when the Mac is back online.\nClaude · Personal: no data")
        let cause = "Tokenjar can't reach any provider, which a VPN, a proxy or a Wi-Fi sign-in page can cause."
        #expect(StatusIconRenderer.toolTip(for: state([old], connectivity: .noAnswer))
            == "\(cause) The usage shown was last updated 25m ago, and Tokenjar tries again at the next refresh.\n\(account) (out of date)")
        #expect(StatusIconRenderer.toolTip(for: state([entry("Personal", used: nil, connection: .timeout)], connectivity: .noAnswer))
            == "\(cause) Tokenjar tries again at the next refresh.\nClaude · Personal: no data")
        #expect(StatusIconRenderer.toolTip(for: state([old], connectivity: .offline, settings: keptSettings))
            == "\(offline)\n\(keptSettings.message)\n\(account) (out of date)")
        #expect(StatusIconRenderer.toolTip(for: state([], settings: keptSettings)) == "\(keptSettings.message)\nTokenjar: no accounts in the menu bar")
        #expect(StatusIconRenderer.toolTip(for: state([], settings: noSettings)) == noSettings.message)
    }

    /// Without a slash each account says why it is not current, so one unreachable provider is named in the tooltip.
    @Test func eachAccountSaysWhyItIsNotCurrent() {
        let lines = StatusIconRenderer.toolTip(for: state([
            entry("A", used: 10, stale: true, connection: .network("dial tcp")),
            entry("B", used: 10, connection: .timeout),
            entry("C", used: 10, attention: .transient),
            entry("D", used: 10, stale: true, attention: .transient),
            entry("E", used: 10, attention: .actionable),
            entry("F", used: 10, stale: true),
        ])).components(separatedBy: "\n").map { $0.components(separatedBy: "50m").last ?? "" }
        #expect(lines == [
            " (can't reach, out of date)", " (no answer)", " (waiting to check again)", " (waiting to check again, out of date)",
            " (last check failed)", " (out of date)",
        ])
        let slashed = StatusIconRenderer.toolTip(for: state([entry("A", used: 10, connection: .timeout), entry("B", used: 10, stale: true, connection: .timeout)], connectivity: .noAnswer))
        #expect(slashed.hasSuffix("Claude · A: 5-hour 10%, resets in 50m\nClaude · B: 5-hour 10%, resets in 50m (out of date)"))
    }

    @Test(arguments: [MenuBarMode.worst, .icon])
    func voiceOverLeadsWithTheState(_ mode: MenuBarMode) {
        func described(_ entries: [MenuBarState.Entry], connectivity: Connectivity = .online, settings: SettingsProblem? = nil) -> String? {
            StatusIconRenderer.render(state(entries, mode: mode, connectivity: connectivity, settings: settings)).image?.accessibilityDescription
        }
        let old = entry("a", used: 16, stale: true, fetchedAgo: 25 * 60)
        #expect(described([old], connectivity: .offline) == "Tokenjar, offline, Claude 5-hour 16% used, out of date")
        let copilot = entry("c", used: nil, attention: .actionable, provider: .copilot)
        #expect(described([entry("a", used: 16), copilot], connectivity: .noAnswer) == "Tokenjar, can't reach any provider, Claude 5-hour 16% used, GitHub Copilot check failed")
        #expect(described([entry("a", used: 16)], settings: keptSettings) == "Tokenjar, settings need attention, Claude 5-hour 16% used")
        #expect(described([], settings: noSettings) == "Tokenjar, settings not loaded")
        #expect(described([entry("a", used: nil)], connectivity: .offline) == "Tokenjar, offline")
        #expect(described([entry("a", used: 16, stale: true, connection: .network("dial tcp"))]) == "Tokenjar, Claude 5-hour 16% used, can't reach Claude, out of date")
        #expect(described([entry("a", used: 16, connection: .timeout)]) == "Tokenjar, Claude 5-hour 16% used, no answer from Claude")
        // A provider that can't be reached is named even when another account sets the number, as the tooltip does.
        let copilotDown = entry("c", used: 1, stale: true, provider: .copilot, connection: .network("dial tcp"))
        #expect(described([entry("a", used: 41), copilotDown]) == "Tokenjar, Claude 5-hour 41% used, can't reach GitHub Copilot")
        #expect(described([entry("a", used: 41), copilotDown], connectivity: .noAnswer) == "Tokenjar, can't reach any provider, Claude 5-hour 41% used")
        #expect(described([entry("c", used: nil, provider: .copilot, connection: .timeout)]) == "Tokenjar, no answer from GitHub Copilot")
    }

    @Test func barsLeadWithTheStateToo() {
        let entries = [entry("Personal", used: 75), entry("b", used: 12, provider: .codex), entry("Work", used: 30)]
        #expect(StatusIconRenderer.render(state(entries, mode: .bars, connectivity: .offline)).image?.accessibilityDescription
            == "Tokenjar, offline, Claude Personal 75%, Codex 12%, Claude Work 30%")
        let down = [entry("a", used: 75), entry("c", used: 1, stale: true, provider: .copilot, connection: .network("dial tcp"))]
        #expect(StatusIconRenderer.render(state(down, mode: .bars)).image?.accessibilityDescription
            == "Tokenjar, Claude 75%, GitHub Copilot 1%, can't reach GitHub Copilot, GitHub Copilot out of date")
    }

    @Test func toolTipListsEveryAccount() {
        let tip = StatusIconRenderer.render(state([entry("Personal", used: 42), entry("Work", used: nil, attention: .actionable)])).toolTip ?? ""
        #expect(tip == "Claude · Personal: 5-hour 42%, resets in 50m\nClaude · Work: no data (last check failed)")
        #expect(StatusIconRenderer.render(state([])).toolTip == "Tokenjar: no accounts in the menu bar")
    }
}

@MainActor
struct SignInCommandDisplayTests {
    @Test func previewRendersNeverShowThisMacsHomeFolder() throws {
        let account = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        let line = try #require(AccountDetailView.signInLine(for: account, cliPaths: [:], paths: AppPaths(), previewMode: true))
        #expect(line.command == "CLAUDE_CONFIG_DIR=/Users/you/.claude-work claude auth login")
        #expect(line.shown == "CLAUDE_CONFIG_DIR=~/.claude-work claude auth login")
        #expect(!line.command.contains(NSHomeDirectory()))
    }

    /// The row reads like every other Settings path, while Copy Command and Terminal get the path that was found.
    @Test func theRowShowsTildePathsAndTheButtonsUseTheRealOnes() throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = try home.makeExecutable(".local/bin/claude")
        let account = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        let line = try #require(AccountDetailView.signInLine(for: account, cliPaths: ["claude": claude.path], paths: home.paths, previewMode: false))
        #expect(line.shown == "CLAUDE_CONFIG_DIR=~/.claude-work ~/.local/bin/claude auth login")
        #expect(line.command == "CLAUDE_CONFIG_DIR=\(home.url.path)/.claude-work \(claude.path) auth login")
    }
}

@MainActor
struct ErrorRowTests {
    /// The header says a Mac-wide cause once; a Retry on every card could not work anyway.
    @Test func aMacWideCauseHidesTheConnectionRow() {
        for connectivity in [Connectivity.offline, .noAnswer] {
            for error in [FetchError.network("dial tcp"), .timeout] {
                #expect(!ErrorRow.isShown(error: error, provider: .copilot, connectivity: connectivity), "\(connectivity) \(error)")
            }
        }
        #expect(ErrorRow.isShown(error: .timeout, provider: .copilot, connectivity: .online))
        // Zen reads a local database, so its failure is its own whatever the network does.
        #expect(ErrorRow.isShown(error: .network("locked"), provider: .opencodeZen, connectivity: .offline))
    }

    /// A saved copy shown because the provider could not be reached gets the same gray row as the error would, and
    /// under a Mac-wide cause the same silence; its note only says where the numbers come from.
    @Test func aSavedCopyNamesWhyOnlyWhenTheCauseIsItsOwn() {
        var cached = UsageSnapshot(accountID: "claude", provider: .claude, fetchedAt: now.addingTimeInterval(-3_600), source: ClaudeUsageFetcher.cacheSource)
        cached.liveCheckFailure = .timeout
        let saved = AccountStatus(snapshot: cached, lastAttempt: now)
        #expect(AccountCard.rowError(status: saved, provider: .claude, connectivity: .online) == .timeout)
        #expect(AccountCard.rowError(status: saved, provider: .claude, connectivity: .noAnswer) == nil)
        cached.liveCheckFailure = .other
        #expect(AccountCard.rowError(status: AccountStatus(snapshot: cached, lastAttempt: now), provider: .claude, connectivity: .online) == nil)
        #expect(AccountCard.rowError(status: AccountStatus(error: .notSignedIn), provider: .claude, connectivity: .offline) == .notSignedIn)
    }

    @Test func anActionableRowStaysWhileOffline() {
        for error in [FetchError.notSignedIn, .cliNotFound("gh"), .parse("shape"), .rateLimited(retryAfter: 60), .noSubscription("none")] {
            #expect(ErrorRow.isShown(error: error, provider: .codex, connectivity: .offline), "\(error)")
        }
    }

    @Test func anEmptyCardSaysWhenItWillBeChecked() {
        #expect(AccountCard.emptyText(isRefreshing: true, connectivity: .offline) == "Checking usage")
        #expect(AccountCard.emptyText(isRefreshing: false, connectivity: .offline) == "No usage yet. Tokenjar checks when the Mac is back online.")
        #expect(AccountCard.emptyText(isRefreshing: false, connectivity: .noAnswer) == "No usage yet. Tokenjar tries again at the next refresh.")
        #expect(AccountCard.emptyText(isRefreshing: false, connectivity: .online) == "No data yet")
    }

    /// The gray icon over fresh data names the cause: only a network error is a connection problem.
    @Test func onlyANetworkErrorShowsWiFi() {
        #expect(ErrorRow.symbol(for: .network("offline"), needsAttention: false) == "wifi.exclamationmark")
        #expect(ErrorRow.symbol(for: .timeout, needsAttention: false) == "clock.arrow.circlepath")
        #expect(ErrorRow.symbol(for: .rateLimited(retryAfter: nil), needsAttention: false) == "clock.arrow.circlepath")
    }

    @Test func aFailureThatNeedsTheUserShowsTheWarningAndNoSubscriptionStaysCalm() {
        for error in [FetchError.network("offline"), .timeout, .notSignedIn] {
            #expect(ErrorRow.symbol(for: error, needsAttention: true) == "exclamationmark.triangle.fill")
        }
        #expect(ErrorRow.symbol(for: .noSubscription("none"), needsAttention: false) == "minus.circle")
    }
}

/// What VoiceOver reads where the popover's meaning is otherwise only visual. Not verified with VoiceOver running.
@MainActor
struct PopoverSpeechTests {
    @Test func theCardMenuNamesItsAccount() {
        #expect(PopoverSpeech.menuLabel(for: AccountConfig(id: "w", provider: .claude, label: "Work")) == "Actions for Claude Work")
        #expect(PopoverSpeech.menuLabel(for: AccountConfig(id: "g", provider: .opencodeGo, label: "Go")) == "Actions for OpenCode Go")
    }

    @Test func theStaleBadgeSpellsTheAgeOut() {
        #expect(PopoverSpeech.staleBadge(age: 3 * 3_600 + 5 * 60) == "Last updated 3 hours, 5 minutes ago")
    }

    @Test func theHeaderIconSaysWhatItsColorMeans() {
        #expect(PopoverSpeech.tone(.clear) == "All clear")
        #expect(PopoverSpeech.tone(.warning) == "Warning")
        #expect(PopoverSpeech.tone(.critical) == "Critical")
        #expect(PopoverSpeech.tone(.problem) == "Needs attention")
        #expect(PopoverSpeech.tone(.empty) == nil)
        // The title says these in words.
        for tone in [PopoverSummary.Tone.offline, .noAnswer, .unreachable(onlyTimeouts: false)] {
            #expect(PopoverSpeech.tone(tone) == nil)
        }
    }

    /// An ok verdict icon repeats the text beside it, so only a warning or critical one is read.
    @Test func onlyAWorryingVerdictIconIsRead() {
        #expect(PopoverSpeech.severity(.ok) == nil)
        #expect(PopoverSpeech.severity(.warning) == "Warning")
        #expect(PopoverSpeech.severity(.critical) == "Critical")
    }
}
