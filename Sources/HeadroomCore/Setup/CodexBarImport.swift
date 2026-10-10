import Foundation

public struct CodexBarImportPreview: Equatable, Sendable {
    public var enabledProviders: [ProviderID]
    public var thresholdsUsed: [Int]?
    public var refreshMinutes: Int?
    public var notificationsEnabled: Bool?

    public init(enabledProviders: [ProviderID], thresholdsUsed: [Int]? = nil, refreshMinutes: Int? = nil, notificationsEnabled: Bool? = nil) {
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
            enabledProviders: providers ?? [], thresholdsUsed: thresholds, refreshMinutes: refresh, notificationsEnabled: notifications
        )
    }

    /// Mirrors CodexBar's provider choices onto the discovered accounts: each is enabled exactly when CodexBar had its
    /// provider on, and added when the config lacks it. Accounts that were not discovered are left alone, and so are
    /// all accounts when the preview names no providers (CodexBar's config.json was missing).
    public static func apply(_ preview: CodexBarImportPreview, to config: AppConfig, discovered: [AccountConfig]) -> AppConfig {
        var out = config
        if !preview.enabledProviders.isEmpty {
            for account in discovered {
                let enabled = preview.enabledProviders.contains(account.provider)
                if let index = out.accounts.firstIndex(where: { $0.id == account.id }) {
                    out.accounts[index].enabled = enabled
                } else {
                    var added = account
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

    /// Manual and the adaptive modes have no fixed interval, so Headroom keeps its own.
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

    /// CodexBar stores % remaining and treats 0 as off; Headroom stores % used, ascending.
    static func usedThresholds(_ remaining: [Int]) -> [Int] {
        Set(remaining.filter { (1...99).contains($0) }.map { 100 - $0 }).sorted()
    }
}
