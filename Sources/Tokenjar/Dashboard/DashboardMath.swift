import Foundation
import TokenjarCore

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

    var inRangePhrase: String {
        switch self {
        case .day: "today or yesterday"
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
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
    var lastMonth: Date
    /// Earliest day the tiles and ranges need; `DashboardContent.hasUsage` covers this period.
    var loadStart: Date
    /// Earliest day any section needs, last month included, so one query serves every tile and range.
    var queryStart: Date
    private(set) var calendar: Calendar

    init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        lastSevenDays = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let longest = calendar.date(byAdding: .day, value: -(DashboardRange.month.dayCount - 1), to: today) ?? today
        loadStart = min(thisMonth, longest)
        lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        queryStart = min(lastMonth, loadStart)
    }

    func firstDay(of range: DashboardRange) -> Date {
        calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
    }

    func days(of range: DashboardRange) -> [Date] {
        (0..<range.dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// What both day-grained charts span for `range`, from its first day to the end of today, so a date sits at the
    /// same x in the limits and spend charts.
    func chartDomain(of range: DashboardRange) -> ClosedRange<Date> {
        firstDay(of: range)...(calendar.date(byAdding: .day, value: 1, to: today) ?? now)
    }

    /// The days both charts label: every day at 7d, and every seventh day counting back from today at 30d.
    func axisDays(of range: DashboardRange) -> [Date] {
        let days = days(of: range)
        guard range == .month else { return days }
        return stride(from: days.count - 1, through: 0, by: -7).map { days[$0] }.reversed()
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

nonisolated struct CacheHitRates: Equatable, Sendable {
    var overall: Double?
    var byModel: [String: Double] = [:]

    /// The line under the spend chart grouped by model, in legend order; nil when no model in `groups` has a rate.
    @MainActor func modelLine(groups: [String]) -> String? {
        let parts = groups.compactMap { model in
            byModel[model].map { "\(DashboardMath.displayName(model)) \(Format.percent($0 * 100))" }
        }
        return parts.isEmpty ? nil : "Cache hit rate: " + parts.joined(separator: ", ")
    }
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

    /// Two raw ids can share a display name, which is listed once.
    var unpricedModelNames: String {
        var seen: Set<String> = []
        return unpricedModels.map(DashboardMath.displayName).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
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

    static func cost(_ rows: [PricedUsageRow], since: Date, before end: Date? = nil) -> CostTotal {
        var total = CostTotal()
        for priced in rows where priced.row.day >= since && priced.row.day < (end ?? .distantFuture) && priced.row.requests > 0 {
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

    /// Cache reads over the whole prompt (`PromptTokens`), overall and per model id. A harness with no cache tokens in
    /// range is left out of both, so a provider that reports no caching neither shows 0 % nor dilutes the overall rate.
    static func cacheHitRates(_ rows: [PricedUsageRow], since: Date) -> CacheHitRates {
        let inRange = rows.map(\.row).filter { $0.day >= since }
        var byHarness: [Harness: PromptTokens] = [:]
        for row in inRange { byHarness[row.harness, default: PromptTokens()].add(row) }
        let reporting = Set(byHarness.filter { $0.value.reportsCache }.keys)
        var byModel: [String: PromptTokens] = [:]
        for row in inRange where reporting.contains(row.harness) { byModel[row.model, default: PromptTokens()].add(row) }
        return CacheHitRates(
            overall: byModel.values.reduce(PromptTokens(), +).cacheHitRate,
            byModel: byModel.compactMapValues(\.cacheHitRate)
        )
    }

    static func groupKey(_ row: DailyUsageRow, by grouping: UsageGrouping, accountNames: [String: String]) -> String {
        switch grouping {
        case .model: row.model
        case .harness: harnessName(row.harness)
        case .project: row.project ?? noProject
        case .account: accountNames[row.accountID] ?? row.accountID
        }
    }

    /// A model id as the spend legend, tooltip and "Not priced" line show it: no release date, and a price tier
    /// (`PriceTable.billedModel`'s `>100k` or `+fast`) in words. Grouping keys keep the raw id.
    static func displayName(_ model: String) -> String {
        var base = model
        var tier = ""
        if let marker = base.firstIndex(of: ">") {
            tier = " (long prompts)"
            base = String(base[..<marker])
        } else if base.hasSuffix("+fast") {
            tier = " (fast mode)"
            base = String(base.dropLast("+fast".count))
        }
        if let date = base.range(of: #"-\d{8}$"#, options: .regularExpression) {
            base.removeSubrange(date)
        }
        return base + tier
    }

    /// `accountNames` are the names `groupKey` gives accounts in config; any other account group is a raw id.
    static func displayGroup(_ group: String, by grouping: UsageGrouping, accountNames: Set<String>) -> String {
        guard group != otherGroup else { return group }
        switch grouping {
        case .model: return displayName(group)
        case .account: return accountNames.contains(group) ? group : "Removed account"
        case .harness, .project: return group
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

    /// The window the All chart draws for one account: the tightest of those long enough to show as a line at
    /// `range`, else the tightest of all. Without the filter a busy 5-hour window wins and turns the overview into
    /// a zigzag of per-cycle peaks, and the chosen window would flip with the time of day.
    static func overviewWindow(of snapshot: UsageSnapshot, range: DashboardRange) -> UsageWindow? {
        var readable = snapshot
        readable.windows = snapshot.windows.filter { !sampling(for: range, windowMinutes: $0.windowMinutes).peaksOnly }
        return readable.windows.isEmpty ? snapshot.tightestWindow : readable.tightestWindow
    }

    /// The limits chart's x range. At 24h it is the last 24 hours. Otherwise it is the domain it shares with the
    /// spend chart. When the samples begin inside it (`earliest`, with nothing before the range: `reachesBack`
    /// false), it starts just before the first sample and ends now, spanning at least `minimumSpan` so minutes of
    /// history still get a readable axis, and `since` is set so the card can say where the history begins.
    static func limitsDomain(
        range: DashboardRange, periods: DashboardPeriods, earliest: Date?, reachesBack: Bool, minimumSpan: TimeInterval = 3 * 3600
    ) -> (domain: ClosedRange<Date>, since: Date?) {
        let now = periods.now
        let full = range == .day ? now.addingTimeInterval(-86_400)...now : periods.chartDomain(of: range)
        guard let earliest, !reachesBack else { return (full, nil) }
        let padded = earliest.addingTimeInterval(-max(range.sampleBucket, 15 * 60))
        let start = max(full.lowerBound, min(padded, now.addingTimeInterval(-minimumSpan)))
        guard start > full.lowerBound else { return (full, nil) }
        return (start...now, earliest)
    }

    struct SpendPeriod: Equatable {
        var interval: DateInterval
        /// nil before the first sample: nothing was recorded, which is not the same as nothing spent.
        var amount: Double?
    }

    /// What each period added to a spend limit, from the window's samples: the month's total at the period's end
    /// minus at its start. A later reset date is the monthly reset, so the new total is all new spend; without reset
    /// dates, a drop of more than `resetDrop` points is. Any other drop is rounding and adds nothing. A period holding
    /// the first sample counts from that sample.
    static func recordedSpend(
        samples: [WindowSample], limit: Double, periods: [DateInterval], now: Date, resetDrop: Double = 0.5
    ) -> [SpendPeriod] {
        var total: [(date: Date, spent: Double)] = []
        var reference: Double?
        var lastReset: Date?
        var spent = 0.0
        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            let resetMoved = lastReset.flatMap { before in sample.resetsAt.map { $0.timeIntervalSince(before) > 3600 } } ?? false
            if let reset = sample.resetsAt { lastReset = reset }
            if reference != nil, resetMoved {
                spent += sample.usedPercent
                reference = sample.usedPercent
            } else if let level = reference {
                if sample.usedPercent >= level {
                    spent += sample.usedPercent - level
                    reference = sample.usedPercent
                } else if sample.resetsAt == nil, level - sample.usedPercent > resetDrop {
                    spent += sample.usedPercent
                    reference = sample.usedPercent
                }
            } else {
                reference = sample.usedPercent
            }
            total.append((sample.timestamp, spent / 100 * limit))
        }
        func spentBy(_ date: Date) -> Double? { total.last { $0.date <= date }?.spent }
        return periods.map { period in
            guard let end = spentBy(min(period.end, now)) else { return SpendPeriod(interval: period, amount: nil) }
            return SpendPeriod(interval: period, amount: end - (spentBy(period.start) ?? 0))
        }
    }

    /// The bars of the spend chart: the last 24 hours by hour at 24h, else the range's days, or the weeks that
    /// cover them.
    static func spendPeriods(range: DashboardRange, weekly: Bool, periods: DashboardPeriods) -> [DateInterval] {
        let calendar = periods.calendar
        if range == .day {
            guard let hour = calendar.dateInterval(of: .hour, for: periods.now) else { return [] }
            return (0..<24).reversed().map { DateInterval(start: hour.start.addingTimeInterval(-Double($0) * 3600), duration: 3600) }
        }
        let days = periods.days(of: range).compactMap { calendar.dateInterval(of: .day, for: $0) }
        guard weekly, let first = days.first, let last = days.last else { return days }
        var weeks: [DateInterval] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: first.start)
        while let week = cursor, week.start < last.end {
            weeks.append(week)
            cursor = calendar.dateInterval(of: .weekOfYear, for: week.end)
        }
        return weeks
    }

    /// One color slot per account for both dashboard charts. Accounts with limit windows come first in config
    /// order, so a spend-only account (OpenCode Zen) never leaves a gap between the drawn lines.
    static func colorSlots(accountIDs: [String], withWindows: Set<String>) -> [String: Int] {
        let ordered = accountIDs.filter(withWindows.contains) + accountIDs.filter { !withWindows.contains($0) }
        return Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
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

/// Where this month's API-equivalent cost is headed, and how that compares with last month's total.
nonisolated struct MonthForecast: Equatable, Sendable {
    /// nil until 5% of the month has passed.
    var projected: Double?
    /// `projected` against last month's total: 0.12 is 12% more. nil without a projection or a cost last month.
    var change: Double?

    static func make(monthToDate: Double, lastMonth: Double?, now: Date, calendar: Calendar) -> MonthForecast {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let projected = projection(of: monthToDate, month: month, now: now) else { return MonthForecast() }
        let change = lastMonth.flatMap { $0 > 0 ? projected / $0 - 1 : nil }
        return MonthForecast(projected: projected, change: change)
    }

    /// The month's total at its average rate so far, through `Pace` so it waits for the same share of the month to
    /// pass as a bar's pace does.
    static func projection(of amount: Double, month: DateInterval, now: Date) -> Double? {
        let window = UsageWindow(id: "month", label: "Month", usedPercent: 1, windowMinutes: Int(month.duration / 60), resetsAt: month.end)
        guard let pace = Pace.compute(window, now: now), pace.fractionElapsed > 0 else { return nil }
        return amount / pace.fractionElapsed
    }

    /// "+12% vs September", with a hyphen for a drop as the pace verdicts write it.
    static func changeText(_ change: Double, lastMonthName: String) -> String {
        let percent = Int((change * 100).rounded())
        guard percent != 0 else { return "Same as \(lastMonthName)" }
        return "\(percent > 0 ? "+" : "")\(percent)% vs \(lastMonthName)"
    }
}

/// This month's API-equivalent spend of the accounts on a plan the price table knows, against those plans' monthly list
/// prices: what the subscriptions would have cost at API prices.
nonisolated struct PlanValue: Equatable, Sendable {
    var spend: Double
    /// The sum of the plans' US monthly list prices.
    var planPrice: Double
    /// In account order, one entry per account.
    var plans: [String]
    var isEstimate: Bool

    var multiple: Double { spend / planPrice }

    /// nil when no account in `accounts` is on a priced plan, or nothing of theirs was priced since `since`.
    static func make(rows: [PricedUsageRow], since: Date, accounts: [AccountConfig], snapshots: [String: UsageSnapshot], table: PriceTable) -> PlanValue? {
        var prices: [String: Double] = [:]
        var plans: [String] = []
        for account in accounts {
            guard let plan = snapshots[account.id]?.plan, let price = table.planPrice(provider: account.provider, plan: plan) else { continue }
            prices[account.id] = price.monthlyUSD
            plans.append(plan)
        }
        let cost = DashboardMath.cost(rows.filter { prices[$0.row.accountID] != nil }, since: since)
        guard cost.hasCost, cost.amount > 0 else { return nil }
        return PlanValue(spend: cost.amount, planPrice: prices.values.reduce(0, +), plans: plans, isEstimate: cost.isEstimate)
    }

    /// "5.7x", or "12x" from 10 up, where a decimal adds nothing.
    @MainActor func valueText(locale: Locale = .autoupdatingCurrent) -> String {
        multiple.formatted(.number.precision(.fractionLength(multiple < 10 ? 1 : 0)).locale(locale)) + "x"
    }

    /// "vs the $200 plan", "vs $220 in 2 plans". The spend stays in `help`: with it the caption truncates at four tiles a row.
    @MainActor func caption(locale: Locale = .autoupdatingCurrent) -> String {
        plans.count == 1 ? "vs the \(money(planPrice, locale)) plan" : "vs \(money(planPrice, locale)) in \(plans.count) plans"
    }

    @MainActor func help(locale: Locale = .autoupdatingCurrent) -> String {
        let names = plans.count == 1 ? "\(plans[0]) plan" : "\(plans.dropLast().joined(separator: ", ")) and \(plans[plans.count - 1]) plans"
        let base = plans.count == 1 ? "the \(money(planPrice, locale)) \(names)" : "the \(money(planPrice, locale)) of the \(names)"
        return "Covered \(money(spend, locale)) of API usage this month, \(valueText(locale: locale)) \(base). "
            + "API-equivalent estimate, not a bill; plan prices are US monthly list prices."
    }

    @MainActor private func money(_ amount: Double, _ locale: Locale) -> String {
        Format.money(amount, currency: "USD", fractionDigits: 0, locale: locale)
    }
}
