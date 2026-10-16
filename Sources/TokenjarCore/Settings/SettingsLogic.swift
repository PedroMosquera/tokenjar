import Foundation

/// Pure rules behind the Settings controls, kept apart from the views so they can be tested without AppKit.
public enum SettingsLogic {
    public static let refreshChoices = [5, 10, 15, 30]
    public static let thresholdRange = 1...100

    /// A new account whose id is a slug no other account uses. Ids are storage keys, so they are never derived from labels.
    public static func newAccount(provider: ProviderID, existing: [AccountConfig]) -> AccountConfig {
        let taken = Set(existing.map(\.id))
        var id = provider.rawValue
        var suffix = 2
        while taken.contains(id) {
            id = "\(provider.rawValue)-\(suffix)"
            suffix += 1
        }
        let siblings = existing.filter { $0.provider == provider }.count
        return AccountConfig(
            id: id, provider: provider, label: siblings == 0 ? "Default" : "Account \(siblings + 1)", showInMenuBar: provider.reportsWindows
        )
    }

    /// The accounts with `id` moved `offset` places, unchanged when that would leave the list or `id` is not in it.
    public static func moving(_ id: String, by offset: Int, in accounts: [AccountConfig]) -> [AccountConfig] {
        guard let from = accounts.firstIndex(where: { $0.id == id }), accounts.indices.contains(from + offset) else { return accounts }
        var out = accounts
        out.insert(out.remove(at: from), at: from + offset)
        return out
    }

    /// A daily or monthly budget typed in Settings. nil for blank or unreadable text, or an amount that is not positive.
    /// A currency symbol or spaces are ignored. With both "." and "," the last one is the decimal point; with one kind,
    /// it is the decimal point when it is the locale's, or when a group after it is not three digits ("5.50" in German).
    public static func budgetAmount(from text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
        let kept = text.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
        guard !kept.isEmpty, !text.contains("-") else { return nil }
        let separators = kept.filter { $0 == "." || $0 == "," }
        var decimal: Character?
        if Set(separators).count > 1 {
            decimal = separators.last
        } else if let separator = separators.first {
            let groups = kept.split(separator: separator, omittingEmptySubsequences: false).dropFirst()
            let isGrouping = groups.allSatisfy { $0.count == 3 } && String(separator) != (locale.decimalSeparator ?? ".")
            decimal = isGrouping ? nil : separator
        }
        let normalized = String(kept.compactMap { character -> Character? in
            if character == decimal { return "." }
            return character.isNumber ? character : nil
        })
        guard let amount = Double(normalized), amount > 0 else { return nil }
        return amount
    }

    /// nil for a blank name, which the name sheet refuses.
    public static func accountLabel(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Unique, in 1...100, ascending.
    public static func normalizedThresholds(_ values: [Int]) -> [Int] {
        Array(Set(values.filter(thresholdRange.contains))).sorted()
    }

    /// `refreshChoices`, plus a hand-edited value from config.json so the picker never shows blank.
    public static func refreshOptions(including current: Int?) -> [Int] {
        guard let current, current > 0, !refreshChoices.contains(current) else { return refreshChoices }
        return (refreshChoices + [current]).sorted()
    }

    /// Empty text means "use the CLI default", stored as nil so the shared config stays portable.
    public static func profileDir(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public enum DashboardURLInput: Equatable, Sendable {
        case providerDefault
        case custom(String)
        case invalid
    }

    /// Only web URLs: the value is handed to NSWorkspace.open, which would also launch file:// paths and app schemes.
    public static func dashboardURL(from text: String) -> DashboardURLInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .providerDefault }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return .invalid }
        return .custom(trimmed)
    }

    /// The credential an account keeps once the user stops using a pasted key. The key is deleted first, so a failed
    /// delete throws while the account still points at the item, and no key is left in the Keychain without a reference.
    public static func removingPastedKey(from credential: CredentialRef?, secrets: any SecretStore) throws -> CredentialRef? {
        guard case .keychain(let keyAccount) = credential else { return credential }
        try secrets.delete(account: keyAccount)
        return nil
    }

    /// Another enabled account of the same provider reading the same profile, which would show the same login twice.
    public static func profileTwin(of account: AccountConfig, in accounts: [AccountConfig], paths: AppPaths) -> AccountConfig? {
        guard let mine = resolvedProfile(account, paths: paths) else { return nil }
        return accounts.first {
            $0.id != account.id && $0.provider == account.provider && $0.enabled && resolvedProfile($0, paths: paths) == mine
        }
    }

    /// The folder the account's CLI reads, its default when none is set; nil for a provider without a profile variable.
    static func resolvedProfile(_ account: AccountConfig, paths: AppPaths) -> String? {
        guard let variable = SignInCommand.profileVariable(for: account.provider) else { return nil }
        return paths.expand(profileDir(from: account.profileDir ?? "") ?? variable.defaultPath).standardizedFileURL.path
    }

    /// Plain-language lines for a confirmation sheet, so an import never changes anything the user has not seen.
    public static func describeChanges(from old: AppConfig, to new: AppConfig) -> [String] {
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
            lines.append("Refresh every \(minutes(new.refreshMinutes)) (now \(minutes(old.refreshMinutes)))")
        }
        if old.menuBar != new.menuBar { lines.append("Menu bar settings") }
        if old.cliPaths != new.cliPaths { lines.append("CLI locations") }
        if old.launchAtLogin != new.launchAtLogin {
            lines.append(new.launchAtLogin ? "Launch at login" : "Do not launch at login")
        }
        return lines
    }

    /// Paths under the home folder written with ~, so a shared config works on a Mac with a different user name.
    public static func tildePath(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func minutes(_ count: Int) -> String {
        count == 1 ? "1 minute" : "\(count) minutes"
    }

    public static func percentList(_ values: [Int]) -> String {
        values.isEmpty ? "none" : values.map { "\($0)%" }.joined(separator: ", ")
    }
}
