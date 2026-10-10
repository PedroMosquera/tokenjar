import Foundation

/// Finds accounts already present on this Mac for first-run setup. Reads only file existence and
/// non-secret structure (which keys exist in opencode's auth.json); never reads token values.
public enum AccountDiscovery {
    /// `environment` supplies XDG_DATA_HOME for opencode's data directory; tests pass an empty one.
    public static func discover(
        paths: AppPaths, cli: CLILocator, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AccountConfig] {
        let fm = FileManager.default
        var accounts: [AccountConfig] = []
        if isDirectory(paths.home.appending(path: ".claude")) {
            accounts.append(AccountConfig(id: "claude", provider: .claude, label: claudeLabel(paths: paths)))
        }
        if fm.fileExists(atPath: paths.home.appending(path: ".codex/auth.json").path) {
            accounts.append(AccountConfig(id: "codex", provider: .codex, label: "ChatGPT"))
        }
        let authFile = openCodeAuthFile(paths: paths, environment: environment)
        let entries = topLevelKeys(of: authFile)
        let authPath = portablePath(authFile, home: paths.home)
        if let key = ["opencode-go", "opencode"].first(where: entries.contains) {
            accounts.append(AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: authPath, key: key)))
        }
        if entries.contains("opencode") {
            accounts.append(AccountConfig(
                id: "opencode-zen", provider: .opencodeZen, label: "Zen", credential: .file(path: authPath, key: "opencode"), showInMenuBar: false
            ))
        }
        if cli.locate("agy") != nil {
            accounts.append(AccountConfig(id: "antigravity", provider: .antigravity, label: "Google"))
        }
        return accounts
    }

    /// False when the account's profile dir or credential file is missing on this machine; such accounts are hidden.
    /// An OpenCode account without a credential falls back to opencode's own auth.json, as its fetcher does.
    public static func isAvailable(
        _ account: AccountConfig, paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch account.provider {
        case .claude:
            return isDirectory(account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".claude"))
        case .codex:
            return isDirectory(account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".codex"))
        case .opencodeGo, .opencodeZen:
            switch account.credential {
            case .file(let path, _): return FileManager.default.fileExists(atPath: paths.expand(path).path)
            case .keychain: return true
            case nil: return FileManager.default.fileExists(atPath: openCodeAuthFile(paths: paths, environment: environment).path)
            }
        case .antigravity:
            return true
        }
    }

    static func openCodeAuthFile(paths: AppPaths, environment: [String: String]) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appending(path: "opencode/auth.json")
        }
        return paths.home.appending(path: ".local/share/opencode/auth.json")
    }

    /// "~/..." for files under home, so a config written on one Mac resolves on the other.
    static func portablePath(_ url: URL, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~/" + path.dropFirst(homePath.count + 1)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Seat types an employer pays for; anything else, or no readable value, is treated as personal.
    private static let workOrganizationTypes: Set<String> = ["claude_enterprise", "claude_team"]

    private static func claudeLabel(paths: AppPaths) -> String {
        struct ClaudeJSON: Decodable {
            struct OAuthAccount: Decodable { var organizationType: String? }
            var oauthAccount: OAuthAccount?
        }
        guard let data = try? Data(contentsOf: paths.home.appending(path: ".claude.json")),
              let type = (try? JSONDecoder().decode(ClaudeJSON.self, from: data))?.oauthAccount?.organizationType
        else { return "Personal" }
        return workOrganizationTypes.contains(type) ? "Work" : "Personal"
    }

    /// Names of the top-level entries; values are never decoded.
    private static func topLevelKeys(of file: URL) -> Set<String> {
        struct KeyNames: Decodable {
            struct Key: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }
            var names: Set<String>
            init(from decoder: Decoder) throws {
                names = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
            }
        }
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode(KeyNames.self, from: data))?.names ?? []
    }
}
