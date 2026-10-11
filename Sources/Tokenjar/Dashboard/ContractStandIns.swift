import Foundation
import TokenjarCore

// Temporary stand-ins, copied from the branches that own them, so the dashboard builds on its own:
// FetchError.attention, UsageWindow.hasReset(now:) and UsageSnapshot.tightestWindow(now:) from polish/core-app, and
// Format.spokenDuration(_:) from polish/popover-menubar. Both merge first; delete this file in the dashboard merge,
// and the build fails on the duplicates until it is gone.

extension FetchError {
    enum Attention: Sendable {
        case calm
        case transient
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

extension UsageWindow {
    func hasReset(now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

extension UsageSnapshot {
    func tightestWindow(now: Date) -> UsageWindow? {
        var live = self
        live.windows = windows.filter { !$0.hasReset(now: now) }
        return live.tightestWindow
    }
}

extension Format {
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "less than a minute" }
        return spokenFormatter.string(from: seconds.rounded(.down)) ?? duration(seconds)
    }

    private static let spokenFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
