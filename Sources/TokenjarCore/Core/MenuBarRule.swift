import Foundation

/// Which accounts the menu bar draws and which number it shows for each. In core so `--status` names the same window
/// as the menu bar. `--status` filters no accounts: it lists every enabled one and never sees a check's error.
public enum MenuBarRule {
    /// An account with no window to show (a link, spend only, or no subscription) would draw an empty bar and a
    /// "no data" line that reads as a failure. An account not checked yet stays in.
    public static func includes(provider: ProviderID, snapshot: UsageSnapshot?, attention: FetchError.Attention?) -> Bool {
        provider.reportsWindows && (snapshot != nil || attention != .calm)
    }

    /// The window the account's number comes from: the fullest one that has not reset by `now`.
    public static func window(of snapshot: UsageSnapshot?, now: Date) -> UsageWindow? {
        snapshot?.tightestWindow(now: now)
    }
}
