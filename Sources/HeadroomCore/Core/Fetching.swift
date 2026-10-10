import Foundation

public struct FetchContext: Sendable {
    public var process: any ProcessRunning
    public var http: HTTPClient
    public var secrets: any SecretStore
    public var cli: CLILocator
    public var paths: AppPaths
    public var now: @Sendable () -> Date

    public init(
        process: any ProcessRunning = FoundationProcessRunner(), http: HTTPClient = HTTPClient(),
        secrets: any SecretStore = KeychainSecretStore(), cli: CLILocator = CLILocator(), paths: AppPaths = AppPaths(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.process = process
        self.http = http
        self.secrets = secrets
        self.cli = cli
        self.paths = paths
        self.now = now
    }
}

/// Produces the current limits for one account. Implementations must not read or refresh OAuth tokens,
/// must not touch other apps' Keychain items, and must not send any request that changes account state.
public protocol UsageFetcher: Sendable {
    func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot
}

public enum FetcherRegistry {
    public static func fetcher(for provider: ProviderID) -> any UsageFetcher {
        switch provider {
        case .claude: ClaudeUsageFetcher()
        case .codex: CodexUsageFetcher()
        case .opencodeGo: OpenCodeGoUsageFetcher()
        case .opencodeZen: OpenCodeZenUsageFetcher()
        case .antigravity: AntigravityUsageFetcher()
        }
    }

    public static func scanner(for provider: ProviderID) -> (any HistoryScanner)? {
        switch provider {
        case .claude: ClaudeHistoryScanner()
        case .codex: CodexHistoryScanner()
        case .opencodeGo: OpenCodeHistoryScanner(providerIDs: ["opencode-go"])
        case .opencodeZen: OpenCodeHistoryScanner(providerIDs: ["opencode"])
        case .antigravity: nil
        }
    }
}
