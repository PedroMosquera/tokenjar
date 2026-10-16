import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct MonthForecastTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func forecast(_ monthToDate: Double, lastMonth: Double? = nil, at now: Date) -> MonthForecast {
        MonthForecast.make(monthToDate: monthToDate, lastMonth: lastMonth, now: now, calendar: Self.calendar)
    }

    /// 15 of October's 31 days have passed, so $150 so far projects to $310.
    @Test func projectsTheMonthAtItsAverageRateInA31DayMonth() throws {
        let projected = try #require(forecast(150, at: date(2026, 10, 16)).projected)
        #expect(abs(projected - 310) < 1e-9)
    }

    /// Halfway through a 28-day February the projection is twice the amount so far.
    @Test func projectsA28DayMonthOverItsOwnLength() throws {
        let projected = try #require(forecast(140, at: date(2027, 2, 15)).projected)
        #expect(abs(projected - 280) < 1e-9)
    }

    /// Like a bar's pace, nothing is projected until 5% of the month has passed, about a day and a half.
    @Test func theFirstDayOfTheMonthIsTooEarlyToProject() {
        let first = forecast(12, lastMonth: 300, at: date(2026, 10, 1, 18))
        #expect(first.projected == nil)
        #expect(first.change == nil)
        #expect(forecast(12, at: date(2026, 10, 3)).projected != nil)
    }

    /// The first instant of a month belongs to the new month, with nothing of it elapsed; the last hour of the month
    /// before projects almost exactly the amount so far.
    @Test func monthBoundaries() throws {
        #expect(forecast(0, at: date(2026, 11, 1)).projected == nil)
        let lastHour = try #require(forecast(743, at: date(2026, 10, 31, 23)).projected)
        #expect(abs(lastHour - 744) < 1e-9)
    }

    @Test func changeComparesTheProjectionWithLastMonthsTotal() throws {
        let change = try #require(forecast(150, lastMonth: 200, at: date(2026, 10, 16)).change)
        #expect(abs(change - 0.55) < 1e-9)
        let down = try #require(forecast(150, lastMonth: 620, at: date(2026, 10, 16)).change)
        #expect(abs(down + 0.5) < 1e-9)
    }

    /// No history last month, or nothing priced in it, says nothing about the change.
    @Test func noLastMonthDataMeansNoChange() {
        #expect(forecast(150, lastMonth: nil, at: date(2026, 10, 16)).change == nil)
        #expect(forecast(150, lastMonth: 0, at: date(2026, 10, 16)).change == nil)
        #expect(forecast(150, lastMonth: nil, at: date(2026, 10, 16)).projected != nil)
    }

    @Test func changeTextNamesLastMonth() {
        #expect(MonthForecast.changeText(0.554, lastMonthName: "September") == "+55% vs September")
        #expect(MonthForecast.changeText(-0.2, lastMonthName: "September") == "-20% vs September")
        #expect(MonthForecast.changeText(0.003, lastMonthName: "September") == "Same as September")
    }
}
