import Foundation

/// Reads limits by running the user's own `claude -p /usage`, which Claude Code answers locally with the
/// account's rate limits. The CLI keeps its credentials to itself; Headroom never sees or refreshes a token.
/// When the CLI is missing or fails, falls back to the limits Claude Code cached in `.claude.json`.
public struct ClaudeUsageFetcher: UsageFetcher {
    public static let source = "claude CLI"
    public static let cacheSource = "Claude Code cache"
    public static let noLimitsNote = "No plan limits for this login"

    static let arguments = [
        "-p", "/usage", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
    ]

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let configDir = account.profileDir.map(context.paths.expand)
        let config = ClaudeGlobalConfig.load(configDir: configDir, home: context.paths.home)
        let now = context.now()

        func snapshot(windows: [UsageWindow], money: [MoneyLine], notes: [String] = []) -> UsageSnapshot {
            UsageSnapshot(accountID: account.id, provider: .claude, plan: config?.plan, windows: windows, money: money, fetchedAt: now, source: Self.source, notes: notes)
        }

        /// The CLI could not answer: use Claude Code's own cache if it is usable, else surface `error`.
        func fallback(_ error: FetchError) throws -> UsageSnapshot {
            guard let cached = config?.cachedLimits(now: now) else { throw error }
            return UsageSnapshot(
                accountID: account.id, provider: .claude, plan: config?.plan, windows: cached.windows, money: cached.money,
                fetchedAt: cached.fetchedAt, source: Self.cacheSource,
                notes: ["\(error.userMessage). Showing the last values Claude Code saved."]
            )
        }

        guard let executable = context.cli.locate("claude") else { return try fallback(.cliNotFound("claude")) }

        var environment = context.cli.baseEnvironment()
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir.path }
        let probeDirectory = context.paths.probeDirectory
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)

        let result: ProcessResult
        do {
            result = try await context.process.run(
                executable, arguments: Self.arguments, environment: environment, currentDirectory: probeDirectory,
                stdin: nil, timeout: 45, outputLimit: 2 << 20
            )
        } catch {
            return try fallback(.cliNotFound("claude"))
        }
        if result.timedOut { return try fallback(.timeout) }

        switch ClaudeUsageOutput.parse(result.stdout) {
        case .report(let limits):
            let windows = limits?.windows ?? []
            if windows.isEmpty, config?.planHasLimits == true { return try fallback(.parse("usage report has no limits")) }
            return snapshot(windows: windows, money: limits?.money ?? [], notes: windows.isEmpty ? [Self.noLimitsNote] : [])
        case .noReport(let apiKeySource):
            let usesAPIKey = apiKeySource.map { $0 != "none" } ?? false
            if !usesAPIKey, config?.isSignedIn != true,
               ClaudeProviderSettings.load(configDir: configDir, home: context.paths.home)?.usesThirdPartyProvider != true {
                throw FetchError.notSignedIn
            }
            if config?.planHasLimits == true { return try fallback(.parse("usage report missing")) }
            return snapshot(windows: [], money: [], notes: [Self.noLimitsNote])
        case .unrecognized:
            return try fallback(.parse("unrecognized /usage output, exit \(result.exitCode)"))
        }
    }
}

/// What one `claude -p /usage --output-format stream-json` run said, reduced to what decides the snapshot.
enum ClaudeUsageOutput {
    /// A plan usage report; `nil` limits when the report carried no `rate_limits`.
    case report(ClaudeRateLimits?)
    /// `/usage` ran but printed only the local cost summary, which is what signed-out, API-key, Bedrock and
    /// Vertex logins all get. `apiKeySource` from the init line tells an API key apart ("none" otherwise).
    case noReport(apiKeySource: String?)
    case unrecognized

    static func parse(_ stdout: Data) -> ClaudeUsageOutput {
        let decoder = JSONDecoder()
        var apiKeySource: String?
        var ranUsage = false
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? decoder.decode(StreamLine.self, from: line) else { continue }
            switch event.type {
            case "system":
                apiKeySource = event.apiKeySource ?? apiKeySource
            case "assistant":
                if let report = event.usageReport { return .report(report.rateLimits) }
            case "result":
                if event.localCommand == "usage", event.isError != true { ranUsage = true }
            default:
                break
            }
        }
        return ranUsage ? .noReport(apiKeySource: apiKeySource) : .unrecognized
    }

    private struct StreamLine: Decodable {
        var type: String?
        var apiKeySource: String?
        var usageReport: UsageReport?
        var localCommand: String?
        var isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, apiKeySource
            case usageReport = "usage_report"
            case localCommand = "local_command"
            case isError = "is_error"
        }
    }

    private struct UsageReport: Decodable {
        var rateLimits: ClaudeRateLimits?
        enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
    }
}
