import Foundation
import TokenjarCore

/// The card's lines for an account billed per use whose cost Tokenjar prices from local history (`CostLine`), such as
/// Claude through an API key or a gateway. nil for every other account.
enum MonthCostLine {
    struct Lines: Equatable {
        /// "$12.40 this month · $7.90 today", or why there is no amount. Beside a budget bar only today's amount, nil
        /// with nothing priced today.
        var amounts: String?
        /// "On pace for ~$40 this month, estimate at list price"; nil when `amounts` has no amount.
        var detail: String?
    }

    static func text(snapshot: UsageSnapshot, rows: [PricedUsageRow], now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> Lines? {
        guard CostLine.applies(to: snapshot), CostLine.source(for: snapshot) == .history, let label = CostLine.label(for: snapshot),
              let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let total = DashboardMath.cost(rows, since: month.start)
        guard total.hasUsage else { return Lines(amounts: "No usage logged this month") }
        guard total.hasCost else { return Lines(amounts: "No list price for the models used this month") }
        let today = DashboardMath.cost(rows, since: calendar.startOfDay(for: now))
        let todayText = today.hasCost ? "\(Format.money(today.amount, locale: locale)) today" : nil
        var detail = label
        if total.unpricedRows > 0 { detail += ", some models unpriced" }
        // The budget bar shows the month's total and its pace already.
        if snapshot.spendLimitMoney != nil { return Lines(amounts: todayText, detail: capitalized(detail)) }
        let amounts = ["\(Format.money(total.amount, locale: locale)) this month", todayText].compactMap { $0 }.joined(separator: " · ")
        if let projected = MonthForecast.projection(of: total.amount, month: month, now: now) {
            detail = "On pace for ~\(Format.money(projected, currency: "USD", fractionDigits: 0, locale: locale)) this month, \(detail)"
        }
        return Lines(amounts: amounts, detail: capitalized(detail))
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The cost line says the login is billed per use, so the note that it has no plan limits would repeat it.
    static func notes(_ notes: [String], besideCostLine: Bool) -> [String] {
        besideCostLine ? notes.filter { $0 != ClaudeUsageFetcher.noLimitsNote } : notes
    }
}
