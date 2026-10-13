import SwiftUI
import TokenjarCore

/// The row a provider's status page adds to that provider's cards. It relays the provider's words, so it stays gray:
/// a severity color would make it Tokenjar's own finding, and orange means the user can fix something.
struct HealthRow: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var text: HealthRowText

    static let iconGap: CGFloat = 6
    static let buttonGap: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.iconGap) {
            Image(systemName: text.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ButtonBesideOrBelow(gap: Self.buttonGap) {
                Text(verbatim: "X\nX").hidden()
                Text(text.candidates[0]).fixedSize(horizontal: false, vertical: true).hidden()
                FirstTextInTwoLines(text: text)
                    .foregroundStyle(.secondary)
                    .help(text.tooltip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text.spoken)
                button
            }
        }
        .font(.callout)
    }

    private var button: some View {
        Button("Status Page") {
            model.openStatusPage(account)
            model.closePopover()
        }
        .controlSize(.small)
        .help("Open \(account.provider.statusPageURL?.host() ?? account.provider.displayName) in the browser")
        .accessibilityLabel("Open \(account.provider.displayName) status page")
    }
}

/// What the row says for one answer, worked out apart from the view so tests can read it.
struct HealthRowText: Equatable {
    /// The worst item: "Partial outage on Claude Code: Elevated errors for Claude Opus 5.5".
    var lead: String
    /// " and 1 more", then " · as of 40m ago" once the answer is old. Every candidate ends with it.
    var trailing: String
    /// `trailing` as a line of its own, "and 1 more · as of 40m ago", for when not even the shortest candidate fits.
    var trailingLine: String
    var symbol: String
    var tooltip: String
    var spoken: String
    /// `lead` and `trailing`, then shorter forms that keep `trailing`: the product list shortened, then the title cut a
    /// word at a time, then the title left out, then the products. The row shows the first that fits.
    var candidates: [String]

    /// nil when the answer reports nothing for the products Tokenjar watches.
    init?(provider: ProviderID, answer: ProviderHealthAnswer, now: Date) {
        guard let worst = answer.items.first else { return nil }
        let more = answer.items.count - 1
        let age = now.timeIntervalSince(answer.answeredAt)
        let showsAge = answer.showsAge(now: now)
        let parts = (more > 0 ? ["and \(more) more"] : []) + (showsAge ? ["as of \(Format.duration(age)) ago"] : [])
        trailingLine = parts.joined(separator: " · ")
        trailing = (more > 0 ? " and \(more) more" : "") + (showsAge ? " · as of \(Format.duration(age)) ago" : "")
        symbol = worst.level == .maintenance ? "wrench.and.screwdriver" : "megaphone"

        let level = worst.level.word
        let who = Self.who(worst.names, more: more)
        lead = worst.title.map { "\(level) on \(who): \($0)" } ?? "\(level) on \(who)"

        let host = provider.statusFeedURL?.host() ?? provider.displayName
        let clauses = answer.items.enumerated().map { index, item in
            "\(index == 0 ? "\(host) reports" : "It also reports") \(Self.phrase(item))."
        }
        let answered = age < 60 ? "Answer from under a minute ago." : "Answer from \(Format.duration(age)) ago."
        tooltip = (clauses + [answered]).joined(separator: " ")

        // VoiceOver has no width to save, so it hears every product and every further item in full.
        var spoken = "\(provider.displayName) status page: \(level.lowercased()) on \(Self.list(worst.names))"
        if let title = worst.title { spoken += ". \(title)" }
        for item in answer.items.dropFirst() { spoken += ". It also reports \(Self.phrase(item))" }
        if showsAge { spoken += ". As of \(Format.spokenDuration(age)) ago" }
        self.spoken = spoken

        var candidates = [lead]
        let untitled = Self.shortWho(worst.names, more: more, titled: false) ?? who
        if let title = worst.title {
            let short = Self.shortWho(worst.names, more: more, titled: true) ?? who
            candidates.append("\(level) on \(short): \(title)")
            let words = title.split(separator: " ")
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let cut = words.prefix(count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:-"))
                candidates.append("\(level) on \(short): \(cut)…")
            }
        }
        candidates += ["\(level) on \(untitled)", level]
        var seen: Set<String> = []
        let trailing = trailing
        self.candidates = candidates.filter { seen.insert($0).inserted }.map { $0 + trailing }
    }

    /// The products for the row: every name up to three, else two and a count. A further item has its own count after
    /// it, so the list then ends in an ellipsis instead of reading "and 2 more and 1 more".
    static func who(_ names: [String], more: Int) -> String {
        guard names.count > 3 else { return list(names) }
        return more == 0 ? "\(names[0]), \(names[1]) and \(names.count - 2) more" : "\(names[0]), \(names[1])…"
    }

    /// The first product and what is left, for when the full list does not fit; nil for a single product. Before a
    /// title "and others" keeps the colon readable; elsewhere an ellipsis stays clear of the item count.
    static func shortWho(_ names: [String], more: Int, titled: Bool) -> String? {
        guard let first = names.first, names.count > 1 else { return nil }
        if more == 0 { return "\(first) and \(names.count - 1) more" }
        return titled ? "\(first) and others" : "\(first)…"
    }

    /// The level in a sentence after "reports", with every name in full: the row may have shortened them.
    static func phrase(_ item: ProviderHealthItem) -> String {
        let who = list(item.names)
        let what = switch item.level {
        case .majorOutage: "a major outage of \(who)"
        case .partialOutage: "a partial outage of \(who)"
        case .degradedPerformance: "degraded performance for \(who)"
        case .unknown: "a problem with \(who)"
        case .incident: "an incident that mentions \(who), without naming an affected component"
        case .maintenance: "maintenance on \(who)"
        }
        return item.title.map { "\(what): \($0)" } ?? what
    }

    /// "Codex CLI, Codex Web, Codex API and Codex VS Code extension".
    static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }
}

/// Shows the first candidate that fits in two lines at the width it is given. When none does, the lead takes one line
/// and `trailingLine` the other, so the count and the age are never the part that is cut.
/// `ViewThatFits` alone cannot do it here: in the popover's scroll view nothing caps the height, so every text fits.
private struct FirstTextInTwoLines: View {
    var text: HealthRowText

    var body: some View {
        TwoLineProposal {
            Text(verbatim: "X\nX").hidden()
            ViewThatFits(in: .vertical) {
                ForEach(Array(text.candidates.enumerated()), id: \.offset) { _, candidate in
                    Text(candidate).fixedSize(horizontal: false, vertical: true)
                }
                if text.trailingLine.isEmpty {
                    Text(text.lead).lineLimit(2)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.lead).lineLimit(1)
                        Text(text.trailingLine).fixedSize()
                    }
                }
            }
        }
    }
}

/// Puts the button beside the text when the row's full text fits there in two lines, its baseline on the text's first,
/// else on a line of its own under the text, as ErrorRow does with two actions, so a long row keeps its title.
/// Subviews: a hidden two-line text, the full text hidden, the text shown, the button.
private struct ButtonBesideOrBelow: Layout {
    var gap: CGFloat

    private struct Arrangement {
        var textWidth: CGFloat
        var textY: CGFloat
        var buttonOrigin: CGPoint
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews)
        let textProposal = ProposedViewSize(width: arrangement.textWidth, height: nil)
        subviews[0].place(at: bounds.origin, proposal: .unspecified)
        subviews[1].place(at: bounds.origin, proposal: textProposal)
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + arrangement.textY), proposal: textProposal)
        subviews[3].place(at: CGPoint(x: bounds.minX + arrangement.buttonOrigin.x, y: bounds.minY + arrangement.buttonOrigin.y), proposal: .unspecified)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        let arrangement = arrange(width: bounds.width, subviews)
        return bounds.minY + arrangement.textY + subviews[2].dimensions(in: ProposedViewSize(width: arrangement.textWidth, height: nil))[guide]
    }

    private func arrange(width: CGFloat?, _ subviews: Subviews) -> Arrangement {
        let twoLines = subviews[0].sizeThatFits(.unspecified).height
        let button = subviews[3].dimensions(in: .unspecified)
        let full = width ?? subviews[1].sizeThatFits(.unspecified).width + gap + button.width
        let narrow = max(0, full - gap - button.width)
        if subviews[1].sizeThatFits(ProposedViewSize(width: narrow, height: nil)).height <= twoLines {
            let text = subviews[2].dimensions(in: ProposedViewSize(width: narrow, height: nil))
            let baseline = max(text[.firstTextBaseline], button[.firstTextBaseline])
            let textY = baseline - text[.firstTextBaseline], buttonY = baseline - button[.firstTextBaseline]
            let height = max(textY + text.height, buttonY + button.height)
            return Arrangement(textWidth: narrow, textY: textY, buttonOrigin: CGPoint(x: full - button.width, y: buttonY), size: CGSize(width: full, height: height))
        }
        let text = subviews[2].sizeThatFits(ProposedViewSize(width: full, height: nil))
        let buttonY = text.height + 6
        return Arrangement(textWidth: full, textY: 0, buttonOrigin: CGPoint(x: full - button.width, y: buttonY), size: CGSize(width: full, height: buttonY + button.height))
    }
}

/// Offers its second subview the height of its first, a hidden two-line text in the same font.
private struct TwoLineProposal: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[1].sizeThatFits(Self.offer(width: proposal.width, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: .unspecified)
        subviews[1].place(at: bounds.origin, proposal: Self.offer(width: bounds.width, subviews))
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        bounds.minY + subviews[1].dimensions(in: Self.offer(width: bounds.width, subviews))[guide]
    }

    private static func offer(width: CGFloat?, _ subviews: Subviews) -> ProposedViewSize {
        ProposedViewSize(width: width, height: subviews[0].sizeThatFits(.unspecified).height)
    }
}
