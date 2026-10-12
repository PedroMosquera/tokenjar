import SwiftUI
import TokenjarCore

struct PopoverHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = PopoverSummary.make(
            accounts: model.accounts, statuses: model.statuses, config: model.config, now: model.popoverNow,
            connectivity: model.connectivity, settings: model.settingsProblem
        )
        HStack(spacing: 10) {
            toneIcon(summary.tone)
                .padding(.leading, -PopoverView.symbolBearing)
                .frame(width: 26, alignment: .leading)
                .spoken(PopoverSpeech.tone(summary.tone))
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.text)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Self.help(for: summary))
                if let updated = Self.updateLine(
                    hasAccounts: !model.accounts.isEmpty, isRefreshing: model.isRefreshing, lastUpdated: model.lastUpdated,
                    connectivity: model.connectivity, nextCheck: model.nextNetworkCheck, now: model.popoverNow
                ) {
                    caption(others: summary.others, updated: updated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            RefreshButton()
        }
    }

    /// The other accounts share the update line when both fit, else get a line of their own above it, so the
    /// names are not cut short just to keep the header one line shorter.
    @ViewBuilder
    private func caption(others: [String], updated: String) -> some View {
        if others.isEmpty {
            // Offline and no-answer lines say what happens next and may take two lines.
            Text(updated)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let list = "Also: \(others.joined(separator: ", "))"
            ViewThatFits(in: .horizontal) {
                Text("\(list) · \(updated)")
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(updated)
                }
            }
            .help(list)
        }
    }

    /// nil without accounts, where "Not updated yet" would only repeat the empty state. `lastUpdated` is the newest
    /// successful check, not the last attempt.
    static func updateLine(hasAccounts: Bool, isRefreshing: Bool, lastUpdated: Date?, connectivity: Connectivity, nextCheck: Date?, now: Date) -> String? {
        guard hasAccounts else { return nil }
        if isRefreshing { return "Updating" }
        let updated = lastUpdated.map { "Updated \(Format.age(of: $0, now: now))" }
        switch connectivity {
        case .online:
            return updated ?? "Not updated yet"
        case .offline:
            return updated.map { "\($0). Tokenjar checks again when the Mac is back online." } ?? "Tokenjar checks when the Mac is back online."
        case .noAnswer:
            let next = "Tokenjar tries again \(when(nextCheck, now: now))."
            return updated.map { "\($0). \(next)" } ?? next
        }
    }

    /// Follows `AppModel.nextNetworkCheck`, so retry steps the scheduler adds show up here by themselves.
    private static func when(_ next: Date?, now: Date) -> String {
        guard let next else { return "at the next refresh" }
        let seconds = next.timeIntervalSince(now)
        return seconds < 60 ? "in under a minute" : "in \(Format.duration(seconds))"
    }

    /// The title's tooltip. "Can't reach any provider" alone does not say what could cause it.
    static func help(for summary: PopoverSummary) -> String {
        guard summary.tone == .noAnswer else { return summary.text }
        return "No provider answered the last check. A VPN, a proxy or a Wi-Fi sign-in page can cause this."
    }

    /// The refresh button and Command-R. The user asked, so it runs whatever macOS says about the network.
    @discardableResult
    static func refreshNow(_ model: AppModel) -> Task<Void, Never>? {
        model.refresh(force: true, userInitiated: true)
    }

    /// Without accounts a refresh has nothing to check, so the button and Command-R stay off rather than do nothing.
    static func canRefresh(hasAccounts: Bool, isRefreshing: Bool) -> Bool {
        hasAccounts && !isRefreshing
    }

    @ViewBuilder
    private func toneIcon(_ tone: PopoverSummary.Tone) -> some View {
        if let symbol = symbol(tone) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color(tone))
        } else {
            Image(nsImage: StatusGlyph.picture(.app))
                .renderingMode(.template)
                .resizable()
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
    }

    /// nil with nothing to judge yet, where the header shows the slot the menu bar shows.
    private func symbol(_ tone: PopoverSummary.Tone) -> String? {
        switch tone {
        case .clear: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .problem: "exclamationmark.circle.fill"
        case .unreachable(let onlyTimeouts): onlyTimeouts ? "clock.arrow.circlepath" : "wifi.exclamationmark"
        case .offline: "wifi.slash"
        case .noAnswer: "wifi.exclamationmark"
        case .empty: nil
        }
    }

    private func color(_ tone: PopoverSummary.Tone) -> AnyShapeStyle {
        switch tone {
        case .clear: AnyShapeStyle(Severity.ok.color)
        case .warning: AnyShapeStyle(Severity.warning.color)
        case .critical: AnyShapeStyle(Severity.critical.color)
        case .problem, .empty, .unreachable, .offline, .noAnswer: AnyShapeStyle(.secondary)
        }
    }
}

private struct RefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            PopoverHeader.refreshNow(model)
        } label: {
            ZStack {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!PopoverHeader.canRefresh(hasAccounts: !model.accounts.isEmpty, isRefreshing: model.isRefreshing))
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh now (⌘R)")
        .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh")
    }
}
