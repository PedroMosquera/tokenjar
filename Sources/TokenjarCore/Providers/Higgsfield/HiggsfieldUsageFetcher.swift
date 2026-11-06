import Foundation

/// Higgsfield's credit balance from the user's own CLI: `higgsfield account status --json`. The CLI keeps its login in
/// ~/.config/higgsfield and reads it in its own process; Tokenjar never opens that folder or handles a token. The answer
/// also holds the account's email, which this decodes past, so it is never kept.
public struct HiggsfieldUsageFetcher: UsageFetcher {
    public static let source = "higgsfield CLI"
    static let noWorkspaceMessage = "No Higgsfield workspace is selected. Run higgsfield workspace set <workspace_id> in Terminal."
    private static let unreachable = FetchError.network("higgsfield could not reach its server")

    /// Nothing else in the CLI is run, since `generate` spends credits. Full name only: `hf` is also Hugging Face's CLI.
    static let arguments = ["account", "status", "--json"]

    /// The binary has Sentry built in and names both switches. Whether they stop it is unverified: no recorded run,
    /// with or without them, tried to send an event.
    static let cliEnvironment = ["HIGGSFIELD_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"]

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        guard let cli = context.cli.locate("higgsfield") else { throw FetchError.cliNotFound("higgsfield") }
        _ = try? context.paths.createProbeDirectory()

        let result: ProcessResult
        do {
            result = try await context.process.run(
                cli, arguments: Self.arguments, environment: context.cli.baseEnvironment().merging(Self.cliEnvironment) { _, own in own },
                currentDirectory: context.paths.probeDirectory, stdin: nil, timeout: 20, outputLimit: 256 * 1024
            )
        } catch {
            throw FetchError.cliNotFound("higgsfield")
        }
        if result.timedOut { throw FetchError.timeout }
        guard result.exitCode == 0 else { throw Self.failure(exitCode: result.exitCode, stderr: result.stderr) }
        return try Self.snapshot(from: result.stdout, account: account, now: context.now())
    }

    /// Exit codes recorded from hf 1.2.2: 2 for no login or an expired one, 3 for no response, 4 for no workspace. stderr
    /// is only matched, never shown or kept, since it can name the account.
    static func failure(exitCode: Int32, stderr: Data) -> FetchError {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        if text.contains("rate limited") || text.contains("too many requests") { return .rateLimited(retryAfter: nil) }
        if text.contains("server error") { return unreachable }
        switch exitCode {
        case 2: return .notSignedIn
        case 3: return unreachable
        case 4: return .unsupported(noWorkspaceMessage)
        // An npm install's launcher is `env node`, and Node may be on no folder Tokenjar's PATH holds.
        case 127: return .cliNotFound("higgsfield")
        default: return .parse("higgsfield exited with status \(exitCode)")
        }
    }

    private struct Status: Decodable {
        var credits: Double
        var plan: String?

        enum CodingKeys: String, CodingKey {
            case credits
            case plan = "subscription_plan_type"
        }
    }

    /// Credits are not dollars, and the answer has no allowance or reset date, so they are a note rather than a money
    /// row or a window. Billing stays nil, which never shows a cost line.
    static func snapshot(from stdout: Data, account: AccountConfig, now: Date) throws -> UsageSnapshot {
        guard let status = try? JSONDecoder().decode(Status.self, from: stdout) else {
            throw FetchError.parse("higgsfield output has no credit number")
        }
        let credits = status.credits.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
        return UsageSnapshot(
            accountID: account.id, provider: .higgsfield, plan: status.plan.flatMap(planLabel), fetchedAt: now, source: source,
            notes: ["Credits: \(credits)"]
        )
    }

    /// Only "free" has been seen, so any other name is shown as it comes rather than mapped.
    static func planLabel(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
