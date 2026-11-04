import Foundation

public enum UpdateCheckMode: String, Sendable, CaseIterable {
    case manual, automatic
}

public struct UpdateDecision: Equatable, Sendable {
    public var notify: Bool
    public var notified: Set<AppVersion>

    public init(notify: Bool, notified: Set<AppVersion>) {
        self.notify = notify
        self.notified = notified
    }
}

public enum UpdateSchedule {
    public static let automaticInterval: TimeInterval = 24 * 3600

    /// A last check in the future counts as due: the Mac's clock can move backwards, and the check would otherwise
    /// stall until the clock caught up.
    public static func isDue(mode: UpdateCheckMode, lastCheckAt: Date?, now: Date) -> Bool {
        guard mode == .automatic else { return false }
        guard let last = lastCheckAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= automaticInterval
    }

    /// A version is news once: every version announced, or shown by Check Now, is remembered, so a withdrawn release
    /// that reappears is not announced again and a withdrawn high tag cannot hold back lower releases. Versions at or
    /// below the installed one can never be news again and are dropped.
    public static func decide(latest: AppVersion, installed: AppVersion, notified: Set<AppVersion>, userInitiated: Bool) -> UpdateDecision {
        let pending = notified.filter { $0 > installed }
        guard latest > installed else { return UpdateDecision(notify: false, notified: pending) }
        return UpdateDecision(notify: !userInitiated && !pending.contains(latest), notified: pending.union([latest]))
    }
}
