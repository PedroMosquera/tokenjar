import Foundation
import TokenjarCore

/// The card's lines for an account billed per use whose cost Tokenjar prices from local history (`CostLine`), such as
/// Claude through an API key or a gateway. nil for every other account.
enum MonthCostLine {
    struct Lines: Equatable {
        /// "$12.40 this month · $7.90 today", or why there is no amount.
        var amounts: String
        /// "On pace for ~$40 this month, estimate at list price"; nil when `amounts` has no amount.
        var detail: String?
    }

    static func text(snapshot: UsageSnapshot, rows: [PricedUsageRow], now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> Lines? {
        guard CostLine.applies(to: snapshot), CostLine.source(for: snapshot) == .history, let label = CostLine.label(for: snapshot),
              let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let total = DashboardMath.cost(rows, since: month.start)
        guard total.hasUsage else { return Lines(amounts: "No usage logged this month") }
        guard total.hasCost else { return Lines(amounts: "No list price for the models used this month") }
        var amounts = "\(Format.money(total.amount, locale: locale)) this month"
        let today = DashboardMath.cost(rows, since: calendar.startOfDay(for: now))
        if today.hasCost { amounts += " · \(Format.money(today.amount, locale: locale)) today" }
        var detail = label
        if let projected = projection(of: total.amount, month: month, now: now) {
            detail = "On pace for ~\(Format.money(projected, currency: "USD", fractionDigits: 0, locale: locale)) this month, \(label)"
        }
        if total.unpricedRows > 0 { detail += ", some models unpriced" }
        return Lines(amounts: amounts, detail: detail.prefix(1).uppercased() + detail.dropFirst())
    }

    /// The cost line says the login is billed per use, so the note that it has no plan limits would repeat it.
    static func notes(_ notes: [String], besideCostLine: Bool) -> [String] {
        besideCostLine ? notes.filter { $0 != ClaudeUsageFetcher.noLimitsNote } : notes
    }

    /// The month's total at its average rate so far, through `Pace` so it waits for the same share of the month to
    /// pass as a bar's pace does.
    private static func projection(of amount: Double, month: DateInterval, now: Date) -> Double? {
        let window = UsageWindow(id: "month", label: "Month", usedPercent: 1, windowMinutes: Int(month.duration / 60), resetsAt: month.end)
        guard let pace = Pace.compute(window, now: now), pace.fractionElapsed > 0 else { return nil }
        return amount / pace.fractionElapsed
    }
}
