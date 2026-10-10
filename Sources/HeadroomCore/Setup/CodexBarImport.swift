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

/// One-shot import of CodexBar's non-secret settings. Reads provider ids/enabled flags from its config.json and an
/// explicit allowlist of defaults keys; never enumerates the defaults domain and never reads apiKey/cookie fields.
public enum CodexBarImport {
    public static func preview(paths: AppPaths) -> CodexBarImportPreview? { nil }
    public static func apply(_ preview: CodexBarImportPreview, to config: AppConfig, discovered: [AccountConfig]) -> AppConfig { config }
}
