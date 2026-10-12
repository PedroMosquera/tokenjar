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
        let dot = state.showsDot, slash = state.isSlashed
        guard let worst = state.worst, let tightest = worst.tightest else {
            let description = "Tokenjar" + stateClause(state) + unreachableClauses(state.entries, in: state) + failedClause(failing, in: state)
            let width = state.mode == .bars ? StatusGlyph.barsBoxWidth(count: state.entries.count) : 0
            return RenderedStatusIcon(
                image: StatusGlyph.neutral(state.icon, dot: dot, slash: slash, width: width, description: description), toolTip: toolTip
            )
        }
        // A faded slash would vanish on a tinted menu bar, and the slash already says the numbers are old.
        let alpha: CGFloat = worst.isStale && !slash ? 0.5 : 1
        let description = accessibilityDescription(worst, window: tightest, failing: failing, in: state)
        let image = StatusGlyph.image(
            state.icon, fraction: tightest.usedPercent / 100, tint: tint(worst.severity), alpha: alpha, dot: dot, slash: slash, description: description
        )
        switch state.mode {
        case .worst:
            let text = title(for: worst, showResetCountdownWhenFull: state.showResetCountdownWhenFull, now: state.now)
            return RenderedStatusIcon(
                image: image, title: text,
                attributedTitle: attributedTitle(text, severity: worst.severity, isStale: worst.isStale, isSlashed: slash),
                toolTip: toolTip
            )
        case .bars:
            let bars = state.entries.map { entry in
                StatusGlyph.Bar(
                    fraction: entry.tightest.map { $0.usedPercent / 100 }, severity: entry.severity,
                    dimmed: (entry.isStale && !slash) || entry.failureNeedsAttention
                )
            }
            return RenderedStatusIcon(image: StatusGlyph.bars(bars, dot: dot, slash: slash, description: barsDescription(state)), toolTip: toolTip)
        case .icon:
            return RenderedStatusIcon(image: image, toolTip: toolTip)
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

    /// What VoiceOver reads for the icon. Icon mode has no title and the tooltip is only delayed help, so the account,
    /// the level the slot shows and the state the tint, fade and dot show have to be spelled out here.
    private static func accessibilityDescription(_ entry: MenuBarState.Entry, window: UsageWindow, failing: MenuBarState.Entry?, in state: MenuBarState) -> String {
        var text = "Tokenjar\(stateClause(state)), \(spokenName(entry, in: state)) \(window.label) "
        if window.usedPercent >= 100, let resetsAt = window.resetsAt {
            text += "full, resets in \(Format.spokenDuration(resetsAt.timeIntervalSince(state.now)))"
        } else {
            text += "\(Format.percent(window.usedPercent)) used"
        }
        if let cause = entry.cause { text += ", " + causeClause(cause, tightest: window, spoken: true) }
        text += unreachableClauses([entry], in: state)
        if entry.isStale, failing?.accountID != entry.accountID { text += ", out of date" }
        return text + unreachableClauses(state.entries.filter { $0.accountID != entry.accountID }, in: state) + failedClause(failing, in: state)
    }

    /// ", can't reach GitHub Copilot" for each account whose check could not connect, as the tooltip names them. Under
    /// the slash the lead already says why.
    private static func unreachableClauses(_ entries: [MenuBarState.Entry], in state: MenuBarState) -> String {
        guard !state.isSlashed else { return "" }
        return entries.compactMap { entry in
            entry.connectionFailure.map { $0 == .timeout ? ", no answer from \(spokenName(entry, in: state))" : ", can't reach \(spokenName(entry, in: state))" }
        }.joined()
    }

    /// What VoiceOver hears first, as the tooltip's first lines say it: why Tokenjar can't refresh, and settings that
    /// need the user.
    private static func stateClause(_ state: MenuBarState) -> String {
        var clause = ""
        switch state.connectivity {
        case .online: break
        case .offline: clause += ", offline"
        case .noAnswer: clause += ", can't reach any provider"
        }
        if let problem = state.settingsProblem {
            clause += problem.nothingLoaded ? ", settings not loaded" : ", settings need attention"
        }
        return clause
    }

    /// Bars shows no number, so every account's level is read out, then what the colors, fades and dims mean.
    private static func barsDescription(_ state: MenuBarState) -> String {
        let levels = state.entries.map { entry in
            "\(spokenName(entry, in: state)) \(entry.tightest.map { Format.percent($0.usedPercent) } ?? "no data")"
        }
        let notes = state.entries.compactMap { entry in
            entry.cause.map { "\(spokenName(entry, in: state)) \(causeClause($0, tightest: entry.tightest, spoken: true))" }
        } + state.entries.filter { $0.isStale && !$0.failureNeedsAttention }.map { "\(spokenName($0, in: state)) out of date" }
            + state.entries.filter(\.failureNeedsAttention).map { "\(spokenName($0, in: state)) check failed" }
        return (["Tokenjar" + stateClause(state)] + levels).joined(separator: ", ") + unreachableClauses(state.entries, in: state)
            + notes.map { ", " + $0 }.joined()
    }

    /// "5-hour runs out ~50m before reset", without the window's name when it is the one whose number is shown.
    private static func causeClause(_ cause: PaceVerdict, tightest: UsageWindow?, spoken: Bool) -> String {
        let text = spoken ? cause.spokenText : cause.text
        let clause = text.prefix(1).lowercased() + text.dropFirst()
        return cause.window.id == tightest?.id ? clause : "\(cause.window.label) \(clause)"
    }

    private static func failedClause(_ failing: MenuBarState.Entry?, in state: MenuBarState) -> String {
        failing.map { ", \(spokenName($0, in: state)) check failed" } ?? ""
    }

    /// The provider alone names an account unless another menu bar account shares it.
    private static func spokenName(_ entry: MenuBarState.Entry, in state: MenuBarState) -> String {
        let title = AccountTitle(provider: entry.provider, label: entry.label)
        let shared = state.entries.contains { $0.accountID != entry.accountID && $0.provider == entry.provider }
        return shared ? title.spokenName : title.provider
    }

    static func toolTip(for state: MenuBarState) -> String {
        if let problem = state.settingsProblem, problem.nothingLoaded { return problem.message }
        let lead = [connectivityLine(state), state.settingsProblem?.message].compactMap { $0 }
        guard !state.entries.isEmpty else { return (lead + ["Tokenjar: no accounts in the menu bar"]).joined(separator: "\n") }
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
                if let cause = entry.cause { line += "; " + causeClause(cause, tightest: window, spoken: false) }
            } else {
                line = "\(name): no data"
            }
            return line + suffix(entry, slashed: state.isSlashed)
        }
        return (lead + lines).joined(separator: "\n")
    }

    /// Why the menu bar is slashed, with the age of what it shows and what happens next.
    private static func connectivityLine(_ state: MenuBarState) -> String? {
        let age = state.lastUpdated.map { Format.age(of: $0, now: state.now) }
        switch state.connectivity {
        case .online:
            return nil
        case .offline:
            return age.map { "This Mac is offline. The usage shown was last updated \($0), and Tokenjar checks again when the Mac is back online." }
                ?? "This Mac is offline. Tokenjar checks usage when the Mac is back online."
        case .noAnswer:
            let cause = "Tokenjar can't reach any provider, which a VPN, a proxy or a Wi-Fi sign-in page can cause."
            return age.map { "\(cause) The usage shown was last updated \($0), and Tokenjar tries again at the next refresh." }
                ?? "\(cause) Tokenjar tries again at the next refresh."
        }
    }

    /// Why one account's line is not current. Under a slash the first line already says why a check failed.
    private static func suffix(_ entry: MenuBarState.Entry, slashed: Bool) -> String {
        let reason: String?
        if entry.attention == .actionable {
            return " (last check failed)"
        } else if let failure = entry.connectionFailure {
            reason = slashed ? nil : (failure == .timeout ? "no answer" : "can't reach")
        } else if entry.attention == .transient {
            reason = "waiting to check again"
        } else {
            reason = nil
        }
        let parts = [reason, entry.isStale ? "out of date" : nil].compactMap { $0 }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func tint(_ severity: Severity) -> NSColor? {
        severity == .ok ? nil : severity.nsColor
    }

    /// Under a slash every number is old, so an ok one goes secondary while an amber or red one keeps its full color: a
    /// near-limit warning is never hidden.
    private static func attributedTitle(_ text: String, severity: Severity, isStale: Bool, isSlashed: Bool) -> NSAttributedString {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: severity == .ok ? .regular : .semibold),
        ]
        // No color when fresh and healthy, so the status item uses the menu bar's own vibrant text color. Not
        // labelColor.withAlphaComponent for stale: that resolves once and can stay white on a light menu bar.
        if let tint = tint(severity) {
            attributes[.foregroundColor] = isStale && !isSlashed ? tint.withAlphaComponent(0.5) : tint
        } else if isStale || isSlashed {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
