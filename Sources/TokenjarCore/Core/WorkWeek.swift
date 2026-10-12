import Foundation

/// The days that count toward pace in windows longer than a day. The weekend comes from the calendar's region through
/// Foundation, so a Friday and Saturday weekend needs no setting of its own.
public struct WorkWeek: Sendable {
    /// Calendar weekday numbers (1 is Sunday) that do not count.
    public let weekend: Set<Int>
    /// Days start and end in this calendar's time zone.
    let calendar: Calendar

    public static let everyDay = WorkWeek(weekend: [], calendar: Calendar(identifier: .gregorian))

    init(weekend: Set<Int>, calendar: Calendar) {
        self.weekend = weekend
        self.calendar = calendar
    }

    public init(calendar: Calendar) {
        // Noon of seven days in a row: every weekday once, clear of a daylight saving change at midnight.
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let noons = (0..<7).compactMap { calendar.date(byAdding: DateComponents(day: $0, hour: 12), to: start) }
        self.init(weekend: Set(noons.filter(calendar.isDateInWeekend).map { calendar.component(.weekday, from: $0) }), calendar: calendar)
    }

    /// Pass the user's calendar: its region decides the weekend for `.workingDays`.
    public init(_ paceDays: PaceDays, calendar: Calendar = .current) {
        switch paceDays {
        case .everyDay: self = .everyDay
        case .workingDays: self.init(calendar: calendar)
        }
    }

    func workingSeconds(from start: Date, to end: Date) -> TimeInterval {
        guard !weekend.isEmpty else { return max(0, end.timeIntervalSince(start)) }
        var total: TimeInterval = 0
        var cursor = start
        while cursor < end {
            let next = min(dayAfter(cursor), end)
            if isWorking(cursor) { total += next.timeIntervalSince(cursor) }
            cursor = next
        }
        return total
    }

    /// Clock seconds from `start` until `working` seconds of working days have passed. The walk stops at `limit` and
    /// counts what is left as plain seconds past it: callers only compare such a time with the limit.
    func clockSeconds(untilWorking working: TimeInterval, from start: Date, limit: Date) -> TimeInterval {
        guard !weekend.isEmpty, working > 0 else { return max(0, working) }
        var left = working
        var cursor = start
        while cursor < limit {
            let next = min(dayAfter(cursor), limit)
            if isWorking(cursor) {
                let span = next.timeIntervalSince(cursor)
                if left <= span { return cursor.addingTimeInterval(left).timeIntervalSince(start) }
                left -= span
            }
            cursor = next
        }
        return max(0, limit.timeIntervalSince(start)) + left
    }

    private func isWorking(_ date: Date) -> Bool {
        !weekend.contains(calendar.component(.weekday, from: date))
    }

    private func dayAfter(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? .distantFuture
    }
}
