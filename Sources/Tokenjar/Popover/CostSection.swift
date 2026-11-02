import Foundation
import TokenjarCore

/// The text of the API value section on a plan card: what the account's logged use would have cost at API list prices
/// over the last 30 local days, today included. `CostSectionView` draws it.
enum CostSection {
    struct Tile: Equatable {
        var title: String
        var value: String
        var detail: String?
        var highlighted = false
    }

    struct Day: Equatable {
        /// Local midnight.
        var date: Date
        var amount: Double
    }

    struct Content: Equatable {
        /// "$20.25", always to the currency's minor unit, so "¥3,291" in yen.
        var today: String
        /// "7.8x plan", or "$780 30d" when the plan's price is unknown.
        var trailing: String
        /// "7.8x", the part of `trailing` the row colours; nil when the plan's price is unknown.
        var multiple: String?
        /// The 30-day value has reached the plan's price.
        var highlightsTrailing: Bool
        /// Four, in grid order.
        var tiles: [Tile]
        /// 30, oldest first, a day without use at 0.
        var days: [Day]
        /// The 30-day total over 30, so days without use pull it down as on the dashboard.
        var average: Double
        var peak: Double
        /// "Avg $26 · Peak $61".
        var summary: String
        /// The chart's accessibility label.
        var spoken: String
        var footer: [String]
        /// The code the amounts are in: USD while a wanted rate has not loaded.
        var currency: String

        func day(at date: Date, calendar: Calendar = .current) -> Day? {
            days.first { calendar.isDate($0.date, inSameDayAs: date) }
        }

        /// "Oct 30: $5.00", in place of the summary while a bar is hovered.
        func readout(_ day: Day, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
            let date = day.date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
            return "\(date): \(Format.money(day.amount, currency: currency, fractionDigits: DisplayCurrency.minorUnitDigits(currency), locale: locale))"
        }
    }

    static let dayCount = 30

    static func start(now: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now))
    }

    /// Plan cards only. A plan snapshot usually carries `billing == nil`, so billing alone cannot tell: an account billed
    /// per use has `MonthCostLine`, and one with a spend limit has its own bar.
    static func applies(to snapshot: UsageSnapshot) -> Bool {
        !CostLine.applies(to: snapshot) && snapshot.spendLimitMoney == nil && snapshot.windows.contains { $0.id != UsageWindow.spendCapID }
    }

    /// `rows` are already in `currency`; `planPrice` is converted here. nil where `applies` is false or the last 30
    /// local days priced to nothing.
    static func make(
        snapshot: UsageSnapshot, rows: [PricedUsageRow], planPrice: PlanPrice?, currency: CostCurrency,
        now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) -> Content? {
        guard applies(to: snapshot), let start = start(now: now, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: dayCount, to: start) else { return nil }
        let rows = rows.filter { $0.row.day >= start && $0.row.day < end }
        let total = DashboardMath.cost(rows, since: start)
        guard total.hasCost, total.amount > 0 else { return nil }
        let code = currency.code
        func money(_ amount: Double) -> String { Format.money(amount, currency: code, locale: locale) }

        let today = Format.money(DashboardMath.cost(rows, since: calendar.startOfDay(for: now)).amount, currency: code, fractionDigits: DisplayCurrency.minorUnitDigits(code), locale: locale)
        let days = (0..<dayCount).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start),
                  let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            return Day(date: date, amount: DashboardMath.cost(rows, since: date, before: next).amount)
        }
        let average = total.amount / Double(dayCount)
        let peak = days.map(\.amount).max() ?? 0
        let topModel = DashboardMath.displayName(topModel(rows))
        let tokens = rows.reduce(0) { $0 + DashboardMath.tokens($1.row) }

        var tiles = [
            Tile(title: "Today", value: today),
            Tile(title: "Last 30 days", value: money(total.amount)),
            Tile(title: "30d tokens", value: Format.tokens(tokens, locale: locale)),
        ]
        var footer: [String] = []
        let trailing: String
        var multiple: String?
        var paysForItself = false
        let plan = planPrice.map { currency.amount($0.monthlyUSD) }.flatMap { $0 > 0 ? $0 : nil }
        if let plan {
            let text = PlanValue.multipleText(total.amount / plan, locale: locale)
            multiple = text
            paysForItself = total.amount >= plan
            trailing = "\(text) plan"
            tiles.append(Tile(
                title: "Plan value", value: text, detail: "the \(Format.money(plan, currency: code, fractionDigits: 0, locale: locale)) plan",
                highlighted: paysForItself
            ))
            footer.append("Top model: \(topModel)")
        } else {
            trailing = "\(money(total.amount)) 30d"
            tiles.append(Tile(title: "Top model", value: topModel))
        }
        footer.append("API-equivalent estimate from this Mac's logs, not a bill\(total.unpricedRows > 0 ? ", some models unpriced" : "").")
        if currency.awaitingRate {
            footer.append("Shown in USD until an exchange rate loads.")
        } else if code != "USD", let date = currency.rateDate.flatMap(Format.rateDay) {
            footer.append("\(code) at the ECB rate of \(date).")
        }

        return Content(
            today: today, trailing: trailing, multiple: multiple, highlightsTrailing: paysForItself, tiles: tiles, days: days, average: average, peak: peak,
            summary: "Avg \(money(average)) · Peak \(money(peak))",
            spoken: "Daily API value, last 30 days, average \(money(average)), peak \(money(peak))",
            footer: footer, currency: code
        )
    }

    /// The model with the largest summed cost, ties to the earlier id so the line does not flip between refreshes.
    private static func topModel(_ rows: [PricedUsageRow]) -> String {
        var costs: [String: Double] = [:]
        for priced in rows {
            if let cost = priced.cost { costs[priced.row.model, default: 0] += cost }
        }
        return costs.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
    }
}
