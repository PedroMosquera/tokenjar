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
        Form {
            Section {
                statusLine
                HStack {
                    Spacer()
                    if statusText.offersCheck {
                        let check = AccountAction.check(account, status: model.status(for: account), model: model)
                        Button(check.title, action: check.run)
                            .disabled(testBlocker != nil || model.status(for: account).isRefreshing)
                            .help(testBlocker ?? check.help ?? "")
                    }
                    Button("Open Usage Page") { model.openProviderDashboard(account) }
                        .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
                }
            } header: {
                header
            }
            generalSection
            if let variable = SignInCommand.profileVariable(for: account.provider) {
                profileSection(variable: variable)
            }
            if account.provider == .opencodeGo || account.provider == .opencodeZen {
                AccountCredentialSection(account: account)
            }
            if !account.provider.isLinkOnly {
                signInSection
            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Remove \(account.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text(removeMessage)
        }
    }

    // MARK: Header

    /// The first section's header, so it scrolls with the rows instead of covering them.
    private var header: some View {
        let title = AccountTitle(provider: account.provider, label: account.label, plan: model.status(for: account).snapshot?.plan)
        let subtitle = [title.label, title.plan].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return HStack(spacing: 12) {
            ProviderLogoView(provider: account.provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.provider)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.body)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var statusLine: some View {
        let line = statusText
        let symbol = Text(Image(systemName: line.symbol)).foregroundStyle(line.tone.color)
        return TextRow {
            Text("\(symbol)  \(line.text)")
                .foregroundStyle(line.tone == .warning ? .primary : .secondary)
            if let detail = line.detail { Text(detail) }
        }
    }

    private var statusText: AccountStatusText {
        AccountStatusText.make(account: account, status: model.status(for: account), missingPath: missingPath, now: model.now)
    }

    /// Preview data describes accounts on no real Mac, so nothing is missing there.
    private var missingPath: String? {
        guard !model.previewMode, !AccountDiscovery.isAvailable(account, paths: model.paths),
              let location = AccountDiscovery.location(of: account, paths: model.paths)
        else { return nil }
        return SettingsLogic.tildePath(location.path, home: model.paths.home.path)
    }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            Toggle("Enabled", isOn: model.accountBinding(account.id, \.enabled, fallback: account.enabled))
            CommittingTextField(title: "Label", prompt: account.provider.displayName, value: account.label) { text in
                let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
                model.updateAccount(account.id) { $0.label = label.isEmpty ? account.provider.displayName : label }
            }
            // MenuBarState leaves link-only accounts out, so the toggle would do nothing.
            if !account.provider.isLinkOnly {
                Toggle("Show in menu bar", isOn: model.accountBinding(account.id, \.showInMenuBar, fallback: account.showInMenuBar))
            }
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
        let cli = account.provider == .copilot ? "gh" : account.provider == .claude ? "claude" : "codex"
        return Section {
            LabeledContent {
                HStack(spacing: 6) {
                    CommittingTextField(title: title, prompt: "\(variable.defaultPath) (CLI default)", value: account.profileDir ?? "", monospaced: true) { text in
                        model.updateAccount(account.id) { $0.profileDir = SettingsLogic.profileDir(from: text) }
                    }
                    .labelsHidden()
                    Button("Choose\u{2026}", action: chooseProfileFolder)
                }
            } label: {
                Text(title)
                Text("Sets \(variable.name) when Tokenjar runs \(cli). Leave empty for \(variable.defaultPath).")
            }
            if let twin = SettingsLogic.profileTwin(of: account, in: model.config.accounts, paths: model.paths), account.enabled {
                Label("Same profile as \(twin.displayName). Both will show the same login.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Profile")
        }
    }

    private var signInSection: some View {
        Section {
            if let command = signInCommand {
                // One line: wrapping breaks at the hyphen in a profile path and reads like two paths. Copy Command
                // copies it whole, and the tooltip shows it whole.
                TextRow {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(command)
                    Text(signInNote)
                }
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
        }
    }

    private var signInNote: String {
        account.provider == .claude
            ? "Runs the provider's own login in Terminal. With an older claude that has no auth command, run claude and type /\u{2060}login."
            : "Runs the provider's own login in Terminal. Tokenjar never sees the credentials."
    }

    private var overridesSection: some View {
        Section("Overrides") {
            // A link-only account has no window to refresh or alert on; its usage page is the one thing to set.
            if !account.provider.isLinkOnly {
                Picker("Refresh every", selection: model.accountBinding(account.id, \.refreshMinutes, fallback: account.refreshMinutes)) {
                    Text(RefreshInterval.inheritedLabel(globalMinutes: model.config.refreshMinutes)).tag(Int?.none)
                    ForEach(SettingsLogic.refreshOptions(including: account.refreshMinutes), id: \.self) { minutes in
                        Text(RefreshInterval.label(minutes)).tag(Int?.some(minutes))
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
            }
            LabeledContent {
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
            } label: {
                Text("Usage page URL")
                if account.provider == .devin {
                    Text("On a grandfathered Windsurf plan, use https://windsurf.com/subscription/manage-plan.")
                }
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
            try? model.secrets.delete(account: keyAccount)
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

/// What Settings says about one account: the status line at the top of its page and the caption on its list row.
struct AccountStatusText: Equatable {
    enum Tone: Equatable {
        case good, neutral, warning

        var color: Color {
            switch self {
            case .good: .green
            case .neutral: .secondary
            case .warning: .orange
            }
        }
    }

    struct Caption: Equatable {
        var text: String
        var isActionable: Bool
    }

    var symbol: String
    var tone: Tone
    var text: String
    var detail: String?
    var caption: Caption?
    var offersCheck = true

    /// `missingPath` is the tilde path of the profile folder or credential file the account reads, when it does not
    /// exist on this Mac. Being off or missing outranks any old snapshot, which no longer describes this Mac.
    static func make(account: AccountConfig, status: AccountStatus, missingPath: String?, now: Date) -> AccountStatusText {
        let provider = account.provider
        if !account.enabled {
            return AccountStatusText(symbol: "pause.circle", tone: .neutral, text: "Off", caption: Caption(text: "Off", isActionable: false))
        }
        if let missingPath {
            return AccountStatusText(
                symbol: "questionmark.folder", tone: .neutral, text: "Not on this Mac: \(missingPath) does not exist",
                caption: Caption(text: "Not on this Mac", isActionable: false)
            )
        }
        if provider.isLinkOnly {
            return AccountStatusText(
                symbol: "link", tone: .neutral, text: "Opens \(account.resolvedDashboardURL.host() ?? provider.displayName)",
                detail: "\(provider.displayName) doesn't share your quota with local apps yet, so this account opens its plan page. Tokenjar runs nothing for it and reads nothing.",
                offersCheck: false
            )
        }
        let caption = status.error.flatMap { caption(for: $0, account: account) }
        let zenNote = provider.reportsWindows ? nil : "Reads this Mac's spend from opencode's local database. No key needed."
        if status.isRefreshing {
            return AccountStatusText(symbol: "arrow.triangle.2.circlepath", tone: .neutral, text: "Checking\u{2026}", detail: zenNote, caption: caption)
        }
        if let error = status.error {
            if ProbeLatch.spentTokens(error) {
                return AccountStatusText(symbol: "exclamationmark.triangle.fill", tone: .warning, text: error.userMessage, caption: caption)
            }
            switch error.attention {
            case .calm:
                return AccountStatusText(symbol: "minus.circle", tone: .neutral, text: "Not subscribed to \(provider.displayName)", caption: caption)
            case .transient:
                let text = status.snapshot.map { "\(error.userMessage) \u{00B7} showing data from \(Format.age(of: $0.fetchedAt, now: now))" } ?? error.userMessage
                return AccountStatusText(symbol: "exclamationmark.arrow.triangle.2.circlepath", tone: .neutral, text: text, detail: zenNote)
            case .actionable:
                return AccountStatusText(symbol: "exclamationmark.triangle.fill", tone: .warning, text: actionableText(error, account: account), caption: caption)
            }
        }
        if let snapshot = status.snapshot {
            let age = Format.age(of: snapshot.fetchedAt, now: now)
            if !provider.reportsWindows {
                return AccountStatusText(symbol: "checkmark.circle.fill", tone: .good, text: "Local spend only \u{00B7} updated \(age)", detail: zenNote)
            }
            let limits = snapshot.windows.isEmpty ? snapshot.notes.first : snapshot.windows.map(\.label).joined(separator: ", ")
            return AccountStatusText(
                symbol: "checkmark.circle.fill", tone: .good, text: (["Updated \(age)"] + [limits].compactMap { $0 }).joined(separator: " \u{00B7} ")
            )
        }
        return AccountStatusText(symbol: "circle.dashed", tone: .neutral, text: "Not checked yet", detail: zenNote)
    }

    /// The list row's caption: what to fix for an actionable failure, nothing for a passing one.
    private static func caption(for error: FetchError, account: AccountConfig) -> Caption? {
        if ProbeLatch.spentTokens(error) { return Caption(text: "Paused", isActionable: true) }
        switch error.attention {
        case .calm: return Caption(text: "Not subscribed", isActionable: false)
        case .transient: return nil
        case .actionable: break
        }
        let text = switch error {
        case .notSignedIn: "Signed out"
        case .unauthorized: account.provider.usesAPIKey ? "Key rejected" : "Login rejected"
        case .cliNotFound: "Not installed"
        case .noSubscription, .rateLimited, .network, .timeout, .parse, .unsupported: "Check failed"
        }
        return Caption(text: text, isActionable: true)
    }

    private static func actionableText(_ error: FetchError, account: AccountConfig) -> String {
        guard case .notSignedIn = error else { return error.userMessage }
        if case .keychain = account.credential { return "No pasted key on this Mac." }
        guard let cli = account.provider.cliName else { return error.userMessage }
        return "Signed out of \(cli)."
    }
}

extension ProviderID {
    /// The command Tokenjar runs or hands to Terminal for this provider, as users type it.
    var cliName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .copilot: "gh"
        case .opencodeGo, .opencodeZen: "opencode"
        case .antigravity: "agy"
        case .devin: nil
        }
    }

    var usesAPIKey: Bool { self == .opencodeGo || self == .opencodeZen }
}
