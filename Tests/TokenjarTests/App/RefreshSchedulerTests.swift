import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

struct RefreshSchedulerTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_660_000)
    private let ok: Result<UsageSnapshot, FetchError> = .failure(.timeout)

    @Test func aRunningFetchIsNeverStartedTwice() {
        var scheduler = RefreshScheduler()
        scheduler.begin(["a"], at: t0)
        #expect(scheduler.due(["a", "b"], now: t0, force: true) == ["b"])
        #expect(scheduler.due(["a", "b"], now: t0, force: false) == ["b"])
    }

    /// Due on the tick nearest its time: a tick that lands a moment early still counts, the tick before it does not.
    @Test func anAccountIsDueOnTheTickNearestItsDelay() {
        var scheduler = RefreshScheduler()
        scheduler.begin(["a"], at: t0)
        scheduler.finish("a", at: t0, delay: 600, rateLimited: false)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(570), force: false).isEmpty)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(570), force: true) == ["a"])
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(599.9), force: false) == ["a"])
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(600), force: false) == ["a"])
    }

    /// A 10-minute account checked on 30-second ticks, whose check takes 2 seconds, is due again on the tick 10 minutes
    /// after the last check started. Counting from the result put it a tick later every time: every 10m 30s.
    @Test func theIntervalCountsFromWhenTheCheckStarted() {
        var scheduler = RefreshScheduler()
        scheduler.begin(["a"], at: t0)
        scheduler.finish("a", at: t0.addingTimeInterval(2), delay: 600, rateLimited: false)
        let firstDueTick = stride(from: 30.0, through: 900, by: 30).first { !scheduler.due(["a"], now: t0.addingTimeInterval($0), force: false).isEmpty }
        #expect(firstDueTick == 600)
    }

    /// A provider's Retry-After counts from its answer.
    @Test func aRateLimitCountsFromTheAnswer() {
        var scheduler = RefreshScheduler()
        scheduler.begin(["a"], at: t0)
        scheduler.finish("a", at: t0.addingTimeInterval(2), delay: 3600, rateLimited: true)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(3601), force: true).isEmpty)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(3602), force: true) == ["a"])
    }

    @Test func anEditMakesOnlyThatAccountDue() {
        var scheduler = RefreshScheduler()
        scheduler.finish("a", at: t0, delay: 600, rateLimited: false)
        scheduler.finish("b", at: t0, delay: 600, rateLimited: false)
        scheduler.invalidate(["a"])
        #expect(scheduler.due(["a", "b"], now: t0.addingTimeInterval(1), force: false) == ["a"])
    }

    @Test func aDroppedResultLeavesTheAccountDue() {
        var scheduler = RefreshScheduler()
        scheduler.begin(["a"], at: t0)
        scheduler.finish("a", at: t0, delay: nil, rateLimited: false)
        #expect(scheduler.due(["a"], now: t0, force: false) == ["a"])
    }

    @Test func aRateLimitHoldsAgainstForcedRefreshesAndEdits() {
        var scheduler = RefreshScheduler()
        scheduler.finish("a", at: t0, delay: 3600, rateLimited: true)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(1800), force: true).isEmpty)
        scheduler.invalidate(["a"])
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(1800), force: false).isEmpty)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(3600), force: true) == ["a"])

        scheduler.finish("a", at: t0, delay: 600, rateLimited: false)
        #expect(scheduler.due(["a"], now: t0.addingTimeInterval(1), force: true) == ["a"])
    }

    @Test(arguments: [
        (nil, 10, false, false, nil, 600.0),
        (5, 10, false, false, nil, 300),
        (nil, 10, true, false, nil, 1800),
        (45, 10, true, false, nil, 2700),
        (nil, 10, false, true, 3600, 3600),
        (nil, 10, false, true, nil, 1200),
        (nil, 0, false, false, nil, 60),
        (nil, 0, false, true, nil, 120),
    ] as [(Int?, Int, Bool, Bool, TimeInterval?, TimeInterval)])
    func retryDelay(accountMinutes: Int?, globalMinutes: Int, lowPower: Bool, rateLimited: Bool, retryAfter: TimeInterval?, expected: TimeInterval) {
        let result: Result<UsageSnapshot, FetchError> = rateLimited ? .failure(.rateLimited(retryAfter: retryAfter)) : ok
        #expect(RefreshScheduler.retryDelay(accountMinutes: accountMinutes, globalMinutes: globalMinutes, lowPower: lowPower, result: result) == expected)
    }

    @Test func thePopoverRefreshesAtMostEveryTwoMinutes() {
        #expect(RefreshScheduler.shouldRefreshOnPopoverOpen(lastRefreshAt: nil, now: t0))
        #expect(!RefreshScheduler.shouldRefreshOnPopoverOpen(lastRefreshAt: t0.addingTimeInterval(-119), now: t0))
        #expect(RefreshScheduler.shouldRefreshOnPopoverOpen(lastRefreshAt: t0.addingTimeInterval(-120), now: t0))
    }

    @Test func historyScansEveryFiveMinutes() {
        #expect(RefreshScheduler.shouldScan(lastScanAt: nil, now: t0))
        #expect(!RefreshScheduler.shouldScan(lastScanAt: t0.addingTimeInterval(-299), now: t0))
        #expect(RefreshScheduler.shouldScan(lastScanAt: t0.addingTimeInterval(-300), now: t0))
    }
}
