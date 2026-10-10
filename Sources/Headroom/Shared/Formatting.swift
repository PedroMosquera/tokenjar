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

    static func money(_ amount: Double, currency: String = "USD") -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(amount >= 100 ? 0 : 2)))
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1e6)
        case 1_000...: String(format: "%.1fk", Double(count) / 1e3)
        default: "\(count)"
        }
    }

    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
