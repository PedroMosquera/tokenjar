import AppKit
import SwiftUI
import TokenjarCore

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model
    @SettingsState private var loginState: LaunchAtLogin.State?
    @SettingsState private var loginError: String?
    @SettingsState private var pendingImport: PendingCodexBarImport?
    @SettingsState private var importNotFound = false

    var body: some View {
        SettingsPage {
            Section {
                launchAtLoginRow
                Picker(selection: model.configBinding(\.refreshMinutes)) {
                    ForEach(SettingsLogic.refreshOptions(including: model.config.refreshMinutes), id: \.self) { minutes in
                        Text(RefreshInterval.label(minutes)).tag(minutes)
                    }
                } label: {
                    Text("Refresh every")
                    Text("Each account can override this.")
                }
                .disabled(!model.canEditConfig)
            }

            Section("Menu bar") {
                Picker(selection: model.configBinding(\.menuBar.mode)) {
                    ForEach(MenuBarMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Show")
                    Text(model.config.menuBar.mode.summary(for: model.config.menuBar.icon))
                }
                Picker(selection: model.configBinding(\.menuBar.icon)) {
                    ForEach(MenuBarIcon.Group.allCases, id: \.self) { group in
                        Section(group.title) {
                            ForEach(group.icons, id: \.self) { icon in
                                MenuBarIconLabel(icon: icon).tag(icon)
                            }
                        }
                    }
                } label: {
                    if model.config.menuBar.mode.usesIcon {
                        Text("Icon")
                    } else {
                        // A disabled pop-up greys itself but not the form's label.
                        Text("Icon").foregroundStyle(.secondary)
                        Text("Not used with \(MenuBarMode.bars.title)")
                    }
                }
                .disabled(!model.config.menuBar.mode.usesIcon)
                LabeledContent {
                    MenuBarPreview(config: model.config.menuBar)
                } label: {
                    Text("Preview")
                    Text(MenuBarPreview.caption(model.config.menuBar))
                }
            }
            .disabled(!model.canEditConfig)

            Section("Usage colors") {
                PercentField(
                    title: "Amber at", value: usageLevel(.warn), range: UsageLevels.warnRange,
                    note: "Bars turn amber and red at these levels in the menu bar, popover and dashboard. Alerts have their own thresholds."
                )
                PercentField(title: "Red at", value: usageLevel(.critical), range: UsageLevels.criticalRange)
            }
            .disabled(!model.canEditConfig)

            providerStatusSection

            configFileSection
        }
        .onAppear {
            if !model.previewMode { loginState = model.launchAtLoginState() }
        }
        .sheet(item: $pendingImport) { pending in
            CodexBarImportSheet(changes: pending.changes) {
                model.updateConfig { config in
                    config = CodexBarImport.apply(pending.preview, to: config, discovered: pending.discovered, paths: model.paths)
                }
            }
        }
        .alert("CodexBar settings not found", isPresented: $importNotFound) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tokenjar looked for CodexBar's config on this Mac and found nothing to import.")
        }
    }

    /// Not a config.json setting, and so not held back by a config that failed to load: the switch belongs to this Mac.
    private var providerStatusSection: some View {
        Section("Provider status") {
            Toggle(isOn: Binding(get: { model.providerStatusOn }, set: { model.setProviderStatus($0) })) {
                Text("Check provider status pages")
                Text(Self.providerStatusCaption)
            }
            if model.providerStatusOn {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        ProviderStatusLines.make(accounts: model.accounts, health: model.providerHealth, inFlight: model.healthInFlight, now: model.now),
                        id: \.self
                    ) { line in
                        Text(line)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let providerStatusCaption = "When you open the Tokenjar popover or refresh, Tokenjar asks the public status pages of Claude, Codex and GitHub Copilot whether the products you use have a problem. It sends no account data. This setting applies to this Mac only."

    private var configFileSection: some View {
        let target = model.paths.configFile.resolvingSymlinksInPath()
        let caption = Self.configFileCaption(paths: model.paths)
        return Section("Configuration") {
            LabeledContent {
                HStack {
                    Button("Reveal in Finder") {
                        let exists = FileManager.default.fileExists(atPath: target.path)
                        NSWorkspace.shared.activateFileViewerSelecting([exists ? target : target.deletingLastPathComponent()])
                    }
                    Button("Reload") { model.loadConfig() }
                }
            } label: {
                Text("Config file")
                // One line: a wrapped path breaks at a slash and reads like two paths. The tooltip has it whole.
                (Text(caption.isLink ? "Links to " : "") + Text(caption.path).font(.system(.subheadline, design: .monospaced)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(target.path)\nHolds no keys, so it is safe in a dotfiles repo. Saves go through the link.")
            }
            if model.hasLocalOverrides {
                Label("config.local.json overrides are active on this Mac. Edits here are saved to config.json; local values still win.", systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Button("Import from CodexBar\u{2026}", action: prepareImport)
                    .disabled(!model.canEditConfig)
            } label: {
                Text("CodexBar")
                Text("Reads CodexBar's settings only when you click, and lists the changes before applying them. Never its keys or cookies.")
            }
        }
    }

    private func usageLevel(_ field: UsageLevels.Field) -> Binding<Int> {
        Binding(
            get: { field == .warn ? model.config.menuBar.warnAt : model.config.menuBar.criticalAt },
            set: { value in
                model.updateConfig { config in
                    let levels = field == .warn
                        ? UsageLevels.pushAlong(warn: value, critical: config.menuBar.criticalAt, keeping: .warn)
                        : UsageLevels.pushAlong(warn: config.menuBar.warnAt, critical: value, keeping: .critical)
                    config.menuBar.warnAt = levels.warn
                    config.menuBar.criticalAt = levels.critical
                }
            }
        )
    }

    @ViewBuilder private var launchAtLoginRow: some View {
        let isOn = Binding(get: { launchesAtLogin }, set: { setLaunchAtLogin($0) })
        if loginState == .requiresApproval {
            LabeledContent {
                HStack(spacing: 10) {
                    Button("Open Login Items Settings") { LaunchAtLogin.openLoginItemsSettings() }
                    Toggle("Launch at login", isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            } label: {
                launchAtLoginLabel
            }
        } else {
            Toggle(isOn: isOn) { launchAtLoginLabel }
                .disabled(!(loginState?.canChange ?? true))
        }
    }

    @ViewBuilder private var launchAtLoginLabel: some View {
        Text("Launch at login")
        if let hint = loginHint { Text(hint) }
    }

    // config.json syncs between Macs, so the registration on this one wins when macOS can report it.
    private var launchesAtLogin: Bool {
        switch loginState {
        case .enabled, .requiresApproval: true
        case .disabled: false
        case .unavailable, nil: model.config.launchAtLogin
        }
    }

    private var loginHint: String? {
        if let loginError { return loginError }
        switch loginState {
        case .requiresApproval: return "macOS is waiting for approval. Turn Tokenjar on in System Settings > General > Login Items."
        case .unavailable: return "Available only in the installed app."
        case .enabled, .disabled, nil: return nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let state = try LaunchAtLogin.set(enabled)
            loginState = state
            loginError = nil
            if state != .unavailable { model.updateConfig { $0.launchAtLogin = enabled } }
        } catch {
            loginState = LaunchAtLogin.state
            loginError = "macOS did not accept the change. Try again from the installed app."
        }
    }

    private func prepareImport() {
        guard let preview = CodexBarImport.preview(paths: model.paths) else {
            importNotFound = true
            return
        }
        let discovered = AccountDiscovery.discover(paths: model.paths, cli: CLILocator(overrides: model.config.cliPaths))
        let proposed = CodexBarImport.apply(preview, to: model.config, discovered: discovered, paths: model.paths)
        pendingImport = PendingCodexBarImport(
            preview: preview, discovered: discovered,
            changes: SettingsLogic.describeChanges(from: model.config, to: proposed)
        )
    }

    /// A stow link shows its target, so the row says where saves land.
    static func configFileCaption(paths: AppPaths) -> (isLink: Bool, path: String) {
        let file = paths.configFile
        let target = file.resolvingSymlinksInPath()
        let isLink = target.path != file.path
        return (isLink, SettingsLogic.tildePath((isLink ? target : file).path, home: paths.home.path))
    }
}

extension MenuBarMode {
    var usesIcon: Bool { self != .bars }

    var title: String {
        switch self {
        case .worst: "Tightest account"
        case .bars: "Bars"
        case .icon: "Icon only"
        }
    }

    /// One sentence, shown under the Show picker for the selected mode.
    func summary(for icon: MenuBarIcon) -> String {
        switch (self, icon) {
        case (.worst, .app): return "The cooldown slot fills to the tightest account's used share, next to its %."
        case (.worst, _): return "\(icon.phrase), next to the tightest account's used %."
        case (.bars, _): return "One bar per menu bar account, in place of the icon."
        case (.icon, .app): return "The cooldown slot alone, filled and tinted for the tightest account."
        case (.icon, _): return "\(icon.phrase) alone, tinted amber or red when an account runs low."
        }
    }
}

/// The lines under Check provider status pages, one per provider with an account here: what its last check got. A
/// failed check changes nothing on the cards, so this is where it shows.
enum ProviderStatusLines {
    static func make(accounts: [AccountConfig], health: [ProviderID: ProviderHealth], inFlight: Set<ProviderID>, now: Date) -> [String] {
        var providers: [ProviderID] = []
        for provider in accounts.map(\.provider) where provider.statusFeedURL != nil && !providers.contains(provider) {
            providers.append(provider)
        }
        guard !providers.isEmpty else { return ["No Claude, Codex or GitHub Copilot account on this Mac, so no status page is asked."] }
        return providers.map { provider in
            "\(provider.displayName): \(outcome(provider, health[provider], checking: inFlight.contains(provider), now: now))."
        }
    }

    private static func outcome(_ provider: ProviderID, _ health: ProviderHealth?, checking: Bool, now: Date) -> String {
        if checking { return "checking now" }
        guard let health, let asked = health.lastAsked, health.answer != nil || health.lastFailure != nil else { return "not asked yet" }
        let when = Format.age(of: asked, now: now)
        guard let failure = health.lastFailure else { return "answered \(when)" }
        let what = switch failure {
        case .parse: "couldn't read the answer"
        case .timeout: "no answer within \(Int(ProviderHealthFetcher.timeout)) s"
        case .network(let detail) where detail.hasPrefix("HTTP "): "the page answered \(detail)"
        case .network: "couldn't reach \(provider.statusFeedURL?.host() ?? provider.displayName)"
        default: "couldn't check"
        }
        return "\(what), \(when)"
    }
}

/// How a refresh interval reads in the General picker and in an account's override.
enum RefreshInterval {
    static func label(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func inheritedLabel(globalMinutes: Int) -> String {
        "Same as General (\(label(globalMinutes)))"
    }
}
