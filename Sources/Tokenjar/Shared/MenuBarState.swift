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
        var fetchedAt: Date? = nil
        /// `AccountStatus.connectionFailure`: the network error or timeout behind the latest check, saved copies included.
        var connectionFailure: FetchError? = nil
        /// The money behind `tightest` when it is a spend cap, for showing the amount in place of the percentage.
        var spend: MoneyLine? = nil
    }

    var mode: MenuBarMode
    var icon: MenuBarIcon = .app
    var entries: [Entry]
    var showResetCountdownWhenFull: Bool
    var spendDisplay: SpendDisplay = .percent
    var now: Date
    var connectivity: Connectivity = .online
    var settingsProblem: SettingsProblem? = nil
    /// The account the person pinned on this Mac. It speaks for the menu bar while it is among `entries`.
    var pinnedAccountID: String? = nil

    /// Tokenjar can't refresh right now: the Mac is offline, or no provider answers.
    var isSlashed: Bool { connectivity != .online }

    /// Something needs the user: a failed check they can fix, or settings that can't be read.
    var showsDot: Bool { failing != nil || settingsProblem != nil }

    /// The newest successful check among the menu bar's accounts.
    var lastUpdated: Date? { entries.compactMap(\.fetchedAt).max() }

    /// The pinned entry, else the one with the least room left: highest severity, then highest used %.
    var worst: Entry? {
        // A pinned account with no number yet would leave the menu bar blank.
        if let pinned = entries.first(where: { $0.accountID == pinnedAccountID && $0.tightest != nil }) { return pinned }
        return entries.max { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            return (a.tightest?.usedPercent ?? -1) < (b.tightest?.usedPercent ?? -1)
        }
    }

    /// The account the failure dot speaks for: the worst one when its failure needs attention, else the first that
    /// does. A network error, a timeout or a rate limit never draws the dot, as it never counts in the header.
    var failing: Entry? {
        if let worst, worst.failureNeedsAttention { return worst }
        return entries.first(where: \.failureNeedsAttention)
    }

    static func make(
        accounts: [AccountConfig], statuses: [String: AccountStatus], config: AppConfig, now: Date,
        connectivity: Connectivity = .online, settingsProblem: SettingsProblem? = nil, pinned: String? = nil
    ) -> MenuBarState {
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
                cause: cause(of: severity, windows: windows, tightest: tightest, config: config.menuBar, now: now),
                fetchedAt: status.snapshot?.fetchedAt,
                connectionFailure: status.connectionFailure,
                spend: tightest?.id == UsageWindow.spendCapID ? status.snapshot?.spendLimitMoney : nil
            )
        }
        return MenuBarState(
            mode: config.menuBar.mode, icon: config.menuBar.icon, entries: entries, showResetCountdownWhenFull: config.menuBar.showResetCountdownWhenFull,
            spendDisplay: config.menuBar.spendDisplay, now: now, connectivity: connectivity, settingsProblem: settingsProblem,
            pinnedAccountID: pinned
        )
    }

    /// The verdict behind a color the tightest window's own number does not explain: a projected run-out, on that
    /// window or on another one.
    private static func cause(of severity: Severity, windows: [UsageWindow], tightest: UsageWindow?, config: MenuBarConfig, now: Date) -> PaceVerdict? {
        guard let tightest, severity > Severity.ofUse(tightest.usedPercent, config: config) else { return nil }
        return PaceVerdict.make(windows: windows.filter { Severity.of($0, config: config, now: now) == severity }, config: config, now: now)
    }
}
