import Foundation

/// `Tokenjar --capture <provider>`: the request the fetcher sends, run once, with its raw answer redacted by
/// `CaptureRedactor` so an unverified shape can become a test fixture. Reuses the fetchers' arguments, version gate and
/// key lookup, so a capture shows what the app itself would see. Prints only; it stores no snapshot, latch or file.
public enum Capture {
    public enum Outcome: Equatable, Sendable {
        /// A redacted JSON document for stdout.
        case document(String)
        /// Nothing was captured; the message says why and the command exits 1.
        case stopped(String)
        /// The provider has no source Tokenjar asks.
        case nothingToCapture(String)
    }

    public static func run(_ account: AccountConfig, context: FetchContext) async -> Outcome {
        await run(account, context: context, codexLauncher: ProcessCodexAppServerLauncher(), environment: ProcessInfo.processInfo.environment)
    }

    /// `environment` is Tokenjar's own, read only for opencode's `XDG_DATA_HOME`, as the fetcher does.
    static func run(
        _ account: AccountConfig, context: FetchContext, codexLauncher: any CodexAppServerLaunching, environment: [String: String]
    ) async -> Outcome {
        do {
            switch account.provider {
            case .claude: return try await claude(account, context: context)
            case .codex: return try await codex(account, context: context, launcher: codexLauncher)
            case .copilot: return try await copilot(account, context: context)
            case .antigravity: return try await antigravity(context: context)
            case .opencodeGo: return try await opencodeGo(account, context: context, environment: environment)
            case .opencodeZen: return .nothingToCapture("OpenCode Zen has nothing to capture: its numbers come from opencode's local database, not from a request.")
            case .devin: return .nothingToCapture("Devin has nothing to capture: Tokenjar runs, reads and sends nothing for it.")
            }
        } catch {
            return .stopped("The capture could not be printed as JSON.")
        }
    }

    static func modelTurnStop(_ cli: String, spends: String) -> String {
        "\(cli) answered /usage with a model turn, which spends \(spends). The capture stopped and printed nothing. It wrote nothing either, so Tokenjar.app does not know: its next check of this \(cli) build runs once more before it pauses."
    }

    // MARK: Claude

    private static func claude(_ account: AccountConfig, context: FetchContext) async throws -> Outcome {
        guard let claude = context.cli.locate("claude") else { return .stopped("claude was not found.") }
        let configDir = account.profileDir.map(context.paths.expand)
        var environment = context.cli.baseEnvironment()
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir.path }
        _ = try? context.paths.createProbeDirectory()

        let result: ProcessResult
        do {
            result = try await context.process.run(
                claude, arguments: ClaudeUsageFetcher.arguments, environment: environment, currentDirectory: context.paths.probeDirectory,
                stdin: nil, timeout: 45, outputLimit: 2 << 20
            )
        } catch {
            return .stopped("claude could not be started.")
        }
        if case .modelTurn = ClaudeUsageOutput.parse(result.stdout).kind { return .stopped(modelTurnStop("claude", spends: "tokens")) }

        let lines: [Any] = result.stdout.split(separator: UInt8(ascii: "\n")).map { line in
            (try? JSONSerialization.jsonObject(with: line)) ?? CaptureRedactor.placeholder
        }
        let settings = (configDir ?? context.paths.home.appending(path: ".claude")).appending(path: "settings.json")
        let document: [String: Any] = [
            "capture": ProviderID.claude.rawValue,
            "probe": ["exitCode": Int(result.exitCode), "timedOut": result.timedOut, "lines": lines],
            "claudeJSON": ClaudeJSONFields.load(ClaudeGlobalConfig.file(configDir: configDir, home: context.paths.home))?.document ?? NSNull(),
            "settingsEnvKeys": EnvKeyNames.load(settings) ?? NSNull(),
            "managedSettingsEnvKeys": EnvKeyNames.load(context.paths.claudeManagedSettingsFile) ?? NSNull(),
        ]
        return .document(try CaptureRedactor.render(document, provider: .claude))
    }

    /// Only the plan-describing fields of `.claude.json`; identity fields are never decoded.
    private struct ClaudeJSONFields: Decodable {
        struct OAuthAccount: Decodable {
            var organizationType, seatTier, billingType, organizationRateLimitTier, userRateLimitTier: String?
            var hasExtraUsageEnabled: Bool?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                organizationType = try? c.decodeIfPresent(String.self, forKey: .organizationType)
                seatTier = try? c.decodeIfPresent(String.self, forKey: .seatTier)
                billingType = try? c.decodeIfPresent(String.self, forKey: .billingType)
                organizationRateLimitTier = try? c.decodeIfPresent(String.self, forKey: .organizationRateLimitTier)
                userRateLimitTier = try? c.decodeIfPresent(String.self, forKey: .userRateLimitTier)
                hasExtraUsageEnabled = try? c.decodeIfPresent(Bool.self, forKey: .hasExtraUsageEnabled)
            }

            private enum CodingKeys: String, CodingKey {
                case organizationType, seatTier, billingType, organizationRateLimitTier, userRateLimitTier, hasExtraUsageEnabled
            }
        }

        var oauthAccount: OAuthAccount?
        var hasExtraUsageEnabled: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            oauthAccount = try? c.decodeIfPresent(OAuthAccount.self, forKey: .oauthAccount)
            hasExtraUsageEnabled = try? c.decodeIfPresent(Bool.self, forKey: .hasExtraUsageEnabled)
        }

        private enum CodingKeys: String, CodingKey { case oauthAccount, hasExtraUsageEnabled }

        static func load(_ url: URL) -> ClaudeJSONFields? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        var document: [String: Any] {
            let account: Any = oauthAccount.map { account in
                [
                    "organizationType": account.organizationType as Any? ?? NSNull(),
                    "seatTier": account.seatTier as Any? ?? NSNull(),
                    "billingType": account.billingType as Any? ?? NSNull(),
                    "organizationRateLimitTier": account.organizationRateLimitTier as Any? ?? NSNull(),
                    "userRateLimitTier": account.userRateLimitTier as Any? ?? NSNull(),
                    "hasExtraUsageEnabled": account.hasExtraUsageEnabled as Any? ?? NSNull(),
                ] as [String: Any]
            } ?? NSNull()
            return ["oauthAccount": account, "hasExtraUsageEnabled": hasExtraUsageEnabled as Any? ?? NSNull()]
        }
    }

    /// The names of the `CLAUDE_CODE_*` and `ANTHROPIC_*` keys in a settings file's `env`. Values are never decoded.
    private struct EnvKeyNames: Decodable {
        var names: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let env = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(stringValue: "env"))
            names = (env?.allKeys.map(\.stringValue) ?? [])
                .filter { $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("ANTHROPIC_") }
                .sorted()
        }

        /// nil when the file is missing; an unreadable file reads as no keys.
        static func load(_ url: URL) -> [String]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONDecoder().decode(Self.self, from: data))?.names ?? []
        }

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    // MARK: Codex

    private static func codex(_ account: AccountConfig, context: FetchContext, launcher: any CodexAppServerLaunching) async throws -> Outcome {
        guard let codex = context.cli.locate("codex") else { return .stopped("codex was not found.") }
        var environment = context.cli.baseEnvironment()
        if account.profileDir != nil { environment["CODEX_HOME"] = CodexRollouts.home(for: account, paths: context.paths).path }
        _ = try? context.paths.createProbeDirectory()

        let connection: any CodexAppServerConnection
        do {
            connection = try launcher.launch(executable: codex, arguments: CodexUsageFetcher.arguments, environment: environment, currentDirectory: context.paths.probeDirectory)
        } catch {
            return .stopped("codex could not be started.")
        }
        defer { connection.terminate() }

        var document: [String: Any] = ["capture": ProviderID.codex.rawValue]
        do {
            let line = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: clientVersion, excludeResetCreditDetails: false)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw CodexAppServerError.timeout
                }
                defer { group.cancelAll() }
                guard let line = try await group.next() else { throw CodexAppServerError.exited }
                return line
            }
            document["response"] = (try? JSONSerialization.jsonObject(with: line)) ?? CaptureRedactor.placeholder
        } catch {
            document["error"] = codexErrorKind(error)
            let outcome = CodexUsageFetcher.classify(error)
            document["classifiedAs"] = outcome == .noPlanLimits ? "noPlanLimits" : outcome == .failed(.notSignedIn) ? "notSignedIn" : "other"
        }
        return .document(try CaptureRedactor.render(document, provider: .codex))
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func codexErrorKind(_ error: any Error) -> String {
        if case CodexAppServerError.rpc = error { return "rpc" }
        if case CodexAppServerError.timeout = error { return "timeout" }
        if case CodexAppServerError.malformed = error { return "malformed" }
        if case CodexAppServerError.exited = error { return "exited" }
        return "failed"
    }

    // MARK: Copilot

    /// The fetcher's GET with the capture's own `--jq` program in place of the fetcher's filter.
    static var copilotArguments: [String] {
        Array(CopilotUsageFetcher.arguments.dropLast()) + [CaptureRedactor.jqProgram(for: .copilot, under: "response")]
    }

    static let copilotPhrases = ["http 401", "http 403", "http 404", "http 429", "http 5", "rate limit", "saml", "dial tcp", "no such host", "error connecting to", "i/o timeout"]

    private static func copilot(_ account: AccountConfig, context: FetchContext) async throws -> Outcome {
        guard let gh = context.cli.locate("gh") else { return .stopped("gh was not found.") }
        var environment = context.cli.baseEnvironment().merging(CopilotUsageFetcher.ghEnvironment) { _, gh in gh }
        if let configDir = account.profileDir.map(context.paths.expand) { environment["GH_CONFIG_DIR"] = configDir.path }
        _ = try? context.paths.createProbeDirectory()

        let result: ProcessResult
        do {
            result = try await context.process.run(
                gh, arguments: copilotArguments, environment: environment, currentDirectory: context.paths.probeDirectory,
                stdin: nil, timeout: 20, outputLimit: 256 * 1024
            )
        } catch {
            return .stopped("gh could not be started.")
        }
        let document: [String: Any] = [
            "capture": ProviderID.copilot.rawValue,
            "exitCode": Int(result.exitCode),
            "timedOut": result.timedOut,
            "response": json(result.stdout),
            "stderr": phraseHits(result.stderr, phrases: copilotPhrases),
        ]
        return .document(try CaptureRedactor.render(document, provider: .copilot))
    }

    // MARK: Antigravity

    static let agyPhrases = ["sign in", "eligible", "terms of service", "region", "dial tcp", "no such host", "eof"]

    private static func antigravity(context: FetchContext) async throws -> Outcome {
        guard let agy = context.cli.locate("agy") else { return .stopped("agy was not found.") }
        let environment = context.cli.baseEnvironment()
        _ = try? context.paths.createProbeDirectory()
        let probe = context.paths.probeDirectory

        let check = AntigravityUsageFetcher.versionCommand
        let versionRun: ProcessResult
        do {
            versionRun = try await context.process.run(
                agy, arguments: check.arguments, environment: environment, currentDirectory: probe, stdin: nil,
                timeout: check.timeout, outputLimit: check.outputLimit
            )
        } catch {
            return .stopped("agy could not be started.")
        }
        guard !versionRun.timedOut, versionRun.exitCode == 0,
              let version = AntigravityUsageFetcher.version(in: String(decoding: versionRun.stdout, as: UTF8.self)) else {
            return .stopped("Could not read the agy version, so /usage was not sent.")
        }
        guard AntigravityUsageFetcher.isSupported(version) else {
            return .stopped("agy \(version.map(String.init).joined(separator: ".")) is older than 1.1.11, which can send /usage to the model as a prompt. Nothing else was run.")
        }

        let usage = AntigravityUsageFetcher.usageCommand
        let usageRun: ProcessResult
        do {
            usageRun = try await context.process.run(
                agy, arguments: usage.arguments, environment: environment, currentDirectory: probe, stdin: nil,
                timeout: usage.timeout, outputLimit: usage.outputLimit
            )
        } catch {
            return .stopped("agy could not be started.")
        }
        if usageRun.exitCode == 0, isAgyModelTurn(usageRun.stdout) { return .stopped(modelTurnStop("agy", spends: "quota")) }

        let document: [String: Any] = [
            "capture": ProviderID.antigravity.rawValue,
            "version": version,
            "usage": [
                "exitCode": Int(usageRun.exitCode),
                "timedOut": usageRun.timedOut,
                "stdout": json(usageRun.stdout),
                "stderr": phraseHits(usageRun.stderr, phrases: agyPhrases),
            ] as [String: Any],
        ]
        return .document(try CaptureRedactor.render(document, provider: .antigravity))
    }

    private static func isAgyModelTurn(_ stdout: Data) -> Bool {
        do {
            _ = try AntigravityUsageFetcher.windows(fromUsageOutput: stdout)
            return false
        } catch let error as FetchError {
            return error == .unsupported(AntigravityUsageFetcher.modelTurnMessage)
        } catch {
            return false
        }
    }

    // MARK: OpenCode Go

    private static func opencodeGo(_ account: AccountConfig, context: FetchContext, environment: [String: String]) async throws -> Outcome {
        let dataDirectory = OpenCodeLocalData.dataDirectory(for: account, paths: context.paths, environment: environment)
        let key: String
        do {
            key = try OpenCodeLocalData.apiKey(for: account, secrets: context.secrets, paths: context.paths, dataDirectory: dataDirectory)
        } catch {
            return .stopped("No OpenCode Go key was found in opencode's auth.json or the --credential-file entry.")
        }

        var document: [String: Any] = ["capture": ProviderID.opencodeGo.rawValue]
        do {
            let response = try await context.http.get(OpenCodeGoUsageFetcher.usageURL, headers: ["Authorization": "Bearer \(key)"], timeout: 20)
            document["status"] = response.status
            document["response"] = json(response.body)
        } catch let error as URLError where error.code == .timedOut {
            document["error"] = "timeout"
        } catch {
            document["error"] = "network"
        }
        return .document(try CaptureRedactor.render(document, provider: .opencodeGo))
    }

    // MARK: Shared

    /// The parsed answer, else null for no output, else the text, which the redactor replaces.
    private static func json(_ data: Data) -> Any {
        if data.isEmpty { return NSNull() }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return object }
        // An update notice printed around the payload, as the agy fetcher tolerates.
        let text = String(decoding: data, as: UTF8.self)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) {
            return object
        }
        return text
    }

    /// Which of `phrases` stderr contains, and how many lines it had. Its text can name the account, so none of it is kept.
    static func phraseHits(_ stderr: Data, phrases: [String]) -> [String: Any] {
        let text = String(decoding: stderr, as: UTF8.self)
        let lower = text.lowercased()
        return ["phrases": phrases.filter { lower.contains($0) }, "lines": text.split(whereSeparator: \.isNewline).count]
    }
}
