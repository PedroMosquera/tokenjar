import Foundation
import HeadroomCore

/// Pure rules behind the Settings controls, kept apart from the views so they can be tested without AppKit.
nonisolated enum SettingsLogic {
    static let refreshChoices = [5, 10, 15, 30]
    static let thresholdRange = 1...100

    /// A new account whose id is a slug no other account uses. Ids are storage keys, so they are never derived from labels.
    static func newAccount(provider: ProviderID, existing: [AccountConfig]) -> AccountConfig {
        let taken = Set(existing.map(\.id))
        var id = provider.rawValue
        var suffix = 2
        while taken.contains(id) {
            id = "\(provider.rawValue)-\(suffix)"
            suffix += 1
        }
        let siblings = existing.filter { $0.provider == provider }.count
        return AccountConfig(id: id, provider: provider, label: siblings == 0 ? "Default" : "Account \(siblings + 1)")
    }

    /// Unique, in 1...100, ascending.
    static func normalizedThresholds(_ values: [Int]) -> [Int] {
        Array(Set(values.filter(thresholdRange.contains))).sorted()
    }

    /// `refreshChoices`, plus a hand-edited value from config.json so the picker never shows blank.
    static func refreshOptions(including current: Int?) -> [Int] {
        guard let current, current > 0, !refreshChoices.contains(current) else { return refreshChoices }
        return (refreshChoices + [current]).sorted()
    }

    /// Empty text means "use the CLI default", stored as nil so the shared config stays portable.
    static func profileDir(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum DashboardURLInput: Equatable {
        case providerDefault
        case custom(String)
        case invalid
    }

    /// Only web URLs: the value is handed to NSWorkspace.open, which would also launch file:// paths and app schemes.
    static func dashboardURL(from text: String) -> DashboardURLInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .providerDefault }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return .invalid }
        return .custom(trimmed)
    }

    /// Another enabled account of the same provider reading the same profile, which would show the same login twice.
    static func profileTwin(of account: AccountConfig, in accounts: [AccountConfig], paths: AppPaths) -> AccountConfig? {
        guard account.provider == .claude || account.provider == .codex else { return nil }
        let mine = resolvedProfile(account, paths: paths)
        return accounts.first { $0.id != account.id && $0.provider == account.provider && $0.enabled && resolvedProfile($0, paths: paths) == mine }
    }

    private static func resolvedProfile(_ account: AccountConfig, paths: AppPaths) -> String {
        let fallback = account.provider == .claude ? "~/.claude" : "~/.codex"
        return paths.expand(profileDir(from: account.profileDir ?? "") ?? fallback).standardizedFileURL.path
    }

    /// Plain-language lines for a confirmation sheet, so an import never changes anything the user has not seen.
    static func describeChanges(from old: AppConfig, to new: AppConfig) -> [String] {
        var lines: [String] = []
        let oldByID = Dictionary(old.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.accounts.map(\.id))
        for account in new.accounts {
            if let before = oldByID[account.id] {
                if before != account { lines.append("Update account \(account.displayName)") }
            } else {
                lines.append("Add account \(account.displayName)")
            }
        }
        for account in old.accounts where !newIDs.contains(account.id) {
            lines.append("Remove account \(account.displayName)")
        }
        if old.alerts.thresholds != new.alerts.thresholds {
            lines.append("Alert thresholds: \(percentList(new.alerts.thresholds)) used (now \(percentList(old.alerts.thresholds)))")
        }
        if old.alerts.enabled != new.alerts.enabled {
            lines.append(new.alerts.enabled ? "Turn alerts on" : "Turn alerts off")
        }
        if old.refreshMinutes != new.refreshMinutes {
            lines.append("Refresh every \(new.refreshMinutes) min (now \(old.refreshMinutes) min)")
        }
        if old.menuBar != new.menuBar { lines.append("Menu bar settings") }
        if old.cliPaths != new.cliPaths { lines.append("CLI locations") }
        if old.launchAtLogin != new.launchAtLogin {
            lines.append(new.launchAtLogin ? "Launch at login" : "Do not launch at login")
        }
        return lines
    }

    /// Paths under the home folder written with ~, so a shared config works on a Mac with a different user name.
    static func tildePath(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func percentList(_ values: [Int]) -> String {
        values.isEmpty ? "none" : values.map { "\($0)%" }.joined(separator: ", ")
    }
}
