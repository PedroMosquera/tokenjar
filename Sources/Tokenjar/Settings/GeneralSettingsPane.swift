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
                Picker("Refresh every", selection: model.configBinding(\.refreshMinutes)) {
                    ForEach(SettingsLogic.refreshOptions(including: model.config.refreshMinutes), id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
            } footer: {
                HelpText.footer("Each account can override the refresh interval.")
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
                    Text("Healthy, amber and full")
                }
                PercentField(title: "Amber at", value: model.configBinding(\.menuBar.warnAt), range: 1...max(1, model.config.menuBar.criticalAt - 1))
                PercentField(title: "Red at", value: model.configBinding(\.menuBar.criticalAt), range: min(100, model.config.menuBar.warnAt + 1)...100)
            }

            configFileSection

            Section {
                LabeledContent {
                    Button("Import from CodexBar\u{2026}", action: prepareImport)
                } label: {
                    Text("CodexBar")
                    Text("Read only when you click. Lists the changes before applying them: enabled providers, alert thresholds, refresh interval and whether alerts are on. Never reads its keys or cookies.")
                }
            }
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

    private var configFileSection: some View {
        let file = model.paths.configFile
        let target = file.resolvingSymlinksInPath()
        return Section {
            LabeledContent("Config file") {
                Text(abbreviated(file))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if target.path != file.path {
                LabeledContent("Links to") {
                    Text(abbreviated(target))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if model.hasLocalOverrides {
                Label("config.local.json overrides are active on this Mac. Edits here are saved to config.json; local values still win.", systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = model.configError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Reveal in Finder") {
                    let exists = FileManager.default.fileExists(atPath: target.path)
                    NSWorkspace.shared.activateFileViewerSelecting([exists ? target : target.deletingLastPathComponent()])
                }
                Button("Reload") { model.loadConfig() }
            }
        } header: {
            Text("Configuration")
        } footer: {
            HelpText.footer("Safe to keep in a dotfiles repo: it holds no keys. Saves go through the symlink, so a stow link survives.")
        }
    }

    @ViewBuilder private var launchAtLoginRow: some View {
        let isOn = Binding(get: { launchesAtLogin }, set: setLaunchAtLogin)
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

    private func abbreviated(_ url: URL) -> String {
        SettingsLogic.tildePath(url.path, home: model.paths.home.path)
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
