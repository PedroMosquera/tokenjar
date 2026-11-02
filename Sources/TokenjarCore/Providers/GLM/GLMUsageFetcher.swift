import Foundation

/// Z.ai GLM Coding Plan limits from `GET https://api.z.ai/api/monitor/usage/quota/limit`, sent with the key pasted in
/// Settings. Z.ai's own client sends the key bare in `authorization`, without `Bearer`. The answer shape follows that
/// client's docs and CodexBar's notes until a live answer is captured.
public struct GLMUsageFetcher: UsageFetcher {
    public static let usageURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let noSubscriptionMessage = "No active GLM Coding Plan for this key"

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let key = try PastedKey.apiKey(for: account, secrets: context.secrets, paths: context.paths)
        let response: HTTPResponse
        do {
            response = try await context.http.get(Self.usageURL, headers: ["Authorization": key], timeout: 20)
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
        switch response.status {
        case 200: break
        case 401: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited(retryAfter: response.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value) })
        case 500...599: throw FetchError.network("z.ai API unavailable (HTTP \(response.status))")
        default: throw FetchError.network("z.ai API returned HTTP \(response.status)")
        }
        // A corporate block page or captive portal answers 200 with HTML: that is an unreachable host, not a new shape.
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw FetchError.network("z.ai answered with something other than JSON")
        }
        // Z.ai answers a rejected key with HTTP 200 and `success: false`. Unverified against a live answer.
        if json["success"] as? Bool == false { throw FetchError.unauthorized }
        let data = json["data"] as? [String: Any] ?? [:]
        guard let limits = data["limits"] as? [[String: Any]] else { throw FetchError.parse("quota body has no data.limits") }
        // Only personal-scope requests are sent, so an empty list means the key has no Coding Plan.
        if limits.isEmpty { throw FetchError.noSubscription(noSubscriptionMessage) }

        var windows: [UsageWindow] = []
        for spec in WindowSpec.all {
            guard let entry = limits.first(where: spec.matches), let percent = (entry["percentage"] as? NSNumber)?.doubleValue else { continue }
            let resetsAt = (entry["nextResetTime"] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            windows.append(UsageWindow(
                id: spec.id, label: spec.label, usedPercent: percent,
                windowMinutes: spec.fixedMinutes ?? UsageWindow.monthMinutes(endingAt: resetsAt), resetsAt: resetsAt, notStarted: percent == 0
            ))
        }
        guard !windows.isEmpty else { throw FetchError.parse("quota body has no 5-hour, weekly or tools window") }
        let plan = ["planName", "plan", "plan_type", "packageName", "level"].lazy.compactMap { data[$0] as? String }.first { !$0.isEmpty }
        return UsageSnapshot(
            accountID: account.id, provider: account.provider, plan: plan ?? "GLM Coding Plan", windows: windows, fetchedAt: now, source: "z.ai API"
        )
    }

    /// `unit` 3 is hours, 5 months and 6 weeks, per Z.ai's client. Plan V3 reports the token windows as `CREDIT_LIMIT`.
    private struct WindowSpec {
        var id: String
        var label: String
        var types: Set<String>
        var unit: Int
        var number: Int?
        /// nil for the monthly tools quota, whose length depends on the month.
        var fixedMinutes: Int?

        func matches(_ entry: [String: Any]) -> Bool {
            guard let type = entry["type"] as? String, types.contains(type), (entry["unit"] as? NSNumber)?.intValue == unit else { return false }
            return number.map { (entry["number"] as? NSNumber)?.intValue == $0 } ?? true
        }

        static let tokenTypes: Set<String> = ["TOKENS_LIMIT", "CREDIT_LIMIT"]
        static let all = [
            WindowSpec(id: "session", label: "5-hour", types: tokenTypes, unit: 3, number: 5, fixedMinutes: 300),
            WindowSpec(id: "weekly", label: "Week", types: tokenTypes, unit: 6, number: nil, fixedMinutes: 10_080),
            WindowSpec(id: "mcp:monthly", label: "Tools (MCP)", types: ["TIME_LIMIT"], unit: 5, number: 1, fixedMinutes: nil),
        ]
    }
}
