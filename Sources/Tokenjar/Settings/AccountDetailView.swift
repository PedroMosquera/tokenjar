import AppKit
import SwiftUI
import TokenjarCore

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
                        let check = AccountAction.check(account, status: model.status(for: account), model: model)
                        Button(check.title, action: check.run)
                            .disabled(testBlocker != nil || model.status(for: account).isRefreshing)
                            .help(testBlocker ?? check.help ?? "")
                        Button("Open Usage Page") { model.openProviderDashboard(account) }
                            .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
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
        let title = AccountTitle(provider: account.provider, label: account.label, plan: model.status(for: account).snapshot?.plan)
        return [account.provider.displayName, title.plan].compactMap { $0 }.joined(separator: " \u{00B7} ")
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
        let title = account.provider == .copilot ? "gh config folder" : "Profile folder"
        return Section {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    CommittingTextField(title: title, prompt: "\(variable.defaultPath) (CLI default)", value: account.profileDir ?? "", monospaced: true) { text in
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
            if account.provider == .copilot {
                HelpText.footer("Sets \(variable.name) when Tokenjar runs gh. Leave empty for \(variable.defaultPath), your usual gh login. A second GitHub account needs a folder of its own: enter it here, then sign in to it with the command below.")
            } else {
                HelpText.footer("Sets \(variable.name) when Tokenjar runs \(account.provider == .claude ? "claude" : "codex"). Leave empty for \(variable.defaultPath).")
            }
        }
    }

    private var signInSection: some View {
        Section {
            if let command = signInCommand {
                // One line: wrapping breaks at the hyphen in a profile path and reads like two paths. Copy Command
                // copies it whole, and the tooltip shows it whole.
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(command)
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
                    Text("Tokenjar reads limits from agy. Install it and sign in there.")
                }
            }
        } header: {
            Text("Sign in")
        } footer: {
            if account.provider == .claude {
                HelpText.footer("Runs the provider's own login in Terminal. With an older claude that has no auth command, run claude and type /\u{2060}login.")
            } else if signInCommand != nil {
                HelpText.footer("Runs the provider's own login in Terminal. Tokenjar never sees the credentials.")
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
            LabeledContent("Usage page URL") {
                CommittingTextField(title: "Usage page URL", prompt: account.provider.defaultDashboardURL.absoluteString, value: account.dashboardURL ?? "") { text in
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
        Self.signInCommand(for: account, cliPaths: model.config.cliPaths, paths: model.paths, previewMode: model.previewMode)
    }

    /// Preview renders become review images that get pasted into PRs, so they use a stand-in home folder and bare
    /// CLI names instead of this Mac's paths.
    static func signInCommand(for account: AccountConfig, cliPaths: [String: String], paths: AppPaths, previewMode: Bool) -> String? {
        let cli = CLILocator(overrides: cliPaths)
        let paths = previewMode ? AppPaths(home: URL(fileURLWithPath: "/Users/you")) : paths
        return SignInCommand.command(for: account, paths: paths) { name in
            previewMode ? name : (cli.locate(name)?.path ?? name)
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
        if case .keychain = account.credential { text += " Its pasted API key is deleted from this Mac's Keychain." }
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
