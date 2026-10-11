import SwiftUI
import TokenjarCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, alerts, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .alerts: "Alerts"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .alerts: "bell"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @SettingsState private var chosenPane: SettingsPane?
    @SettingsState private var chosenAccountID: String?

    /// `pane` opens on that pane as if it had been clicked; nil follows `settingsSelection`.
    init(pane: SettingsPane? = nil) {
        _chosenPane = SettingsState(initialValue: pane)
    }

    // Until the user picks something, follow `settingsSelection` so "Settings for this account" lands on that account.
    private var pane: SettingsPane {
        chosenPane ?? (model.settingsSelection == nil ? .general : .accounts)
    }

    private var accountID: String? {
        let ids = model.config.accounts.map(\.id)
        if let id = chosenAccountID ?? model.settingsSelection, ids.contains(id) { return id }
        return ids.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 460)
        .onChange(of: model.settingsSelection) { _, id in
            guard let id else { return }
            chosenPane = .accounts
            chosenAccountID = id
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { item in
                SettingsSidebarRow(title: item.title, symbol: item.symbol, isSelected: item == pane) { select(item) }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 160)
        .background(Color.primary.opacity(0.035).ignoresSafeArea())
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general:
            GeneralSettingsPane()
        case .accounts:
            AccountsSettingsPane(selection: accountID) { selectAccount($0) }
        case .alerts:
            AlertsSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }

    // Mirrors the choice into `settingsSelection` so a later "Settings for this account" is seen as a change.
    private func select(_ item: SettingsPane) {
        chosenPane = item
        model.settingsSelection = item == .accounts ? accountID : nil
    }

    private func selectAccount(_ id: String?) {
        chosenPane = .accounts
        chosenAccountID = id
        model.settingsSelection = id
    }
}

struct SettingsSidebarRow: View {
    var title: String
    var symbol: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(title)
                Spacer(minLength: 0)
            }
            .selectableRow(isSelected)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func selectableRow(_ isSelected: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
    }
}
