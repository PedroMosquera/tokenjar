import SwiftUI
import HeadroomCore

/// One severity scale for every surface, so color means the same thing for every provider.
enum Severity: Int, Comparable {
    case ok, warning, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    /// Warning at `warnAt` or when the pace projects exhaustion before reset; critical at `criticalAt`.
    static func of(_ window: UsageWindow, config: MenuBarConfig, now: Date) -> Severity {
        if window.usedPercent >= Double(config.criticalAt) { return .critical }
        if window.usedPercent >= Double(config.warnAt) { return .warning }
        if let pace = Pace.compute(window, now: now), pace.runsOutBeforeReset, window.usedPercent >= 50 { return .warning }
        return .ok
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
