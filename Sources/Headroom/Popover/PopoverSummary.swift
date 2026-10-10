import Foundation
import HeadroomCore

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
}

/// The popover header's one-line answer: the account closest to a limit, or "All clear" with the next reset.
struct PopoverSummary: Equatable {
    enum Tone: Equatable {
        case clear, warning, critical, problem, empty
    }

    var tone: Tone
    var text: String
    /// When an account is named, the other accounts with a window above ok or a failed check, in config order.
    /// Cards keep config order, so this is how an at-risk account below the fold still reaches the header.
    var others: [String] = []

    static func make(accounts: [AccountConfig], statuses: [String: AccountStatus], config: MenuBarConfig, now: Date) -> PopoverSummary {
        guard !accounts.isEmpty else { return PopoverSummary(tone: .empty, text: "No accounts yet") }
        var worst: (account: AccountConfig, window: UsageWindow, severity: Severity)?
        var nextReset: Date?
        var failing = 0
        var withData = 0
        var needsALook: [AccountConfig] = []
        for account in accounts {
            let status = statuses[account.id] ?? AccountStatus()
            if status.error != nil { failing += 1 }
            if status.error != nil || Severity.worst(of: status.snapshot?.windows ?? [], config: config, now: now) > .ok {
                needsALook.append(account)
            }
            guard let snapshot = status.snapshot else { continue }
            withData += 1
            for window in snapshot.windows {
                let severity = Severity.of(window, config: config, now: now)
                if worst.map({ (severity, window.usedPercent) > ($0.severity, $0.window.usedPercent) }) ?? true {
                    worst = (account, window, severity)
                }
                if window.usedPercent > 0, let resetsAt = window.resetsAt, resetsAt > now {
                    nextReset = min(nextReset ?? resetsAt, resetsAt)
                }
            }
        }
        if let worst, worst.severity > .ok {
            let name = AccountTitle(provider: worst.account.provider, label: worst.account.label).name
            let window = worst.window
            let detail: String
            if window.usedPercent >= 100, let countdown = Format.countdown(to: window.resetsAt, now: now) {
                detail = "\(window.label) full, resets in \(countdown)"
            } else {
                detail = "\(window.label) at \(Format.percent(window.usedPercent))"
            }
            // The caption has room for a few words: the provider alone names an account unless another account shares it.
            let others = needsALook.filter { $0.id != worst.account.id }.map { account in
                let shared = accounts.contains { $0.id != account.id && $0.provider == account.provider }
                return shared ? AccountTitle(provider: account.provider, label: account.label).name : account.provider.displayName
            }
            return PopoverSummary(tone: worst.severity == .critical ? .critical : .warning, text: "\(name): \(detail)", others: others)
        }
        if failing > 0 {
            return PopoverSummary(tone: .problem, text: failing == 1 ? "1 account needs attention" : "\(failing) accounts need attention")
        }
        if withData == 0 { return PopoverSummary(tone: .empty, text: "Waiting for usage data") }
        guard let nextReset else { return PopoverSummary(tone: .clear, text: "All clear") }
        return PopoverSummary(tone: .clear, text: "All clear · next reset in \(Format.duration(nextReset.timeIntervalSince(now)))")
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
    }

    var window: UsageWindow
    var kind: Kind

    /// Deltas inside this band read as "On pace"; smaller ones are noise from sampling and rounding.
    static let tolerance = 5.0

    /// Judges every paced window and keeps the most urgent kind, then the higher severity, then the higher used %.
    /// "Runs out" uses the projected-exhaustion alert thresholds in docs/design.md, so whenever that alert fires the
    /// verdict reads "Runs out" or "Limit reached"; earlier or smaller overuse reads as "Ahead of pace".
    static func make(windows: [UsageWindow], config: MenuBarConfig, now: Date) -> PaceVerdict? {
        let judged = windows.compactMap { window in
            Pace.compute(window, now: now).map { pace in
                (verdict: PaceVerdict(window: window, kind: kind(of: window, pace: pace)), severity: Severity.of(window, config: config, now: now))
            }
        }
        return judged.max { a, b in
            (a.verdict.kind.urgency, a.severity, a.verdict.window.usedPercent) < (b.verdict.kind.urgency, b.severity, b.verdict.window.usedPercent)
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

    var text: String {
        switch kind {
        case .onPace: "On pace"
        case .ahead(let points): "Ahead of pace +\(Format.percent(points))"
        case .under(let points): "Under pace -\(Format.percent(points))"
        case .runsOut(let gap): "Runs out ~\(Format.duration(gap)) before reset"
        case .exhausted(let untilReset): "Limit reached, resets in \(Format.duration(untilReset))"
        }
    }
}
