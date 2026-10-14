import Foundation
import TokenjarCore

/// The card's line for an account billed per use whose cost Tokenjar prices from local history (`CostLine`), such as
/// Claude through an API key or a gateway. nil for every other account.
enum MonthCostLine {
    static func text(snapshot: UsageSnapshot, rows: [PricedUsageRow], now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String? {
        guard CostLine.applies(to: snapshot), CostLine.source(for: snapshot) == .history, let label = CostLine.label(for: snapshot),
              let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
        let total = DashboardMath.cost(rows, since: monthStart)
        guard total.hasUsage else { return "No usage logged this month" }
        guard total.hasCost else { return "No list price for the models used this month" }
        let line = "\(Format.money(total.amount, locale: locale)) this month, \(label)"
        return total.unpricedRows > 0 ? line + ", some models unpriced" : line
    }
}
