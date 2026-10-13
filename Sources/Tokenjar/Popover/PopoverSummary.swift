import Foundation
import TokenjarCore

/// Display name parts with the repetition default labels cause removed: "OpenCode Go · Go" becomes
/// "OpenCode Go", and a plan equal to the label ("Codex · Plus" on plan "Plus") gets no pill.
struct AccountTitle: Equatable {
    var provider: String
    var label: String?
    var plan: String?

    init(provider: ProviderID, label: String, plan: String? = nil) {
        self.provider = provider.displayName
        let providerWords = Set(provider.displayName.lowercased().split(separator: " ").map(String.init))
        let label = label.trimmingCharacters(in: .whitespaces)
        let isRedundant = { (text: String) in
            text.isEmpty || text.lowercased() == provider.displayName.lowercased() || providerWords.contains(text.lowercased())
        }
        self.label = isRedundant(label) ? nil : label
        let plan = plan?.trimmingCharacters(in: .whitespaces) ?? ""
        self.plan = isRedundant(plan) || plan.lowercased() == label.lowercased() ? nil : plan
    }

    var name: String { label.map { "\(provider) · \($0)" } ?? provider }
    /// `name` without the middle dot, which VoiceOver can read out.
    var spokenName: String { label.map { "\(provider) \($0)" } ?? provider }
}

/// The popover header's one-line answer: the account closest to a limit, or "All clear" with the next reset.
struct PopoverSummary: Equatable {
    enum Tone: Equatable {
        case clear, warning, critical, problem, empty
        /// The Mac has no usable network path.
        case offline
        /// The network is up, but no provider answers.
        case noAnswer
        /// An account that needs the network has no fresh data and its latest check could not reach the provider.
        case unreachable(onlyTimeouts: Bool)
    }

    var tone: Tone
    var text: String
    /// When an account is named, the other accounts with a window above ok, a failed check or no way to refresh, in
    /// config order.
    /// Cards keep config order, so this is how an at-risk account below the fold still reaches the header.
    var others: [String] = []
    /// Under a red or full title only: the other account whose fullest live window is least used, among those with fresh
    /// data and nothing amber, red or failed. "Codex has room: 5-hour 2% used".
    var room: String?

    /// How account names are written: `AccountTitle.name` on screen, `spokenName` for VoiceOver.
    enum Voice { case written, spoken }

    /// `majorOutages` are providers whose status page reports a major outage; the room hint never points at one.
    static func make(
        accounts: [AccountConfig], statuses: [String: AccountStatus], config: AppConfig, now: Date,
        connectivity: Connectivity = .online, settings: SettingsProblem? = nil, majorOutages: Set<ProviderID> = [], voice: Voice = .written
    ) -> PopoverSummary {
        // In priority order: what stops every check, then what makes every number old, then one account at a time.
        guard !accounts.isEmpty else {
            if settings?.nothingLoaded == true { return PopoverSummary(tone: .problem, text: "Settings not loaded") }
            return PopoverSummary(tone: .empty, text: "No accounts yet")
        }
        var worst: (account: AccountConfig, window: UsageWindow, severity: Severity)?
        var nextReset: Date?
        var failing = 0
        var withData = 0
        var needsALook: [AccountConfig] = []
        /// `needsALook` without the accounts a Mac-wide cause already explains.
        var needsYou: [AccountConfig] = []
        var unreachable: [(account: AccountConfig, failure: FetchError)] = []
        var roomiest: (account: AccountConfig, window: UsageWindow)?
        for account in accounts {
            let status = statuses[account.id] ?? AccountStatus()
            let refreshMinutes = account.refreshMinutes ?? config.refreshMinutes
            let failed = status.failureNeedsAttention(now: now, refreshMinutes: refreshMinutes)
            if failed { failing += 1 }
            let stuck = status.cannotRefresh(now: now, refreshMinutes: refreshMinutes)
            if stuck, let failure = status.connectionFailure { unreachable.append((account, failure)) }
            let pressed = Severity.worst(of: status.snapshot?.windows ?? [], config: config.menuBar, now: now) > .ok
            if failed || stuck || pressed { needsALook.append(account) }
            if failed || pressed { needsYou.append(account) }
            // A link card or a spend-only account is ready at once and has no limits, so it must not stand in for
            // accounts still being checked.
            guard let snapshot = status.snapshot, account.provider.reportsWindows else { continue }
            withData += 1
            // Strictly fewer, so a tie keeps the account first in config order.
            if !(failed || stuck || pressed), status.error?.attention != .calm, !majorOutages.contains(account.provider),
               !status.isStale(now: now, refreshMinutes: refreshMinutes), let fullest = snapshot.tightestWindow(now: now),
               roomiest.map({ fullest.usedPercent < $0.window.usedPercent }) ?? true {
                roomiest = (account, fullest)
            }
            for window in snapshot.windows where !window.hasReset(now: now) {
                let severity = Severity.of(window, config: config.menuBar, now: now)
                if worst.map({ (severity, window.usedPercent) > ($0.severity, $0.window.usedPercent) }) ?? true {
                    worst = (account, window, severity)
                }
                if window.usedPercent > 0, let resetsAt = window.resetsAt, resetsAt > now {
                    nextReset = min(nextReset ?? resetsAt, resetsAt)
                }
            }
        }
        let settingsName = settings == nil ? [] : ["settings"]
        // The title outranks the limit summary, so the near-limit account and the one to fix, which the menu bar's color
        // and dot point at, are named here instead.
        switch connectivity {
        case .offline: return PopoverSummary(tone: .offline, text: "Offline", others: needsYou.map { shortName($0, among: accounts, voice: voice) } + settingsName)
        case .noAnswer:
            return PopoverSummary(tone: .noAnswer, text: "Can't reach any provider", others: needsYou.map { shortName($0, among: accounts, voice: voice) } + settingsName)
        case .online: break
        }
        if let worst, worst.severity > .ok {
            let title = AccountTitle(provider: worst.account.provider, label: worst.account.label)
            let name = voice == .spoken ? title.spokenName : title.name
            let window = worst.window
            let detail: String
            if window.usedPercent >= 100, let countdown = Format.countdown(to: window.resetsAt, now: now) {
                detail = "\(window.label) full, resets in \(countdown)"
            } else {
                detail = "\(window.label) at \(Format.percent(window.usedPercent))"
            }
            let others = needsALook.filter { $0.id != worst.account.id }.map { shortName($0, among: accounts, voice: voice) } + settingsName
            // Only once the named window stops the work: under amber there is still room on that account. Full also
            // counts below Red at, which a hand-edited config can set above 100.
            let blocked = worst.severity == .critical || window.usedPercent >= 100
            let room = blocked ? roomiest.map {
                "\(shortName($0.account, among: accounts, voice: voice)) has room: \($0.window.label) \(Format.percent($0.window.usedPercent)) used"
            } : nil
            return PopoverSummary(tone: worst.severity == .critical ? .critical : .warning, text: "\(name): \(detail)", others: others, room: room)
        }
        if settings != nil { return PopoverSummary(tone: .problem, text: "Settings need attention") }
        if failing > 0 {
            return PopoverSummary(tone: .problem, text: failing == 1 ? "1 account needs attention" : "\(failing) accounts need attention")
        }
        if !unreachable.isEmpty {
            let onlyTimeouts = unreachable.allSatisfy { $0.failure == .timeout }
            guard unreachable.count == 1, let only = unreachable.first else {
                return PopoverSummary(tone: .unreachable(onlyTimeouts: onlyTimeouts), text: "\(unreachable.count) accounts can't refresh")
            }
            let name = shortName(only.account, among: accounts, voice: voice)
            return PopoverSummary(tone: .unreachable(onlyTimeouts: onlyTimeouts), text: onlyTimeouts ? "No answer from \(name)" : "Can't reach \(name)")
        }
        if withData == 0 {
            let nothingToTrack = accounts.allSatisfy { !$0.provider.reportsWindows || statuses[$0.id]?.error?.attention == .calm }
            return PopoverSummary(tone: .empty, text: nothingToTrack ? "No limits to track" : "Waiting for usage data")
        }
        guard let nextReset else { return PopoverSummary(tone: .clear, text: "All clear") }
        return PopoverSummary(tone: .clear, text: "All clear · next reset in \(Format.duration(nextReset.timeIntervalSince(now)))")
    }

    /// The header has room for a few words: the provider alone names an account unless another account shares it.
    private static func shortName(_ account: AccountConfig, among accounts: [AccountConfig], voice: Voice) -> String {
        let shared = accounts.contains { $0.id != account.id && $0.provider == account.provider }
        guard shared else { return account.provider.displayName }
        let title = AccountTitle(provider: account.provider, label: account.label)
        return voice == .spoken ? title.spokenName : title.name
    }
}

extension AccountStatus {
    /// A connection failure with no fresh data to show instead.
    func cannotRefresh(now: Date, refreshMinutes: Int) -> Bool {
        connectionFailure != nil && (snapshot == nil || isStale(now: now, refreshMinutes: refreshMinutes))
    }

    /// Whether the last failed check needs the user: the menu bar dot, the header's count and the orange icons. Only an
    /// actionable failure does. A network error, a timeout or a rate limit is nothing to fix, however old the data;
    /// the header names one that leaves no fresh data (`cannotRefresh`).
    func failureNeedsAttention(now: Date, refreshMinutes: Int) -> Bool {
        error?.attention == .actionable
    }
}

/// One line judging the pace of the most urgent window among those with enough elapsed time to project.
struct PaceVerdict: Equatable {
    enum Kind: Equatable {
        case onPace
        /// Points of used % above an even pace.
        case ahead(Double)
        /// Points of used % below an even pace.
        case under(Double)
        /// Seconds between projected exhaustion and the reset.
        case runsOut(TimeInterval)
        /// Already at 100 %; seconds until the reset.
        case exhausted(TimeInterval)

        fileprivate var urgency: Int {
            switch self {
            case .onPace, .under: 0
            case .ahead: 1
            case .runsOut: 2
            case .exhausted: 3
            }
        }

        fileprivate var lockout: TimeInterval {
            if case .runsOut(let gap) = self { return gap }
            return 0
        }
    }

    var window: UsageWindow
    var kind: Kind

    /// Deltas inside this band read as "On pace"; smaller ones are noise from sampling and rounding.
    static let tolerance = 5.0

    /// Judges every paced window from 1 % used and keeps the most urgent kind, then among run-outs the longer lockout
    /// before the reset, then the higher severity, then the higher used %. "Runs out" uses the projected-exhaustion
    /// alert thresholds in docs/design.md, so whenever that alert fires the verdict reads "Runs out" or "Limit
    /// reached"; earlier or smaller overuse reads as "Ahead of pace".
    static func make(windows: [UsageWindow], config: MenuBarConfig, now: Date) -> PaceVerdict? {
        let judged = windows.filter { $0.usedPercent >= 1 }.compactMap { window in
            Pace.compute(window, now: now).map { pace in
                (verdict: PaceVerdict(window: window, kind: kind(of: window, pace: pace)), severity: Severity.of(window, config: config, now: now))
            }
        }
        return judged.max { a, b in
            (a.verdict.kind.urgency, a.verdict.kind.lockout, a.severity, a.verdict.window.usedPercent)
                < (b.verdict.kind.urgency, b.verdict.kind.lockout, b.severity, b.verdict.window.usedPercent)
        }?.verdict
    }

    private static func kind(of window: UsageWindow, pace: Pace) -> Kind {
        if window.usedPercent >= 100 { return .exhausted(pace.secondsToReset) }
        if pace.runsOutBeforeReset, window.usedPercent >= 50, pace.fractionElapsed >= 0.1,
           let eta = pace.secondsToExhaustion, pace.secondsToReset - eta >= 15 * 60 {
            return .runsOut(pace.secondsToReset - eta)
        }
        if pace.delta >= tolerance { return .ahead(pace.delta) }
        if pace.delta <= -tolerance { return .under(-pace.delta) }
        return .onPace
    }

    /// A projected or actual run-out is at least a warning even below `warnAt`, so the line explains an orange bar.
    func severity(config: MenuBarConfig, now: Date) -> Severity {
        switch kind {
        case .onPace, .ahead, .under: .ok
        case .runsOut, .exhausted: max(.warning, Severity.of(window, config: config, now: now))
        }
    }

    var text: String { phrase(duration: Format.duration, about: "~") }

    /// `text` with the units spelled out, for VoiceOver.
    var spokenText: String { phrase(duration: Format.spokenDuration, about: "about ") }

    private func phrase(duration: (TimeInterval) -> String, about: String) -> String {
        switch kind {
        case .onPace: "On pace"
        case .ahead(let points): "Ahead of pace +\(Format.percent(points))"
        case .under(let points): "Under pace -\(Format.percent(points))"
        case .runsOut(let gap): "Runs out \(about)\(duration(gap)) before reset"
        case .exhausted(let untilReset): "Limit reached, resets in \(duration(untilReset))"
        }
    }
}
