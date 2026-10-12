import Foundation

public struct Pace: Equatable, Sendable {
    /// Where usage would be now if spent evenly across the window.
    public var expectedPercent: Double
    /// actual - expected. Positive means ahead of an even pace.
    public var delta: Double
    /// Seconds until 100 % at the current average rate; nil when nothing has been used yet.
    public var secondsToExhaustion: TimeInterval?
    public var secondsToReset: TimeInterval
    public var fractionElapsed: Double

    public var runsOutBeforeReset: Bool {
        guard let eta = secondsToExhaustion else { return false }
        return eta < secondsToReset
    }

    /// Linear-since-window-start pace. In a window longer than a day, `workWeek` limits the expected % and the rate to
    /// working days, so the expected % holds at 100 through a trailing weekend and at 0 through a leading one, and the
    /// projection adds no use while no working time is left. Only a window with no working time at all counts every
    /// day. Returns nil when the window length or reset is unknown, the window has not started, or less than
    /// `minimumElapsedFraction` of it has passed (too little data to project).
    public static func compute(_ window: UsageWindow, now: Date, minimumElapsedFraction: Double = 0.05, workWeek: WorkWeek = .everyDay) -> Pace? {
        guard !window.notStarted, let minutes = window.windowMinutes, minutes > 0, let resetsAt = window.resetsAt else { return nil }
        let length = Double(minutes) * 60
        let secondsToReset = resetsAt.timeIntervalSince(now)
        guard secondsToReset >= 0, secondsToReset <= length else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        let week = window.isShort || workWeek.workingSeconds(from: start, to: resetsAt) <= 0 ? .everyDay : workWeek
        let elapsed = week.workingSeconds(from: start, to: now)
        let fraction = elapsed / week.workingSeconds(from: start, to: resetsAt)
        guard fraction >= minimumElapsedFraction else { return nil }
        let expected = fraction * 100
        let used = window.usedPercent
        var eta: TimeInterval?
        if used > 0 {
            let rate = used / elapsed
            eta = week.clockSeconds(untilWorking: max(0, (100 - used) / rate), from: now, limit: resetsAt)
        }
        return Pace(expectedPercent: expected, delta: used - expected, secondsToExhaustion: eta, secondsToReset: secondsToReset, fractionElapsed: fraction)
    }
}
