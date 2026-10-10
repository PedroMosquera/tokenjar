import Foundation
import Testing
@testable import HeadroomCore

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

    @Test func hiddenEarlyInWindowAndWhenNotStarted() {
        let early = UsageWindow(id: "session", label: "5-hour", usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(299 * 60))
        #expect(Pace.compute(early, now: now) == nil)
        let idle = UsageWindow(id: "session", label: "5-hour", usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(300 * 60), notStarted: true)
        #expect(Pace.compute(idle, now: now) == nil)
    }
}
