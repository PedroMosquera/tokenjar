import AppKit
import SwiftUI
import TokenjarCore

/// States exactly what the app touches. Keep it in step with the fetchers, scanners and HTTPClient.allowedEndpoints.
struct AboutSettingsPane: View {
    @Environment(AppModel.self) private var model

    private struct Item: Identifiable {
        var id: String { what }
        var what: String
        var why: String
    }

    private let runs = [
        Item(what: "claude -p /usage --output-format stream-json", why: "Claude limits. Hooks and MCP off, no session saved, run from an empty private folder. Uses no tokens."),
        Item(what: "codex -s read-only -a never app-server", why: "Codex limits. Read-only sandbox, never asks for approval. Sends only initialize and account/rateLimits/read."),
        Item(what: "agy --version", why: "Checks agy is 1.1.11 or later before asking for usage, since older versions could send /\u{2060}usage to the model."),
        Item(what: "agy -p /usage --output-format json", why: "Antigravity limits."),
        Item(what: "gh api --method GET copilot_internal/user --jq <filter>", why: "GitHub Copilot limits, through your own gh login: gh sends this GET to api.github.com with its own token. The filter keeps only the plan, the reset date and the quota numbers. gh's telemetry and update check are off for it."),
    ]

    private let reads = [
        Item(what: "~/.claude/projects/**/*.jsonl", why: "Token counts, model ids, timestamps and project folder names. Also ~/.config/claude/projects, or the account's CLAUDE_CONFIG_DIR instead of both."),
        Item(what: "~/.claude.json", why: "Plan name, and Claude Code's cached limits when the CLI cannot report. Its account id is only compared with the one on the cached limits, so another login's limits are never shown. The one inside CLAUDE_CONFIG_DIR when the account sets one, or an older .config.json when present."),
        Item(what: "~/.claude/settings.json", why: "Only whether Bedrock, Vertex or Foundry is turned on, to tell a cloud login from being signed out. Or the account's CLAUDE_CONFIG_DIR."),
        Item(what: "~/.codex/sessions/**/rollout-*.jsonl", why: "Token counts, model ids, timestamps and project folder names, from archived_sessions too. When the CLI cannot report, the last limits Codex logged. Or the account's CODEX_HOME."),
        Item(what: "~/.codex/auth.json", why: "Only whether it exists, at first run and when you click Import from CodexBar. Never opened."),
        Item(what: "Devin.app, Windsurf.app and their Application Support folders", why: "Only whether one exists, in /Applications or ~/Applications, at first run and when you click Import from CodexBar, to offer a Devin account. Never opened."),
        Item(what: "~/.local/share/opencode/auth.json", why: "The opencode-go or opencode API key, or the entry the account names, for the OpenCode Go request below. At first run and on Import from CodexBar, only which entries exist. Or $XDG_DATA_HOME/opencode, or the account's profile folder."),
        Item(what: "~/.local/share/opencode/opencode.db", why: "Read-only: cost and token counts per model. Same folder as auth.json."),
        Item(what: "~/.config/tokenjar/", why: "config.json, config.local.json and pricing.json."),
        Item(what: "CodexBar's settings", why: "Only when you click Import from CodexBar, which lists the changes before applying them: enabled providers, warning thresholds, refresh interval and notification setting. Never its keys or cookies."),
    ]

    private let writes = [
        Item(what: "~/.config/tokenjar/config.json", why: "Settings, through the symlink if it is one."),
        Item(what: "~/Library/Application Support/Tokenjar/", why: "tokenjar.sqlite: usage history. alert-state.json: which alerts already fired. probe-latch.json: accounts whose usage check spent tokens, so it is not run again until claude updates or you try once more. probe: an empty folder the CLIs run in."),
        Item(what: "$TMPDIR/tokenjar-sign-in-<account>.command", why: "Only when you click Sign In in Terminal: the login command for Terminal to run. It deletes itself when it runs."),
        Item(what: "Keychain: \(AppPaths.keychainService)", why: "Only API keys you paste here."),
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
                    }
                }
                HelpText("Shows how much room is left on each AI subscription. Built from source; no telemetry, no updates feed.")
            }

            itemSection("Runs", runs)
            itemSection("Reads", reads)

            Section("Contacts") {
                itemRow(Item(what: "GET https://opencode.ai/zen/go/v1/usage", why: "OpenCode Go limits. The only network request Tokenjar makes. Dashboards open in your browser."))
            }

            itemSection("Writes", writes)

            Section("Never") {
                Text("Reads, stores or refreshes an OAuth token.")
                Text("Reads another app's Keychain items.")
                Text("Stores prompts, responses, emails or account ids.")
                Text("Sends anything that spends credits or starts a model turn.")
            }

            Section("Provider dashboards") {
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

    // A build-folder binary has no icon of its own and AppKit hands back a generic folder.
    @ViewBuilder private var appIcon: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage).resizable()
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
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
