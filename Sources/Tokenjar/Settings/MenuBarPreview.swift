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

/// The chosen icon and mode as the menu bar draws them for a healthy, an amber and a full account, at the configured
/// amber level and colored by the same rule as the menu bar.
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
        // The samples are NSButtons that do nothing; one description reads better than three dead buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(config))
    }

    static let sampleTime = Date(timeIntervalSince1970: 0)

    static func caption(_ config: MenuBarConfig) -> String {
        config.showResetCountdownWhenFull ? "Healthy, amber and full (time to reset)" : "Healthy, amber and full"
    }

    static func accessibilityText(_ config: MenuBarConfig) -> String {
        let used = levels(config)
        return "Healthy at \(Format.percent(used[0])), amber at \(Format.percent(used[1])), full at \(Format.percent(used[2]))"
    }

    static func samples(_ config: MenuBarConfig) -> [RenderedStatusIcon] {
        sampleEntries(config).map { entry in
            StatusIconRenderer.render(MenuBarState(
                mode: config.mode, icon: config.icon, entries: [entry], showResetCountdownWhenFull: config.showResetCountdownWhenFull, now: sampleTime
            ))
        }
    }

    static func sampleEntries(_ config: MenuBarConfig) -> [MenuBarState.Entry] {
        levels(config).map { used in
            let window = UsageWindow(id: "session", label: "5-hour", usedPercent: used, windowMinutes: 300, resetsAt: sampleTime.addingTimeInterval(47 * 60))
            let severity = Severity.of(window, config: config, now: sampleTime)
            return MenuBarState.Entry(accountID: "sample", provider: .claude, label: "Sample", tightest: window, severity: severity, isStale: false, hasError: false)
        }
    }

    /// Half the amber level stays under 50 %, where no pace can turn a window amber, so the healthy sample is healthy.
    private static func levels(_ config: MenuBarConfig) -> [Double] {
        [Double(config.warnAt / 2), Double(config.warnAt), 100]
    }
}
