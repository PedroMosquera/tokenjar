import Foundation

/// Reads Codex limits by asking the user's own `codex app-server`, which owns the ChatGPT credentials and
/// their refresh. Headroom never sees a token. When the CLI is missing or the server fails, the last limits
/// codex wrote to a session log are shown instead, dated when they were logged so the UI marks them stale.
public struct CodexUsageFetcher: UsageFetcher {
    static let arguments = ["-s", "read-only", "-a", "never", "app-server"]
    static let source = "codex app-server"
    static let noPlanLimitsNote = "No plan limits for this login"

    let launcher: any CodexAppServerLaunching
    let timeout: TimeInterval
    let clientVersion: String

    public init() {
        self.init(launcher: ProcessCodexAppServerLauncher())
    }

    init(
        launcher: any CodexAppServerLaunching, timeout: TimeInterval = 20,
        clientVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    ) {
        self.launcher = launcher
        self.timeout = timeout
        self.clientVersion = clientVersion
    }

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let home = CodexRollouts.home(for: account, paths: context.paths)
        let fallback = { CodexRollouts.lastLoggedSnapshot(codexHome: home, accountID: account.id, now: context.now()) }

        guard let binary = context.cli.locate("codex") else {
            if let logged = fallback() { return logged }
            throw FetchError.cliNotFound("codex")
        }

        var environment = context.cli.baseEnvironment()
        if account.profileDir != nil { environment["CODEX_HOME"] = home.path }
        let directory = context.paths.probeDirectory

        do {
            try context.paths.createProbeDirectory()
            let line = try await readRateLimits(binary: binary, environment: environment, directory: directory)
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
                  let snapshot = CodexRateLimitMapping.snapshot(
                      from: envelope.result, accountID: account.id, fetchedAt: context.now(), source: Self.source
                  )
            else { throw CodexAppServerError.malformed }
            return snapshot
        } catch {
            switch Self.classify(error) {
            case .noPlanLimits:
                return UsageSnapshot(accountID: account.id, provider: .codex, fetchedAt: context.now(), source: Self.source, notes: [Self.noPlanLimitsNote])
            case .failed(.notSignedIn):
                throw FetchError.notSignedIn
            case .failed(let fetchError):
                if let logged = fallback() { return logged }
                throw fetchError
            }
        }
    }

    private func readRateLimits(binary: URL, environment: [String: String], directory: URL) async throws -> Data {
        let connection = try launcher.launch(executable: binary, arguments: Self.arguments, environment: environment, currentDirectory: directory)
        defer { connection.terminate() }
        let clientVersion = self.clientVersion, timeout = self.timeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: clientVersion) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CodexAppServerError.timeout
            }
            defer { group.cancelAll() }
            guard let line = try await group.next() else { throw CodexAppServerError.exited }
            return line
        }
    }

    enum Outcome: Equatable {
        case noPlanLimits
        case failed(FetchError)
    }

    /// Maps a failure to what the card shows. Raw server messages are matched here and never displayed.
    static func classify(_ error: any Error) -> Outcome {
        switch error {
        case CodexAppServerError.rpc(_, let message):
            let text = message.lowercased()
            // API-key logins have no plan limits; codex refuses the read with this wording.
            if text.contains("chatgpt authentication required") { return .noPlanLimits }
            let signedOut = ["codex account authentication required", "not logged in", "not signed in", "log in again", "login again", "401", "unauthorized"]
            if signedOut.contains(where: text.contains) { return .failed(.notSignedIn) }
            return .failed(.network("codex rate limit request failed"))
        case CodexAppServerError.timeout:
            return .failed(.timeout)
        case CodexAppServerError.malformed:
            return .failed(.parse("codex rate limit response"))
        default:
            return .failed(.unsupported("Codex app-server did not answer"))
        }
    }

    private struct Envelope: Decodable {
        var result: CodexRateLimitsResult
    }
}
