import Foundation

enum Format {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "3d 4h", "1h 48m", "12m", "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

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

    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
