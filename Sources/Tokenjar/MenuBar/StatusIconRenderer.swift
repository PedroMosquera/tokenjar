import AppKit
import TokenjarCore

struct RenderedStatusIcon {
    var image: NSImage?
    var title: String = ""
    var attributedTitle = NSAttributedString()
    var toolTip: String?
}

enum StatusIconRenderer {
    static func render(_ state: MenuBarState) -> RenderedStatusIcon {
        let toolTip = toolTip(for: state)
        guard let worst = state.worst, worst.tightest != nil else {
            return RenderedStatusIcon(image: StatusGlyph.neutral(dot: state.entries.contains(where: \.hasError)), toolTip: toolTip)
        }
        let alpha: CGFloat = worst.isStale ? 0.5 : 1
        switch state.mode {
        case .worst:
            let text = title(for: worst, showResetCountdownWhenFull: state.showResetCountdownWhenFull, now: state.now)
            return RenderedStatusIcon(
                image: StatusGlyph.brand(tint: tint(worst.severity), alpha: alpha, dot: worst.hasError),
                title: text,
                attributedTitle: attributedTitle(text, severity: worst.severity, isStale: worst.isStale),
                toolTip: toolTip
            )
        case .bars:
            let bars = state.entries.map { entry in
                StatusGlyph.Bar(fraction: entry.tightest.map { $0.usedPercent / 100 }, severity: entry.severity, dimmed: entry.isStale || entry.hasError)
            }
            return RenderedStatusIcon(image: StatusGlyph.bars(bars), toolTip: toolTip)
        case .icon:
            return RenderedStatusIcon(
                image: StatusGlyph.brand(tint: tint(worst.severity), alpha: alpha, dot: worst.hasError),
                toolTip: toolTip
            )
        }
    }

    /// Used % of the tightest window, or the time until it resets once it is full.
    static func title(for entry: MenuBarState.Entry, showResetCountdownWhenFull: Bool, now: Date) -> String {
        guard let window = entry.tightest else { return "" }
        if showResetCountdownWhenFull, window.usedPercent >= 100, let countdown = Format.countdown(to: window.resetsAt, now: now) {
            return countdown
        }
        return Format.percent(window.usedPercent)
    }

    static func toolTip(for state: MenuBarState) -> String {
        guard !state.entries.isEmpty else { return "Tokenjar: no accounts in the menu bar" }
        let lines = state.entries.map { entry -> String in
            let name = AccountTitle(provider: entry.provider, label: entry.label).name
            var line: String
            if let window = entry.tightest {
                line = "\(name): \(window.label) \(Format.percent(window.usedPercent))"
                if window.notStarted {
                    line += ", not started"
                } else if let countdown = Format.countdown(to: window.resetsAt, now: state.now) {
                    line += ", resets in \(countdown)"
                }
            } else {
                line = "\(name): no data"
            }
            if entry.hasError { line += " (last check failed)" } else if entry.isStale { line += " (out of date)" }
            return line
        }
        return lines.joined(separator: "\n")
    }

    private static func tint(_ severity: Severity) -> NSColor? {
        severity == .ok ? nil : severity.nsColor
    }

    private static func attributedTitle(_ text: String, severity: Severity, isStale: Bool) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: severity == .ok ? .regular : .semibold),
        ]
        // No color when fresh and healthy, so the status item uses the menu bar's own vibrant text color. Not
        // labelColor.withAlphaComponent for stale: that resolves once and can stay white on a light menu bar.
        if let tint = tint(severity) {
            attributes[.foregroundColor] = isStale ? tint.withAlphaComponent(0.5) : tint
        } else if isStale {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
