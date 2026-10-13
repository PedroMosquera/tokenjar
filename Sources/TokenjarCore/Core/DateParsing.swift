import Foundation

public enum DateParsing {
    // ISO8601DateFormatter is thread-safe; building one per call cost about 25 us, which dominated history scans.
    nonisolated(unsafe) private static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Accepts ISO-8601 with or without fractional seconds (any number of digits) and with `Z` or `±hh:mm`.
    /// Providers mix `2026-10-10T22:29:59.123456+00:00` and `2026-10-12T09:00:00+00:00` in one response.
    public static func iso8601(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard let tIndex = s.firstIndex(of: "T") else { return nil }
        var main = s
        var fraction: Double = 0
        if let dot = s[tIndex...].firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            fraction = Double("0" + s[dot..<end]) ?? 0
            main = String(s[..<dot]) + String(s[end...])
        }
        guard let base = internetDateTime.date(from: main) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    private static let imfFixdate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// An HTTP `Date` header in the form every current server sends, "Mon, 12 Oct 2026 20:57:15 GMT". The two obsolete
    /// forms RFC 9110 still lets a recipient accept are not read.
    static func httpDate(_ string: String) -> Date? {
        imfFixdate.date(from: string.trimmingCharacters(in: .whitespaces))
    }

    /// Epoch seconds or milliseconds, distinguished by magnitude.
    public static func epoch(_ value: Double) -> Date {
        value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
    }
}
