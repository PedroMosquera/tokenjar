import SwiftUI
import HeadroomCore

/// One severity scale for every surface, so color means the same thing for every provider.
enum Severity: Int, Comparable {
    case ok, warning, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    /// Warning at `warnAt`, or when the window is projected to run out at least 15 minutes before it resets
    /// (the same rule the alert engine uses, so a bar is never orange while the verdict says "On pace").
    static func of(_ window: UsageWindow, config: MenuBarConfig, now: Date) -> Severity {
        if window.usedPercent >= Double(config.criticalAt) { return .critical }
        if window.usedPercent >= Double(config.warnAt) { return .warning }
        if window.usedPercent >= 50, let pace = Pace.compute(window, now: now), pace.fractionElapsed >= 0.1,
           let eta = pace.secondsToExhaustion, pace.secondsToReset - eta >= 15 * 60 {
            return .warning
        }
        return .ok
    }

    static func worst(of windows: [UsageWindow], config: MenuBarConfig, now: Date) -> Severity {
        windows.map { of($0, config: config, now: now) }.max() ?? .ok
    }

    var color: Color {
        switch self {
        case .ok: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .ok: .controlAccentColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}
