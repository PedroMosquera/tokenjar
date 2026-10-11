import SwiftUI
import TokenjarCore

struct AccountsSettingsPane: View {
    @Environment(AppModel.self) private var model
    var selection: String?
    var onSelect: (String?) -> Void

    @SettingsState private var removing: AccountConfig?

    var body: some View {
        Group {
            if model.config.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add Claude, Codex, OpenCode, Antigravity, Copilot or Devin to track its limits.")
                } actions: {
                    addMenu { Text("Add Account") }
                        .menuStyle(.button)
                        .fixedSize()
                }
            } else {
                HStack(spacing: 0) {
                    accountList
                        .frame(width: 220)
                    Divider().ignoresSafeArea()
                    if let account = selectedAccount {
                        AccountDetailView(account: account, onRemove: { removing = account })
                            .id(account.id)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove \(removing?.displayName ?? "account")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("Remove", role: .destructive) { remove(account) }
        } message: { account in
            Text(removeMessage(account))
        }
    }

    private var selectedAccount: AccountConfig? {
        selection.flatMap { id in model.config.accounts.first { $0.id == id } }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            list
            listBar
        }
    }

    private var list: some View {
        List(selection: Binding(get: { selection }, set: { if let id = $0 { onSelect(id) } })) {
            ForEach(ProviderID.allCases, id: \.self) { provider in
                let accounts = model.config.accounts.filter { $0.provider == provider }
                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            AccountListRow(content: AccountListRowContent.make(account: account, status: model.statusText(for: account)))
                                .tag(account.id)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            ProviderLogoView(provider: provider, size: 14)
                            Text(provider.displayName)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand { if model.canEditConfig { removing = selectedAccount } }
    }

    private var listBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                addMenu {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add Account")
                .accessibilityLabel("Add Account")
                Divider().frame(height: 16)
                Button {
                    removing = selectedAccount
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(selectedAccount == nil)
                .help("Remove Account")
                .accessibilityLabel("Remove Account")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .disabled(!model.canEditConfig)
        }
    }

    private func addMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(ProviderID.allCases, id: \.self) { provider in
                Button(provider.displayName) { add(provider) }
            }
        } label: {
            label()
        }
    }

    private func add(_ provider: ProviderID) {
        let account = SettingsLogic.newAccount(provider: provider, existing: model.config.accounts)
        model.updateConfig { $0.accounts.append(account) }
        onSelect(account.id)
    }

    private func removeMessage(_ account: AccountConfig) -> String {
        var text = "It is removed from config.json. Its history stays in the local database."
        if case .keychain = account.credential { text += " Its pasted API key is deleted from this Mac's Keychain." }
        return text
    }

    private func remove(_ account: AccountConfig) {
        if case .keychain(let keyAccount) = account.credential {
            try? model.secrets.delete(account: keyAccount)
        }
        model.updateConfig { $0.accounts.removeAll { $0.id == account.id } }
        removing = nil
        onSelect(nil)
    }
}

struct AccountListRow: View {
    var content: AccountListRowContent

    var body: some View {
        HStack(spacing: 6) {
            Text(content.title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let caption = content.caption {
                HStack(spacing: 3) {
                    if content.isActionable {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    Text(caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.title)
        .accessibilityValue(content.caption ?? "")
    }
}

struct AccountListRowContent: Equatable {
    var title: String
    var caption: String?
    /// Only a caption the user has to act on carries the warning symbol.
    var isActionable = false

    static func make(account: AccountConfig, status: AccountStatusText) -> AccountListRowContent {
        let title = AccountTitle(provider: account.provider, label: account.label)
        return AccountListRowContent(title: title.label ?? title.provider, caption: status.caption?.text, isActionable: status.caption?.isActionable ?? false)
    }
}
