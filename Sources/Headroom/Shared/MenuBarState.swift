import Foundation
import HeadroomCore

/// Everything the menu bar icon needs, computed from the model so the renderer stays a pure function.
struct MenuBarState: Equatable {
    struct Entry: Equatable {
        var accountID: String
        var provider: ProviderID
        var label: String
        var tightest: UsageWindow?
        var severity: Severity
        var isStale: Bool
        var hasError: Bool
    }

    var mode: MenuBarMode
    var entries: [Entry]
    var showResetCountdownWhenFull: Bool
    var now: Date

    /// The entry with the least headroom: highest severity, then highest used %.
    var worst: Entry? {
        entries.max { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            return (a.tightest?.usedPercent ?? -1) < (b.tightest?.usedPercent ?? -1)
        }
    }

    static func make(accounts: [AccountConfig], statuses: [String: AccountStatus], config: AppConfig, now: Date) -> MenuBarState {
        let entries = accounts.map { account -> Entry in
            let status = statuses[account.id] ?? AccountStatus()
            let tightest = status.snapshot?.tightestWindow
            return Entry(
                accountID: account.id,
                provider: account.provider,
                label: account.label,
                tightest: tightest,
                severity: tightest.map { Severity.of($0, config: config.menuBar, now: now) } ?? .ok,
                isStale: status.isStale(now: now, refreshMinutes: account.refreshMinutes ?? config.refreshMinutes),
                hasError: status.error != nil
            )
        }
        return MenuBarState(mode: config.menuBar.mode, entries: entries, showResetCountdownWhenFull: config.menuBar.showResetCountdownWhenFull, now: now)
    }
}
