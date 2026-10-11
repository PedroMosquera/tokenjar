import SwiftUI
import TokenjarCore

/// A picker choice as the menu shows it: its glyph and plain name.
struct MenuBarIconLabel: View {
    var icon: MenuBarIcon

    var body: some View {
        Label {
            Text(icon.title)
        } icon: {
            Image(nsImage: StatusGlyph.picture(icon))
        }
    }
}

/// The chosen icon and mode as the menu bar draws them for a healthy, an amber and a full account.
struct MenuBarPreview: View {
    var config: MenuBarConfig
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.samples(config).enumerated()), id: \.offset) { _, rendered in
                StatusItemPreview(rendered: rendered)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    static func samples(_ config: MenuBarConfig) -> [RenderedStatusIcon] {
        let now = Date(timeIntervalSince1970: 0)
        return [(42.0, Severity.ok), (85, .warning), (100, .critical)].map { used, severity in
            let window = UsageWindow(id: "session", label: "5-hour", usedPercent: used, windowMinutes: 300, resetsAt: now.addingTimeInterval(47 * 60))
            let entry = MenuBarState.Entry(accountID: "sample", provider: .claude, label: "Sample", tightest: window, severity: severity, isStale: false, failureNeedsAttention: false)
            return StatusIconRenderer.render(MenuBarState(
                mode: config.mode, icon: config.icon, entries: [entry], showResetCountdownWhenFull: config.showResetCountdownWhenFull, now: now
            ))
        }
    }
}
