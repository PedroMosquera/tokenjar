import SwiftUI
import TokenjarCore

/// The row a provider's status page adds to that provider's cards. It relays the provider's words, so it stays gray:
/// a severity color would make it Tokenjar's own finding, and orange means the user can fix something.
struct HealthRow: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var text: HealthRowText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: text.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            FirstTextInTwoLines(texts: text.candidates)
                .foregroundStyle(.secondary)
                .help(text.tooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text.spoken)
            Spacer(minLength: 8)
            Button("Status Page") {
                model.openStatusPage(account)
                model.closePopover()
            }
            .controlSize(.small)
            .help("Open \(account.provider.statusPageURL?.host() ?? account.provider.displayName) in the browser")
            .accessibilityLabel("Open \(account.provider.displayName) status page")
        }
        .font(.callout)
    }
}

/// What the row says for one answer, worked out apart from the view so tests can read it.
struct HealthRowText: Equatable {
    /// The worst item: "Partial outage on Claude Code: Elevated errors for Claude Opus 5.5".
    var lead: String
    /// " and 1 more", then " · as of 40m ago" once the answer is old. Never cut: when the row runs out of room, the
    /// title gives up words instead.
    var trailing: String
    var symbol: String
    var tooltip: String
    var spoken: String
    /// `lead` and `trailing`, then the same with the title cut a word at a time; the row shows the first that fits.
    var candidates: [String]

    /// nil when the answer reports nothing for the products Tokenjar watches.
    init?(provider: ProviderID, answer: ProviderHealthAnswer, now: Date) {
        guard let worst = answer.items.first else { return nil }
        let more = answer.items.count - 1
        let age = now.timeIntervalSince(answer.answeredAt)
        let showsAge = answer.showsAge(now: now)
        lead = worst.text
        trailing = (more > 0 ? " and \(more) more" : "") + (showsAge ? " · as of \(Format.duration(age)) ago" : "")
        symbol = worst.level == .maintenance ? "wrench.and.screwdriver" : "megaphone"

        let host = provider.statusFeedURL?.host() ?? provider.displayName
        let clauses = answer.items.enumerated().map { index, item in
            "\(index == 0 ? "\(host) reports" : "It also reports") \(Self.phrase(item))."
        }
        let answered = age < 60 ? "Answer from under a minute ago." : "Answer from \(Format.duration(age)) ago."
        tooltip = (clauses + [answered]).joined(separator: " ")

        var spoken = "\(provider.displayName) status page: \(worst.level.word.lowercased()) on \(worst.who)"
        if let title = worst.title { spoken += ". \(title)" }
        if more > 0 { spoken += ". And \(more) more" }
        if showsAge { spoken += ". As of \(Format.spokenDuration(age)) ago" }
        self.spoken = spoken

        var candidates = [lead + trailing]
        let level = worst.level.word
        if let title = worst.title {
            let words = title.split(separator: " ")
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let cut = words.prefix(count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:-"))
                candidates.append("\(level) on \(worst.who): \(cut)…\(trailing)")
            }
            candidates.append("\(level) on \(worst.who): …\(trailing)")
        }
        if let first = worst.names.first, worst.names.count > 1 {
            // A second " and N more" would read as more items, not more products.
            if more == 0 { candidates.append("\(level) on \(first) and \(worst.names.count - 1) more\(trailing)") }
            candidates.append("\(level) on \(first)…\(trailing)")
        }
        self.candidates = candidates
    }

    /// The level in a sentence after "reports", with every name in full: the row may have shortened them to a count.
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

/// Shows the first of `texts` that fits in two lines at the width it is given, else the last one cut at two lines.
/// `ViewThatFits` alone cannot do it here: in the popover's scroll view nothing caps the height, so every text fits.
private struct FirstTextInTwoLines: View {
    var texts: [String]

    var body: some View {
        TwoLineProposal {
            Text(verbatim: "X\nX").hidden()
            ViewThatFits(in: .vertical) {
                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                Text(texts.last ?? "").lineLimit(2)
            }
        }
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
