import Foundation
import TokenjarCore

nonisolated struct DashboardLoadKey: Hashable, Sendable {
    var accountIDs: [String]
    var range: DashboardRange
    /// Bumped by the model after a refresh records samples or a scan stores usage rows.
    var historyRevision: Int

    /// Content for another page is dimmed until its own lands. New history for the page on screen swaps in at full
    /// opacity, so a refresh in the background never makes the window flicker.
    static func dims(shown: DashboardLoadKey?, wanted: DashboardLoadKey) -> Bool {
        guard let shown else { return true }
        return shown.accountIDs != wanted.accountIDs || shown.range != wanted.range
    }
}

/// Everything the detail pane draws from history. Built off the main actor when the selection, range or data
/// changes, so the view body never queries the store.
nonisolated struct DashboardContent: Sendable {
    struct Series: Identifiable, Equatable, Sendable {
        var id: String
        var label: String
        var colorIndex: Int
        /// One point per cycle (`DashboardMath.sampling`); nothing connects one cycle's peak to the next.
        var peaksOnly = false
    }

    /// What `load` reads, taken from the model on the main actor so the load itself can run anywhere.
    struct Input: Sendable {
        var store: (any UsageStore)?
        var priceTable: PriceTable
        var accounts: [AccountConfig]
        /// nil means every account in `accounts`.
        var account: AccountConfig?
        var snapshots: [String: UsageSnapshot]
        /// The name each account goes by in a chart legend.
        var names: [String: String]
        var range: DashboardRange
        var now: Date
        var key: DashboardLoadKey
    }

    var key: DashboardLoadKey?
    var periods = DashboardPeriods(now: Date())
    var costToday = CostTotal()
    var costLastSevenDays = CostTotal()
    var costThisMonth = CostTotal()
    var costLastMonth = CostTotal()
    var totals = UsageTotals()
    /// Over the range on screen, like `totals`.
    var cacheHitRates = CacheHitRates()
    var series: [Series] = []
    var pointsBySeries: [String: [LimitPoint]] = [:]
    var resets: [ResetMarker] = []
    /// The limits chart's x range (`DashboardMath.limitsDomain`).
    var limitsDomain = Date()...Date()
    /// When the limits history begins, if that is after the range starts.
    var limitsSince: Date?
    /// The selected account's spend-limit samples, for its spend chart; nil for All and for an account without one.
    var spendLimit: SpendLimitHistory?
    var spend: [UsageGrouping: SpendBreakdown] = [:]
    var projects: [ProjectSummary] = []
    /// Keyed by the name the spend chart groups accounts by, so an account's bars match its limits line.
    var accountSlotByName: [String: Int] = [:]
    /// Any usage at all since `periods.loadStart` (about a month), whatever range is on screen. Last month does not count:
    /// it shows only as the comparison in the forecast tile.
    var hasUsage = false

    /// Every account in scope has a color slot, so these are all the names the account grouping can give.
    struct SpendLimitHistory: Equatable, Sendable {
        var samples: [WindowSample]
        var limit: Double
        var currency: String
    }

    var accountNames: Set<String> { Set(accountSlotByName.keys) }
    var points: [LimitPoint] { series.flatMap { pointsBySeries[$0.id] ?? [] } }
    var linePoints: [LimitPoint] { series.filter { !$0.peaksOnly }.flatMap { pointsBySeries[$0.id] ?? [] } }
    var peakPoints: [LimitPoint] { series.filter(\.peaksOnly).flatMap { pointsBySeries[$0.id] ?? [] } }

    static let spendGroupLimit = 6
    static let projectLimit = 8
    /// Past this many resets in view a window's markers become a fence (a 5-hour window over 30 days), so they are dropped.
    static let resetMarkerLimit = 12

    /// Series colors follow `DashboardMath.colorSlots` (All) or the window's position in the snapshot (one account),
    /// so they never depend on rank. Queries the store, so it belongs off the main actor.
    static func load(_ input: Input) -> DashboardContent {
        let range = input.range
        var content = DashboardContent(key: input.key, periods: DashboardPeriods(now: input.now))
        let periods = content.periods
        let accounts = input.accounts
        let scope = input.account.map { [$0] } ?? accounts

        let daily = (try? input.store?.dailyUsage(accountIDs: scope.map(\.id), since: periods.queryStart)) ?? []
        let rows = daily.map(input.priceTable.priced)
        content.hasUsage = rows.contains { $0.row.day >= periods.loadStart && $0.row.requests > 0 }
        content.costToday = DashboardMath.cost(rows, since: periods.today)
        content.costLastSevenDays = DashboardMath.cost(rows, since: periods.lastSevenDays)
        content.costThisMonth = DashboardMath.cost(rows, since: periods.thisMonth)
        content.costLastMonth = DashboardMath.cost(rows, since: periods.lastMonth, before: periods.thisMonth)
        let firstDay = periods.firstDay(of: range)
        content.totals = DashboardMath.totals(rows, since: firstDay)
        content.cacheHitRates = DashboardMath.cacheHitRates(rows, since: firstDay)
        let names = input.names
        let snapshots = input.snapshots
        let slots = DashboardMath.colorSlots(
            accountIDs: accounts.map(\.id), withWindows: Set(snapshots.filter { !$0.value.windows.isEmpty }.keys)
        )
        content.accountSlotByName = Dictionary(
            accounts.compactMap { account in slots[account.id].map { (names[account.id] ?? account.id, $0) } }, uniquingKeysWith: min
        )
        for grouping in UsageGrouping.allCases {
            content.spend[grouping] = DashboardMath.dailySpend(rows, by: grouping, since: firstDay, limit: spendGroupLimit, accountNames: names)
        }
        content.projects = DashboardMath.topProjects(rows, since: firstDay, limit: projectLimit)

        // A day before the range shows whether history reaches back to its start, or begins inside it.
        let rangeStart = range == .day ? input.now.addingTimeInterval(-range.duration) : periods.firstDay(of: range)
        let lookback = rangeStart.addingTimeInterval(-86_400)
        var wanted: [(id: String, label: String, colorIndex: Int, accountID: String, window: UsageWindow)] = []
        if let account = input.account {
            let windows = snapshots[account.id]?.windows ?? []
            for (index, window) in windows.enumerated() {
                wanted.append((window.id, window.label, index, account.id, window))
            }
        } else {
            for account in accounts {
                guard let snapshot = snapshots[account.id], let window = DashboardMath.overviewWindow(of: snapshot, range: range),
                      let slot = slots[account.id] else { continue }
                wanted.append((account.id, names[account.id] ?? account.id, slot, account.id, window))
            }
        }
        if let account = input.account, let money = snapshots[account.id]?.spendLimitMoney, let limit = money.limit {
            // Weekly bars can start up to six days before the range, and each bar needs the check before its start.
            let since = rangeStart.addingTimeInterval(-8 * 86_400)
            let samples = (try? input.store?.samples(accountID: account.id, windowID: UsageWindow.spendCapID, since: since)) ?? []
            content.spendLimit = SpendLimitHistory(samples: samples, limit: limit, currency: money.currency)
        }
        var earliest: Date?
        var reachesBack = false
        for entry in wanted {
            let loaded = (try? input.store?.samples(accountID: entry.accountID, windowID: entry.window.id, since: lookback)) ?? []
            let samples = loaded.filter { $0.timestamp >= rangeStart }
            let sampling = DashboardMath.sampling(for: range, windowMinutes: entry.window.windowMinutes)
            let label = sampling.peaksOnly ? "\(entry.label) (peak per cycle)" : entry.label
            let points = DashboardMath.limitPoints(
                seriesID: entry.id, label: label, samples: samples, bucket: sampling.bucket,
                maxGap: max(2 * 3600, 3 * sampling.bucket)
            )
            guard let first = points.first else { continue }
            reachesBack = reachesBack || loaded.count > samples.count
            earliest = min(earliest ?? first.date, first.date)
            content.series.append(Series(id: entry.id, label: label, colorIndex: entry.colorIndex, peaksOnly: sampling.peaksOnly))
            content.pointsBySeries[entry.id] = points
            let resets = DashboardMath.resets(in: samples)
            if resets.count <= resetMarkerLimit {
                content.resets += resets.map { ResetMarker(seriesID: entry.id, date: $0) }
            }
        }
        (content.limitsDomain, content.limitsSince) = DashboardMath.limitsDomain(
            range: range, periods: periods, earliest: earliest, reachesBack: reachesBack
        )
        return content
    }
}

extension DashboardContent.Input {
    init(model: AppModel, accounts: [AccountConfig], account: AccountConfig?, range: DashboardRange, now: Date, key: DashboardLoadKey) {
        self.init(
            store: model.store, priceTable: model.priceTable, accounts: accounts, account: account,
            snapshots: Dictionary(accounts.compactMap { account in model.status(for: account).snapshot.map { (account.id, $0) } }, uniquingKeysWith: { a, _ in a }),
            names: Dictionary(accounts.map { ($0.id, AccountTitle(provider: $0.provider, label: $0.label).name) }, uniquingKeysWith: { a, _ in a }),
            range: range, now: now, key: key
        )
    }
}

/// Which cards the detail pane shows. A card that could only ever say "nothing here" is left out.
struct DashboardSections: Equatable {
    /// Cost and token tiles, daily spend and top projects, which all come from local usage logs.
    var history: Bool
    var limits: Bool

    /// `status` is the selected account's; All ignores it.
    static func make(account: AccountConfig?, accounts: [AccountConfig], status: AccountStatus?) -> DashboardSections {
        guard let account else {
            return DashboardSections(history: accounts.contains { $0.provider.harness != nil }, limits: true)
        }
        // Before the first check nothing says whether the account has limits, so the card stays to explain the wait.
        // A calm failure (no subscription) is the answer itself, so there is nothing to wait for.
        let hasLimits = status?.snapshot.map { !$0.windows.isEmpty } ?? (status?.error?.attention != .calm)
        let limits = !account.provider.isLinkOnly && hasLimits
        return DashboardSections(history: account.provider.harness != nil, limits: limits)
    }

    /// The daily spend card's message, standing in for the cost tiles and top projects too, when none of them has
    /// anything to show over the whole period the page loads. That period holds every range, so the message names the
    /// one on screen. nil while the first load runs.
    static func historyEmptyMessage(account: AccountConfig?, content: DashboardContent, range: DashboardRange) -> String? {
        guard content.key != nil, !content.hasUsage else { return nil }
        return noUsageMessage(account: account, range: range)
    }

    /// What the daily spend card shows in place of its chart. nil while the first load runs and when there is a chart.
    /// An empty range says the same whether or not the rest of the loaded period has usage, so switching ranges does
    /// not change the wording.
    static func spendEmptyMessage(account: AccountConfig?, content: DashboardContent, breakdown: SpendBreakdown, range: DashboardRange) -> String? {
        guard content.key != nil else { return nil }
        if !content.hasUsage || !breakdown.hasUsage { return noUsageMessage(account: account, range: range) }
        if breakdown.segments.isEmpty { return "No prices for these models: \(breakdown.unpricedModelNames)." }
        return nil
    }

    private static func noUsageMessage(account: AccountConfig?, range: DashboardRange) -> String {
        guard let account else { return "No usage \(range.inRangePhrase)." }
        return "No \(AccountTitle(provider: account.provider, label: account.label).name) usage \(range.inRangePhrase)."
    }

    /// `status` is the selected account's, nil for All.
    static func limitsEmptyMessage(status: AccountStatus?, anyAccountHasWindows: Bool) -> String {
        if let status {
            if status.snapshot == nil {
                guard let error = status.error else { return "No limits yet. They appear after the first refresh." }
                let message = error.userMessage
                return "No limits yet. Last check: \(message.hasSuffix(".") ? message : message + ".")"
            }
        } else if !anyAccountHasWindows {
            return "No account reports plan limits yet."
        }
        return "No limit history yet. A sample is saved on every refresh."
    }
}
