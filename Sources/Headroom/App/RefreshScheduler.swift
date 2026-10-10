import Foundation
import HeadroomCore

/// When each account is fetched next. Pure, so the timing rules can be tested without spawning a CLI.
struct RefreshScheduler {
    private(set) var nextDue: [String: Date] = [:]
    private(set) var inFlight: Set<String> = []
    /// Set from a 429 (Retry-After, or twice the interval). Popover open, wake and the header button force a
    /// refresh, and none of them may re-hit a provider that asked to be left alone.
    private var backoffUntil: [String: Date] = [:]

    static let popoverRefreshAge: TimeInterval = 120
    static let scanInterval: TimeInterval = 5 * 60

    /// Accounts to fetch now. `force` skips the interval but never a rate-limit backoff or a fetch already running.
    func due(_ ids: [String], now: Date, force: Bool) -> [String] {
        ids.filter { id in
            guard !inFlight.contains(id), (backoffUntil[id] ?? .distantPast) <= now else { return false }
            return force || (nextDue[id] ?? .distantPast) <= now
        }
    }

    mutating func begin(_ ids: [String]) {
        inFlight.formUnion(ids)
    }

    /// `delay` nil leaves the account due at once, for a result that was dropped.
    mutating func finish(_ id: String, at now: Date, delay: TimeInterval?, rateLimited: Bool) {
        inFlight.remove(id)
        let due = delay.map { now.addingTimeInterval($0) }
        nextDue[id] = due
        backoffUntil[id] = rateLimited ? due : nil
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
