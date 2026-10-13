import Foundation

/// OpenCode Go limits from `GET https://opencode.ai/zen/go/v1/usage`, the only request the app sends with a key.
/// The API key comes from the account's credential, else from opencode's auth.json; it is sent only in the
/// Authorization header and never logged or returned.
public struct OpenCodeGoUsageFetcher: UsageFetcher {
    public static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    let environment: [String: String]

    public init() {
        self.init(environment: ProcessInfo.processInfo.environment)
    }

    init(environment: [String: String]) {
        self.environment = environment
    }

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let dataDirectory = OpenCodeLocalData.dataDirectory(for: account, paths: context.paths, environment: environment)
        let key = try OpenCodeLocalData.apiKey(for: account, secrets: context.secrets, paths: context.paths, dataDirectory: dataDirectory)
        let response: HTTPResponse
        do {
            response = try await context.http.get(Self.usageURL, headers: ["Authorization": "Bearer \(key)"], timeout: 20)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch let error as URLError {
            throw FetchError.network("URLError \(error.code.rawValue)")
        } catch {
            throw FetchError.network(String(describing: type(of: error)))
        }
        return try Self.snapshot(from: response, account: account, now: context.now())
    }

    static func snapshot(from response: HTTPResponse, account: AccountConfig, now: Date) throws -> UsageSnapshot {
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        if let error = errorKind(json) {
            switch error {
            case .entitlement: throw FetchError.noSubscription(noSubscriptionMessage)
            case .auth: throw FetchError.unauthorized
            case .rateLimit: throw FetchError.rateLimited(retryAfter: retryAfter(response))
            }
        }
        switch response.status {
        case 200: break
        case 401: throw FetchError.unauthorized
        // A bad key is 401. 403 means the key is valid but its workspace has no Go plan: never report it as a bad key.
        case 403: throw FetchError.noSubscription(noSubscriptionMessage)
        case 429: throw FetchError.rateLimited(retryAfter: retryAfter(response))
        case 500...599: throw FetchError.network("OpenCode API unavailable (HTTP \(response.status))")
        default: throw FetchError.network("OpenCode API returned HTTP \(response.status)")
        }
        guard let json else { throw FetchError.parse("usage body is not a JSON object") }

        let usage = json["usage"] as? [String: Any] ?? json
        var windows: [UsageWindow] = []
        var notes: [String] = []
        for spec in WindowSpec.all {
            guard let raw = usage[spec.key] as? [String: Any], let percent = (raw["percent"] as? NSNumber)?.doubleValue else { continue }
            let resetsAt = (raw["resetsAt"] as? String).flatMap(DateParsing.iso8601)
            let limited = (raw["status"] as? String) == "rate-limited"
            // An idle window reports 0 with a reset time the server made up, so its countdown means nothing.
            let notStarted = percent == 0 && !limited
            windows.append(UsageWindow(
                id: spec.id, label: spec.label, usedPercent: percent, windowMinutes: spec.fixedMinutes ?? UsageWindow.monthMinutes(endingAt: resetsAt),
                resetsAt: resetsAt, notStarted: notStarted
            ))
            if limited { notes.append("\(spec.limitName) limit reached") }
        }
        guard !windows.isEmpty else { throw FetchError.parse("usage body has no rolling, weekly or monthly window") }
        return UsageSnapshot(
            accountID: account.id, provider: account.provider, plan: "Go", windows: windows,
            fetchedAt: now, source: "opencode API", notes: notes
        )
    }

    static let noSubscriptionMessage = "No active OpenCode Go subscription for this key"

    private struct WindowSpec {
        var key: String
        var id: String
        var label: String
        var limitName: String
        /// nil for the monthly window, whose length depends on the month.
        var fixedMinutes: Int?

        static let all = [
            WindowSpec(key: "rolling", id: "session", label: "5-hour", limitName: "5-hour", fixedMinutes: 300),
            WindowSpec(key: "weekly", id: "weekly", label: "Week", limitName: "Weekly", fixedMinutes: 10_080),
            WindowSpec(key: "monthly", id: "monthly", label: "Month", limitName: "Monthly", fixedMinutes: nil),
        ]
    }

    enum ErrorKind {
        case auth, entitlement, rateLimit
    }

    /// Classic bodies carry `{"error": {"type": "AuthError"}}`; migrated v2 Console workspaces answer with
    /// `{"_tag": "..."}`. Only names that clearly mean auth, entitlement or rate limiting are classified;
    /// anything else falls through to the HTTP status.
    static func errorKind(_ json: [String: Any]?) -> ErrorKind? {
        guard let json else { return nil }
        let name = ((json["error"] as? [String: Any])?["type"] as? String) ?? (json["_tag"] as? String)
        guard let name else { return nil }
        let normalized = name.lowercased().filter(\.isLetter)
        if normalized.contains("entitlement") || normalized.contains("subscription") { return .entitlement }
        if normalized.contains("ratelimit") || normalized.contains("toomanyrequests") { return .rateLimit }
        if normalized.contains("auth") { return .auth }
        return nil
    }

    private static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        response.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value) }
    }
}
