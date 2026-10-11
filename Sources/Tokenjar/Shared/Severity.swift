import SwiftUI
import TokenjarCore

/// One severity scale for every surface, so color means the same thing for every provider.
enum Severity: Int, Comparable {
    case ok, warning, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    /// Warning at `warnAt`, or when the window is projected to run out at least 15 minutes before it resets (the
    /// alert engine's rule). The projection never colors a bar the verdict calls "On pace", but `warnAt` can.
    /// Ok once the reset has passed: the use shown is the old cycle's until the next check replaces it.
    static func of(_ window: UsageWindow, config: MenuBarConfig, now: Date) -> Severity {
        if window.hasReset(now: now) { return .ok }
        let byUse = ofUse(window.usedPercent, config: config)
        if byUse > .ok { return byUse }
        if window.usedPercent >= 50, let pace = Pace.compute(window, now: now), pace.fractionElapsed >= 0.1,
           let eta = pace.secondsToExhaustion, pace.secondsToReset - eta >= 15 * 60 {
            return .warning
        }
        return .ok
    }

    /// The thresholds alone, without the projection.
    static func ofUse(_ usedPercent: Double, config: MenuBarConfig) -> Severity {
        if usedPercent >= Double(config.criticalAt) { return .critical }
        if usedPercent >= Double(config.warnAt) { return .warning }
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
