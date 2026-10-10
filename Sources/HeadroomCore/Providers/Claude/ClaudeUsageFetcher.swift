import Foundation

/// Reads limits by running the user's own `claude -p /usage`, which Claude Code answers locally with the
/// account's rate limits. The CLI keeps its credentials to itself; Headroom never sees or refreshes a token.
/// When the CLI is missing or fails, falls back to the limits Claude Code cached in `.claude.json`, except when
/// the run spent tokens: that throws `.unsupported` so it cannot go unnoticed.
public struct ClaudeUsageFetcher: UsageFetcher {
    public static let source = "claude CLI"
    public static let cacheSource = "Claude Code cache"
    public static let noLimitsNote = "No plan limits for this login"
    public static let modelTurnMessage = "claude CLI ran /usage as a prompt, which spends tokens. Checks for this account are paused until claude updates or you click Try once more."

    static let arguments = [
        "-p", "/usage", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
        "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
    ]

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let configDir = account.profileDir.map(context.paths.expand)
        let config = ClaudeGlobalConfig.load(configDir: configDir, home: context.paths.home)
        let now = context.now()

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
        try? context.paths.createProbeDirectory()

        let result: ProcessResult
        do {
            result = try await context.process.run(
                executable, arguments: Self.arguments, environment: environment, currentDirectory: probeDirectory,
                stdin: nil, timeout: 45, outputLimit: 2 << 20
            )
        } catch {
            return try fallback(.cliNotFound("claude"))
        }
        let output = ClaudeUsageOutput.parse(result.stdout)
        if result.timedOut {
            // A turn cut short has already spent tokens; the cache would hide that every refresh spends them again.
            if case .modelTurn = output.kind { throw FetchError.unsupported(Self.modelTurnMessage) }
            return try fallback(.timeout)
        }
        // API key usage is billed outside the subscription, so the plan saved in .claude.json does not describe this login.
        let plan = output.usesAPIKey ? nil : config?.plan

        func snapshot(windows: [UsageWindow], money: [MoneyLine], notes: [String] = []) -> UsageSnapshot {
            UsageSnapshot(accountID: account.id, provider: .claude, plan: plan, windows: windows, money: money, fetchedAt: now, source: Self.source, notes: notes)
        }

        switch output.kind {
        case .report(let limits):
            let windows = limits?.windows ?? []
            if windows.isEmpty, !output.usesAPIKey, config?.planHasLimits == true { return try fallback(.parse("usage report has no limits")) }
            return snapshot(windows: windows, money: limits?.money ?? [], notes: windows.isEmpty ? [Self.noLimitsNote] : [])
        case .noReport:
            if output.usesAPIKey { return snapshot(windows: [], money: [], notes: [Self.noLimitsNote]) }
            if config?.isSignedIn != true,
               ClaudeProviderSettings.load(configDir: configDir, home: context.paths.home)?.usesThirdPartyProvider != true {
                throw FetchError.notSignedIn
            }
            if config?.planHasLimits == true { return try fallback(.parse("usage report missing")) }
            return snapshot(windows: [], money: [], notes: [Self.noLimitsNote])
        case .modelTurn:
            // No cache fallback: it would hide that every refresh now spends tokens.
            throw FetchError.unsupported(Self.modelTurnMessage)
        case .unrecognized:
            return try fallback(.parse("unrecognized /usage output, exit \(result.exitCode)"))
        }
    }
}

/// What one `claude -p /usage --output-format stream-json` run said, reduced to what decides the snapshot.
struct ClaudeUsageOutput {
    enum Kind {
        /// A plan usage report; `nil` limits when the report carried no `rate_limits`.
        case report(ClaudeRateLimits?)
        /// `/usage` ran but printed only the local cost summary, which is what signed-out, API-key, Bedrock and
        /// Vertex logins all get.
        case noReport
        /// The CLI sent `/usage` to the model instead of answering it locally, so the run spent tokens.
        case modelTurn
        case unrecognized
    }

    var kind: Kind
    /// From the init line's `apiKeySource`, which is "none" when no API key is in use.
    var usesAPIKey: Bool

    private init(_ kind: Kind, apiKeySource: String?) {
        self.kind = kind
        usesAPIKey = apiKeySource.map { $0 != "none" } ?? false
    }

    static func parse(_ stdout: Data) -> ClaudeUsageOutput {
        let decoder = JSONDecoder()
        var apiKeySource: String?
        var ranUsage = false, modelReplied = false
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? decoder.decode(StreamLine.self, from: line) else { continue }
            switch event.type {
            case "system":
                apiKeySource = event.apiKeySource ?? apiKeySource
            case "assistant":
                if let report = event.usageReport { return Self(.report(report.rateLimits), apiKeySource: apiKeySource) }
                // The local answer carries `local_command_run`; any other assistant line is the model's. A run cut short
                // by the timeout or a crash never prints the result line that would count the turn.
                if event.localCommandRun == nil { modelReplied = true }
            case "result":
                if (event.numTurns ?? 0) > 0 || (event.totalCostUSD ?? 0) > 0 { return Self(.modelTurn, apiKeySource: apiKeySource) }
                if event.localCommand == "usage", event.isError != true { ranUsage = true }
            default:
                break
            }
        }
        if modelReplied { return Self(.modelTurn, apiKeySource: apiKeySource) }
        return Self(ranUsage ? .noReport : .unrecognized, apiKeySource: apiKeySource)
    }

    private struct StreamLine: Decodable {
        var type: String?
        var apiKeySource: String?
        var usageReport: UsageReport?
        var localCommandRun: LocalCommandRun?
        var localCommand: String?
        var isError: Bool?
        var numTurns: Int?
        var totalCostUSD: Double?

        enum CodingKeys: String, CodingKey {
            case type, apiKeySource
            case usageReport = "usage_report"
            case localCommandRun = "local_command_run"
            case localCommand = "local_command"
            case isError = "is_error"
            case numTurns = "num_turns"
            case totalCostUSD = "total_cost_usd"
        }
    }

    private struct UsageReport: Decodable {
        var rateLimits: ClaudeRateLimits?
        enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
    }

    /// Only its presence matters.
    private struct LocalCommandRun: Decodable {}
}
