import Foundation
import TokenjarCore

enum Format {
    /// Whole percent, except that nothing above 0 reads "0%" and nothing below 100 reads "100%".
    static func percent(_ value: Double) -> String {
        if value > 0, value < 1 { return "<1%" }
        if value >= 99, value < 100 { return "99%" }
        return "\(Int(value.rounded()))%"
    }

    /// "3d 4h", "3d", "1h 48m", "2h", "12m", "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// "1 hour, 48 minutes", for accessibility text only. English, like every other string the app shows.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "less than a minute" }
        return spokenFormatter.string(from: seconds.rounded(.down)) ?? duration(seconds)
    }

    private static let spokenFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func countdown(to date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        return duration(date.timeIntervalSince(now))
    }

    /// "just now", "2m ago", "3h ago", "2d ago".
    static func age(of date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        return duration(s) + " ago"
    }

    /// Whole amounts and amounts from 100 up drop the cents: "$30" on a chart axis, "$12.40" for a small spend.
    static func money(_ amount: Double, currency: String = "USD", locale: Locale = .autoupdatingCurrent) -> String {
        money(amount, currency: currency, fractionDigits: centsDigits(amount), locale: locale)
    }

    /// "$12.40 used of $100.00": one precision for both, so a row never mixes styles.
    static func moneyUsed(_ amount: Double, of limit: Double, currency: String = "USD", locale: Locale = .autoupdatingCurrent) -> String {
        let digits = max(centsDigits(amount), centsDigits(limit))
        return "\(money(amount, currency: currency, fractionDigits: digits, locale: locale)) used of \(money(limit, currency: currency, fractionDigits: digits, locale: locale))"
    }

    /// "$477 of $3,000", with `moneyUsed`'s shared precision.
    static func moneyOf(_ amount: Double, of limit: Double, currency: String = "USD", locale: Locale = .autoupdatingCurrent) -> String {
        let digits = max(centsDigits(amount), centsDigits(limit))
        return "\(money(amount, currency: currency, fractionDigits: digits, locale: locale)) of \(money(limit, currency: currency, fractionDigits: digits, locale: locale))"
    }

    /// "35% used · resets in 21d 4h" under a spend limit's bar, with "$240 over" once spend has passed the limit.
    static func spendLimitDetail(_ window: UsageWindow, money line: MoneyLine? = nil, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["\(percent(window.usedPercent)) used"]
        if let line, let limit = line.limit, line.amount > limit {
            let digits = max(centsDigits(line.amount), centsDigits(limit))
            parts.append("\(money(line.amount - limit, currency: line.currency, fractionDigits: digits, locale: locale)) over")
        }
        if let countdown = countdown(to: window.resetsAt, now: now) { parts.append("resets in \(countdown)") }
        return parts.joined(separator: " · ")
    }

    /// "$4.31 of $6.10". Whole units from a $100 budget up, where cents are noise; below it, as with a $200 monthly
    /// limit, the cents carry the information.
    static func dailyAmounts(_ day: DailySpend, locale: Locale = .autoupdatingCurrent) -> String {
        "\(dailyMoney(day.spent, day, locale)) of \(dailyMoney(day.budget, day, locale))"
    }

    /// "70% of the recommended budget · 4h 40m left today", or "$42 over the daily budget · …" past it, with
    /// "since 9:14 AM" when today counts only from its first check.
    static func dailyDetail(_ day: DailySpend, now: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let budget = day.isRecommended ? "the recommended budget" : "the daily budget"
        var parts = [day.isOver ? "\(dailyMoney(day.spent - day.budget, day, locale)) over \(budget)" : "\(percent(day.usedPercent)) of \(budget)"]
        if let from = day.countedFrom {
            parts.append("since " + from.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)))
        }
        parts.append("\(duration(day.dayEnd.timeIntervalSince(now))) left today")
        return parts.joined(separator: " · ")
    }

    private static func dailyMoney(_ amount: Double, _ day: DailySpend, _ locale: Locale) -> String {
        money(amount, currency: day.currency, fractionDigits: day.budget >= 100 ? 0 : 2, locale: locale)
    }

    private static func centsDigits(_ amount: Double) -> Int {
        amount >= 100 || amount == amount.rounded() ? 0 : 2
    }

    static func money(_ amount: Double, currency: String, fractionDigits: Int, locale: Locale) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// "999", "1.5k", "164.6M". The suffixes stay English like the rest of the UI; the decimal separator follows the
    /// locale, as the request counts and money beside these numbers do. The unit is picked after rounding, so
    /// 999,950 reads "1.0M", never "1000.0k".
    static func tokens(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard count >= 1_000 else { return count.formatted(.number.locale(locale)) }
        func tenths(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        }
        var value = Double(count) / 1_000
        for suffix in ["k", "M"] {
            let rounded = (value * 10).rounded() / 10
            if rounded < 1_000 { return tenths(rounded) + suffix }
            value /= 1_000
        }
        return tenths((value * 10).rounded() / 10) + "B"
    }
}
