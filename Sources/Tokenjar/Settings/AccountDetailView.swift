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
                        if statusText.offersCheck, fix != .tryOnceMore, fix != .tryAgain {
                            checkButton
                        }
                        Button("Open Usage Page") { model.openProviderDashboard(account) }
                            .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
                    }
                } header: {
                    header
                }
                // While config.json cannot be saved, edits would be dropped; checks, links and sign-in still work.
                generalSection
                    .disabled(!model.canEditConfig)
                if let variable = SignInCommand.profileVariable(for: account.provider) {
                    profileSection(variable: variable)
                        .disabled(!model.canEditConfig)
                }
                // Zen reads only opencode's local database, so it has no key to choose and no login to run.
                if account.provider == .opencodeGo {
                    AccountCredentialSection(account: account, signInCommand: signInCommand, onSignIn: openSignIn)
                        .id(Self.credentialAnchor)
                        .disabled(!model.canEditConfig)
                }
                // OpenCode's login belongs to its key source, inside the Credential section.
                if !account.provider.isLinkOnly, !account.provider.usesAPIKey {
                    signInSection
                }
                overridesSection
                    .disabled(!model.canEditConfig)
                Section {
                    HStack {
                        Spacer()
                        Button("Remove Account\u{2026}", role: .destructive, action: onRemove)
                    }
                }
                .disabled(!model.canEditConfig)
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

    private func statusRow(_ scroller: ScrollViewProxy) -> some View {
        let line = statusText
        let symbol = Text(Image(systemName: line.symbol)).foregroundStyle(line.tone.color)
        return LabeledContent {
            switch fix {
            case .signIn:
                if let line = signInCommand {
                    Button("Sign In in Terminal\u{2026}") { openSignIn(line.command) }
                }
            case .changeKey:
                Button("Change Key\u{2026}") {
                    withAnimation { scroller.scrollTo(Self.credentialAnchor, anchor: .top) }
                }
            case .tryOnceMore, .tryAgain:
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
                // Short on purpose: the form puts a field under its label once the label's one-line width leaves no room.
                Text("For a second login")
            }
            .help("Sets \(variable.name) when Tokenjar runs \(cli). Leave empty for \(variable.defaultPath).")
            if let twin = SettingsLogic.profileTwin(of: account, in: model.config.accounts, paths: model.paths), account.enabled {
                LabeledContent {
                    Button("Choose\u{2026}", action: chooseProfileFolder)
                } label: {
                    SettingsNotice(kind: .warning, text: "Same profile as \(twin.displayName). Both will show the same login.", isSecondary: true)
                }
            }
        } header: {
            Text("Login")
        }
    }

    private var signInSection: some View {
        Section {
            if let line = signInCommand {
                // One line: wrapping breaks at the hyphen in a profile path and reads like two paths. Copy Command
                // copies it whole, and the tooltip shows it whole.
                TextRow {
                    Text(line.shown)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line.shown)
                    Text(signInNote)
                }
                HStack {
                    Spacer()
                    Button("Copy Command") { SignInLauncher.copy(line.command) }
                    Button("Sign In in Terminal\u{2026}") { openSignIn(line.command) }
                }
            } else {
                switch AgySignInRow.make(status: model.status(for: account)) {
                case .install:
                    LabeledContent {
                        Link("Install agy", destination: SignInCommand.antigravityInstallURL)
                    } label: {
                        Text("Antigravity CLI")
                        Text("Tokenjar reads limits from agy. Install it and sign in there.")
                    }
                case .signedOut:
                    TextRow {
                        Text("Antigravity CLI")
                        Text("Signed out. Run agy in Terminal and sign in again.")
                    }
                case .signedIn:
                    TextRow {
                        Text("Antigravity CLI")
                        Text("Signed in through agy. To switch Google accounts, sign in again in agy.")
                    }
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
            }
            if dashboardError {
                SettingsNotice(kind: .error, text: "Enter a web address starting with https://")
            }
            // A button, not the address in a note: a long URL wraps at its slashes and pushes the field under its label.
            if account.provider == .devin {
                LabeledContent {
                    Button("Use Windsurf Page") {
                        dashboardError = false
                        model.updateAccount(account.id) { $0.dashboardURL = Self.windsurfUsageURL }
                    }
                    .disabled(account.dashboardURL == Self.windsurfUsageURL)
                    .help(Self.windsurfUsageURL)
                } label: {
                    Text("Windsurf plan")
                    Text("A grandfathered Windsurf plan shows its usage on windsurf.com.")
                }
            }
        }
    }

    static let windsurfUsageURL = "https://windsurf.com/subscription/manage-plan"

    // MARK: Actions

    private var signInCommand: SignInLine? {
        Self.signInLine(for: account, cliPaths: model.config.cliPaths, paths: model.paths, previewMode: model.previewMode)
    }

    /// Preview renders become review images that get pasted into PRs, so they use a stand-in home folder and bare
    /// CLI names instead of this Mac's paths.
    static func signInLine(for account: AccountConfig, cliPaths: [String: String], paths: AppPaths, previewMode: Bool) -> SignInLine? {
        let cli = CLILocator(overrides: cliPaths)
        let paths = previewMode ? AppPaths(home: URL(fileURLWithPath: "/Users/you")) : paths
        let executable = { (name: String) in previewMode ? name : (cli.locate(name)?.path ?? name) }
        guard let command = SignInCommand.command(for: account, paths: paths, executable: executable),
              let shown = SignInCommand.command(for: account, paths: paths, executable: executable, abbreviatingHome: true)
        else { return nil }
        return SignInLine(command: command, shown: shown)
    }

    private var testBlocker: String? { Self.testBlocker(enabled: account.enabled, missingPath: missingPath) }

    /// Refresh only fetches enabled accounts that exist on this Mac, so Test would silently do nothing for the rest.
    static func testBlocker(enabled: Bool, missingPath: String?) -> String? {
        if !enabled { return "Turn the account on to test it" }
        if let missingPath { return "\(missingPath) is not on this Mac" }
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
        AccountStatusText.make(account: account, status: status(for: account), missingPath: missingPath(of: account), now: now, connectivity: connectivity)
    }

    /// The tilde path of what the account reads when it is not on this Mac. Preview data describes accounts on no real
    /// Mac, so nothing is missing there.
    func missingPath(of account: AccountConfig) -> String? {
        guard !previewMode, !AccountDiscovery.isAvailable(account, paths: paths),
              let location = AccountDiscovery.location(of: account, paths: paths, environment: ProcessInfo.processInfo.environment)
        else { return nil }
        return SettingsLogic.tildePath(location.path, home: paths.home.path)
    }
}

/// An account's login command: `command` is what Copy Command and Sign In in Terminal use, `shown` is the row's text.
struct SignInLine: Equatable {
    var command: String
    var shown: String
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

    /// `missingPath` is the tilde path of what the account reads (`AccountDiscovery.location`), when it does not exist on
    /// this Mac. Being off or missing outranks any old snapshot, which no longer describes this Mac.
    static func make(account: AccountConfig, status: AccountStatus, missingPath: String?, now: Date, connectivity: Connectivity = .online) -> AccountStatusText {
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
                detail: "\(provider.displayName) doesn't share your quota with local apps yet, so this account opens its usage page. Tokenjar runs nothing for it and reads nothing.",
                offersCheck: false
            )
        }
        let caption = status.error.flatMap { caption(for: $0, account: account) }
        let zenNote = provider.reportsWindows ? nil : "Reads this Mac's spend from opencode's local database. No key needed."
        if status.isRefreshing {
            return AccountStatusText(symbol: "arrow.triangle.2.circlepath", tone: .neutral, text: "Checking\u{2026}", detail: zenNote, caption: caption)
        }
        if provider.checkUsesNetwork, let line = macWideLine(connectivity, status: status, now: now) { return line }
        if let error = status.error {
            if ProbeLatch.spentTokens(error) {
                return AccountStatusText(symbol: "exclamationmark.triangle.fill", tone: .warning, text: error.userMessage, caption: caption)
            }
            switch error.attention {
            case .calm:
                return AccountStatusText(symbol: "minus.circle", tone: .neutral, text: "Not subscribed to \(provider.displayName)", caption: caption)
            case .transient:
                // Its own line: messages are full sentences, and the age would read as part of the last one.
                let shown = status.snapshot.map { "Showing data from \(Format.age(of: $0.fetchedAt, now: now))." }
                return AccountStatusText(
                    symbol: "exclamationmark.arrow.triangle.2.circlepath", tone: .neutral, text: error.userMessage(provider: provider), detail: shown ?? zenNote
                )
            case .actionable:
                return AccountStatusText(symbol: "exclamationmark.triangle.fill", tone: .warning, text: actionableText(error, account: account), caption: caption)
            }
        }
        if let snapshot = status.snapshot {
            let age = Format.age(of: snapshot.fetchedAt, now: now)
            if !provider.reportsWindows {
                return AccountStatusText(symbol: "checkmark.circle.fill", tone: .good, text: "Local spend only \u{00B7} updated \(age)", detail: zenNote)
            }
            // Its own line: some window labels contain a middle dot themselves, so a dot after the age would misread.
            let limits = snapshot.windows.isEmpty ? snapshot.notes.first : "Limits: " + snapshot.windows.map { unbreakable($0.label) }.joined(separator: ", ")
            return AccountStatusText(symbol: "checkmark.circle.fill", tone: .good, text: "Updated \(age)", detail: limits)
        }
        return AccountStatusText(symbol: "circle.dashed", tone: .neutral, text: "Not checked yet", detail: zenNote)
    }

    /// Under a Mac-wide cause, for a connection failure (a saved copy shown because of one included) or an account with
    /// nothing yet: the cause, not the account, is the news. nil otherwise, so a failure the user can fix still reads as
    /// the account's own.
    private static func macWideLine(_ connectivity: Connectivity, status: AccountStatus, now: Date) -> AccountStatusText? {
        guard status.connectionFailure != nil || (status.error == nil && status.snapshot == nil) else { return nil }
        let shown = status.snapshot.map { "Showing data from \(Format.age(of: $0.fetchedAt, now: now))." }
        switch connectivity {
        case .online:
            return nil
        case .offline:
            return AccountStatusText(
                symbol: "wifi.slash", tone: .neutral, text: "This Mac is offline. Tokenjar checks this account again when it is back online.", detail: shown
            )
        case .noAnswer:
            return AccountStatusText(
                symbol: "wifi.exclamationmark", tone: .neutral, text: "Can't reach any provider. Tokenjar tries again at the next refresh.", detail: shown
            )
        }
    }

    /// A label wrapped inside itself ("Gemini" then "· Week") reads as two windows, so the list may only wrap between
    /// labels: no-break spaces, and a word joiner after each hyphen of a raw window name such as "two-day".
    private static func unbreakable(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "-\u{2060}")
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
        case .keychainDenied: "Keychain denied"
        case .noSubscription, .rateLimited, .network, .timeout, .parse, .unsupported, .cliTooOld: "Check failed"
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

/// What the Sign in section says for an Antigravity account. agy has no login command to hand to Terminal, so this row
/// is the only place the page says how to sign in again.
enum AgySignInRow: Equatable {
    case install, signedOut, signedIn

    /// A failed check keeps the last snapshot, so the current error decides first. Without one, an account that has
    /// worked has agy already, and offering the install would read as if something were missing.
    static func make(status: AccountStatus) -> AgySignInRow {
        switch status.error {
        case .cliNotFound: .install
        case .notSignedIn: .signedOut
        default: status.snapshot == nil ? .install : .signedIn
        }
    }
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
    /// Try Again, which asks macOS for a pasted key once more after a Deny.
    case tryAgain

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
        case .keychainDenied:
            return .tryAgain
        case .noSubscription, .rateLimited, .network, .timeout, .parse, .unsupported, .cliTooOld:
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
