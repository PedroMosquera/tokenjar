import Foundation
import HeadroomCore

nonisolated enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Usage history is stored per calendar day, so "24h" covers yesterday and today rather than a partial day.
    var dayCount: Int {
        switch self {
        case .day: 2
        case .week: 7
        case .month: 30
        }
    }

    /// Bucket for thinning window samples, so a 30-day chart stays a few hundred points per line.
    var sampleBucket: TimeInterval {
        switch self {
        case .day: 0
        case .week: 30 * 60
        case .month: 2 * 3600
        }
    }

    var dayCaption: String {
        switch self {
        case .day: "today and yesterday"
        case .week: "last 7 days"
        case .month: "last 30 days"
        }
    }
}

/// Calendar boundaries for the KPI tiles and day-grained sections, all at local midnight.
nonisolated struct DashboardPeriods: Equatable, Sendable {
    var now: Date
    var today: Date
    /// Today and the six days before it.
    var lastSevenDays: Date
    var thisMonth: Date
    /// Earliest day any section needs, so one query serves every tile and range.
    var loadStart: Date
    private var calendar: Calendar

    init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        lastSevenDays = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let longest = calendar.date(byAdding: .day, value: -(DashboardRange.month.dayCount - 1), to: today) ?? today
        loadStart = min(thisMonth, longest)
    }

    func firstDay(of range: DashboardRange) -> Date {
        calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
    }

    func days(of range: DashboardRange) -> [Date] {
        (0..<range.dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
}

nonisolated struct CostTotal: Equatable, Sendable {
    var amount: Double = 0
    /// True when any part came from the price table rather than a cost the harness recorded.
    var isEstimate = false
    var pricedRows = 0
    var unpricedRows = 0

    var hasUsage: Bool { pricedRows + unpricedRows > 0 }
    var hasCost: Bool { pricedRows > 0 }
}

nonisolated struct UsageTotals: Equatable, Sendable {
    var tokens = 0
    var requests = 0
}

nonisolated struct SpendSegment: Identifiable, Equatable, Sendable {
    var day: Date
    var group: String
    var cost: Double

    var id: String { "\(day.timeIntervalSinceReferenceDate)|\(group)" }
}

nonisolated struct SpendBreakdown: Equatable, Sendable {
    /// Legend order: highest total cost first, "Other" last.
    var groups: [String] = []
    /// Sorted by day, then by legend order, so stacks put the largest group at the base.
    var segments: [SpendSegment] = []
    /// Models with usage in range that have neither a price nor a recorded cost.
    var unpricedModels: [String] = []
    var isEstimate = false
    var hasUsage = false
}

nonisolated struct ProjectSummary: Identifiable, Equatable, Sendable {
    var project: String
    var requests: Int
    var tokens: Int
    /// nil when no row of this project could be priced.
    var cost: Double?
    var isEstimate: Bool

    var id: String { project }
}

nonisolated struct LimitPoint: Identifiable, Equatable, Sendable {
    /// Account id in the All view, window id for a single account.
    var seriesID: String
    var label: String
    /// Increments across a gap in sampling (app quit, Mac asleep) so the line breaks instead of bridging it.
    var segment: Int
    var date: Date
    var usedPercent: Double
    /// Position in the series; stores can hold two samples with the same timestamp, so the date is not a key.
    var index: Int

    var id: String { "\(seriesID)|\(index)" }
    var lineID: String { "\(seriesID)#\(segment)" }
}

nonisolated struct ResetMarker: Identifiable, Equatable, Sendable {
    var seriesID: String
    var date: Date

    var id: String { "\(seriesID)|\(date.timeIntervalSinceReferenceDate)" }
}

/// Pure aggregation behind the dashboard. Callers price rows first (`AppModel.pricedUsage`), then regroup here.
nonisolated enum DashboardMath {
    static let otherGroup = "Other"
    static let noProject = "No project"

    /// Same sum as `UsageEvent.totalTokens`; reasoning tokens are already part of output.
    static func tokens(_ row: DailyUsageRow) -> Int {
        row.inputTokens + row.outputTokens + row.cacheReadTokens + row.cacheWrite5mTokens + row.cacheWrite1hTokens
    }

    static func cost(_ rows: [PricedUsageRow], since: Date) -> CostTotal {
        var total = CostTotal()
        for priced in rows where priced.row.day >= since && priced.row.requests > 0 {
            if let cost = priced.costUSD {
                total.amount += cost
                total.pricedRows += 1
                total.isEstimate = total.isEstimate || priced.isEstimate
            } else {
                total.unpricedRows += 1
            }
        }
        return total
    }

    static func totals(_ rows: [PricedUsageRow], since: Date) -> UsageTotals {
        rows.reduce(into: UsageTotals()) { totals, priced in
            guard priced.row.day >= since else { return }
            totals.tokens += tokens(priced.row)
            totals.requests += priced.row.requests
        }
    }

    static func groupKey(_ row: DailyUsageRow, by grouping: UsageGrouping, accountNames: [String: String]) -> String {
        switch grouping {
        case .model: row.model
        case .harness: harnessName(row.harness)
        case .project: row.project ?? noProject
        case .account: accountNames[row.accountID] ?? row.accountID
        }
    }

    static func harnessName(_ harness: Harness) -> String {
        switch harness {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    /// Daily cost stacked by `grouping`. Keeps the `limit` most expensive groups and folds the rest into
    /// "Other", unless only one group would fold (a one-member "Other" hides a name and saves no legend space).
    static func dailySpend(
        _ rows: [PricedUsageRow], by grouping: UsageGrouping, since: Date, limit: Int, accountNames: [String: String] = [:]
    ) -> SpendBreakdown {
        var breakdown = SpendBreakdown()
        var totals: [String: Double] = [:]
        var unpriced: Set<String> = []
        var inRange: [(row: DailyUsageRow, group: String, cost: Double)] = []
        for priced in rows where priced.row.day >= since && priced.row.requests > 0 {
            breakdown.hasUsage = true
            guard let cost = priced.costUSD else {
                unpriced.insert(priced.row.model)
                continue
            }
            breakdown.isEstimate = breakdown.isEstimate || priced.isEstimate
            let group = groupKey(priced.row, by: grouping, accountNames: accountNames)
            totals[group, default: 0] += cost
            inRange.append((priced.row, group, cost))
        }
        breakdown.unpricedModels = unpriced.sorted()

        let ranked = totals.filter { $0.value > 0 }.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }.map(\.key)
        let kept = ranked.count > limit + 1 ? Array(ranked.prefix(limit)) : ranked
        let keptSet = Set(kept)
        breakdown.groups = kept.count < ranked.count ? kept + [otherGroup] : kept
        let order = Dictionary(uniqueKeysWithValues: breakdown.groups.enumerated().map { ($1, $0) })

        struct Key: Hashable { var day: Date; var group: String }
        var sums: [Key: Double] = [:]
        for entry in inRange where entry.cost > 0 {
            let group = keptSet.contains(entry.group) ? entry.group : otherGroup
            sums[Key(day: entry.row.day, group: group), default: 0] += entry.cost
        }
        breakdown.segments = sums.map { SpendSegment(day: $0.key.day, group: $0.key.group, cost: $0.value) }.sorted { a, b in
            a.day != b.day ? a.day < b.day : (order[a.group] ?? .max) < (order[b.group] ?? .max)
        }
        return breakdown
    }

    /// Projects by cost (unpriced last), then tokens. Rows without a project are grouped under "No project".
    static func topProjects(_ rows: [PricedUsageRow], since: Date, limit: Int) -> [ProjectSummary] {
        var byProject: [String: ProjectSummary] = [:]
        for priced in rows where priced.row.day >= since && priced.row.requests > 0 {
            let name = priced.row.project ?? noProject
            var summary = byProject[name] ?? ProjectSummary(project: name, requests: 0, tokens: 0, cost: nil, isEstimate: false)
            summary.requests += priced.row.requests
            summary.tokens += tokens(priced.row)
            if let cost = priced.costUSD {
                summary.cost = (summary.cost ?? 0) + cost
                summary.isEstimate = summary.isEstimate || priced.isEstimate
            }
            byProject[name] = summary
        }
        let sorted = byProject.values.sorted { a, b in
            if (a.cost ?? -1) != (b.cost ?? -1) { return (a.cost ?? -1) > (b.cost ?? -1) }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return a.project < b.project
        }
        return Array(sorted.prefix(limit))
    }

    /// Keeps the highest sample per `bucket` (peaks are what matter against a limit) plus the latest sample,
    /// so the line still ends at the current value. Input must be sorted by time.
    static func downsample(_ samples: [WindowSample], bucket: TimeInterval) -> [WindowSample] {
        guard bucket > 0, samples.count > 2 else { return samples }
        var out: [WindowSample] = []
        var currentBucket: Double?
        for sample in samples {
            let b = (sample.timestamp.timeIntervalSinceReferenceDate / bucket).rounded(.down)
            if b != currentBucket {
                out.append(sample)
                currentBucket = b
            } else if sample.usedPercent >= out[out.count - 1].usedPercent {
                out[out.count - 1] = sample
            }
        }
        if let last = samples.last, out.last != last { out.append(last) }
        return out
    }

    /// Times where a window in use reset: `resetsAt` jumped forward by more than `tolerance` (providers
    /// report the same reset with a few seconds of jitter) and either the old reset passed or usage dropped
    /// (a reset credit). An idle window's synthetic `resetsAt` (sample time + window) jumps on every sample
    /// and across every gap, so a jump from a sample at 0% never counts. The marker sits at the old reset
    /// time when it falls between the two samples, else at the first sample of the new cycle.
    static func resets(in samples: [WindowSample], tolerance: TimeInterval = 600) -> [Date] {
        var out: [Date] = []
        for (previous, next) in zip(samples, samples.dropFirst()) {
            guard previous.usedPercent > 0, let before = previous.resetsAt, let after = next.resetsAt,
                  after.timeIntervalSince(before) > tolerance,
                  before <= next.timestamp || next.usedPercent < previous.usedPercent else { continue }
            out.append(before > previous.timestamp && before <= next.timestamp ? before : next.timestamp)
        }
        return out
    }

    /// How to thin one window's samples for `range`. With more than `maxCycles` resets in view the sawtooth
    /// turns into a solid band, so each window-length bucket keeps only its peak and the line traces how high
    /// every cycle got instead.
    static func sampling(for range: DashboardRange, windowMinutes: Int?, maxCycles: Double = 12) -> (bucket: TimeInterval, peaksOnly: Bool) {
        guard let minutes = windowMinutes, minutes > 0 else { return (range.sampleBucket, false) }
        let length = Double(minutes) * 60
        guard range.duration / length > maxCycles else { return (range.sampleBucket, false) }
        return (max(range.sampleBucket, length), true)
    }

    /// One chart series: thinned, clamped to 0...100, and split wherever consecutive samples are more than `maxGap` apart.
    static func limitPoints(
        seriesID: String, label: String, samples: [WindowSample], bucket: TimeInterval, maxGap: TimeInterval
    ) -> [LimitPoint] {
        var segment = 0
        var previous: Date?
        return downsample(samples, bucket: bucket).enumerated().map { index, sample in
            if let previous, sample.timestamp.timeIntervalSince(previous) > maxGap { segment += 1 }
            previous = sample.timestamp
            return LimitPoint(
                seriesID: seriesID, label: label, segment: segment, date: sample.timestamp,
                usedPercent: min(100, max(0, sample.usedPercent)), index: index
            )
        }
    }
}
