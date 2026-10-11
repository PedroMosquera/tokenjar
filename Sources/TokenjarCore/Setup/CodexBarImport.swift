import Foundation

public struct CodexBarImportPreview: Equatable, Sendable {
    /// nil when no CodexBar config.json was found; empty when one was found with none of Tokenjar's providers enabled.
    public var enabledProviders: [ProviderID]?
    /// From CodexBar's global warning list only. Its per-window session and weekly lists are not read.
    public var thresholdsUsed: [Int]?
    public var refreshMinutes: Int?
    public var notificationsEnabled: Bool?

    public init(enabledProviders: [ProviderID]? = nil, thresholdsUsed: [Int]? = nil, refreshMinutes: Int? = nil, notificationsEnabled: Bool? = nil) {
        self.enabledProviders = enabledProviders
        self.thresholdsUsed = thresholdsUsed
        self.refreshMinutes = refreshMinutes
        self.notificationsEnabled = notificationsEnabled
    }
}

/// Reads one preferences key at a time. `UserDefaults` conforms; tests use a dictionary.
public protocol DefaultsReading {
    func object(forKey defaultName: String) -> Any?
}

extension UserDefaults: DefaultsReading {}

/// One-shot import of CodexBar's non-secret settings. Reads provider ids/enabled flags from its config.json and an
/// explicit allowlist of defaults keys; never enumerates the defaults domain and never reads apiKey/cookie fields.
public enum CodexBarImport {
    public static let defaultsSuite = "com.steipete.codexbar"
    /// Every defaults key the import may read. Adding one is a privacy decision.
    public static let defaultsKeys = ["refreshFrequency", "quotaWarningNotificationsEnabled", "quotaWarningThresholds"]

    /// nil when CodexBar has left nothing to import on this Mac.
    /// `defaults` nil means CodexBar's own suite; `environment` supplies XDG_CONFIG_HOME.
    public static func preview(
        paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment, defaults: (any DefaultsReading)? = nil
    ) -> CodexBarImportPreview? {
        let reader: (any DefaultsReading)? = defaults ?? UserDefaults(suiteName: defaultsSuite)
        let providers = configFileCandidates(paths: paths, environment: environment)
            .lazy.compactMap(enabledProviders(in:)).first
        let thresholds = (reader?.object(forKey: "quotaWarningThresholds") as? [Int]).map(usedThresholds).flatMap { $0.isEmpty ? nil : $0 }
        let refresh = (reader?.object(forKey: "refreshFrequency") as? String).flatMap(refreshMinutes)
        let notifications = reader?.object(forKey: "quotaWarningNotificationsEnabled") as? Bool
        if providers == nil, thresholds == nil, refresh == nil, notifications == nil { return nil }
        return CodexBarImportPreview(
            enabledProviders: providers, thresholdsUsed: thresholds, refreshMinutes: refresh, notificationsEnabled: notifications
        )
    }

    /// Mirrors CodexBar's provider choices onto the discovered accounts. Configured accounts that are the same login as a
    /// discovered one, whatever their id, are enabled exactly when CodexBar had the provider on; a discovered login the
    /// config lacks is added, under a free id. Accounts that match nothing discovered are left alone, and so are all
    /// accounts when `enabledProviders` is nil.
    public static func apply(
        _ preview: CodexBarImportPreview, to config: AppConfig, discovered: [AccountConfig],
        paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppConfig {
        var out = config
        if let providers = preview.enabledProviders {
            for account in discovered {
                let enabled = providers.contains(account.provider)
                let matches = out.accounts.indices.filter { isSameLogin(out.accounts[$0], account, paths: paths, environment: environment) }
                for index in matches { out.accounts[index].enabled = enabled }
                if matches.isEmpty {
                    var added = account
                    added.id = freeID(account.id, taken: Set(out.accounts.map(\.id)))
                    added.enabled = enabled
                    out.accounts.append(added)
                }
            }
        }
        if let thresholds = preview.thresholdsUsed { out.alerts.thresholds = thresholds }
        if let minutes = preview.refreshMinutes { out.refreshMinutes = minutes }
        if let enabled = preview.notificationsEnabled { out.alerts.enabled = enabled }
        return out
    }

    /// Same provider and same profile dir or credential file. Antigravity has one login per Mac. Two entries of one
    /// auth.json are different logins, but an account without a credential uses the key discovery would pick.
    static func isSameLogin(_ a: AccountConfig, _ b: AccountConfig, paths: AppPaths, environment: [String: String]) -> Bool {
        guard a.provider == b.provider else { return false }
        if a.provider == .antigravity { return true }
        guard let locationA = AccountDiscovery.location(of: a, paths: paths, environment: environment),
              let locationB = AccountDiscovery.location(of: b, paths: paths, environment: environment),
              locationA.standardizedFileURL.path == locationB.standardizedFileURL.path
        else { return false }
        if case .file(_, let keyA) = a.credential, case .file(_, let keyB) = b.credential { return keyA == keyB }
        return true
    }

    private static func freeID(_ id: String, taken: Set<String>) -> String {
        guard taken.contains(id) else { return id }
        return (2...).lazy.map { "\(id)-\($0)" }.first { !taken.contains($0) }!
    }

    /// $XDG_CONFIG_HOME/codexbar when set, else ~/.config/codexbar, then the legacy ~/.codexbar.
    static func configFileCandidates(paths: AppPaths, environment: [String: String]) -> [URL] {
        var directories: [URL] = []
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            directories.append(URL(fileURLWithPath: xdg).appending(path: "codexbar"))
        } else {
            directories.append(paths.home.appending(path: ".config/codexbar"))
        }
        directories.append(paths.home.appending(path: ".codexbar"))
        return directories.map { $0.appending(path: "config.json") }
    }

    /// Decodes only `providers[].id` and `providers[].enabled`; every other field, keys included, is skipped.
    static func enabledProviders(in file: URL) -> [ProviderID]? {
        struct Config: Decodable {
            struct Provider: Decodable {
                var id: String
                var enabled: Bool?
            }
            var providers: [Provider]
        }
        guard let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        var seen: [ProviderID] = []
        for provider in config.providers where provider.enabled == true {
            if let id = providerID(provider.id), !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    static func providerID(_ codexBarID: String) -> ProviderID? {
        switch codexBarID {
        case "codex": .codex
        case "claude": .claude
        case "opencodego": .opencodeGo
        case "opencode": .opencodeZen
        case "antigravity", "gemini": .antigravity
        default: nil
        }
    }

    /// Manual and the adaptive modes have no fixed interval, so Tokenjar keeps its own.
    static func refreshMinutes(_ frequency: String) -> Int? {
        switch frequency {
        case "oneMinute": 1
        case "twoMinutes": 2
        case "fiveMinutes": 5
        case "fifteenMinutes": 15
        case "thirtyMinutes": 30
        default: nil
        }
    }

    /// CodexBar stores % remaining and treats 0 as off; Tokenjar stores % used, ascending.
    static func usedThresholds(_ remaining: [Int]) -> [Int] {
        Set(remaining.filter { (1...99).contains($0) }.map { 100 - $0 }).sorted()
    }
}
