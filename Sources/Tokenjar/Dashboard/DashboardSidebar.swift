import SwiftUI
import TokenjarCore

struct DashboardSidebar: View {
    @Environment(AppModel.self) private var model

    private enum Item: Hashable {
        case all
        case account(String)
    }

    /// Deselecting (Command-click on the selected row) keeps the current page rather than leaving the pane empty.
    private var selection: Binding<Item?> {
        Binding(
            get: { model.dashboardSelection.map(Item.account) ?? .all },
            set: { item in
                switch item {
                case .all: model.dashboardSelection = nil
                case .account(let id): model.dashboardSelection = id
                case nil: break
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                Label("All accounts", systemImage: "square.grid.2x2")
                    .tag(Item.all)
            }
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    AccountRow(account: account)
                        .tag(Item.account(account.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct AccountRow: View {
    var account: AccountConfig

    var body: some View {
        let title = AccountTitle(provider: account.provider, label: account.label)
        HStack(spacing: 8) {
            ProviderLogoView(provider: account.provider, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.label ?? title.provider)
                    .lineLimit(1)
                if title.label != nil {
                    Text(title.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .truncationMode(.tail)
            Spacer(minLength: 4)
            SidebarBadgeView(account: account)
        }
    }
}

/// Reads `model.now` itself, so a tick redraws only the badges and not the list around them.
private struct SidebarBadgeView: View {
    @Environment(AppModel.self) private var model
    /// `.increased` on the selected row of the key window, where severity colors would clash with the accent fill.
    @Environment(\.backgroundProminence) private var prominence
    var account: AccountConfig

    var body: some View {
        let status = model.status(for: account)
        let onSelection = prominence == .increased
        if let window = status.snapshot?.tightestWindow {
            let severity = Severity.of(window, config: model.config.menuBar, now: model.now)
            let stale = status.isStale(now: model.now, refreshMinutes: account.refreshMinutes ?? model.config.refreshMinutes)
            Text(Format.percent(window.usedPercent))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(onSelection ? Color.white : severity == .ok ? Color.secondary : severity.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(onSelection ? Color.white.opacity(0.2) : severity == .ok ? Color.primary.opacity(0.07) : severity.color.opacity(0.16)))
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
