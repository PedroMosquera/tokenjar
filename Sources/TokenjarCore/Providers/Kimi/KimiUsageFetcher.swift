import Foundation

/// Kimi Code limits through the CLI's own `kimi web` server on 127.0.0.1, started for one check and stopped. The CLI
/// reads and refreshes its OAuth login itself. The banner's token persists in the Kimi home's server.token and opens
/// every route of any `kimi web` on that home, so it stays in memory and is never logged, stored or shown.
public struct KimiUsageFetcher: UsageFetcher {
    public static let source = "kimi web"
    /// Port 0 lets the system pick a free port, which the banner then names.
    static let arguments = ["web", "--no-open", "--port", "0"]
    static let usagePath = "/api/v1/oauth/usage"
    static let userInfoPath = "/api/v1/oauth/userinfo"

    /// Without the first, every check sends a `server_started` event. The second stops a self-staged update re-exec,
    /// whose child process `terminate()` cannot reach.
    static let cliEnvironment = ["KIMI_DISABLE_TELEMETRY": "true", "KIMI_CODE_NO_AUTO_UPDATE": "true"]

    let launcher: any CodexAppServerLaunching
    let timeout: TimeInterval

    public init() {
        self.init(launcher: ProcessCodexAppServerLauncher())
    }

    init(launcher: any CodexAppServerLaunching, timeout: TimeInterval = 20) {
        self.launcher = launcher
        self.timeout = timeout
    }

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        try await Self.withServer(account, context: context, launcher: launcher, timeout: timeout) { server in
            let usage = try await Self.get(Self.usagePath, from: server, http: context.http)
            // The plan name is a nicety: a failed userinfo read never fails the check.
            let plan = (try? await Self.get(Self.userInfoPath, from: server, http: context.http, timeout: 5)).flatMap(Self.planName)
            return try Self.snapshot(from: usage, plan: plan, account: account, now: context.now())
        }
    }

    /// Starts `kimi web`, runs `body` once its banner names the port and token, and stops the server however `body` ends.
    static func withServer<T: Sendable>(
        _ account: AccountConfig, context: FetchContext, launcher: any CodexAppServerLaunching, timeout: TimeInterval,
        _ body: @escaping @Sendable (KimiServerBanner) async throws -> T
    ) async throws -> T {
        guard let binary = context.cli.locate("kimi") else { throw FetchError.cliNotFound("kimi") }
        do {
            try context.paths.createProbeDirectory()
        } catch {
            throw FetchError.unsupported("Tokenjar could not prepare its probe folder")
        }
        var environment = context.cli.baseEnvironment().merging(cliEnvironment) { _, own in own }
        if let profileDir = account.profileDir { environment["KIMI_CODE_HOME"] = context.paths.expand(profileDir).path }

        let connection: any CodexAppServerConnection
        do {
            connection = try launcher.launch(
                executable: binary, arguments: arguments, environment: environment, currentDirectory: context.paths.probeDirectory
            )
        } catch {
            throw FetchError.cliNotFound("kimi")
        }
        defer { connection.terminate() }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                guard let server = await KimiServerBanner.read(connection.lines) else {
                    throw FetchError.unsupported("kimi web did not start")
                }
                return try await body(server)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw FetchError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw FetchError.timeout }
            return value
        }
    }

    static func get(_ path: String, from server: KimiServerBanner, http: HTTPClient, timeout: TimeInterval = 15) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(server.port)\(path)") else { throw FetchError.parse("kimi web port") }
        let response: HTTPResponse
        do {
            response = try await http.get(url, headers: ["Authorization": "Bearer \(server.token)"], timeout: timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch {
            throw FetchError.network("kimi web did not answer")
        }
        guard response.status == 200 else { throw FetchError.unsupported("kimi web answered HTTP \(response.status)") }
        return response.body
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        var data: Payload?
    }

    private struct UsageResult: Decodable {
        var kind: String
        var quota: Quota?
        var status: Int?
        var message: String?
    }

    private struct Quota: Decodable {
        var usages: Usages
        var extraUsage: Booster?
    }

    private struct Usages: Decodable {
        var limit5h: Entry?
        var limit7d: Entry?
        var monthTotal: Entry?
        var monthCode: Entry?
    }

    private struct Entry: Decodable {
        var usedRatio: Double
        var resetAt: String?
    }

    private struct Booster: Decodable {
        var balanceCents: Int
        var totalCents: Int
        var currency: String
    }

    static func snapshot(from body: Data, plan: String?, account: AccountConfig, now: Date) throws -> UsageSnapshot {
        guard let result = (try? JSONDecoder().decode(Envelope<UsageResult>.self, from: body))?.data else {
            throw FetchError.parse("kimi usage body has no result")
        }
        guard result.kind == "ok", let quota = result.quota else {
            throw failure(status: result.status, message: result.message ?? "")
        }

        var windows: [UsageWindow] = []
        func add(_ entry: Entry?, id: String, label: String, minutes: Int?) {
            guard let entry else { return }
            let resetsAt = entry.resetAt.flatMap(DateParsing.iso8601)
            windows.append(UsageWindow(
                id: id, label: label, usedPercent: entry.usedRatio * 100,
                windowMinutes: minutes ?? UsageWindow.monthMinutes(endingAt: resetsAt), resetsAt: resetsAt
            ))
        }
        add(quota.usages.limit5h, id: "session", label: "5-hour", minutes: 300)
        add(quota.usages.limit7d, id: "weekly", label: "Week", minutes: 10_080)
        add(quota.usages.monthTotal, id: "monthly", label: "Month", minutes: nil)
        guard !windows.isEmpty else { throw FetchError.parse("kimi usage has no 5-hour, weekly or monthly limit") }

        var notes: [String] = []
        // The month is shared with Kimi's other apps; this is the CLI's own share of it.
        if let code = quota.usages.monthCode, quota.usages.monthTotal != nil {
            notes.append("Kimi Code used \(percent(code.usedRatio)) of the month")
        }
        if let booster = quota.extraUsage, booster.totalCents > 0 {
            notes.append("Booster: \(money(booster.balanceCents, booster.currency)) left of \(money(booster.totalCents, booster.currency))")
        }
        return UsageSnapshot(
            accountID: account.id, provider: .kimi, plan: plan, windows: windows, fetchedAt: now, source: source, notes: notes
        )
    }

    /// The CLI's message is only matched, never shown.
    static func failure(status: Int?, message: String) -> FetchError {
        switch status {
        case 401: return .notSignedIn
        case 404: return .noSubscription("No Kimi Code plan for this login")
        case 429: return .rateLimited(retryAfter: nil)
        default: break
        }
        let text = message.lowercased()
        if ["login", "log in", "logged in", "not authenticated"].contains(where: text.contains) { return .notSignedIn }
        return .network("Kimi could not read the usage")
    }

    private struct UserInfoResult: Decodable {
        var userInfo: UserInfo?
    }

    /// Only the plan name is decoded. The same answer holds the account's email and nickname, which are never read.
    private struct UserInfo: Decodable {
        var userLevelName: String?
    }

    static func planName(_ body: Data) -> String? {
        guard let name = (try? JSONDecoder().decode(Envelope<UserInfoResult>.self, from: body))?.data?.userInfo?.userLevelName,
              !name.isEmpty else { return nil }
        return name
    }

    private static func percent(_ ratio: Double) -> String {
        (ratio * 100).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US"))) + "%"
    }

    private static func money(_ cents: Int, _ currency: String) -> String {
        (Double(cents) / 100).formatted(.currency(code: currency.isEmpty ? "USD" : currency).locale(Locale(identifier: "en_US")))
    }
}

/// Where a started `kimi web` listens, read from the banner it prints on stdout:
/// `Local:    http://127.0.0.1:50659/#token=…` and `Token:    …`.
struct KimiServerBanner: Equatable, Sendable {
    var port: Int
    var token: String

    /// nil when the stream ends before both lines appear.
    static func read(_ lines: AsyncStream<Data>) async -> KimiServerBanner? {
        var port: Int?
        var token: String?
        for await line in lines {
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Local:") {
                let address = text.dropFirst("Local:".count).trimmingCharacters(in: .whitespaces)
                port = URLComponents(string: String(address.prefix { $0 != "#" }))?.port
            } else if text.hasPrefix("Token:") {
                let value = text.dropFirst("Token:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, !value.contains(" ") { token = value }
            }
            if let port, let token { return KimiServerBanner(port: port, token: token) }
        }
        return nil
    }
}
