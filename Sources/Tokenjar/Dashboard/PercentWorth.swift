import Foundation
import TokenjarCore

/// What 1% of a limit window a day or longer bought, cycle by cycle: the tokens and API-equivalent cost this Mac's logs
/// recorded from the cycle's start up to its highest check, over the used % at that check. Usage is cut at the
/// check's timestamp, not at a local day, so a cycle that resets mid-day gets exactly its own part of that day.
nonisolated struct PercentWorth: Equatable, Sendable {
    struct Cycle: Equatable, Sendable {
        var start: Date
        var resetsAt: Date
        var peakPercent: Double
        /// When the peak was sampled; usage counts up to here so the % and the tokens describe the same moment.
        var peakAt: Date
    }

    struct Row: Identifiable, Equatable, Sendable {
        var cycle: Cycle
        var tokens: Int
        /// nil when a model used in the cycle has no price, which would understate it.
        var cost: Double?
        var isEstimate: Bool
        var isCurrent: Bool

        var id: Date { cycle.resetsAt }
        var tokensPerPercent: Double { Double(tokens) / cycle.peakPercent }
        var costPerPercent: Double? { cost.map { $0 / cycle.peakPercent } }
    }

    var windowID: String
    var label: String
    /// Newest first.
    var rows: [Row]

    static let floorPercent = 10.0
    static let cycleLimit = 8
    /// Providers report one reset with a few seconds of jitter, as `DashboardMath.resets` allows for.
    static let resetTolerance: TimeInterval = 600

    /// Windows of a day or more that cover the whole account. An id with a colon is scoped to a model, a pool or an extra
    /// limit, whose % the account's total usage would overstate; a spend cap is money, not a share of a plan. None
    /// without local logs, or when another account reads the same logs (`sharesLocalSource`).
    static func windows(account: AccountConfig, snapshot: UsageSnapshot?, sharesLocalSource: Bool) -> [UsageWindow] {
        guard account.provider.harness != nil, !sharesLocalSource else { return [] }
        return (snapshot?.windows ?? []).filter { window in
            !window.id.contains(":") && window.id != UsageWindow.spendCapID && (window.windowMinutes ?? 0) >= 1_440 && window.resetsAt != nil
        }
    }

    /// True when another account on this Mac scans the same logs. Event keys carry no account, so those rows are stored
    /// under whichever account scanned first and mix both logins' usage.
    static func sharesLocalSource(_ account: AccountConfig, among accounts: [AccountConfig], paths: AppPaths) -> Bool {
        func source(_ account: AccountConfig) -> String? {
            guard let scanner = FetcherRegistry.scanner(for: account.provider), let key = scanner.sharedSourceKey(for: account, paths: paths) else { return nil }
            return scanner.name + "|" + key
        }
        guard let mine = source(account) else { return false }
        return accounts.contains { $0.id != account.id && source($0) == mine }
    }

    /// A window of 28 days or more follows its billing month, as `UsageWindow.monthMinutes` has it, so each past cycle
    /// gets its own month's length rather than the current one's.
    static func cycleLength(of window: UsageWindow) -> (Date) -> TimeInterval {
        let minutes = window.windowMinutes ?? 0
        guard minutes >= 28 * 1_440 else { return { _ in TimeInterval(minutes) * 60 } }
        return { reset in TimeInterval(UsageWindow.monthMinutes(endingAt: reset) ?? minutes) * 60 }
    }

    /// Consecutive samples whose resets agree within `resetTolerance` make one cycle. A cycle starts one window before
    /// its reset, but never before the previous cycle's last sample, so no usage counts twice.
    static func cycles(samples: [WindowSample], length: (Date) -> TimeInterval) -> [Cycle] {
        var groups: [[WindowSample]] = []
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let reset = sample.resetsAt else { continue }
            if let previous = groups.last?.last?.resetsAt, abs(reset.timeIntervalSince(previous)) <= resetTolerance {
                groups[groups.count - 1].append(sample)
            } else {
                groups.append([sample])
            }
        }
        var out: [Cycle] = []
        var previousEnd: Date?
        for group in groups {
            guard let last = group.last, let reset = last.resetsAt,
                  let peak = group.reversed().max(by: { $0.usedPercent < $1.usedPercent }) else { continue }
            let nominal = reset.addingTimeInterval(-length(reset))
            out.append(Cycle(start: max(nominal, previousEnd ?? nominal), resetsAt: reset, peakPercent: peak.usedPercent, peakAt: peak.timestamp))
            previousEnd = last.timestamp
        }
        return out
    }

    /// Newest first, at most `limit`. A cycle under `floor` % is left out, since a small divisor turns noise into a wild
    /// number, and so is one with no local usage, whose use all happened elsewhere.
    static func rows(
        cycles: [Cycle], now: Date, limit: Int = cycleLimit, floor: Double = floorPercent, usage: (DateInterval) -> [PricedUsageRow]
    ) -> [Row] {
        var out: [Row] = []
        for cycle in cycles.reversed() where out.count < limit && cycle.peakPercent >= floor && cycle.peakAt > cycle.start {
            let priced = usage(DateInterval(start: cycle.start, end: cycle.peakAt)).filter { $0.row.requests > 0 }
            let tokens = priced.reduce(0) { $0 + DashboardMath.tokens($1.row) }
            guard tokens > 0 else { continue }
            let cost = DashboardMath.cost(priced, since: .distantPast)
            out.append(Row(
                cycle: cycle, tokens: tokens, cost: cost.hasCost && cost.unpricedRows == 0 ? cost.amount : nil,
                isEstimate: cost.isEstimate, isCurrent: cycle.resetsAt > now
            ))
        }
        return out
    }
}
