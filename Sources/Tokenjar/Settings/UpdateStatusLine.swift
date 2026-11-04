import Foundation

enum UpdateStatusLine {
    /// nil while nothing has been checked yet, so About shows no line at all.
    static func text(_ status: UpdateStatus, now: Date) -> String? {
        switch status {
        case .unknown: nil
        case .checking: "Checking..."
        case .upToDate(let at): "Up to date · checked \(ago(at, now: now))"
        case .available(let release): "Tokenjar \(release.version) is available"
        case .failed(let at): "Couldn't check for updates · \(ago(at, now: now))"
        }
    }

    private static func ago(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
