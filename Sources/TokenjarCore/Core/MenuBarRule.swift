import Foundation

/// Which accounts the menu bar draws and which number it shows for each. In core so the app's menu bar and the
/// `--status` line can never disagree.
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

    /// True for a check that passed with no window, or a calm failure such as no subscription: the account has no limit
    /// to show, which is not the same as missing data. Any window, even one that reset, keeps it tracked.
    public static func hasNothingToTrack(snapshot: UsageSnapshot?, attention: FetchError.Attention?) -> Bool {
        guard snapshot?.windows.isEmpty ?? true else { return false }
        return attention == .calm || (attention == nil && snapshot != nil)
    }
}
