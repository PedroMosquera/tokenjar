import Foundation

public enum UpdateCheckMode: String, Sendable, CaseIterable {
    case manual, automatic
}

public struct UpdateDecision: Equatable, Sendable {
    public var notify: Bool
    public var notifiedVersion: AppVersion?

    public init(notify: Bool, notifiedVersion: AppVersion?) {
        self.notify = notify
        self.notifiedVersion = notifiedVersion
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

    /// A user-initiated check shows its result itself, so it never notifies but still marks the version as seen.
    /// Only equality with the last notified version silences a notice: a mistaken high tag that is later withdrawn
    /// must not hold back every real release after it.
    public static func decide(latest: AppVersion, installed: AppVersion, notified: AppVersion?, userInitiated: Bool) -> UpdateDecision {
        guard latest > installed else { return UpdateDecision(notify: false, notifiedVersion: notified) }
        return UpdateDecision(notify: !userInitiated && latest != notified, notifiedVersion: latest)
    }
}
