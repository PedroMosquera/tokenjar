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
        // Narrower, the account page beside the sidebar and the account list puts its fields under their labels.
        .frame(minWidth: 800, minHeight: 460)
        .navigationTitle(pane.title)
        .onChange(of: model.settingsSelection) { _, id in
            guard let id else { return }
            chosenPane = .accounts
            chosenAccountID = id
        }
    }

    // A native list, so its selection turns grey while the account list has focus, as in System Settings, instead of
    // showing two accent highlights at once.
    private var sidebar: some View {
        List(selection: Binding(get: { pane }, set: { if let item = $0 { select(item) } })) {
            ForEach(SettingsPane.allCases) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 160)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general:
            withConfigBanner { GeneralSettingsPane() }
        case .accounts:
            withConfigBanner { AccountsSettingsPane(selection: accountID) { selectAccount($0) } }
        case .alerts:
            withConfigBanner { AlertsSettingsPane() }
        case .about:
            AboutSettingsPane()
        }
    }

    /// Across the top of every pane that edits config, so the reason its controls are disabled is in view.
    private func withConfigBanner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if let problem = model.configError {
                SettingsBanner(text: problem)
            }
            content()
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
