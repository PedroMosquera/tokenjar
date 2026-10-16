import Foundation

public enum AlertKind: Codable, Hashable, Sendable {
    case threshold(Int)
    case projectedExhaustion
    case windowReset
    case earlyReset
    case sourceProblem
    case dailyBudget
    case overLimit
}

public struct AlertEvent: Hashable, Sendable {
    /// Notification request identifier. It is the dedupe key, so re-posting replaces instead of stacking.
    public var id: String
    /// Groups notifications per account in Notification Center.
    public var threadID: String
    public var title: String
    public var body: String
    public var kind: AlertKind
    public var accountID: String
    public var windowID: String?

    public init(id: String, threadID: String, title: String, body: String, kind: AlertKind, accountID: String, windowID: String? = nil) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.body = body
        self.kind = kind
        self.accountID = accountID
        self.windowID = windowID
    }
}

/// What one evaluation asks the notifier to do. Withdrawals are separate from events because a reset or a
/// recovered source removes delivered notifications even when nothing new is posted.
public struct AlertOutcome: Equatable, Sendable {
    public var events: [AlertEvent]
    /// Identifiers of notifications that no longer apply. Some were recorded silently and never delivered;
    /// removing an identifier that was never delivered is a no-op.
    public var withdrawals: [String]

    public init(events: [AlertEvent] = [], withdrawals: [String] = []) {
        self.events = events
        self.withdrawals = withdrawals
    }
}

/// Persisted between launches so alerts are not repeated after a restart.
public struct AlertState: Codable, Equatable, Sendable {
    /// Dedupe keys already alerted, or recorded silently, in each window's current cycle.
    public var firedKeys: Set<String>
    /// Not persisted: every launch re-baselines, so nothing fires on the first poll after launch.
    public var baselinedAccounts: Set<String>
    public var failingAccounts: Set<String>
    /// Last known reset per "accountID|windowID", to detect resets. A poll without a reset time keeps the previous one.
    public var lastResetsAt: [String: Date]
    public var lastUsedPercent: [String: Double]
    /// Cycle id per "accountID|windowID": the reset time, rounded to 10 minutes, when the cycle was first seen.
    /// Held for the whole cycle so jitter across a rounding boundary cannot re-arm alerts.
    public var cycles: [String: Int]
    /// Not persisted: a new cycle that began well before the old reset, per "accountID|windowID", waiting for the next
    /// sample of this launch to confirm it.
    public var earlyResetCandidates: [String: EarlyResetCandidate]

    public init() {
        firedKeys = []
        baselinedAccounts = []
        failingAccounts = []
        lastResetsAt = [:]
        lastUsedPercent = [:]
        cycles = [:]
        earlyResetCandidates = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case firedKeys, failingAccounts, lastResetsAt, lastUsedPercent, cycles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        firedKeys = try c.decodeIfPresent(Set<String>.self, forKey: .firedKeys) ?? []
        failingAccounts = try c.decodeIfPresent(Set<String>.self, forKey: .failingAccounts) ?? []
        lastResetsAt = try c.decodeIfPresent([String: Date].self, forKey: .lastResetsAt) ?? [:]
        lastUsedPercent = try c.decodeIfPresent([String: Double].self, forKey: .lastUsedPercent) ?? [:]
        cycles = try c.decodeIfPresent([String: Int].self, forKey: .cycles) ?? [:]
    }
}

/// The old cycle's last reading before a sample showed it starting over early.
public struct EarlyResetCandidate: Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date
    /// Seen while the poll was silent, so confirming it records the alert without posting it.
    public var silent: Bool
}

public enum AlertEngine {
    static let cycleRounding: TimeInterval = 600
    /// How far ahead the old reset must still be for a new cycle to count as early. It absorbs clock skew between the
    /// Mac and the provider and reset times rounded to the hour, and a reset less than an hour early is not news.
    static let earlyResetMargin: TimeInterval = 3600
    static let resetDropPoints = 30.0
    static let resetAlertMinimumUsed = 80.0
    static let projectionMinimumUsed = 50.0
    static let projectionMinimumElapsed = 0.10
    static let projectionMinimumMargin: TimeInterval = 15 * 60

    /// Pure: the outcome and the new `state` depend only on the arguments.
    ///
    /// An account's first successful snapshot in a session only records a baseline: crossings already present
    /// are marked as alerted without posting. Failures before that are recorded silently too, except a probe that spent
    /// tokens, which notifies at once. With alerts disabled the state keeps tracking the same way, so turning alerts on
    /// does not replay old crossings.
    /// Network errors, timeouts and rate limiting never open a source-problem episode: they usually mean the Mac
    /// went offline, and would otherwise notify once per account.
    /// Windows whose reset time has passed are skipped. A not-started window never fires a threshold or a projection,
    /// but can still get a reset alert, because OpenCode Go reports a window that just reset as not started.
    /// `clock` formats the reset time in projection alerts; tests pass a fixed locale and time zone.
    public static func evaluate(
        account: AccountConfig, result: Result<UsageSnapshot, FetchError>, config: AppConfig,
        state: inout AlertState, now: Date, clock: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened),
        daily: DailySpend? = nil, locale: Locale = .autoupdatingCurrent
    ) -> AlertOutcome {
        switch result {
        case .failure(let error):
            return sourceFailed(account: account, error: error, config: config, state: &state)
        case .success(let snapshot):
            var outcome = AlertOutcome()
            if state.failingAccounts.remove(account.id) != nil {
                outcome.withdrawals.append(sourceKey(account))
            }
            let silent = !config.alerts.enabled || !state.baselinedAccounts.contains(account.id)
            state.baselinedAccounts.insert(account.id)
            for window in snapshot.windows {
                evaluate(
                    window, account: account, config: config, silent: silent, savedCopy: snapshot.liveCheckFailure != nil,
                    state: &state, now: now, clock: clock,
                    money: window.id == UsageWindow.spendCapID ? snapshot.spendLimitMoney : nil, locale: locale, into: &outcome
                )
            }
            if let daily { evaluate(daily, account: account, silent: silent, state: &state, locale: locale, into: &outcome) }
            return outcome
        }
    }

    private static func sourceFailed(account: AccountConfig, error: FetchError, config: AppConfig, state: inout AlertState) -> AlertOutcome {
        guard error.attention != .transient, state.failingAccounts.insert(account.id).inserted else { return AlertOutcome() }
        // A run that spent tokens is news, not a condition carried over from before launch, and the app stops probing a
        // Claude account after one, so waiting for a baseline would mean never saying so.
        guard state.baselinedAccounts.contains(account.id) || spentTokens(error), config.alerts.enabled, config.alerts.sourceProblems
        else { return AlertOutcome() }
        let event = AlertEvent(
            id: sourceKey(account), threadID: account.id, title: account.displayName, body: error.userMessage,
            kind: .sourceProblem, accountID: account.id
        )
        return AlertOutcome(events: [event])
    }

    private static func spentTokens(_ error: FetchError) -> Bool {
        error == .unsupported(ClaudeUsageFetcher.modelTurnMessage) || error == .unsupported(AntigravityUsageFetcher.modelTurnMessage)
    }

    private static func evaluate(
        _ window: UsageWindow, account: AccountConfig, config: AppConfig, silent: Bool, savedCopy: Bool,
        state: inout AlertState, now: Date, clock: Date.FormatStyle, money: MoneyLine?, locale: Locale, into outcome: inout AlertOutcome
    ) {
        // A finished cycle's numbers, e.g. from a stale fallback snapshot, would fire into the current cycle.
        if let resetsAt = window.resetsAt, resetsAt <= now { return }
        let windowKey = "\(account.id)|\(window.id)"
        let previousUsed = state.lastUsedPercent[windowKey], previousReset = state.lastResetsAt[windowKey]
        let isReset = previousUsed.map { isNewCycle(window, previousUsed: $0, previousReset: previousReset) } ?? false
        state.lastUsedPercent[windowKey] = window.usedPercent
        if let resetsAt = window.resetsAt { state.lastResetsAt[windowKey] = resetsAt }

        if isReset || state.cycles[windowKey] == nil {
            let stale = state.firedKeys.filter { $0.hasPrefix(windowKey + "|") }
            state.firedKeys.subtract(stale)
            outcome.withdrawals += stale.sorted()
            state.cycles[windowKey] = cycleID(window.resetsAt ?? now)
        }
        let prefix = "\(windowKey)|\(state.cycles[windowKey]!)|"

        if isReset, config.alerts.windowResets, let previousUsed, previousUsed >= resetAlertMinimumUsed {
            let key = prefix + "reset"
            state.firedKeys.insert(key)
            if !silent {
                outcome.events.append(event(key, account, window, .windowReset, "\(limitName(window)) reset · now at \(percent(window.usedPercent))"))
            }
        }

        // Early: a new cycle while the old reset was still `earlyResetMargin` ahead, announced only if the next sample
        // still reads as a new cycle against the old one. A saved copy can hold an earlier, lower reading of this cycle.
        if !savedCopy {
            if let candidate = state.earlyResetCandidates.removeValue(forKey: windowKey),
               isNewCycle(window, previousUsed: candidate.usedPercent, previousReset: candidate.resetsAt) {
                if config.alerts.earlyResets {
                    let key = prefix + "early"
                    state.firedKeys.insert(key)
                    if !silent, !candidate.silent {
                        // The plain reset notice describes the same reset with less.
                        outcome.withdrawals += [prefix + "reset"].filter(state.firedKeys.contains)
                        var body = "\(limitName(window)) reset early · now at \(percent(window.usedPercent))"
                        if let resetsAt = window.resetsAt { body += " · next reset \(resetsAt.formatted(clock.weekday(.abbreviated)))" }
                        outcome.events.append(event(key, account, window, .earlyReset, body))
                    }
                }
            } else if isReset, let previousUsed, let previousReset, previousReset.timeIntervalSince(now) >= earlyResetMargin {
                state.earlyResetCandidates[windowKey] = EarlyResetCandidate(usedPercent: previousUsed, resetsAt: previousReset, silent: silent)
            }
        }

        guard !window.notStarted else { return }

        let crossed = config.thresholds(for: account).filter { window.usedPercent >= Double($0) }
        if let top = crossed.max(), !state.firedKeys.contains(prefix + "\(top)") {
            let lowerKeys = crossed.filter { $0 != top }.map { prefix + "\($0)" }
            if !silent {
                outcome.withdrawals += lowerKeys.filter(state.firedKeys.contains)
                var body = "\(limitName(window)) at \(percent(window.usedPercent))"
                if let resetsAt = window.resetsAt { body += " · resets in \(duration(resetsAt.timeIntervalSince(now)))" }
                outcome.events.append(event(prefix + "\(top)", account, window, .threshold(top), body))
            }
            state.firedKeys.formUnion(lowerKeys)
            state.firedKeys.insert(prefix + "\(top)")
        }

        // A limit billed past 100 % gets one notice when spend first passes it; nothing stops, so no threshold says so.
        if window.limitStyle == .overage, window.usedPercent > 100, state.firedKeys.insert(prefix + "over").inserted, !silent {
            let body = if let money, let limit = money.limit {
                "\(window.label) passed: \(Self.money(money.amount, money.currency, locale)) of \(Self.money(limit, money.currency, locale))"
            } else {
                "\(window.label) passed at \(percent(window.usedPercent))"
            }
            outcome.events.append(event(prefix + "over", account, window, .overLimit, body))
        }

        if config.alerts.projectedExhaustion,
           window.usedPercent >= projectionMinimumUsed, window.usedPercent < 100,
           let resetsAt = window.resetsAt,
           let pace = Pace.compute(window, now: now, minimumElapsedFraction: projectionMinimumElapsed),
           let eta = pace.secondsToExhaustion,
           pace.secondsToReset - eta >= projectionMinimumMargin,
           state.firedKeys.insert(prefix + "projected").inserted, !silent {
            let margin = duration(pace.secondsToReset - eta)
            let verb = window.limitStyle == .overage ? "will pass its limit" : "will run out"
            let body = "\(window.label) \(verb) about \(margin) before it resets (\(resetsAt.formatted(clock)))"
            outcome.events.append(event(prefix + "projected", account, window, .projectedExhaustion, body))
        }
    }

    /// Once a day, the first time today's spend goes over the budget. Only today's key is kept.
    private static func evaluate(
        _ daily: DailySpend, account: AccountConfig, silent: Bool, state: inout AlertState, locale: Locale, into outcome: inout AlertOutcome
    ) {
        let prefix = "\(account.id)|daily|"
        let key = prefix + "\(Int(daily.dayStart.timeIntervalSince1970))"
        state.firedKeys = state.firedKeys.filter { !$0.hasPrefix(prefix) || $0 == key }
        guard daily.isOver, state.firedKeys.insert(key).inserted, !silent else { return }
        // Cents under a $100 budget, as the popover shows them, or $3.40 of $3.33 would read "$3 of $3".
        let digits = daily.budget >= 100 ? 0 : 2
        let money = { (amount: Double) in amount.formatted(.currency(code: daily.currency).precision(.fractionLength(digits)).locale(locale)) }
        outcome.events.append(AlertEvent(
            id: key, threadID: account.id, title: account.displayName,
            body: "Today's spend is over its daily budget: \(money(daily.spent)) of \(money(daily.budget))",
            kind: .dailyBudget, accountID: account.id, windowID: DailySpend.windowID
        ))
    }

    /// A reset moves the reset time forward by about a whole window; half a window leaves room for providers
    /// that start the next window at first use. The usage drop covers windows without a reset time or length.
    /// A spend limit's share also drops when its limit is raised mid-month, so with reset times on both sides only the
    /// reset time moving starts its new cycle.
    static func isNewCycle(_ window: UsageWindow, previousUsed: Double, previousReset: Date?) -> Bool {
        let resetKnown = previousReset != nil && window.resetsAt != nil
        if previousUsed - window.usedPercent >= resetDropPoints, !(window.limitStyle == .overage && resetKnown) { return true }
        guard let previousReset, let resetsAt = window.resetsAt, let minutes = window.windowMinutes else { return false }
        return resetsAt.timeIntervalSince(previousReset) > Double(minutes) * 60 / 2
    }

    static func cycleID(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / cycleRounding).rounded()) * Int(cycleRounding)
    }

    static func sourceKey(_ account: AccountConfig) -> String {
        "\(account.id)|source"
    }

    private static func event(_ id: String, _ account: AccountConfig, _ window: UsageWindow, _ kind: AlertKind, _ body: String) -> AlertEvent {
        AlertEvent(id: id, threadID: account.id, title: account.displayName, body: body, kind: kind, accountID: account.id, windowID: window.id)
    }

    /// "Week limit", but "Spend limit" as it is rather than "Spend limit limit".
    private static func limitName(_ window: UsageWindow) -> String {
        window.label.lowercased().hasSuffix("limit") ? window.label : "\(window.label) limit"
    }

    private static func money(_ amount: Double, _ currency: String, _ locale: Locale) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(0)).locale(locale))
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Same shape as the app's countdowns: "3d 4h", "1h 12m", "40m", "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}
