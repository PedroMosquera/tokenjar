import Foundation
import TokenjarCore

// Temporary stand-ins for API the polish/core-app branch adds (FetchError.attention, ProviderID.reportsWindows,
// UsageWindow.hasReset(now:), UsageSnapshot.tightestWindow(now:), AppModel.popoverNow). core-app merges first;
// delete this file in that merge, and the build fails on the duplicates until it is gone.

extension FetchError {
    enum Attention: Equatable, Sendable {
        /// Nothing to fix and nothing to wait for, such as an account without a subscription.
        case calm
        /// Likely to pass on the next check.
        case transient
        /// Needs the user.
        case actionable
    }

    var attention: Attention {
        switch self {
        case .noSubscription: .calm
        case .network, .timeout, .rateLimited: .transient
        case .cliNotFound, .notSignedIn, .unauthorized, .parse, .unsupported: .actionable
        }
    }
}

extension ProviderID {
    var reportsWindows: Bool {
        switch self {
        case .opencodeZen, .devin: false
        case .claude, .codex, .opencodeGo, .antigravity, .copilot: true
        }
    }
}

extension UsageWindow {
    func hasReset(now: Date) -> Bool {
        guard !notStarted, let resetsAt else { return false }
        return resetsAt <= now
    }
}

extension UsageSnapshot {
    func tightestWindow(now: Date) -> UsageWindow? {
        var live = self
        live.windows = windows.filter { !$0.hasReset(now: now) }
        return live.tightestWindow
    }
}

extension AppModel {
    var popoverNow: Date { now }
}
