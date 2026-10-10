import AppKit
import SwiftUI

/// Categorical colors stepped separately for light and dark, checked with the dataviz palette validator
/// against white and #1E1E1E cards. Slot order is what keeps series apart under color blindness, so assign
/// slots in order and never cycle: extra series get `other`.
enum DashboardPalette {
    /// For accounts and limit windows. Lines cross, so the first four are chosen to stay apart as a set,
    /// not only as neighbours (blue next to violet fails that in dark mode, so violet comes fifth). No red
    /// or orange, so a series never reads as the critical threshold; yellow relies on the dashed, labelled
    /// warn rule to stay distinct from warning amber.
    static let series: [Color] = [
        pair(0x2A78D6, 0x3987E5), // blue
        pair(0xE87BA4, 0xD55181), // magenta
        pair(0x008300, 0x008300), // green
        pair(0xEDA100, 0xC98500), // yellow
        pair(0x4A3AA7, 0x9085E9), // violet
        pair(0x1BAF7A, 0x199E70), // aqua
    ]

    /// For spend groups (model, harness, project), where no threshold shares the plot.
    static let spend: [Color] = [
        pair(0x2A78D6, 0x3987E5), // blue
        pair(0xEB6834, 0xD95926), // orange
        pair(0x1BAF7A, 0x199E70), // aqua
        pair(0xEDA100, 0xC98500), // yellow
        pair(0xE87BA4, 0xD55181), // magenta
        pair(0x008300, 0x008300), // green
        pair(0x4A3AA7, 0x9085E9), // violet
    ]

    static let other = pair(0xA3A29C, 0x6B6A66)

    static func series(_ index: Int) -> Color {
        series.indices.contains(index) ? series[index] : other
    }

    static func spend(_ index: Int) -> Color {
        spend.indices.contains(index) ? spend[index] : other
    }

    private nonisolated static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private nonisolated static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}
