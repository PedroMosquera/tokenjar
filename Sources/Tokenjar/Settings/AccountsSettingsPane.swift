import SwiftUI
import TokenjarCore

struct AccountsSettingsPane: View {
    @Environment(AppModel.self) private var model
    var selection: String?
    var onSelect: (String?) -> Void

    @SettingsState private var removing: AccountConfig?
    @SettingsState private var naming: AccountNaming?

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
                        .disabled(!model.canEditConfig)
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
        .sheet(item: $naming) { naming in
            AccountNameSheet(naming: naming) { name in commit(naming, name: name) }
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
        ScrollViewReader { scroller in
            List(selection: Binding(get: { selection }, set: { if let id = $0 { onSelect(id) } })) {
                // One list in the user's order, so dragging here is the order the popover's cards follow.
                ForEach(model.config.accounts) { account in
                    AccountMenuRow(isSelected: account.id == selection) {
                        AccountListRow(
                            content: AccountListRowContent.make(account: account, status: model.statusText(for: account)), provider: account.provider,
                            isSelected: account.id == selection
                        )
                    } menu: {
                        accountMenu(account)
                    }
                    .tag(account.id)
                    .listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    guard model.canEditConfig else { return }
                    model.updateConfig { $0.accounts.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { if model.canEditConfig { removing = selectedAccount } }
            // A List does not follow a selection made in code, such as "Settings for This Account" picking a row
            // below the fold.
            .onAppear { reveal(selection, in: scroller) }
            .onChange(of: selection) { _, id in reveal(id, in: scroller) }
        }
    }

    @ViewBuilder private func accountMenu(_ account: AccountConfig) -> some View {
        let accounts = model.config.accounts
        Group {
            Button("Rename\u{2026}") { naming = .rename(account) }
            if account.provider.reportsWindows {
                Toggle("Show in Menu Bar", isOn: model.accountBinding(account.id, \.showInMenuBar, fallback: account.showInMenuBar))
            }
            Divider()
            Button("Move Up") { move(account, by: -1) }
                .disabled(accounts.first?.id == account.id)
            Button("Move Down") { move(account, by: 1) }
                .disabled(accounts.last?.id == account.id)
            Divider()
            Button("Remove\u{2026}", role: .destructive) { removing = account }
        }
        .disabled(!model.canEditConfig)
    }

    private func move(_ account: AccountConfig, by offset: Int) {
        model.updateConfig { $0.accounts = SettingsLogic.moving(account.id, by: offset, in: $0.accounts) }
    }

    private func reveal(_ id: String?, in scroller: ScrollViewProxy) {
        if let id { scroller.scrollTo(id) }
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

    /// Nothing is saved until the sheet's Add, so a cancelled add leaves no "Account 2" behind.
    private func add(_ provider: ProviderID) {
        naming = .add(SettingsLogic.newAccount(provider: provider, existing: model.config.accounts))
    }

    private func commit(_ naming: AccountNaming, name: String) {
        switch naming {
        case .add(var account):
            account.label = name
            model.updateConfig { $0.accounts.append(account) }
        case .rename(let account):
            model.updateConfig { config in
                if let index = config.accounts.firstIndex(where: { $0.id == account.id }) { config.accounts[index].label = name }
            }
        }
        onSelect(naming.account.id)
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
    var provider: ProviderID
    var isSelected = false

    /// Orange is hard to see on the selection's accent fill. SwiftUI does not tell an inset list's row when its selection
    /// is emphasized, so a selected row always draws the symbol like its caption; its detail page shows the warning.
    static func symbolTint(isSelected: Bool) -> Color? {
        isSelected ? nil : .orange
    }

    var body: some View {
        HStack(spacing: 6) {
            ProviderLogoView(provider: provider, size: 14)
            Text(content.title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let caption = content.caption {
                HStack(spacing: 3) {
                    if content.isActionable {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Self.symbolTint(isSelected: isSelected).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    }
                    Text(caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.title == provider.displayName ? content.title : "\(provider.displayName), \(content.title)")
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

enum AccountNaming: Identifiable {
    case add(AccountConfig)
    case rename(AccountConfig)

    var account: AccountConfig {
        switch self {
        case .add(let account), .rename(let account): account
        }
    }

    var id: String { account.id }
}

struct AccountNameSheet: View {
    var naming: AccountNaming
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @SettingsState private var name: String
    @FocusState private var nameFocused: Bool

    init(naming: AccountNaming, onCommit: @escaping (String) -> Void) {
        self.naming = naming
        self.onCommit = onCommit
        _name = SettingsState(initialValue: naming.account.label)
    }

    private var provider: ProviderID { naming.account.provider }

    private var title: String {
        switch naming {
        case .add: "New \(provider.displayName) Account"
        case .rename: "Rename \(provider.displayName) Account"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ProviderLogoView(provider: provider, size: 20)
                Text(title).font(.headline)
            }
            TextField("Name", text: $name, prompt: Text("Work, Personal\u{2026}"))
                .focused($nameFocused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(naming.isAdd ? "Add" : "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(SettingsLogic.accountLabel(from: name) == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }

    private func commit() {
        guard let label = SettingsLogic.accountLabel(from: name) else { return }
        onCommit(label)
        dismiss()
    }
}

private extension AccountNaming {
    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}

/// A list row with its actions both on right-click and behind a \u{22EF} button, which shows while the row is hovered or
/// selected so the menu can be found without knowing to right-click.
private struct AccountMenuRow<Row: View, MenuItems: View>: View {
    var isSelected: Bool
    @ViewBuilder var row: Row
    @ViewBuilder var menu: MenuItems

    @SettingsState private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            row
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Account Actions")
            .accessibilityLabel("Account Actions")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }
}
