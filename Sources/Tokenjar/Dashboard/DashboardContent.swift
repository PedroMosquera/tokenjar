import Foundation
import TokenjarCore

struct DashboardLoadKey: Hashable {
    var accountIDs: [String]
    var range: DashboardRange
    /// Bumped by the model after a refresh records samples or a scan stores usage rows.
    var historyRevision: Int
}

/// Everything the detail pane draws from history. Built in `task(id:)` when the selection, range or data
/// changes, so the view body never queries the store.
struct DashboardContent {
    struct Series: Identifiable, Equatable {
        var id: String
        var label: String
        var colorIndex: Int
        /// One point per cycle (`DashboardMath.sampling`); nothing connects one cycle's peak to the next.
        var peaksOnly = false
    }

    var key: DashboardLoadKey?
    var periods = DashboardPeriods(now: Date())
    var costToday = CostTotal()
    var costLastSevenDays = CostTotal()
    var costThisMonth = CostTotal()
    var totals = UsageTotals()
    var series: [Series] = []
    var pointsBySeries: [String: [LimitPoint]] = [:]
    var resets: [ResetMarker] = []
    var spend: [UsageGrouping: SpendBreakdown] = [:]
    var projects: [ProjectSummary] = []
    /// Keyed by the name the spend chart groups accounts by, so an account's bars match its limits line.
    var accountSlotByName: [String: Int] = [:]

    /// Every account in scope has a color slot, so these are all the names the account grouping can give.
    var accountNames: Set<String> { Set(accountSlotByName.keys) }
    var points: [LimitPoint] { series.flatMap { pointsBySeries[$0.id] ?? [] } }
    var linePoints: [LimitPoint] { series.filter { !$0.peaksOnly }.flatMap { pointsBySeries[$0.id] ?? [] } }
    var peakPoints: [LimitPoint] { series.filter(\.peaksOnly).flatMap { pointsBySeries[$0.id] ?? [] } }

    static let spendGroupLimit = 6
    static let projectLimit = 8
    /// Past this many resets in view a window's markers become a fence (a 5-hour window over 30 days), so they are dropped.
    static let resetMarkerLimit = 12

    /// `account` nil means every account in `accounts`. Series colors follow `DashboardMath.colorSlots` (All) or
    /// the window's position in the snapshot (one account), so they never depend on rank.
    static func load(
        model: AppModel, accounts: [AccountConfig], account: AccountConfig?, range: DashboardRange, now: Date, key: DashboardLoadKey
    ) -> DashboardContent {
        var content = DashboardContent(key: key, periods: DashboardPeriods(now: now))
        let periods = content.periods
        let scope = account.map { [$0] } ?? accounts

        let rows = model.pricedUsage(accountIDs: scope.map(\.id), since: periods.loadStart)
        content.costToday = DashboardMath.cost(rows, since: periods.today)
        content.costLastSevenDays = DashboardMath.cost(rows, since: periods.lastSevenDays)
        content.costThisMonth = DashboardMath.cost(rows, since: periods.thisMonth)
        let firstDay = periods.firstDay(of: range)
        content.totals = DashboardMath.totals(rows, since: firstDay)
        let names = Dictionary(accounts.map { ($0.id, AccountTitle(provider: $0.provider, label: $0.label).name) }, uniquingKeysWith: { a, _ in a })
        let snapshots = Dictionary(accounts.compactMap { account in model.status(for: account).snapshot.map { (account.id, $0) } }, uniquingKeysWith: { a, _ in a })
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

        let since = now.addingTimeInterval(-range.duration)
        var wanted: [(id: String, label: String, colorIndex: Int, accountID: String, window: UsageWindow)] = []
        if let account {
            let windows = model.status(for: account).snapshot?.windows ?? []
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
        for entry in wanted {
            let samples = model.samples(accountID: entry.accountID, windowID: entry.window.id, since: since)
            let sampling = DashboardMath.sampling(for: range, windowMinutes: entry.window.windowMinutes)
            let label = sampling.peaksOnly ? "\(entry.label) (peak per cycle)" : entry.label
            let points = DashboardMath.limitPoints(
                seriesID: entry.id, label: label, samples: samples, bucket: sampling.bucket,
                maxGap: max(2 * 3600, 3 * sampling.bucket)
            )
            guard !points.isEmpty else { continue }
            content.series.append(Series(id: entry.id, label: label, colorIndex: entry.colorIndex, peaksOnly: sampling.peaksOnly))
            content.pointsBySeries[entry.id] = points
            let resets = DashboardMath.resets(in: samples)
            if resets.count <= resetMarkerLimit {
                content.resets += resets.map { ResetMarker(seriesID: entry.id, date: $0) }
            }
        }
        return content
    }
}

/// Which cards the detail pane shows. A card that could only ever say "nothing here" is left out.
struct DashboardSections: Equatable {
    /// Cost and token tiles, daily spend and top projects, which all come from local usage logs.
    var history: Bool
    var limits: Bool

    /// `snapshot` is the selected account's; All ignores it.
    static func make(account: AccountConfig?, accounts: [AccountConfig], snapshot: UsageSnapshot?) -> DashboardSections {
        guard let account else {
            return DashboardSections(history: accounts.contains { $0.provider.harness != nil }, limits: true)
        }
        // Before the first check nothing says whether the account has limits, so the card stays to explain the wait.
        let limits = !account.provider.isLinkOnly && (snapshot.map { !$0.windows.isEmpty } ?? true)
        return DashboardSections(history: account.provider.harness != nil, limits: limits)
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
