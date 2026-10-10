import SwiftUI
import HeadroomCore

/// Custom rows rather than List or NavigationSplitView, which may not draw in offscreen snapshot renders.
struct DashboardSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(id: nil) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text("All accounts").lineLimit(1)
                Spacer(minLength: 4)
            }
            Text("Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(model.accounts) { account in
                row(id: account.id) {
                    ProviderLogoView(provider: account.provider, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.label)
                            .lineLimit(1)
                        Text(account.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .truncationMode(.tail)
                    Spacer(minLength: 4)
                    badge(for: account)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row<Label: View>(id: String?, @ViewBuilder label: () -> Label) -> some View {
        let selected = model.dashboardSelection == id
        return Button {
            model.dashboardSelection = id
        } label: {
            HStack(spacing: 8) { label() }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func badge(for account: AccountConfig) -> some View {
        let status = model.status(for: account)
        if let window = status.snapshot?.tightestWindow {
            let severity = Severity.of(window, config: model.config.menuBar, now: model.now)
            let stale = status.isStale(now: model.now, refreshMinutes: account.refreshMinutes ?? model.config.refreshMinutes)
            Text(Format.percent(window.usedPercent))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(severity == .ok ? Color.secondary : severity.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(severity == .ok ? Color.primary.opacity(0.07) : severity.color.opacity(0.16)))
                .opacity(stale ? 0.5 : 1)
                .help("\(window.label): \(Format.percent(window.usedPercent)) used")
        } else if let error = status.error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(error.userMessage)
        }
    }
}
