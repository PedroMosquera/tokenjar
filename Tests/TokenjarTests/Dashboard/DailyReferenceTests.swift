import Foundation
import Testing
@testable import Tokenjar

struct DailyReferenceTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!

    func day(_ offset: Int) -> Date {
        Self.calendar.date(byAdding: .day, value: offset, to: today)!
    }

    var week: [Date] { (-6...0).map(day) }

    func breakdown(_ segments: [(Int, String, Double)]) -> SpendBreakdown {
        SpendBreakdown(
            groups: Array(Set(segments.map(\.1))).sorted(),
            segments: segments.map { SpendSegment(day: day($0.0), group: $0.1, value: $0.2) },
            hasUsage: true
        )
    }

    /// $14 over a 7-day range is $2 a day, however few of those days had usage.
    @Test func theAverageCountsDaysWithoutUsageAsZero() throws {
        let spend = breakdown([(-5, "a", 1), (-5, "b", 2), (-1, "a", 4), (-1, "b", 7)])
        let reference = try #require(DailyReference.make(spend, days: week))
        #expect(reference.average == 2)
        #expect(reference.peak == 11)
        #expect(reference.peakDay == day(-1))
        #expect(reference.idleDays == 5)
    }

    /// Segments before the range, such as a load that still holds last month, neither lift the peak nor the average.
    @Test func onlyDaysInTheRangeCount() throws {
        let spend = breakdown([(-20, "a", 100), (-2, "a", 3), (0, "a", 5)])
        let reference = try #require(DailyReference.make(spend, days: week))
        #expect(reference.peak == 5)
        #expect(reference.average == 8.0 / 7)
    }

    @Test func fewerThanTwoDaysWithDataDrawNoRules() {
        #expect(DailyReference.make(breakdown([(-1, "a", 4), (-1, "b", 7)]), days: week) == nil)
        #expect(DailyReference.make(breakdown([(-1, "a", 4), (-2, "a", 0)]), days: week) == nil)
        #expect(DailyReference.make(SpendBreakdown(), days: week) == nil)
    }

    /// Within an eighth of the peak the two labels would overlap, so the average's hangs under its rule.
    @Test func anAverageCloseToThePeakHangsItsLabelBelow() {
        let close = DailyReference(average: 9, peak: 10, peakDay: day(0), idleDays: 0)
        let apart = DailyReference(average: 5, peak: 10, peakDay: day(0), idleDays: 0)
        #expect(close.averageLabelBelow)
        #expect(!apart.averageLabelBelow)
    }

    @Test func theNoteNamesTheIdleDaysOnlyWhenThereAreAny() {
        #expect(DailyReference.idleNote(0) == nil)
        #expect(DailyReference.idleNote(1) == "The average counts the day without usage as zero.")
        #expect(DailyReference.idleNote(5) == "The average counts the 5 days without usage as zero.")
    }
}
