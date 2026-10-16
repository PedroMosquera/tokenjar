import Foundation
import TokenjarCore

/// A year of daily activity, one cell per day and a column per week, colored by API-equivalent cost.
nonisolated struct ActivityCalendar: Equatable, Sendable {
    enum Metric: Equatable, Sendable {
        case cost
        case tokens
    }

    struct Day: Equatable, Sendable {
        var date: Date
        var requests = 0
        var tokens = 0
        /// nil when nothing that day was priced.
        var cost: Double?
        /// 0 without usage, else 1 to 4.
        var level = 0

        var hasUsage: Bool { requests > 0 }
    }

    static let weekCount = 53

    var metric = Metric.cost
    var weeks: [[Day]] = []
    var activeDays = 0
    var total = 0.0
    var isEstimate = false

    /// The first day of the first column: the start of the week `weeks - 1` weeks before this one.
    static func firstDay(today: Date, calendar: Calendar, weeks: Int = weekCount) -> Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
    }

    /// Colors by cost, unless nothing in the whole span has a price, when tokens stand in so the calendar still shows
    /// when work happened. With costs, a day of unpriced usage only gets the lowest level: it was active, at an unknown cost.
    static func make(_ rows: [PricedUsageRow], today: Date, calendar: Calendar, weeks: Int = weekCount) -> ActivityCalendar {
        let first = firstDay(today: today, calendar: calendar, weeks: weeks)
        var byDay: [Date: Day] = [:]
        var activity = ActivityCalendar()
        for priced in rows where priced.row.day >= first && priced.row.day <= today && priced.row.requests > 0 {
            var day = byDay[priced.row.day] ?? Day(date: priced.row.day)
            day.requests += priced.row.requests
            day.tokens += DashboardMath.tokens(priced.row)
            if let cost = priced.costUSD {
                day.cost = (day.cost ?? 0) + cost
                activity.isEstimate = activity.isEstimate || priced.isEstimate
            }
            byDay[priced.row.day] = day
        }
        activity.metric = byDay.values.contains { $0.cost != nil } ? .cost : .tokens
        let values = byDay.values.map(activity.value)
        let thresholds = thresholds(values)
        activity.activeDays = byDay.count
        activity.total = values.reduce(0, +)

        var date = first
        var week: [Day] = []
        while date <= today {
            var day = byDay[date] ?? Day(date: date)
            day.level = level(activity.value(of: day), hasUsage: day.hasUsage, thresholds: thresholds)
            week.append(day)
            if week.count == 7 {
                activity.weeks.append(week)
                week = []
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        if !week.isEmpty { activity.weeks.append(week) }
        return activity
    }

    func value(of day: Day) -> Double {
        metric == .cost ? day.cost ?? 0 : Double(day.tokens)
    }

    /// The lower quartile, median and upper quartile of the values above zero.
    static func thresholds(_ values: [Double]) -> [Double] {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { sorted[Int((Double(sorted.count - 1) * $0).rounded(.down))] }
    }

    static func level(_ value: Double, hasUsage: Bool, thresholds: [Double]) -> Int {
        guard hasUsage else { return 0 }
        return 1 + thresholds.filter { value > $0 }.count
    }

    /// The columns that hold the first day of a month, where that month is named.
    func monthStarts(calendar: Calendar) -> [Int] {
        weeks.indices.filter { index in weeks[index].contains { calendar.component(.day, from: $0.date) == 1 } }
    }

    /// "Mon, Oct 5, 2026: $12.40", "...: 1.2M tokens, no price", "...: no usage".
    @MainActor func readout(_ day: Day, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let date = day.date.formatted(style.weekday(.abbreviated).month(.abbreviated).day().year())
        guard day.hasUsage else { return "\(date): no usage" }
        let tokens = "\(Format.tokens(day.tokens, locale: locale)) tokens"
        guard metric == .cost else { return "\(date): \(tokens)" }
        return "\(date): " + (day.cost.map { Format.money($0, locale: locale) } ?? "\(tokens), no price")
    }

    /// "$4,120 over 214 days with usage", or in tokens when nothing is priced.
    @MainActor func summary(locale: Locale = .autoupdatingCurrent) -> String {
        guard activeDays > 0 else { return "No usage in the last 12 months" }
        let amount = metric == .cost ? Format.money(total, locale: locale) : "\(Format.tokens(Int(total), locale: locale)) tokens"
        return "\(amount) over \(activeDays) day\(activeDays == 1 ? "" : "s") with usage"
    }
}

/// Where the calendar's square cells sit: weekday names in a leading column, month names in a row above.
nonisolated struct ActivityGrid: Equatable {
    static let labelWidth: CGFloat = 30
    static let monthHeight: CGFloat = 16
    /// Past this a wide window would turn the calendar into large tiles; it stays leading-aligned instead.
    static let maxPitch: CGFloat = 16

    var pitch: CGFloat
    var weeks: Int

    init(width: CGFloat, weeks: Int) {
        pitch = min(Self.maxPitch, max(1, (width - Self.labelWidth) / CGFloat(max(weeks, 1))))
        self.weeks = weeks
    }

    var height: CGFloat { Self.monthHeight + 7 * pitch }

    /// Square, with a gap of about a fifth of the pitch so neighbouring levels stay apart.
    func cell(week: Int, weekday: Int) -> CGRect {
        let gap = max(1, (pitch / 5).rounded())
        return CGRect(
            x: Self.labelWidth + CGFloat(week) * pitch, y: Self.monthHeight + CGFloat(weekday) * pitch,
            width: pitch - gap, height: pitch - gap
        )
    }

    /// The cell whose pitch holds `point`, gap included, so the readout does not flicker between cells.
    func position(at point: CGPoint) -> (week: Int, weekday: Int)? {
        let x = point.x - Self.labelWidth, y = point.y - Self.monthHeight
        guard x >= 0, y >= 0 else { return nil }
        let week = Int(x / pitch), weekday = Int(y / pitch)
        guard week < weeks, weekday < 7 else { return nil }
        return (week, weekday)
    }
}
