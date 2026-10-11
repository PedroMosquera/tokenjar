import SwiftUI
import TokenjarCore

struct AccountsSettingsPane: View {
    @Environment(AppModel.self) private var model
    var selection: String?
    var onSelect: (String?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            accountList
                .frame(width: 180)
            Divider().ignoresSafeArea()
            if let id = selection, let account = model.config.accounts.first(where: { $0.id == id }) {
                AccountDetailView(account: account, onRemoved: { onSelect(nil) })
                    .id(account.id)
            } else {
                emptyDetail
            }
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        let accounts = model.config.accounts.filter { $0.provider == provider }
                        if !accounts.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    ProviderLogoView(provider: provider, size: 14)
                                    Text(provider.displayName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)
                                ForEach(accounts) { account in
                                    AccountListRow(account: account, note: note(for: account), isSelected: account.id == selection) {
                                        onSelect(account.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Menu {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        Button(provider.displayName) { add(provider) }
                    }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No account selected")
                .font(.headline)
            HelpText("Add an account with the button below the list.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func note(for account: AccountConfig) -> String? {
        if !account.enabled { return "Off" }
        if !model.previewMode, !AccountDiscovery.isAvailable(account, paths: model.paths) { return "Not on this Mac" }
        return nil
    }

    private func add(_ provider: ProviderID) {
        let account = SettingsLogic.newAccount(provider: provider, existing: model.config.accounts)
        model.updateConfig { $0.accounts.append(account) }
        onSelect(account.id)
    }
}

struct AccountListRow: View {
    var account: AccountConfig
    var note: String?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(account.label)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .selectableRow(isSelected)
        }
        .buttonStyle(.plain)
    }
}
