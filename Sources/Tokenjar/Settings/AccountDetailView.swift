import AppKit
import SwiftUI
import TokenjarCore

struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    /// Asks the accounts pane to confirm removing this account; the list's minus button asks the same way.
    var onRemove: () -> Void

    @SettingsState private var dashboardError = false
    @SettingsState private var signInFailed = false

    private static let credentialAnchor = "credential"

    var body: some View {
        ScrollViewReader { scroller in
            Form {
                Section {
                    statusRow(scroller)
                    HStack {
                        Spacer()
                        if statusText.offersCheck, fix != .tryOnceMore {
                            checkButton
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
                // Zen reads only opencode's local database, so it has no key to choose and no login to run.
                if account.provider == .opencodeGo {
                    AccountCredentialSection(account: account, signInCommand: signInCommand, onSignIn: openSignIn)
                        .id(Self.credentialAnchor)
                }
                // OpenCode's login belongs to its key source, inside the Credential section.
                if !account.provider.isLinkOnly, !account.provider.usesAPIKey {
                    signInSection
                }
                overridesSection
                Section {
                    HStack {
                        Spacer()
                        Button("Remove Account\u{2026}", role: .destructive, action: onRemove)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Couldn't open Terminal", isPresented: $signInFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use Copy Command and paste it into Terminal.")
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

    /// The status line, with the state's one fix beside it.
    private func statusRow(_ scroller: ScrollViewProxy) -> some View {
        let line = statusText
        let symbol = Text(Image(systemName: line.symbol)).foregroundStyle(line.tone.color)
        return LabeledContent {
            switch fix {
            case .signIn:
                if let command = signInCommand {
                    Button("Sign In in Terminal\u{2026}") { openSignIn(command) }
                }
            case .changeKey:
                Button("Change Key\u{2026}") {
                    withAnimation { scroller.scrollTo(Self.credentialAnchor, anchor: .top) }
                }
            case .tryOnceMore:
                checkButton
            case .searchedFolders, nil:
                EmptyView()
            }
        } label: {
            Text("\(symbol)  \(line.text)")
                .foregroundStyle(line.tone == .warning ? .primary : .secondary)
            if let detail = line.detail { Text(detail) }
            if fix == .searchedFolders, case .cliNotFound(let cli) = model.status(for: account).error {
                let locator = CLILocator(home: model.paths.home, overrides: model.config.cliPaths)
                Text(AccountFix.searchedText(for: cli, locator: locator, home: model.paths.home.path))
                    .help(locator.searchDirectories.map { SettingsLogic.tildePath($0.path, home: model.paths.home.path) }.joined(separator: "\n"))
            }
        }
    }

    private var checkButton: some View {
        let check = AccountAction.check(account, status: model.status(for: account), model: model)
        return Button(check.title, action: check.run)
            .disabled(testBlocker != nil || model.status(for: account).isRefreshing)
            .help(testBlocker ?? check.help ?? "")
    }

    /// Offered only while the status line shows the failure it fixes.
    private var fix: AccountFix? {
        let status = model.status(for: account)
        guard let error = status.error, account.enabled, missingPath == nil, !status.isRefreshing, !account.provider.isLinkOnly else { return nil }
        return AccountFix.primary(for: error, provider: account.provider, credential: account.credential)
    }

    private var statusText: AccountStatusText { model.statusText(for: account) }

    private var missingPath: String? { model.missingPath(of: account) }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            Toggle("Enabled", isOn: model.accountBinding(account.id, \.enabled, fallback: account.enabled))
            CommittingTextField(title: "Label", prompt: account.provider.displayName, value: account.label) { text in
                let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
                model.updateAccount(account.id) { $0.label = label.isEmpty ? account.provider.displayName : label }
            }
            // The menu bar shows windows, so an account that reports none would never appear there.
            if account.provider.reportsWindows {
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
        let title = account.provider == .copilot ? "GitHub CLI folder" : "Profile folder"
        let cli = account.provider.cliName ?? account.provider.displayName
        return Section {
            LabeledContent {
                HStack(spacing: 6) {
                    // A fixed width keeps the row on one line; a long path truncates in the middle instead.
                    CommittingTextField(title: title, prompt: variable.defaultPath, value: account.profileDir ?? "", monospaced: true) { text in
                        model.updateAccount(account.id) { $0.profileDir = SettingsLogic.profileDir(from: text) }
                    }
                    .labelsHidden()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 120)
                    Button("Choose\u{2026}", action: chooseProfileFolder)
                }
            } label: {
                Text(title)
                // The form stacks the field under the label when the label's one-line width leaves it no room; a
                // capped subtitle wraps instead, so the field and Choose stay on the title's line.
                Text("Use a separate folder for a second login")
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .help("Sets \(variable.name) when Tokenjar runs \(cli). Leave empty for \(variable.defaultPath).")
            if let twin = SettingsLogic.profileTwin(of: account, in: model.config.accounts, paths: model.paths), account.enabled {
                Label("Same profile as \(twin.displayName). Both will show the same login.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Login")
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
                    Spacer()
                    Button("Copy Command") { SignInLauncher.copy(command) }
                    Button("Sign In in Terminal\u{2026}") { openSignIn(command) }
                }
            } else if needsAgy {
                LabeledContent {
                    Link("Install agy", destination: SignInCommand.antigravityInstallURL)
                } label: {
                    Text("Antigravity CLI")
                    Text("Tokenjar reads limits from agy. Install it and sign in there.")
                }
            } else {
                TextRow {
                    Text("Antigravity CLI")
                    Text("Signed in through agy. To switch Google accounts, sign in again in agy.")
                }
            }
        } header: {
            Text("Sign in")
        }
    }

    /// An account that has worked has agy already; offering the install then reads as if something were missing.
    private var needsAgy: Bool {
        let status = model.status(for: account)
        return status.error == .cliNotFound("agy") || status.snapshot == nil
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
                // Thresholds are crossed by windows; spend-only Zen has none.
                if account.provider.reportsWindows {
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

    private func openSignIn(_ command: String) {
        do {
            try SignInLauncher.run(command: command, account: account)
        } catch {
            signInFailed = true
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

extension AppModel {
    func statusText(for account: AccountConfig) -> AccountStatusText {
        AccountStatusText.make(account: account, status: status(for: account), missingPath: missingPath(of: account), now: now)
    }

    /// The tilde path of what the account reads when it is not on this Mac. Preview data describes accounts on no real
    /// Mac, so nothing is missing there.
    func missingPath(of account: AccountConfig) -> String? {
        guard !previewMode, !AccountDiscovery.isAvailable(account, paths: paths),
              let location = AccountDiscovery.location(of: account, paths: paths)
        else { return nil }
        return SettingsLogic.tildePath(location.path, home: paths.home.path)
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

    /// Whether SignInCommand has a login to hand to Terminal. agy has none, and Devin runs nothing.
    var hasSignInCommand: Bool { self != .antigravity && self != .devin }
}

/// The one fix the status box offers next to a failed check's message.
enum AccountFix: Equatable {
    /// Sign In in Terminal, running the provider CLI's own login.
    case signIn
    /// Change Key, which scrolls to the Credential section.
    case changeKey
    /// Try Once More, the only way to probe again after a check spent tokens or quota.
    case tryOnceMore
    /// No button: a line saying where Tokenjar looked for the CLI.
    case searchedFolders

    static func primary(for error: FetchError, provider: ProviderID, credential: CredentialRef?) -> AccountFix? {
        if ProbeLatch.spentTokens(error) { return .tryOnceMore }
        let pastedKey = if case .keychain = credential { true } else { false }
        switch error {
        case .notSignedIn:
            if provider.usesAPIKey, pastedKey { return .changeKey }
            return provider.hasSignInCommand ? .signIn : nil
        case .unauthorized:
            if provider.usesAPIKey { return .changeKey }
            return provider.hasSignInCommand ? .signIn : nil
        case .cliNotFound:
            return .searchedFolders
        case .noSubscription, .rateLimited, .network, .timeout, .parse, .unsupported:
            return nil
        }
    }

    /// "Looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and 5 more", or the one path cliPaths sets.
    static func searchedText(for cli: String, locator: CLILocator, home: String) -> String {
        if let override = locator.overrides[cli] {
            return "Looked only at \(SettingsLogic.tildePath((override as NSString).expandingTildeInPath, home: home)), set in cliPaths"
        }
        let folders = locator.searchDirectories.map { SettingsLogic.tildePath($0.path, home: home) }
        let shown = folders.prefix(3).joined(separator: ", ")
        return folders.count > 3 ? "Looked in \(shown) and \(folders.count - 3) more" : "Looked in \(shown)"
    }
}
