import Foundation
import Testing
@testable import TokenjarCore

struct AlertEngineTests {
    let now = fixedNow
    let account = AccountConfig(id: "claude-work", provider: .claude, label: "Work")
    let clock = Date.FormatStyle(
        date: .omitted, time: .shortened, locale: Locale(identifier: "en_GB"),
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!
    )

    var thresholdsOnly: AppConfig {
        var config = AppConfig()
        config.alerts.projectedExhaustion = false
        config.alerts.earlyResets = false
        return config
    }

    func session(_ used: Double, resetsAt: Date?, notStarted: Bool = false) -> UsageWindow {
        UsageWindow(id: "session", label: "5-hour", usedPercent: used, windowMinutes: 300, resetsAt: resetsAt, notStarted: notStarted)
    }

    func ok(_ windows: UsageWindow...) -> Result<UsageSnapshot, FetchError> {
        .success(UsageSnapshot(accountID: account.id, provider: .claude, windows: windows, fetchedAt: now, source: "test"))
    }

    func run(
        _ state: inout AlertState, _ result: Result<UsageSnapshot, FetchError>, config: AppConfig? = nil,
        account: AccountConfig? = nil, at time: Date? = nil
    ) -> AlertOutcome {
        AlertEngine.evaluate(
            account: account ?? self.account, result: result, config: config ?? thresholdsOnly, state: &state, now: time ?? now, clock: clock,
            locale: Locale(identifier: "en_US")
        )
    }

    // MARK: Baseline

    @Test func firstEvaluationOnlyRecordsBaseline() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3600)
        #expect(run(&state, ok(session(90, resetsAt: resetsAt))) == AlertOutcome())
        #expect(run(&state, ok(session(91, resetsAt: resetsAt))) == AlertOutcome())
        let crossed = run(&state, ok(session(96, resetsAt: resetsAt)))
        #expect(crossed.events.map(\.kind) == [.threshold(95)])
    }

    @Test func persistedStateRebaselinesButRemembersFiredAlerts() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)))
        #expect(run(&state, ok(session(85, resetsAt: resetsAt))).events.count == 1)

        var restored = try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state))
        #expect(restored.baselinedAccounts.isEmpty)
        #expect(restored.firedKeys == state.firedKeys)
        #expect(run(&restored, ok(session(96, resetsAt: resetsAt))) == AlertOutcome())
        #expect(run(&restored, ok(session(97, resetsAt: resetsAt))) == AlertOutcome())
    }

    // MARK: Thresholds

    @Test func firesOnlyTheHighestNewlyCrossedThreshold() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(72 * 60)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)))
        let outcome = run(&state, ok(session(97, resetsAt: resetsAt)))
        let event = try #require(outcome.events.first)
        #expect(outcome.events.count == 1)
        #expect(event.kind == .threshold(95))
        #expect(event.title == "Claude · Work")
        #expect(event.body == "5-hour limit at 97% · resets in 1h 12m")
        #expect(event.threadID == "claude-work")
        #expect(event.accountID == "claude-work")
        #expect(event.windowID == "session")
        #expect(event.id == "claude-work|session|\(AlertEngine.cycleID(resetsAt))|95")
        #expect(run(&state, ok(session(98, resetsAt: resetsAt))) == AlertOutcome())
        // Skipped thresholds count as crossed, so a dip within the cycle does not fire the lower one late.
        #expect(run(&state, ok(session(90, resetsAt: resetsAt))) == AlertOutcome())
    }

    @Test func doesNotRepeatWithinACycleAndSupersedesLowerThreshold() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)))
        let first = run(&state, ok(session(82, resetsAt: resetsAt)))
        #expect(first.events.map(\.kind) == [.threshold(80)])
        for used in [85.0, 79.0, 84.0, 90.0] {
            #expect(run(&state, ok(session(used, resetsAt: resetsAt))) == AlertOutcome())
        }
        let higher = run(&state, ok(session(95, resetsAt: resetsAt)))
        #expect(higher.events.map(\.kind) == [.threshold(95)])
        #expect(higher.withdrawals == [try #require(first.events.first).id])
    }

    @Test func accountThresholdsOverrideGlobalOnes() {
        var state = AlertState()
        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work", alertThresholds: [90, 70])
        let resetsAt = now.addingTimeInterval(3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)), account: work)
        #expect(run(&state, ok(session(72, resetsAt: resetsAt)), account: work).events.map(\.kind) == [.threshold(70)])
        #expect(run(&state, ok(session(81, resetsAt: resetsAt)), account: work) == AlertOutcome())
    }

    @Test func toleratesResetJitterAcrossTheRoundingBoundary() {
        var state = AlertState()
        // xx:05:00 is where rounding to 10 minutes flips, so jitter of a fraction of a second changes the rounded value.
        let boundary = Date(timeIntervalSince1970: 1_800_003_300)
        let early = boundary.addingTimeInterval(-0.3), late = boundary.addingTimeInterval(0.4)
        #expect(AlertEngine.cycleID(early) != AlertEngine.cycleID(late))
        _ = run(&state, ok(session(10, resetsAt: early)))
        #expect(run(&state, ok(session(82, resetsAt: late))).events.count == 1)
        #expect(run(&state, ok(session(83, resetsAt: early))) == AlertOutcome())
        #expect(run(&state, ok(session(84, resetsAt: late))) == AlertOutcome())
    }

    // MARK: Resets

    /// Real snapshots carry several windows, and Claude's ids share a prefix (`weekly`, `weekly:Fable`). A reset of one
    /// window must withdraw and re-arm only that window's alerts, and a first poll must not clear another's baseline.
    @Test func aResetOnlyRearmsItsOwnWindow() {
        var state = AlertState()
        let sessionReset = now.addingTimeInterval(3600)
        let weeklyReset = now.addingTimeInterval(2 * 86_400), fableReset = now.addingTimeInterval(3 * 86_400)
        func poll(_ session: Double, _ weekly: Double, _ fable: Double, weeklyResetsAt: Date) -> AlertOutcome {
            run(&state, ok(
                self.session(session, resetsAt: sessionReset),
                UsageWindow(id: "weekly", label: "Week", usedPercent: weekly, windowMinutes: 10_080, resetsAt: weeklyResetsAt),
                UsageWindow(id: "weekly:Fable", label: "Week · Fable", usedPercent: fable, windowMinutes: 10_080, resetsAt: fableReset)
            ))
        }

        #expect(poll(85, 85, 85, weeklyResetsAt: weeklyReset) == AlertOutcome())
        #expect(poll(86, 86, 86, weeklyResetsAt: weeklyReset) == AlertOutcome())
        let reset = poll(86, 2, 86, weeklyResetsAt: weeklyReset.addingTimeInterval(7 * 86_400))
        #expect(reset == AlertOutcome(withdrawals: ["claude-work|weekly|\(AlertEngine.cycleID(weeklyReset))|80"]))
        #expect(poll(87, 3, 87, weeklyResetsAt: weeklyReset.addingTimeInterval(7 * 86_400)) == AlertOutcome())
    }

    @Test func reArmsAfterAResetAndWithdrawsTheOldCycle() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)))
        let before = try #require(run(&state, ok(session(85, resetsAt: resetsAt))).events.first)

        let next = resetsAt.addingTimeInterval(5 * 3600)
        let reset = run(&state, ok(session(2, resetsAt: next)), at: resetsAt.addingTimeInterval(60))
        #expect(reset.events.isEmpty)
        #expect(reset.withdrawals == [before.id])

        let after = try #require(run(&state, ok(session(83, resetsAt: next)), at: next.addingTimeInterval(-3600)).events.first)
        #expect(after.kind == .threshold(80))
        #expect(after.id != before.id)
    }

    @Test func resetIsAForwardJumpOfMoreThanHalfTheWindow() {
        let resetsAt = now.addingTimeInterval(3600)
        let half: TimeInterval = 150 * 60
        #expect(!AlertEngine.isNewCycle(session(50, resetsAt: resetsAt.addingTimeInterval(half)), previousUsed: 50, previousReset: resetsAt))
        #expect(AlertEngine.isNewCycle(session(50, resetsAt: resetsAt.addingTimeInterval(half + 1)), previousUsed: 50, previousReset: resetsAt))
        #expect(!AlertEngine.isNewCycle(session(50, resetsAt: resetsAt.addingTimeInterval(-3 * 3600)), previousUsed: 50, previousReset: resetsAt))
        #expect(!AlertEngine.isNewCycle(session(60.1, resetsAt: resetsAt), previousUsed: 90, previousReset: resetsAt))
        #expect(AlertEngine.isNewCycle(session(60, resetsAt: resetsAt), previousUsed: 90, previousReset: resetsAt))
    }

    @Test func usageDropReArmsAWindowWithoutResetTime() throws {
        var state = AlertState()
        _ = run(&state, ok(session(10, resetsAt: nil)))
        let before = try #require(run(&state, ok(session(85, resetsAt: nil))).events.first)
        #expect(before.body == "5-hour limit at 85%")
        let dropped = run(&state, ok(session(40, resetsAt: nil)), at: now.addingTimeInterval(3600))
        #expect(dropped.withdrawals == [before.id])
        let again = try #require(run(&state, ok(session(81, resetsAt: nil)), at: now.addingTimeInterval(7200)).events.first)
        #expect(again.id != before.id)
    }

    @Test func aPollWithoutResetTimeKeepsTheLastOne() throws {
        // A cycle that ends under the 30-point drop can only be detected through the reset time moving forward.
        var state = AlertState()
        let low = AccountConfig(id: "claude-work", provider: .claude, label: "Work", alertThresholds: [20])
        let resetsAt = now.addingTimeInterval(3600), next = resetsAt.addingTimeInterval(5 * 3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)), account: low)
        let before = try #require(run(&state, ok(session(25, resetsAt: resetsAt)), account: low).events.first)

        #expect(run(&state, ok(session(0, resetsAt: nil)), account: low, at: resetsAt.addingTimeInterval(60)) == AlertOutcome())
        let reset = run(&state, ok(session(5, resetsAt: next)), account: low, at: resetsAt.addingTimeInterval(120))
        #expect(reset.withdrawals == [before.id])
        let after = run(&state, ok(session(30, resetsAt: next)), account: low, at: resetsAt.addingTimeInterval(3600))
        #expect(after.events.map(\.kind) == [.threshold(20)])
    }

    @Test func windowsWhoseResetHasPassedAreIgnored() throws {
        // A stale fallback snapshot from a finished cycle alternating with live polls.
        var state = AlertState()
        let current = now.addingTimeInterval(4 * 3600), finished = now.addingTimeInterval(-600)
        _ = run(&state, ok(session(10, resetsAt: current)))
        #expect(run(&state, ok(session(85, resetsAt: finished))) == AlertOutcome())
        #expect(run(&state, ok(session(11, resetsAt: current))) == AlertOutcome())
        #expect(run(&state, ok(session(85, resetsAt: finished))) == AlertOutcome())
        #expect(run(&state, ok(session(85, resetsAt: now))) == AlertOutcome())
        #expect(run(&state, ok(session(82, resetsAt: current))).events.map(\.kind) == [.threshold(80)])
    }

    @Test func resetAlertNeedsTheSettingAndAHighPreviousCycle() throws {
        var config = thresholdsOnly
        config.alerts.windowResets = true
        let resetsAt = now.addingTimeInterval(3600), next = resetsAt.addingTimeInterval(5 * 3600)

        var high = AlertState()
        _ = run(&high, ok(session(10, resetsAt: resetsAt)), config: config)
        _ = run(&high, ok(session(80, resetsAt: resetsAt)), config: config)
        let reset = run(&high, ok(session(3, resetsAt: next)), config: config, at: resetsAt.addingTimeInterval(60))
        let event = try #require(reset.events.first)
        #expect(reset.events.count == 1)
        #expect(event.kind == .windowReset)
        #expect(event.body == "5-hour limit reset · now at 3%")

        var low = AlertState()
        _ = run(&low, ok(session(10, resetsAt: resetsAt)), config: config)
        _ = run(&low, ok(session(79.9, resetsAt: resetsAt)), config: config)
        #expect(run(&low, ok(session(3, resetsAt: next)), config: config, at: resetsAt.addingTimeInterval(60)).events.isEmpty)
    }

    // MARK: Early resets

    func weekly(_ used: Double, resetsAt: Date?) -> UsageWindow {
        UsageWindow(id: "weekly", label: "Week", usedPercent: used, windowMinutes: 10_080, resetsAt: resetsAt)
    }

    var withEarlyResets: AppConfig {
        var config = thresholdsOnly
        config.alerts.earlyResets = true
        return config
    }

    /// One poll an hour from `start`; the first poll of a fresh state is the launch baseline.
    func pollHourly(_ state: inout AlertState, _ windows: [UsageWindow], config: AppConfig? = nil, from start: Date? = nil) -> [AlertOutcome] {
        windows.enumerated().map { index, window in
            run(&state, ok(window), config: config ?? withEarlyResets, at: (start ?? now).addingTimeInterval(Double(index) * 3600))
        }
    }

    func earlyResetEvents(_ outcomes: [AlertOutcome]) -> [AlertEvent] {
        outcomes.flatMap(\.events).filter { $0.kind == .earlyReset }
    }

    @Test func aCycleStartingDaysBeforeItsResetIsAnnouncedOnceTheNextPollAgrees() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400), next = now.addingTimeInterval(2 * 3600 + 7 * 86_400)
        let outcomes = pollHourly(&state, [
            weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt), weekly(2, resetsAt: next), weekly(3, resetsAt: next), weekly(4, resetsAt: next),
        ])
        #expect(earlyResetEvents(Array(outcomes[..<3])).isEmpty, "one sample is not enough")
        let event = try #require(earlyResetEvents([outcomes[3]]).first)
        #expect(event.body == "Week limit reset early · now at 3% · next reset Fri 10:00")
        #expect(event.title == "Claude · Work")
        #expect(event.id == "claude-work|weekly|\(AlertEngine.cycleID(next))|early")
        #expect(event.windowID == "weekly")
        #expect(earlyResetEvents([outcomes[4]]).isEmpty)
    }

    @Test func usageClearedWhileTheResetTimeStaysPutIsAnEarlyReset() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400)
        let outcomes = pollHourly(&state, [
            weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt),
            weekly(1, resetsAt: resetsAt.addingTimeInterval(-120)), weekly(2, resetsAt: resetsAt.addingTimeInterval(90)),
        ])
        #expect(earlyResetEvents(outcomes).map(\.body) == ["Week limit reset early · now at 2% · next reset Mon 08:01"])
    }

    @Test func anOnScheduleResetIsNotEarly() {
        var config = withEarlyResets
        config.alerts.windowResets = true
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(2 * 3600), next = resetsAt.addingTimeInterval(7 * 86_400)
        let outcomes = pollHourly(&state, [
            weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt), weekly(2, resetsAt: next), weekly(3, resetsAt: next),
        ], config: config)
        #expect(outcomes[2].events.map(\.kind) == [.windowReset])
        #expect(earlyResetEvents(outcomes).isEmpty)
    }

    /// The Mac's clock a few minutes behind the provider's makes a scheduled reset look early; reset times that wobble
    /// by minutes are not a reset at all.
    @Test func clockSkewAndResetTimeJitterAreNotEarly() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(4 * 3600), next = resetsAt.addingTimeInterval(7 * 86_400)
        var outcomes = pollHourly(&state, [
            weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt.addingTimeInterval(240)),
            weekly(90, resetsAt: resetsAt.addingTimeInterval(-240)), weekly(91, resetsAt: resetsAt),
        ])
        outcomes.append(run(&state, ok(weekly(1, resetsAt: next)), config: withEarlyResets, at: resetsAt.addingTimeInterval(-3 * 60)))
        outcomes.append(run(&state, ok(weekly(2, resetsAt: next)), config: withEarlyResets, at: resetsAt.addingTimeInterval(57 * 60)))
        #expect(earlyResetEvents(outcomes).isEmpty)
    }

    @Test func earlyMeansAtLeastAnHourBeforeTheScheduledReset() {
        func events(seenBefore lead: TimeInterval) -> [AlertEvent] {
            var state = AlertState()
            let resetsAt = now.addingTimeInterval(5 * 3600), next = resetsAt.addingTimeInterval(7 * 86_400)
            var outcomes = pollHourly(&state, [weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt)])
            let seen = resetsAt.addingTimeInterval(-lead)
            outcomes.append(run(&state, ok(weekly(1, resetsAt: next)), config: withEarlyResets, at: seen))
            outcomes.append(run(&state, ok(weekly(2, resetsAt: next)), config: withEarlyResets, at: seen.addingTimeInterval(600)))
            return earlyResetEvents(outcomes)
        }
        #expect(events(seenBefore: 3600).count == 1)
        #expect(events(seenBefore: 3599).isEmpty)
    }

    /// A lagging replica or a zero read that the next poll takes back.
    @Test func aSampleThatBouncesBackIsNotAnEarlyReset() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400)
        let outcomes = pollHourly(&state, [
            weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt), weekly(0, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt),
            weekly(0, resetsAt: resetsAt.addingTimeInterval(7 * 86_400)), weekly(91, resetsAt: resetsAt), weekly(92, resetsAt: resetsAt),
        ])
        #expect(earlyResetEvents(outcomes).isEmpty)
    }

    @Test func anAnnouncedEarlyResetIsNotRepeatedAfterARelaunch() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400), next = now.addingTimeInterval(7 * 86_400)
        let first = pollHourly(&state, [weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt), weekly(2, resetsAt: next), weekly(3, resetsAt: next)])
        #expect(earlyResetEvents(first).count == 1)

        var restored = try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state))
        let later = pollHourly(&restored, [weekly(3, resetsAt: next), weekly(4, resetsAt: next), weekly(5, resetsAt: next)], from: now.addingTimeInterval(4 * 3600))
        #expect(earlyResetEvents(later).isEmpty)
        #expect(earlyResetEvents(pollHourly(&state, [weekly(4, resetsAt: next), weekly(5, resetsAt: next)], from: now.addingTimeInterval(4 * 3600))).isEmpty)
    }

    /// Like every other alert, what the launch baseline sees is recorded, not announced.
    @Test func anEarlyResetFirstSeenOnTheBaselinePollStaysQuiet() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400), next = now.addingTimeInterval(7 * 86_400)
        _ = pollHourly(&state, [weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt)])

        var restored = try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state))
        let later = pollHourly(&restored, [weekly(2, resetsAt: next), weekly(3, resetsAt: next)], from: now.addingTimeInterval(2 * 3600))
        #expect(earlyResetEvents(later).isEmpty)
    }

    /// A provider's saved copy can hold an earlier, lower reading of the same cycle.
    @Test func aSavedCopyNeverStartsAnEarlyReset() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400)
        _ = pollHourly(&state, [weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt)])
        let saved = Result<UsageSnapshot, FetchError>.success(UsageSnapshot(
            accountID: account.id, provider: .claude, windows: [weekly(20, resetsAt: resetsAt)], fetchedAt: now, source: "cache", liveCheckFailure: .network
        ))
        let outcomes = (2...3).map { run(&state, saved, config: withEarlyResets, at: now.addingTimeInterval(Double($0) * 3600)) }
        #expect(earlyResetEvents(outcomes).isEmpty)
    }

    @Test func earlyResetAlertsCanBeTurnedOff() {
        for change in [{ (config: inout AppConfig) in config.alerts.earlyResets = false }, { $0.alerts.enabled = false }] {
            var config = withEarlyResets
            change(&config)
            var state = AlertState()
            let resetsAt = now.addingTimeInterval(3 * 86_400), next = now.addingTimeInterval(7 * 86_400)
            let outcomes = pollHourly(&state, [weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt), weekly(2, resetsAt: next), weekly(3, resetsAt: next)], config: config)
            #expect(earlyResetEvents(outcomes).isEmpty)
        }
    }

    /// With the plain reset alert on too, the early one replaces it rather than stacking a second notice for one reset.
    @Test func anEarlyResetReplacesThePlainResetNotice() throws {
        var config = withEarlyResets
        config.alerts.windowResets = true
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 86_400), next = now.addingTimeInterval(7 * 86_400)
        let outcomes = pollHourly(&state, [weekly(10, resetsAt: resetsAt), weekly(90, resetsAt: resetsAt), weekly(2, resetsAt: next), weekly(3, resetsAt: next)], config: config)
        let plain = try #require(outcomes[2].events.first { $0.kind == .windowReset })
        #expect(outcomes[3].events.map(\.kind) == [.earlyReset])
        #expect(outcomes[3].withdrawals == [plain.id])
    }

    // MARK: Projection

    func projection(used: Double, resetIn: TimeInterval, config: AppConfig = AppConfig()) -> [AlertEvent] {
        var state = AlertState()
        let window = { (used: Double) in self.session(used, resetsAt: self.now.addingTimeInterval(resetIn)) }
        _ = run(&state, ok(window(1)), config: config)
        return run(&state, ok(window(used)), config: config).events.filter { $0.kind == .projectedExhaustion }
    }

    @Test func projectsExhaustionOncePerCycle() throws {
        // 2h of 5h elapsed at 60 %: runs out in 80m, the reset is in 3h.
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 3600)
        _ = run(&state, ok(session(20, resetsAt: resetsAt)), config: AppConfig(), at: now.addingTimeInterval(-3600))
        let outcome = run(&state, ok(session(60, resetsAt: resetsAt)), config: AppConfig())
        let event = try #require(outcome.events.first)
        #expect(outcome.events.count == 1)
        #expect(event.kind == .projectedExhaustion)
        #expect(event.body == "5-hour will run out about 1h 40m before it resets (11:00)")
        #expect(run(&state, ok(session(62, resetsAt: resetsAt)), config: AppConfig(), at: now.addingTimeInterval(600)) == AlertOutcome())
    }

    @Test func projectionNeedsHalfUsed() {
        #expect(projection(used: 50, resetIn: 3 * 3600).count == 1)
        #expect(projection(used: 49.9, resetIn: 3 * 3600).isEmpty)
    }

    @Test func projectionNeedsTenPercentElapsed() {
        // 5h window: 10 % elapsed is 30 minutes, so the reset is 4h30m away.
        #expect(projection(used: 50, resetIn: 270 * 60).count == 1)
        #expect(projection(used: 50, resetIn: 270 * 60 + 1).isEmpty)
    }

    @Test func projectionNeedsFifteenMinutesOfMargin() {
        // At 60 % the ETA is two thirds of the elapsed time, so the margin is 18000 - 5/3 * elapsed seconds.
        #expect(projection(used: 60, resetIn: 18_000 - (18_000 - 901) * 0.6).count == 1)
        #expect(projection(used: 60, resetIn: 18_000 - (18_000 - 899) * 0.6).isEmpty)
    }

    @Test func projectionSkipsFullWindowsAndCanBeTurnedOff() {
        #expect(projection(used: 100, resetIn: 3 * 3600).isEmpty)
        var off = AppConfig()
        off.alerts.projectedExhaustion = false
        #expect(projection(used: 60, resetIn: 3 * 3600, config: off).isEmpty)
    }

    // MARK: Source problems

    @Test func sourceProblemFiresOncePerEpisodeAndClearsOnSuccess() throws {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)))

        let failed = run(&state, .failure(.notSignedIn))
        let event = try #require(failed.events.first)
        #expect(failed.events.count == 1)
        #expect(event.kind == .sourceProblem)
        #expect(event.title == "Claude · Work")
        #expect(event.body == "Signed out. Sign in again to see limits.")
        #expect(event.id == "claude-work|source")
        #expect(run(&state, .failure(.cliNotFound("claude"))) == AlertOutcome())

        let recovered = run(&state, ok(session(11, resetsAt: resetsAt)))
        #expect(recovered == AlertOutcome(withdrawals: [event.id]))
        #expect(run(&state, .failure(.parse("unexpected token near <REDACTED>"))).events.map(\.body) == ["Couldn't read the usage answer. An update may have changed it."])
    }

    @Test func transientFailuresNeverAlert() {
        var state = AlertState()
        _ = run(&state, ok(session(10, resetsAt: now.addingTimeInterval(3600))))
        for error in [FetchError.network("REDACTED"), .timeout, .rateLimited(retryAfter: 60)] {
            #expect(run(&state, .failure(error)) == AlertOutcome())
        }
        #expect(run(&state, .failure(.unauthorized)).events.count == 1)
    }

    @Test func failureBeforeBaselineIsSilent() {
        var state = AlertState()
        #expect(run(&state, .failure(.notSignedIn)) == AlertOutcome())
        #expect(run(&state, .failure(.notSignedIn)) == AlertOutcome())
        #expect(run(&state, ok(session(90, resetsAt: now.addingTimeInterval(3600)))).events.isEmpty)
        #expect(run(&state, .failure(.notSignedIn)).events.count == 1)
    }

    /// The app stops probing a Claude account after a run that spent tokens, so that first failure is the only chance
    /// to say so, baseline or not. The user's switches still apply.
    @Test(arguments: [ClaudeUsageFetcher.modelTurnMessage, AntigravityUsageFetcher.modelTurnMessage])
    func aProbeThatSpentTokensAlertsEvenBeforeBaseline(message: String) {
        var state = AlertState()
        #expect(run(&state, .failure(.unsupported(message))).events.map(\.body) == [message])
        #expect(run(&state, .failure(.unsupported(message))) == AlertOutcome(), "still once per episode")

        var muted = thresholdsOnly
        muted.alerts.sourceProblems = false
        var fresh = AlertState()
        #expect(run(&fresh, .failure(.unsupported(message)), config: muted) == AlertOutcome())
        muted = thresholdsOnly
        muted.alerts.enabled = false
        fresh = AlertState()
        #expect(run(&fresh, .failure(.unsupported(message)), config: muted) == AlertOutcome())
        fresh = AlertState()
        #expect(run(&fresh, .failure(.unsupported("Update agy to 1.1.11 or later"))) == AlertOutcome(), "other failures still wait for a baseline")
    }

    /// A denial notifies only after a success this launch, such as when config.json is pointed at a key not read yet.
    /// Neither the notification nor the dashboard its click opens has a Try Again button, so the text cannot ask for one.
    @Test func aKeychainDenialAfterABaselineNotifiesWithoutNamingAButton() throws {
        var state = AlertState()
        _ = run(&state, ok(session(10, resetsAt: now.addingTimeInterval(3600))))
        let failed = run(&state, .failure(.keychainDenied))
        let event = try #require(failed.events.first)
        #expect(failed.events.count == 1)
        #expect(event.kind == .sourceProblem)
        #expect(!event.body.contains("Try Again"))
    }

    @Test func sourceProblemsCanBeTurnedOff() {
        var config = thresholdsOnly
        config.alerts.sourceProblems = false
        var state = AlertState()
        _ = run(&state, ok(session(10, resetsAt: now.addingTimeInterval(3600))), config: config)
        #expect(run(&state, .failure(.notSignedIn), config: config) == AlertOutcome())
    }

    // MARK: Global switches and idle windows

    @Test func disabledAlertsStaySilentAndDoNotReplayWhenReEnabled() {
        var disabled = AppConfig()
        disabled.alerts.enabled = false
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3 * 3600)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)), config: disabled)
        #expect(run(&state, ok(session(85, resetsAt: resetsAt)), config: disabled).events.isEmpty)
        #expect(run(&state, .failure(.notSignedIn), config: disabled).events.isEmpty)
        #expect(run(&state, ok(session(86, resetsAt: resetsAt)), config: disabled).events.isEmpty)

        #expect(run(&state, ok(session(87, resetsAt: resetsAt)), config: AppConfig()).events.isEmpty)
        #expect(run(&state, ok(session(96, resetsAt: resetsAt)), config: AppConfig()).events.map(\.kind) == [.threshold(95)])
    }

    @Test func notStartedWindowsNeverCrossThresholdsOrProject() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(5 * 3600)
        _ = run(&state, ok(session(0, resetsAt: resetsAt, notStarted: true)), config: AppConfig())
        #expect(run(&state, ok(session(97, resetsAt: resetsAt, notStarted: true)), config: AppConfig()) == AlertOutcome())
    }

    @Test func aResetIntoAnIdleWindowStillAlerts() throws {
        // OpenCode Go reports a window that just reset as 0 % and not started.
        var config = thresholdsOnly
        config.alerts.windowResets = true
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3600), after = resetsAt.addingTimeInterval(60)
        _ = run(&state, ok(session(10, resetsAt: resetsAt)), config: config)
        _ = run(&state, ok(session(85, resetsAt: resetsAt)), config: config)
        let reset = run(&state, ok(session(0, resetsAt: after.addingTimeInterval(5 * 3600), notStarted: true)), config: config, at: after)
        #expect(reset.events.map(\.body) == ["5-hour limit reset · now at 0%"])
    }

    @Test func durationsMatchTheAppCountdowns() {
        #expect(AlertEngine.duration(3 * 86_400 + 4 * 3600 + 59) == "3d 4h")
        #expect(AlertEngine.duration(72 * 60) == "1h 12m")
        #expect(AlertEngine.duration(40 * 60) == "40m")
        #expect(AlertEngine.duration(59) == "<1m")
        #expect(AlertEngine.duration(-5) == "<1m")
        // Pace math lands a hair under whole minutes; truncating would print "1h 39m".
        #expect(AlertEngine.duration(5_999.9999) == "1h 40m")
    }

    @Test func cycleIDRoundsToTenMinutes() {
        #expect(AlertEngine.cycleID(Date(timeIntervalSince1970: 1_800_000_299)) == 1_800_000_000)
        #expect(AlertEngine.cycleID(Date(timeIntervalSince1970: 1_800_000_301)) == 1_800_000_600)
    }

    // MARK: Daily budget

    private func daily(_ spent: Double, budget: Double = 100, dayStart: Date? = nil) -> DailySpend {
        let start = dayStart ?? now.addingTimeInterval(-8 * 3600)
        return DailySpend(
            spent: spent, budget: budget, isRecommended: false, currency: "USD", dayStart: start, dayEnd: start.addingTimeInterval(86_400), countedFrom: nil
        )
    }

    private func runDaily(_ state: inout AlertState, _ spend: DailySpend, config: AppConfig? = nil) -> AlertOutcome {
        AlertEngine.evaluate(account: account, result: ok(), config: config ?? thresholdsOnly, state: &state, now: now, clock: clock, daily: spend, locale: Locale(identifier: "en_US"))
    }

    /// One notification a day, the first time today's spend goes over the budget.
    @Test func goingOverTheDailyBudgetNotifiesOnceADay() {
        var state = AlertState()
        #expect(runDaily(&state, daily(40)).events.isEmpty)
        let over = runDaily(&state, daily(120))
        #expect(over.events.map(\.kind) == [.dailyBudget])
        #expect(over.events.first?.body == "Today's spend is over its daily budget: $120 of $100")
        #expect(runDaily(&state, daily(150)).events.isEmpty)
        let tomorrow = now.addingTimeInterval(16 * 3600)
        #expect(runDaily(&state, daily(40, dayStart: tomorrow)).events.isEmpty)
        #expect(runDaily(&state, daily(130, dayStart: tomorrow)).events.map(\.kind) == [.dailyBudget])
    }

    /// Only today's key is kept, so the state does not grow by one key a day.
    @Test func earlierDaysAreForgotten() {
        var state = AlertState()
        _ = runDaily(&state, daily(40))
        _ = runDaily(&state, daily(120))
        _ = runDaily(&state, daily(130, dayStart: now.addingTimeInterval(16 * 3600)))
        #expect(state.firedKeys.filter { $0.contains("|daily|") }.count == 1)
    }

    @Test func theDailyBudgetIsQuietWithAlertsOff() {
        var state = AlertState()
        var config = thresholdsOnly
        config.alerts.enabled = false
        _ = runDaily(&state, daily(40), config: config)
        #expect(runDaily(&state, daily(120), config: config).events.isEmpty)
    }

    // MARK: Over a spend limit

    private func spendLimit(_ used: Double) -> Result<UsageSnapshot, FetchError> {
        let window = UsageWindow(
            id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: used, windowMinutes: 44_640, resetsAt: now.addingTimeInterval(18 * 86_400),
            limitStyle: .overage
        )
        let money = MoneyLine(label: "Extra usage", amount: used * 30, limit: 3_000, currency: "USD")
        return .success(UsageSnapshot(accountID: account.id, provider: .claude, windows: [window], money: [money], fetchedAt: now, source: "test"))
    }

    /// Once per cycle, the first time spend goes past the limit, with the money.
    @Test func goingOverASpendLimitNotifiesOnce() {
        var state = AlertState()
        _ = run(&state, spendLimit(96))
        let over = run(&state, spendLimit(104))
        #expect(over.events.map(\.kind) == [.overLimit])
        #expect(over.events.first?.body == "Spend limit passed: $3,120 of $3,000")
        #expect(run(&state, spendLimit(110)).events.isEmpty)
    }

    /// A limit that stops the work at 100 % says so through its threshold alerts, never "passed".
    @Test func aHardLimitAtFullIsNotPassed() {
        var state = AlertState()
        let resetsAt = now.addingTimeInterval(3600)
        _ = run(&state, ok(session(90, resetsAt: resetsAt)))
        #expect(!run(&state, ok(session(104, resetsAt: resetsAt))).events.contains { $0.kind == .overLimit })
    }

    /// "Spend limit limit at 80%" doubled the word.
    @Test func aLabelEndingInLimitIsNotDoubled() {
        var state = AlertState()
        _ = run(&state, spendLimit(50))
        #expect(run(&state, spendLimit(81)).events.first?.body == "Spend limit at 81% · resets in 18d 0h")
    }

    /// Raising the limit mid-month drops the share without a new month: no reset notice, and crossed levels stay crossed.
    @Test func aRaisedSpendLimitIsNotAReset() {
        var state = AlertState()
        _ = run(&state, spendLimit(50))
        _ = run(&state, spendLimit(96))
        let raised = run(&state, spendLimit(48))
        #expect(!raised.events.contains { $0.kind == .windowReset })
        #expect(raised.withdrawals.isEmpty)
    }

    /// Under $100 a day the cents are the difference between over and not.
    @Test func aSmallDailyBudgetKeepsItsCents() {
        var state = AlertState()
        _ = runDaily(&state, daily(1, budget: 3.33))
        #expect(runDaily(&state, daily(3.40, budget: 3.33)).events.first?.body == "Today's spend is over its daily budget: $3.40 of $3.33")
    }
}

