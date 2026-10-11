import Foundation
import Testing
@testable import TokenjarCore

struct PaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func projectsExhaustionBeforeReset() throws {
        // 5h window, 2h elapsed, 60 % used: rate 30 %/h, 40 % left takes 80m, reset is in 3h.
        let window = UsageWindow(id: "session", label: "5-hour", usedPercent: 60, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600))
        let pace = try #require(Pace.compute(window, now: now))
        #expect(abs(pace.expectedPercent - 40) < 0.001)
        #expect(abs(pace.delta - 20) < 0.001)
        #expect(abs(try #require(pace.secondsToExhaustion) - 80 * 60) < 1)
        #expect(pace.runsOutBeforeReset)
    }

    @Test func onPaceDoesNotRunOut() throws {
        // 2 of 7 days elapsed, 20 % used: 10 %/day, the remaining 80 % lasts 8 days, reset is in 5.
        let window = UsageWindow(id: "weekly", label: "Week", usedPercent: 20, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(5 * 86_400))
        let pace = try #require(Pace.compute(window, now: now))
        #expect(!pace.runsOutBeforeReset)
    }

    @Test func nothingUsedHasNoExhaustionTime() throws {
        let window = UsageWindow(id: "session", label: "5-hour", usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(200 * 60))
        let pace = try #require(Pace.compute(window, now: now))
        #expect(pace.secondsToExhaustion == nil)
        #expect(!pace.runsOutBeforeReset)
    }

    /// Half used at half time runs out exactly at the reset, which is not "before". The values divide exactly in binary.
    @Test func runningOutExactlyAtTheResetIsNotBeforeIt() throws {
        let window = UsageWindow(id: "session", label: "5-hour", usedPercent: 50, windowMinutes: 300, resetsAt: now.addingTimeInterval(150 * 60))
        let pace = try #require(Pace.compute(window, now: now))
        #expect(pace.secondsToExhaustion == pace.secondsToReset)
        #expect(!pace.runsOutBeforeReset)
    }

    @Test func hiddenEarlyInWindowAndWhenNotStarted() {
        let early = UsageWindow(id: "session", label: "5-hour", usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(299 * 60))
        #expect(Pace.compute(early, now: now) == nil)
        let idle = UsageWindow(id: "session", label: "5-hour", usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(300 * 60), notStarted: true)
        #expect(Pace.compute(idle, now: now) == nil)
    }
}

/// Dates in October 2026, UTC: the 10th and 17th are Saturdays, the 12th and 19th Mondays.
extension PaceTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    var saturdaySunday: WorkWeek { WorkWeek(weekend: [7, 1], calendar: Self.utc) }

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func window(used: Double, from start: Date, days: Int) -> UsageWindow {
        UsageWindow(id: "weekly", label: "Week", usedPercent: used, windowMinutes: days * 1440, resetsAt: start.addingTimeInterval(Double(days) * 86_400))
    }

    /// 15 working hours of 120 have passed, against 63 of 168 on the clock. 25 % in 15 working hours leaves 45 more:
    /// the rest of Monday, Tuesday, and Wednesday until noon.
    @Test func workingDaysPaceSkipsTheWeekend() throws {
        #expect(Self.utc.component(.weekday, from: date(10)) == 7)
        let week = window(used: 25, from: date(10), days: 7)
        let pace = try #require(Pace.compute(week, now: date(12, 15), workWeek: saturdaySunday))
        #expect(abs(pace.expectedPercent - 12.5) < 0.001)
        #expect(abs(pace.fractionElapsed - 0.125) < 0.000_001)
        #expect(abs(try #require(pace.secondsToExhaustion) - 45 * 3600) < 1)
        #expect(pace.runsOutBeforeReset)
        #expect(try #require(Pace.compute(week, now: date(12, 15))).runsOutBeforeReset == false)
    }

    /// 84 working hours of 240 have passed on a Thursday at noon. 50 % at that rate needs 84 more: Thursday afternoon,
    /// Friday, then Monday and Tuesday, so the clock runs 132 hours where a linear pace gives 84.
    @Test func theRunOutTimeSkipsWeekendsToo() throws {
        let fortnight = window(used: 50, from: date(12), days: 14)
        let pace = try #require(Pace.compute(fortnight, now: date(15, 12), workWeek: saturdaySunday))
        #expect(abs(pace.expectedPercent - 35) < 0.001)
        #expect(abs(try #require(pace.secondsToExhaustion) - 132 * 3600) < 1)
    }

    /// Past the reset only the order matters: the window does not run out before it.
    @Test func aRunOutAfterTheResetStaysAfterIt() throws {
        let week = window(used: 60, from: date(12), days: 7)
        let pace = try #require(Pace.compute(week, now: date(15, 12), workWeek: saturdaySunday))
        #expect(abs(pace.expectedPercent - 70) < 0.001)
        #expect(!pace.runsOutBeforeReset)
        #expect(try #require(Pace.compute(week, now: date(15, 12))).runsOutBeforeReset)
    }

    /// Saturday in a week that resets on Monday has no working time left, so the even pace would sit at 100 %.
    @Test func aWindowWithNoWorkingTimeLeftFallsBackToLinear() throws {
        let week = window(used: 80, from: date(12), days: 7)
        let linear = try #require(Pace.compute(week, now: date(17, 12)))
        #expect(Pace.compute(week, now: date(17, 12), workWeek: saturdaySunday) == linear)
    }

    /// Sunday 22:00 to Monday 03:00: with the work week it would count only Monday's hours.
    @Test func fiveHourWindowsIgnoreTheWorkWeek() throws {
        let session = UsageWindow(id: "session", label: "5-hour", usedPercent: 40, windowMinutes: 300, resetsAt: date(12, 3))
        let linear = try #require(Pace.compute(session, now: date(12, 1)))
        #expect(abs(linear.expectedPercent - 60) < 0.001)
        #expect(Pace.compute(session, now: date(12, 1), workWeek: saturdaySunday) == linear)
    }

    /// Which locale gives a Friday and Saturday weekend is not pinned here: the test finds one through Foundation's
    /// own `nextWeekend` first, then checks `WorkWeek` agrees.
    @Test func weekendDaysComeFromTheCalendarRegion() throws {
        let unitedStates = calendar(locale: "en_US")
        try #require(weekendByProbe(unitedStates) == [7, 1])
        #expect(WorkWeek(calendar: unitedStates).weekend == [7, 1])

        let fridaySaturday = try #require(["he_IL", "ar_SA", "ar_EG", "ar_KW"].map(calendar(locale:)).first { weekendByProbe($0) == [6, 7] })
        #expect(WorkWeek(calendar: fridaySaturday).weekend == [6, 7])
    }

    @Test func paceDaysPicksTheWorkWeek() {
        let unitedStates = calendar(locale: "en_US")
        #expect(WorkWeek(.everyDay, calendar: unitedStates).weekend.isEmpty)
        #expect(WorkWeek(.workingDays, calendar: unitedStates).weekend == [7, 1])
    }

    private func calendar(locale: String) -> Calendar {
        var calendar = Self.utc
        calendar.locale = Locale(identifier: locale)
        return calendar
    }

    private func weekendByProbe(_ calendar: Calendar) -> Set<Int> {
        guard let weekend = calendar.nextWeekend(startingAfter: date(5)) else { return [] }
        return Set(stride(from: weekend.start, to: weekend.end, by: 86_400).map { calendar.component(.weekday, from: $0.addingTimeInterval(43_200)) })
    }
}
