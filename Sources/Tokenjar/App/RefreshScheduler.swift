import Foundation
import TokenjarCore

/// When each account is fetched next. Pure, so the timing rules can be tested without spawning a CLI.
struct RefreshScheduler {
    private(set) var nextDue: [String: Date] = [:]
    private(set) var inFlight: Set<String> = []
    /// Set from a 429 (Retry-After, or twice the interval). Popover open, wake and the header button force a
    /// refresh, and none of them may re-hit a provider that asked to be left alone.
    private var backoffUntil: [String: Date] = [:]
    private var startedAt: [String: Date] = [:]

    static let tickInterval: TimeInterval = 30
    /// An account is due on the tick nearest its time. Each tick lands a little after its mark, by a different amount
    /// each time, so a strict comparison would often leave it for the next tick: a 10-minute account checked every 10m 30s.
    static let dueSlack = tickInterval / 2
    static let popoverRefreshAge: TimeInterval = 120
    static let scanInterval: TimeInterval = 5 * 60

    /// Accounts to fetch now. `force` skips the interval but never a rate-limit backoff or a fetch already running.
    func due(_ ids: [String], now: Date, force: Bool) -> [String] {
        ids.filter { id in
            guard !inFlight.contains(id), (backoffUntil[id] ?? .distantPast) <= now else { return false }
            return force || (nextDue[id] ?? .distantPast) <= now.addingTimeInterval(Self.dueSlack)
        }
    }

    mutating func begin(_ ids: [String], at now: Date) {
        inFlight.formUnion(ids)
        for id in ids { startedAt[id] = now }
    }

    /// `delay` nil leaves the account due at once, for a result that was dropped. The interval counts from when the
    /// check started, so a check that takes a few seconds does not push every later one back by a tick; a rate-limit
    /// backoff counts from the answer that asked for it.
    mutating func finish(_ id: String, at now: Date, delay: TimeInterval?, rateLimited: Bool) {
        inFlight.remove(id)
        let base = rateLimited ? now : startedAt[id] ?? now
        startedAt[id] = nil
        let due = delay.map { base.addingTimeInterval($0) }
        nextDue[id] = due
        backoffUntil[id] = rateLimited ? due : nil
    }

    /// The soonest any of `ids` is checked again: each one's next due time or backoff, whichever is later, skipping
    /// checks already running. nil when none has a time yet.
    func nextCheck(_ ids: [String]) -> Date? {
        ids.filter { !inFlight.contains($0) }
            .compactMap { id in [nextDue[id], backoffUntil[id]].compactMap { $0 }.max() }
            .min()
    }

    /// Edited accounts are due at once; a rate-limit backoff still holds.
    mutating func invalidate(_ ids: [String]) {
        for id in ids { nextDue[id] = nil }
    }

    static func retryDelay(accountMinutes: Int?, globalMinutes: Int, lowPower: Bool, result: Result<UsageSnapshot, FetchError>) -> TimeInterval {
        let configured = accountMinutes ?? globalMinutes
        // Clamped before the rate-limit branch, so a hand-edited 0 cannot turn a 429 into a retry every tick.
        let minutes = Double(max(1, lowPower ? max(configured, 30) : configured))
        if case .failure(.rateLimited(let retryAfter)) = result {
            return max(retryAfter ?? 0, minutes * 2 * 60)
        }
        return minutes * 60
    }

    static func shouldRefreshOnPopoverOpen(lastRefreshAt: Date?, now: Date) -> Bool {
        lastRefreshAt.map { now.timeIntervalSince($0) >= popoverRefreshAge } ?? true
    }

    static func shouldScan(lastScanAt: Date?, now: Date) -> Bool {
        lastScanAt.map { now.timeIntervalSince($0) >= scanInterval } ?? true
    }
}
