import Foundation
import HeadroomCore

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

    var points: [LimitPoint] { series.flatMap { pointsBySeries[$0.id] ?? [] } }

    static let spendGroupLimit = 6
    static let projectLimit = 8
    /// Past this many resets in view a window's markers become a fence (a 5-hour window over 30 days), so they are dropped.
    static let resetMarkerLimit = 12

    /// `account` nil means every account in `accounts`. Series colors follow the account's position in
    /// `accounts` (All) or the window's position in the snapshot (one account), so they never depend on rank.
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
        let names = Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
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
            for (index, account) in accounts.enumerated() {
                guard let window = model.status(for: account).snapshot?.tightestWindow else { continue }
                wanted.append((account.id, account.displayName, index, account.id, window))
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
            content.series.append(Series(id: entry.id, label: label, colorIndex: entry.colorIndex))
            content.pointsBySeries[entry.id] = points
            let resets = DashboardMath.resets(in: samples)
            if resets.count <= resetMarkerLimit {
                content.resets += resets.map { ResetMarker(seriesID: entry.id, date: $0) }
            }
        }
        return content
    }
}
