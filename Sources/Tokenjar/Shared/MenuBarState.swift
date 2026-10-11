import Foundation
import TokenjarCore

/// Everything the menu bar icon needs, computed from the model so the renderer stays a pure function.
struct MenuBarState: Equatable {
    struct Entry: Equatable {
        var accountID: String
        var provider: ProviderID
        var label: String
        var tightest: UsageWindow?
        var severity: Severity
        var isStale: Bool
        /// How much the last check's failure matters; nil when it passed.
        var attention: FetchError.Attention? = nil
        /// `AccountStatus.failureNeedsAttention`, the popover header's rule, so the menu bar and the header never
        /// disagree about a failed check.
        var failureNeedsAttention: Bool
        /// Set when a projection, not the tightest window's own number, gives `severity`.
        var cause: PaceVerdict? = nil

        /// A calm failure, such as no subscription, is a state of the account rather than a check that failed.
        var checkFailed: Bool { attention.map { $0 != .calm } ?? false }
    }

    var mode: MenuBarMode
    var icon: MenuBarIcon = .app
    var entries: [Entry]
    var showResetCountdownWhenFull: Bool
    var now: Date

    /// The entry with the least room left: highest severity, then highest used %.
    var worst: Entry? {
        entries.max { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            return (a.tightest?.usedPercent ?? -1) < (b.tightest?.usedPercent ?? -1)
        }
    }

    /// The account the failure dot speaks for: the worst one when its failure needs attention, else the first that
    /// does. A network error or timeout over fresh data draws no dot, as it draws no warning in the header.
    var failing: Entry? {
        if let worst, worst.failureNeedsAttention { return worst }
        return entries.first(where: \.failureNeedsAttention)
    }

    static func make(accounts: [AccountConfig], statuses: [String: AccountStatus], config: AppConfig, now: Date) -> MenuBarState {
        // An account with no window to show (a link, spend only, or no subscription) would draw an empty bar and a
        // "no data" line that reads as a failure.
        let entries = accounts.compactMap { account -> Entry? in
            let status = statuses[account.id] ?? AccountStatus()
            let refreshMinutes = account.refreshMinutes ?? config.refreshMinutes
            guard account.provider.reportsWindows, status.snapshot != nil || status.error?.attention != .calm else { return nil }
            let windows = status.snapshot?.windows ?? []
            let tightest = status.snapshot?.tightestWindow(now: now)
            // Every window counts: a lower window projected to run out still needs to color the menu bar.
            let severity = Severity.worst(of: windows, config: config.menuBar, now: now)
            return Entry(
                accountID: account.id,
                provider: account.provider,
                label: account.label,
                tightest: tightest,
                severity: severity,
                isStale: status.isStale(now: now, refreshMinutes: refreshMinutes),
                attention: status.error?.attention,
                failureNeedsAttention: status.failureNeedsAttention(now: now, refreshMinutes: refreshMinutes),
                cause: cause(of: severity, windows: windows, tightest: tightest, config: config.menuBar, now: now)
            )
        }
        return MenuBarState(mode: config.menuBar.mode, icon: config.menuBar.icon, entries: entries, showResetCountdownWhenFull: config.menuBar.showResetCountdownWhenFull, now: now)
    }

    /// The verdict behind a color the tightest window's own number does not explain: a projected run-out, on that
    /// window or on another one.
    private static func cause(of severity: Severity, windows: [UsageWindow], tightest: UsageWindow?, config: MenuBarConfig, now: Date) -> PaceVerdict? {
        guard let tightest, severity > Severity.ofUse(tightest.usedPercent, config: config) else { return nil }
        return PaceVerdict.make(windows: windows.filter { Severity.of($0, config: config, now: now) == severity }, config: config, now: now)
    }
}
