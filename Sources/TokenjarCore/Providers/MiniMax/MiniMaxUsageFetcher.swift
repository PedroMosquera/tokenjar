import Foundation

/// MiniMax Token Plan limits from `GET https://api.minimax.io/v1/token_plan/remains`, sent with the plan key pasted in
/// Settings as a Bearer token. The answer shape follows CodexBar's reading until a live answer is captured: one
/// `model_remains` entry per model, whose `*_usage_count` fields count what remains, not what was used.
public struct MiniMaxUsageFetcher: UsageFetcher {
    public static let usageURL = URL(string: "https://api.minimax.io/v1/token_plan/remains")!
    static let noSubscriptionMessage = "No active MiniMax Token Plan for this key"

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let key = try PastedKey.apiKey(for: account, secrets: context.secrets, paths: context.paths)
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
        switch response.status {
        case 200: break
        case 401: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited(retryAfter: response.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value) })
        case 500...599: throw FetchError.network("MiniMax API unavailable (HTTP \(response.status))")
        default: throw FetchError.network("MiniMax API returned HTTP \(response.status)")
        }
        // A corporate block page or captive portal answers 200 with HTML: that is an unreachable host, not a new shape.
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw FetchError.network("MiniMax answered with something other than JSON")
        }
        if let base = json["base_resp"] as? [String: Any], let code = (base["status_code"] as? NSNumber)?.intValue, code != 0 {
            throw bodyError(code: code, message: (base["status_msg"] as? String) ?? (base["status_message"] as? String) ?? "")
        }
        guard let models = json["model_remains"] as? [[String: Any]] else { throw FetchError.parse("remains body has no model_remains") }

        var pools: [Pool] = []
        for model in models {
            guard let name = model["model_name"] as? String, isText(name) else { continue }
            let readings = Lane.allCases.compactMap { lane -> Reading? in
                guard let used = lane.used(in: model) else { return nil }
                return Reading(lane: lane, used: used, resetsAt: lane.resetsAt(in: model))
            }
            if !readings.isEmpty { pools.append(Pool(name: name, readings: readings)) }
        }
        guard !pools.isEmpty else { throw FetchError.parse("remains body has no text model with a 5-hour or weekly quota") }
        let pooled = pools.count > 1
        var windows: [UsageWindow] = []
        for pool in pools {
            for reading in pool.readings {
                windows.append(UsageWindow(
                    id: pooled ? "\(slug(pool.name)):\(reading.lane.id)" : reading.lane.id,
                    label: pooled ? "\(pool.name) · \(reading.lane.label)" : reading.lane.label,
                    usedPercent: reading.used, windowMinutes: reading.lane.minutes, resetsAt: reading.resetsAt, notStarted: reading.used == 0
                ))
            }
        }
        return UsageSnapshot(accountID: account.id, provider: account.provider, plan: "Token Plan", windows: windows, fetchedAt: now, source: "minimax API")
    }

    /// MiniMax answers errors with HTTP 200 and a non-zero `base_resp.status_code`; only the message tells them apart.
    private static func bodyError(code: Int, message: String) -> FetchError {
        let text = message.lowercased()
        if text.contains("plan") || text.contains("subscription") { return .noSubscription(noSubscriptionMessage) }
        if ["key", "auth", "token"].contains(where: text.contains) { return .unauthorized }
        return .network("MiniMax API error \(code)")
    }

    /// The Token Plan also lists speech, image, video and music quotas, which are not coding limits.
    private static func isText(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return !["speech", "image", "video", "music", "voice", "hailuo"].contains(where: lowered.contains)
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private struct Pool {
        var name: String
        var readings: [Reading]
    }

    private struct Reading {
        var lane: Lane
        var used: Double
        var resetsAt: Date?
    }

    private enum Lane: CaseIterable {
        case interval, weekly

        var id: String { self == .interval ? "session" : "weekly" }
        var label: String { self == .interval ? "5-hour" : "Week" }
        var minutes: Int { self == .interval ? 300 : 10_080 }
        private var prefix: String { self == .interval ? "current_interval" : "current_weekly" }
        private var boostKeys: [String] { self == .interval ? ["interval_boost_permill", "interval_boost_permille"] : ["weekly_boost_permill", "weekly_boost_permille"] }
        private var endKey: String { self == .interval ? "end_time" : "weekly_end_time" }

        /// An explicit percent wins; otherwise the remaining count against the total, raised by any boost.
        func used(in model: [String: Any]) -> Double? {
            if let used = number(model["\(prefix)_used_percent"]) { return used }
            if let remaining = number(model["\(prefix)_remaining_percent"]) { return 100 - remaining }
            guard let base = number(model["\(prefix)_total_count"]), base > 0, let remaining = number(model["\(prefix)_usage_count"]) else { return nil }
            let boost = boostKeys.lazy.compactMap { number(model[$0]) }.first ?? 0
            let total = base * (1000 + boost) / 1000
            return max(0, min(100, (total - remaining) / total * 100))
        }

        func resetsAt(in model: [String: Any]) -> Date? {
            number(model[endKey]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }

        private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    }
}
