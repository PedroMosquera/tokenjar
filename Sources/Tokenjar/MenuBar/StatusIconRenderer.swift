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
        let failing = state.failing
        guard let worst = state.worst, let tightest = worst.tightest else {
            let description = "Tokenjar" + failedClause(failing, in: state)
            return RenderedStatusIcon(image: StatusGlyph.neutral(state.icon, dot: failing != nil, description: description), toolTip: toolTip)
        }
        let alpha: CGFloat = worst.isStale ? 0.5 : 1
        let description = accessibilityDescription(worst, window: tightest, failing: failing, in: state)
        switch state.mode {
        case .worst:
            let text = title(for: worst, showResetCountdownWhenFull: state.showResetCountdownWhenFull, now: state.now)
            return RenderedStatusIcon(
                image: StatusGlyph.image(state.icon, fraction: tightest.usedPercent / 100, tint: tint(worst.severity), alpha: alpha, dot: failing != nil, description: description),
                title: text,
                attributedTitle: attributedTitle(text, severity: worst.severity, isStale: worst.isStale),
                toolTip: toolTip
            )
        case .bars:
            let bars = state.entries.map { entry in
                StatusGlyph.Bar(fraction: entry.tightest.map { $0.usedPercent / 100 }, severity: entry.severity, dimmed: entry.isStale || entry.checkFailed)
            }
            return RenderedStatusIcon(image: StatusGlyph.bars(bars), toolTip: toolTip)
        case .icon:
            return RenderedStatusIcon(
                image: StatusGlyph.image(state.icon, fraction: tightest.usedPercent / 100, tint: tint(worst.severity), alpha: alpha, dot: failing != nil, description: description),
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

    /// What VoiceOver reads for the icon. Icon mode has no title and the tooltip is only delayed help, so the level the
    /// slot shows and the state the fade and dot show have to be spelled out here.
    private static func accessibilityDescription(_ entry: MenuBarState.Entry, window: UsageWindow, failing: MenuBarState.Entry?, in state: MenuBarState) -> String {
        var text = "Tokenjar, \(window.label) \(Format.percent(window.usedPercent)) used"
        if entry.isStale, failing?.accountID != entry.accountID { text += ", out of date" }
        return text + failedClause(failing, in: state)
    }

    private static func failedClause(_ failing: MenuBarState.Entry?, in state: MenuBarState) -> String {
        failing.map { ", \(spokenName($0, in: state)) check failed" } ?? ""
    }

    /// The provider alone names an account unless another menu bar account shares it. No middle dot: VoiceOver
    /// reads it out.
    private static func spokenName(_ entry: MenuBarState.Entry, in state: MenuBarState) -> String {
        let title = AccountTitle(provider: entry.provider, label: entry.label)
        let shared = state.entries.contains { $0.accountID != entry.accountID && $0.provider == entry.provider }
        guard shared, let label = title.label else { return title.provider }
        return "\(title.provider) \(label)"
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
            if entry.checkFailed { line += " (last check failed)" } else if entry.isStale { line += " (out of date)" }
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
