import Foundation

/// What `Tokenjar --status` prints: each enabled account's last snapshot in config order, read without running a check,
/// so a script such as a tmux or Claude Code status line shows what the menu bar shows. `version` changes only when a
/// field changes meaning or goes away.
public struct StatusReport: Encodable, Equatable, Sendable {
    public var version = 1
    public var generatedAt: Date
    public var accounts: [Account]

    public struct Account: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var provider: String
        public var plan: String?
        /// nil until the account's first check.
        public var fetchedAt: Date?
        /// Older than two refresh intervals, which the menu bar draws faded.
        public var stale: Bool
        /// The window the menu bar's number comes from.
        public var tightestWindowID: String?
        /// Windows that have reset since the snapshot are left out: their numbers describe a cycle that ended.
        public var windows: [Window]
        public var notes: [String]
    }

    public struct Window: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var usedPercent: Double
        public var resetsAt: Date?
        /// Where an even pace would be now; nil early in a window or without a known length.
        public var expectedPercent: Double?
        public var runsOutBeforeReset: Bool?
    }

    public static func make(config: AppConfig, snapshots: [UsageSnapshot], now: Date) -> StatusReport {
        let byID = Dictionary(snapshots.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
        let accounts = config.accounts.filter(\.enabled).map { account in
            let snapshot = byID[account.id]
            let windows = (snapshot?.windows ?? []).filter { !$0.hasReset(now: now) }.map { window in
                // Every-day pace, as the popover and alerts use: `paceDays` must not make the two disagree.
                let pace = Pace.compute(window, now: now)
                return Window(
                    id: window.id, label: window.label, usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                    expectedPercent: pace?.expectedPercent, runsOutBeforeReset: pace?.runsOutBeforeReset
                )
            }
            return Account(
                id: account.id, label: account.label, provider: account.provider.rawValue, plan: snapshot?.plan,
                fetchedAt: snapshot?.fetchedAt,
                stale: snapshot?.isStale(now: now, refreshMinutes: account.refreshMinutes ?? config.refreshMinutes) ?? false,
                tightestWindowID: MenuBarRule.window(of: snapshot, now: now)?.id, windows: windows, notes: snapshot?.notes ?? []
            )
        }
        return StatusReport(generatedAt: now, accounts: accounts)
    }

    /// One line of JSON with sorted keys and ISO 8601 dates.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
