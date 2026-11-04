import AppKit
import SwiftUI
import TokenjarCore

/// States exactly what the app touches. Keep it in step with the fetchers, scanners and HTTPClient.allowedEndpoints.
/// docs/privacy.md names every Runs, Reads and Contacts item by its `what`, and AboutSummaryTests fails when they differ.
struct AboutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @SettingsState private var failedUpdateCommand: String?

    struct Item: Identifiable {
        var id: String { what }
        var what: String
        var why: String
    }

    static let runs = [
        Item(what: "claude -p /usage --output-format stream-json", why: "Claude limits. Hooks and MCP off, no session saved, run from an empty private folder. Uses no tokens."),
        Item(what: "codex -s read-only -a never app-server", why: "Codex limits. Read-only sandbox, never asks for approval. Sends only initialize and account/rateLimits/read."),
        Item(what: "agy --version", why: "Checks agy is 1.1.11 or later before asking for usage, since older versions could send /\u{2060}usage to the model."),
        Item(what: "agy -p /usage --output-format json", why: "Antigravity limits."),
        Item(what: "gh api --method GET copilot_internal/user --jq <filter>", why: "GitHub Copilot limits, through your own gh login: gh sends this GET to api.github.com with its own token. The filter keeps only the plan, the reset date and the quota numbers. gh's telemetry and update check are off for it."),
    ]

    static let reads = [
        Item(what: "~/.claude/projects/**/*.jsonl", why: "Token counts, model ids, timestamps and project folder names. Also ~/.config/claude/projects, or the account's CLAUDE_CONFIG_DIR instead of both."),
        Item(what: "~/.claude.json", why: "Plan name, and Claude Code's cached limits when the CLI cannot report. Its account id is only compared with the one on the cached limits, so another login's limits are never shown. The one inside CLAUDE_CONFIG_DIR when the account sets one, or an older .config.json when present."),
        Item(what: "~/.claude/settings.json", why: "Only whether a cloud provider, a gateway or an API key is set up, to tell such a login from being signed out. Never a key's value. Or the account's CLAUDE_CONFIG_DIR."),
        Item(what: "/Library/Application Support/ClaudeCode/managed-settings.json", why: "The same, from the settings an administrator deploys to the whole Mac."),
        Item(what: "~/.codex/sessions/**/rollout-*.jsonl", why: "Token counts, model ids, timestamps and project folder names, from archived_sessions too. When the CLI cannot report, the last limits Codex logged. Or the account's CODEX_HOME."),
        Item(what: "~/.codex/auth.json", why: "Only whether it exists, at first run and when you click Import from CodexBar. Never opened."),
        Item(what: "Devin.app, Windsurf.app and their Application Support folders", why: "Only whether one exists, in /Applications or ~/Applications, at first run and when you click Import from CodexBar, to offer a Devin account. Never opened."),
        Item(what: "Cursor.app and its Application Support folder", why: "Only whether one exists, at first run and when you click Import from CodexBar, to offer a Cursor account. Never opened: the folder holds Cursor's login."),
        Item(what: "~/.local/share/opencode/auth.json", why: "The opencode-go or opencode API key, or the entry the account names, for the OpenCode Go request below. At first run and on Import from CodexBar, only which entries exist. Or $XDG_DATA_HOME/opencode, or the account's profile folder."),
        Item(what: "~/.local/share/opencode/opencode.db", why: "Read-only: cost and token counts per model. Same folder as auth.json."),
        Item(what: "~/.config/tokenjar/", why: "config.json, config.local.json and pricing.json."),
        Item(what: "CodexBar's settings", why: "Only when you click Import from CodexBar, which lists the changes before applying them: enabled providers, warning thresholds, refresh interval and notification setting. Never its keys or cookies."),
    ]

    static let contacts = [
        Item(what: "GET https://opencode.ai/zen/go/v1/usage", why: "OpenCode Go limits. The only request that carries a key. Usage and status pages open in your browser."),
        Item(what: "GET https://status.claude.com/api/v2/summary.json", why: "Claude's public status. Only with provider status on, when you open the popover or refresh."),
        Item(what: "GET https://status.openai.com/proxy/status.openai.com", why: "Codex's public status. Only with provider status on, when you open the popover or refresh."),
        Item(what: "GET https://www.githubstatus.com/api/v2/summary.json", why: "GitHub Copilot's public status. Only with provider status on, when you open the popover or refresh."),
        Item(what: "GET https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml", why: "Exchange rates for estimates. Only when the currency is not USD, when you open the popover or dashboard, refresh or pick a currency, and a newer rate should exist."),
        Item(what: "GET https://api.github.com/repos/PedroMosquera/tokenjar/releases/latest", why: "The latest Tokenjar release. Only when you click Check Now, or once a day with Check for updates set to Automatic."),
    ]

    private let writes = [
        Item(what: "~/.config/tokenjar/config.json", why: "Settings, through the symlink if it is one."),
        Item(what: "~/Library/Application Support/Tokenjar/", why: "tokenjar.sqlite: usage history. alert-state.json: which alerts already fired. probe-latch.json: accounts whose usage check spent tokens or quota, so it is not run again until that CLI (claude or agy) updates or you click Try Once More. probe: an empty folder the CLIs run in."),
        Item(what: "$TMPDIR/tokenjar-update.command", why: "Only when you click Update in Terminal: the update command for Terminal to run. It deletes itself when it runs."),
        Item(what: "$TMPDIR/tokenjar-sign-in-<account>.command", why: "Only when you click Sign In in Terminal: the login command for Terminal to run. It deletes itself when it runs."),
        Item(what: "Keychain: \(AppPaths.keychainService)", why: "Only API keys you paste here."),
        Item(what: "Preferences: \(AppPaths.bundleIdentifier)", why: "Window frames and, for this Mac only: whether provider status is on, the pinned account, the currency and its exchange rates, which API value sections are open, and the update check setting, its last check, the latest version seen and the newer versions already announced."),
    ]

    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: 14) {
                    appIcon
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tokenjar").font(.title3.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Shows how much room is left on each AI subscription. Built from source. No telemetry, and it checks for updates only when you ask.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }

            if let updates = model.updates {
                updatesSection(updates)
            }

            itemSection("Runs", Self.runs)
            itemSection("Reads", Self.reads)
            itemSection("Contacts", Self.contacts)
            itemSection("Writes", writes)

            Section("Never") {
                Text("Reads, stores or refreshes an OAuth token.")
                Text("Reads another app's Keychain items.")
                Text("Stores prompts, responses, emails or account ids.")
                Text("Sends anything that spends credits or starts a model turn.")
            }

            Section("Usage pages") {
                ForEach(dashboardProviders, id: \.self) { provider in
                    LabeledContent {
                        Link(provider.defaultDashboardURL.host() ?? provider.defaultDashboardURL.absoluteString, destination: provider.defaultDashboardURL)
                    } label: {
                        HStack(spacing: 8) {
                            ProviderLogoView(provider: provider, size: 16)
                            Text(provider == .opencodeGo ? "OpenCode" : provider.displayName)
                        }
                    }
                }
            }
        }
    }

    private struct CopyCommand: Identifiable {
        var id: String { name }
        var name: String
        var command: String
    }

    private static let updateCommands = [
        CopyCommand(name: "Homebrew", command: "brew upgrade tokenjar && tokenjar-install-app"),
        CopyCommand(name: "curl", command: "curl -fsSL https://raw.githubusercontent.com/PedroMosquera/tokenjar/main/Scripts/get.sh | bash"),
        CopyCommand(name: "make", command: "git pull && make install"),
    ]

    private static func updateNoticeSummary(_ delivery: AlertDelivery) -> String {
        delivery.action == .openNotificationSettings
            ? "Notifications for Tokenjar are off in System Settings, so update notices are not shown."
            : "Update notices arrive quietly in Notification Center. Allow banners to see them on screen."
    }

    @ViewBuilder private func updatesSection(_ updates: UpdateChecker) -> some View {
        let delivery = AlertDelivery(model.notificationPermission)
        Section("Updates") {
            Picker(selection: Binding(
                get: { updates.mode },
                set: { mode in
                    updates.mode = mode
                    if mode == .automatic {
                        model.requestNotificationPermission(prominent: true)
                        model.checkForUpdatesIfDue()
                    }
                }
            )) {
                Text("Manual").tag(UpdateCheckMode.manual)
                Text("Automatic").tag(UpdateCheckMode.automatic)
            } label: {
                Text("Check for updates")
                Text(updates.mode == .automatic
                    ? "Tokenjar asks GitHub once a day and notifies you once per new version."
                    : "Tokenjar asks GitHub only when you click Check Now.")
            }
            if updates.mode == .automatic, let action = delivery.action {
                HStack {
                    Text(Self.updateNoticeSummary(delivery))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch action {
                    case .allowBanners:
                        Button("Allow Banners") { model.requestNotificationPermission(prominent: true) }
                    case .openNotificationSettings:
                        Button("Open Notification Settings") {
                            NSWorkspace.shared.open(AlertDelivery.notificationSettingsURL(bundleID: Bundle.main.bundleIdentifier))
                        }
                    }
                }
            }
            LabeledContent {
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.status == .checking || !updates.canCheck)
            } label: {
                if !updates.canCheck {
                    Text("Update checks need the installed app.")
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(UpdateStatusLine.text(updates.status, lastCheck: updates.lastCheck, now: context.date))
                    }
                }
            }
            if case .available(let release) = updates.status {
                Link("What's new in \(release.version)", destination: release.pageURL)
                LabeledContent {
                    Button("Update in Terminal") { openUpdateInTerminal(release.version) }
                } label: {
                    Text("Update to \(release.version)")
                    Text("Opens Terminal, runs the update for this copy of Tokenjar, then opens the new version.")
                }
                ForEach(Self.updateCommands) { item in
                    LabeledContent {
                        Button("Copy") { TerminalLauncher.copy(item.command) }
                    } label: {
                        Text(item.name)
                        Text(item.command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .alert("Couldn't open Terminal", isPresented: Binding(
            get: { failedUpdateCommand != nil },
            set: { if !$0 { failedUpdateCommand = nil } }
        )) {
            Button("Copy Command") { failedUpdateCommand.map(TerminalLauncher.copy) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copy the update command and paste it into Terminal.")
        }
        .onAppear { model.refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotificationPermission()
        }
    }

    private func openUpdateInTerminal(_ version: AppVersion) {
        let command = UpdateCommand.terminal(
            method: UpdateCommand.method(fileExists: FileManager.default.fileExists(atPath:)), version: version,
            appBundle: Bundle.main.bundlePath, home: NSHomeDirectory()
        )
        do {
            try TerminalLauncher.run(command: command, title: "update to \(version)", fileName: UpdateCommand.terminalScriptFileName)
        } catch {
            failedUpdateCommand = command
        }
    }

    // A build-folder binary has no icon of its own and AppKit hands back a generic folder.
    @ViewBuilder private var appIcon: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage).resizable()
        } else {
            Image(nsImage: StatusGlyph.picture(.app))
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor)
                .padding(6)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// OpenCode Go and Zen share one console.
    private var dashboardProviders: [ProviderID] {
        ProviderID.allCases.filter { $0 != .opencodeZen }
    }

    private func itemSection(_ title: String, _ items: [Item]) -> some View {
        Section(title) {
            ForEach(items) { itemRow($0) }
        }
    }

    private func itemRow(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.what)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Text(item.why)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
