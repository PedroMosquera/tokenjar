import SwiftUI
import TokenjarCore

struct PopoverHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = PopoverSummary.make(accounts: model.accounts, statuses: model.statuses, config: model.config.menuBar, now: model.now)
        HStack(spacing: 10) {
            Image(systemName: symbol(summary.tone))
                .font(.title2)
                .foregroundStyle(color(summary.tone))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.text)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(summary.text)
                caption(others: summary.others)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            RefreshButton()
        }
    }

    /// The other accounts share the update line when both fit, else get a line of their own above it, so the
    /// names are not cut short just to keep the header one line shorter.
    @ViewBuilder
    private func caption(others: [String]) -> some View {
        if others.isEmpty {
            Text(updatedText)
        } else {
            let list = "Also: \(others.joined(separator: ", "))"
            ViewThatFits(in: .horizontal) {
                Text("\(list) · \(updatedText)")
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(updatedText)
                }
            }
            .help(list)
        }
    }

    private var updatedText: String {
        if model.isRefreshing { return "Updating" }
        guard let last = model.lastRefreshAt else { return "Not updated yet" }
        return "Updated \(Format.age(of: last, now: model.now))"
    }

    private func symbol(_ tone: PopoverSummary.Tone) -> String {
        switch tone {
        case .clear: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .problem: "exclamationmark.circle.fill"
        case .empty: "gauge.with.dots.needle.33percent"
        }
    }

    private func color(_ tone: PopoverSummary.Tone) -> AnyShapeStyle {
        switch tone {
        case .clear: AnyShapeStyle(Severity.ok.color)
        case .warning: AnyShapeStyle(Severity.warning.color)
        case .critical: AnyShapeStyle(Severity.critical.color)
        case .problem, .empty: AnyShapeStyle(.secondary)
        }
    }
}

private struct RefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.refresh(force: true)
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
        .disabled(model.isRefreshing)
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh now (⌘R)")
        .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh")
    }
}
