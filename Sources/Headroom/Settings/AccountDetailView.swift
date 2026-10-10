import AppKit
import SwiftUI
import HeadroomCore

struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var onRemoved: () -> Void

    @SettingsState private var confirmRemove = false
    @SettingsState private var dashboardError = false
    @SettingsState private var signInError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section {
                    statusLine
                    HStack {
                        Spacer()
                        Button("Test") { model.refresh(force: true) }
                            .disabled(testBlocker != nil || model.isRefreshing)
                            .help(testBlocker ?? "Fetch this account's usage now")
                        Button("Open Dashboard") { model.openProviderDashboard(account) }
                    }
                }
                generalSection
                if let variable = SignInCommand.profileVariable(for: account.provider) {
                    profileSection(variable: variable)
                }
                if account.provider == .opencodeGo || account.provider == .opencodeZen {
                    AccountCredentialSection(account: account)
                }
                signInSection
                overridesSection
                Section {
                    HStack {
                        Spacer()
                        Button("Remove Account\u{2026}", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Remove \(account.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text(removeMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ProviderLogoView(provider: account.provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let plan = model.status(for: account).snapshot?.plan
        return [account.provider.displayName, plan].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var statusLine: some View {
        let status = model.status(for: account)
        let (text, symbol, color): (String, String, Color) = {
            if status.isRefreshing { return ("Checking\u{2026}", "arrow.triangle.2.circlepath", .secondary) }
            if let error = status.error { return (error.userMessage, "exclamationmark.triangle.fill", .orange) }
            if let snapshot = status.snapshot {
                let windows = snapshot.windows.count == 1 ? "1 window" : "\(snapshot.windows.count) windows"
                return ("\(snapshot.source) \u{00B7} \(windows) \u{00B7} updated \(Format.age(of: snapshot.fetchedAt, now: model.now))", "checkmark.circle.fill", .green)
            }
            if !account.enabled { return ("Off", "pause.circle", .secondary) }
            return ("Not checked yet", "circle.dashed", .secondary)
        }()
        return Label {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
    }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            Toggle("Enabled", isOn: model.accountBinding(account.id, \.enabled, fallback: account.enabled))
            CommittingTextField(title: "Label", prompt: account.provider.displayName, value: account.label) { text in
                let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
                model.updateAccount(account.id) { $0.label = label.isEmpty ? account.provider.displayName : label }
            }
            Toggle("Show in menu bar", isOn: model.accountBinding(account.id, \.showInMenuBar, fallback: account.showInMenuBar))
            LabeledContent("ID") {
                Text(account.id)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func profileSection(variable: (name: String, defaultPath: String)) -> some View {
        Section {
            LabeledContent("Profile folder") {
                HStack(spacing: 6) {
                    CommittingTextField(title: "Profile folder", prompt: "\(variable.defaultPath) (CLI default)", value: account.profileDir ?? "", monospaced: true) { text in
                        model.updateAccount(account.id) { $0.profileDir = SettingsLogic.profileDir(from: text) }
                    }
                    .labelsHidden()
                    Button("Choose\u{2026}", action: chooseProfileFolder)
                }
            }
            if let twin = SettingsLogic.profileTwin(of: account, in: model.config.accounts, paths: model.paths), account.enabled {
                Label("Same profile as \(twin.displayName). Both will show the same login.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Profile")
        } footer: {
            HelpText.footer("Sets \(variable.name) when Headroom runs \(account.provider == .claude ? "claude" : "codex"). Leave empty for \(variable.defaultPath).")
        }
    }

    private var signInSection: some View {
        Section {
            if let command = signInCommand {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    if let signInError {
                        Text(signInError).font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Copy Command") { SignInLauncher.copy(command) }
                    Button("Sign In in Terminal\u{2026}") { openSignIn(command) }
                }
            } else {
                LabeledContent {
                    Link("Install agy", destination: SignInCommand.antigravityInstallURL)
                } label: {
                    Text("Antigravity CLI")
                    Text("Headroom reads limits from agy. Install it and sign in there.")
                }
            }
        } header: {
            Text("Sign in")
        } footer: {
            if account.provider == .claude {
                HelpText.footer("Runs the provider's own login in Terminal. With an older claude that has no auth command, run claude and type /login.")
            } else if signInCommand != nil {
                HelpText.footer("Runs the provider's own login in Terminal. Headroom never sees the credentials.")
            }
        }
    }

    private var overridesSection: some View {
        Section("Overrides") {
            Picker("Refresh", selection: model.accountBinding(account.id, \.refreshMinutes, fallback: account.refreshMinutes)) {
                Text("Global (\(model.config.refreshMinutes) minutes)").tag(Int?.none)
                ForEach(SettingsLogic.refreshOptions(including: account.refreshMinutes), id: \.self) { minutes in
                    Text("Every \(minutes) minutes").tag(Int?.some(minutes))
                }
            }
            Toggle(isOn: customThresholds) {
                Text("Custom alert thresholds")
                Text("Global: \(SettingsLogic.percentList(model.config.alerts.thresholds)) used")
            }
            if let thresholds = account.alertThresholds {
                ThresholdRows(values: thresholds) { values in
                    model.updateAccount(account.id) { $0.alertThresholds = values }
                }
            }
            LabeledContent("Dashboard URL") {
                CommittingTextField(title: "Dashboard URL", prompt: account.provider.defaultDashboardURL.absoluteString, value: account.dashboardURL ?? "") { text in
                    switch SettingsLogic.dashboardURL(from: text) {
                    case .providerDefault:
                        dashboardError = false
                        model.updateAccount(account.id) { $0.dashboardURL = nil }
                    case .custom(let url):
                        dashboardError = false
                        model.updateAccount(account.id) { $0.dashboardURL = url }
                    case .invalid:
                        dashboardError = true
                    }
                }
                .labelsHidden()
            }
            if dashboardError {
                Text("Enter a web address starting with https://").font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: Actions

    private var signInCommand: String? {
        let cli = CLILocator(overrides: model.config.cliPaths)
        return SignInCommand.command(for: account, paths: model.paths) { name in
            model.previewMode ? name : (cli.locate(name)?.path ?? name)
        }
    }

    /// Refresh only fetches enabled accounts that exist on this Mac, so Test would silently do nothing for the rest.
    private var testBlocker: String? {
        if !account.enabled { return "Turn the account on to test it" }
        if !model.previewMode, !AccountDiscovery.isAvailable(account, paths: model.paths) {
            return "Its profile folder or credential is not on this Mac"
        }
        return nil
    }

    private var customThresholds: Binding<Bool> {
        Binding(
            get: { account.alertThresholds != nil },
            set: { on in model.updateAccount(account.id) { $0.alertThresholds = on ? model.config.alerts.thresholds : nil } }
        )
    }

    private var removeMessage: String {
        var text = "It is removed from config.json. Its history stays in the local database."
        if case .keychain = account.credential { text += " Its saved API key is deleted from the Keychain." }
        return text
    }

    private func remove() {
        if case .keychain(let keyAccount) = account.credential {
            try? KeychainSecretStore().delete(account: keyAccount)
        }
        model.updateConfig { $0.accounts.removeAll { $0.id == account.id } }
        onRemoved()
    }

    private func openSignIn(_ command: String) {
        do {
            try SignInLauncher.run(command: command, account: account)
            signInError = nil
        } catch {
            signInError = "Could not create the sign-in script."
        }
    }

    private func chooseProfileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose the CLI profile folder for \(account.displayName)"
        let current = SettingsLogic.profileDir(from: account.profileDir ?? "") ?? SignInCommand.profileVariable(for: account.provider)?.defaultPath ?? "~"
        panel.directoryURL = model.paths.expand(current)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateAccount(account.id) { $0.profileDir = SettingsLogic.tildePath(url.path, home: model.paths.home.path) }
    }
}
