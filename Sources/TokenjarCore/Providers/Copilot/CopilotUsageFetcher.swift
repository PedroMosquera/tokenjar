import Foundation

/// GitHub Copilot's monthly allowances from the user's own gh CLI: `gh api --method GET copilot_internal/user`, the
/// undocumented endpoint VS Code's Copilot extension reads. gh keeps its token in its own Keychain item and sends the
/// request itself; Tokenjar never reads gh's files or token. The jq filter runs inside gh, so the login, ids and
/// organizations in the response never reach this process.
public struct CopilotUsageFetcher: UsageFetcher {
    public static let source = "gh CLI"
    static let noAccessMessage = "No Copilot access for this GitHub account"

    static let filter = "{copilot_plan, access_type_sku, token_based_billing, quota_reset_date, quota_reset_date_utc, quota_snapshots: ((.quota_snapshots // {}) | map_values({entitlement, remaining, quota_remaining, percent_remaining, unlimited, has_quota, overage_count, overage_permitted, credits_used, token_based_billing})), monthly_quotas: (.monthly_quotas | if type == \"object\" then {chat, completions} else null end), limited_user_quotas: (.limited_user_quotas | if type == \"object\" then {chat, completions} else null end)}"

    /// GET with no field flags: any -f/-F/--input makes gh send a POST, and --cache writes the answer to disk. The API
    /// version is pinned as VS Code pins it, so a new default on this undocumented endpoint cannot change the shape.
    static let arguments = [
        "api", "--method", "GET", "-H", "X-GitHub-Api-Version: 2025-04-01", "copilot_internal/user", "--jq", filter,
    ]

    /// Without GH_TELEMETRY=false every check would also send gh's own telemetry event, with a persistent device id.
    static let ghEnvironment = [
        "GH_TELEMETRY": "false", "DO_NOT_TRACK": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_PROMPT_DISABLED": "1",
    ]

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        guard let gh = context.cli.locate("gh") else { throw FetchError.cliNotFound("gh") }
        var environment = context.cli.baseEnvironment().merging(Self.ghEnvironment) { _, gh in gh }
        if let configDir = account.profileDir.map(context.paths.expand) { environment["GH_CONFIG_DIR"] = configDir.path }
        _ = try? context.paths.createProbeDirectory()

        let result: ProcessResult
        do {
            result = try await context.process.run(
                gh, arguments: Self.arguments, environment: environment, currentDirectory: context.paths.probeDirectory,
                stdin: nil, timeout: 20, outputLimit: 256 * 1024
            )
        } catch {
            throw FetchError.cliNotFound("gh")
        }
        if result.timedOut { throw FetchError.timeout }
        guard result.exitCode == 0 else { throw Self.failure(exitCode: result.exitCode, stderr: result.stderr) }
        return try Self.snapshot(from: result.stdout, account: account, now: context.now())
    }
}

extension CopilotUsageFetcher {
    /// gh exits 4 when it has no login, and 1 with "gh: <message> (HTTP <status>)" when the API refuses. stderr is only
    /// matched, never shown or kept, since it can name the account.
    static func failure(exitCode: Int32, stderr: Data) -> FetchError {
        if exitCode == 4 { return .notSignedIn }
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        // GitHub answers a spent primary rate limit with 403, so the wording decides before the status does.
        if text.contains("http 429") || text.contains("rate limit") { return .rateLimited(retryAfter: nil) }
        if text.contains("http 401") { return .unauthorized }
        if text.contains("http 403") || text.contains("http 404") { return .noSubscription(noAccessMessage) }
        if text.contains(/http 5\d\d/) { return .network("GitHub API unavailable") }
        // Offline, or behind a proxy gh cannot see (the minimal environment drops HTTPS_PROXY): Retry, not an alert.
        if ["error connecting to", "dial tcp", "i/o timeout", "timeout exceeded", "connection reset"].contains(where: text.contains) {
            return .network("gh could not reach GitHub")
        }
        return .parse("gh exited with status \(exitCode)")
    }

    static func snapshot(from stdout: Data, account: AccountConfig, now: Date) throws -> UsageSnapshot {
        guard let json = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else {
            throw FetchError.parse("gh api output is not a JSON object")
        }
        let snapshots = json["quota_snapshots"] as? [String: Any] ?? [:]
        let plan = (json["copilot_plan"] as? String).flatMap(planLabel)
        guard plan != nil || !snapshots.isEmpty else { throw FetchError.parse("gh api output has no Copilot plan or quotas") }

        // Each snapshot's own quota_reset_at is 0 in live answers, so only the account-level date is used.
        let resetsAt = (json["quota_reset_date_utc"] as? String).flatMap(DateParsing.iso8601)
            ?? (json["quota_reset_date"] as? String).flatMap { DateParsing.iso8601("\($0)T00:00:00Z") }
        func window(_ id: String, _ label: String, usedPercent: Double) -> UsageWindow {
            UsageWindow(id: id, label: label, usedPercent: usedPercent, windowMinutes: UsageWindow.monthMinutes(endingAt: resetsAt), resetsAt: resetsAt)
        }

        var windows: [UsageWindow] = []
        var notes: [String] = []
        // VS Code reads `premium_models ?? premium_interactions`: the same allowance under a newer name. The filter
        // turns a null premium_models into an object of nulls, so an empty one falls through like a missing one.
        let premium = ["premium_models", "premium_interactions"].lazy.compactMap { Quota(snapshots[$0]) }.first(where: { !$0.isBlank })
        if let premium {
            // Since 2026-06-01 premium requests are billed as AI credits, still under the old key.
            let credits = json["token_based_billing"] as? Bool == true || premium.tokenBased
            let unit = credits ? "AI credits" : "premium requests"
            if let used = premium.usedPercent {
                windows.append(window("monthly", credits ? "AI credits" : "Premium requests", usedPercent: used))
                if let overage = premium.overageCount, overage > 0 {
                    notes.append("\(count(overage)) \(unit) over the allowance this cycle")
                }
            } else if let used = premium.creditsUsed, premium.unlimited || (credits && (premium.entitlement ?? 0) == 0) {
                // A pooled seat has no per-user budget, so the count is all there is to show. Token-billed Business
                // seats can arrive as a zero-entitlement placeholder without the unlimited flag.
                notes.append("\(count(used)) \(unit) used this cycle (no per-user limit)")
            }
        }

        let isFree = json["access_type_sku"] as? String == "free_limited_copilot"
        for (key, label) in [("chat", "Chat"), ("completions", "Completions")] {
            if let used = Quota(snapshots[key])?.usedPercent {
                windows.append(window("\(key):monthly", label, usedPercent: used))
            } else if isFree, let used = freeUsedPercent(key, monthly: json["monthly_quotas"], remaining: json["limited_user_quotas"]) {
                windows.append(window("\(key):monthly", label, usedPercent: used))
            }
        }

        let known: Set<String> = ["premium_models", "premium_interactions", "chat", "completions"]
        for key in snapshots.keys.sorted() where !known.contains(key) {
            guard let used = Quota(snapshots[key])?.usedPercent else { continue }
            let id = key.lowercased().filter { $0.isLetter || $0.isNumber }
            let words = key.replacingOccurrences(of: "_", with: " ")
            windows.append(window("\(id):monthly", words.prefix(1).uppercased() + words.dropFirst(), usedPercent: used))
        }

        if windows.isEmpty, notes.isEmpty { notes.append("No per-user limits for this account") }
        return UsageSnapshot(
            accountID: account.id, provider: .copilot, plan: plan, windows: windows, fetchedAt: now, source: source, notes: notes
        )
    }

    /// The individual plan names are inferred from VS Code's Copilot extension.
    static func planLabel(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "": nil
        case "free": "Free"
        case "individual": "Pro"
        case "individual_pro": "Pro+"
        case "individual_max": "Max"
        case "business": "Business"
        case "enterprise": "Enterprise"
        default: raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// Copilot Free can send placeholder snapshots and carry its caps in `monthly_quotas`, with what is left in
    /// `limited_user_quotas` (CodexBar and VS Code read them that way; no Free account has been probed).
    private static func freeUsedPercent(_ key: String, monthly: Any?, remaining: Any?) -> Double? {
        guard let total = number((monthly as? [String: Any])?[key]), total > 0,
              let left = number((remaining as? [String: Any])?[key]) else { return nil }
        return min(100, max(0, (total - left) / total * 100))
    }

    private static func count(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
    }

    /// JSON numbers, or numbers sent as strings. JSON booleans also arrive as NSNumber and are refused.
    fileprivate static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { return number.doubleValue }
        if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
        return nil
    }
}

/// One entry of `quota_snapshots`.
private struct Quota {
    var entitlement: Double?
    var quotaRemaining: Double?
    var percentRemaining: Double?
    var unlimited: Bool
    var overageCount: Double?
    var creditsUsed: Double?
    var tokenBased: Bool

    init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        let number = CopilotUsageFetcher.number
        entitlement = number(object["entitlement"])
        quotaRemaining = number(object["quota_remaining"])
        percentRemaining = number(object["percent_remaining"])
        unlimited = object["unlimited"] as? Bool == true
        overageCount = number(object["overage_count"])
        creditsUsed = number(object["credits_used"])
        tokenBased = object["token_based_billing"] as? Bool == true
    }

    var isBlank: Bool {
        !unlimited && entitlement == nil && quotaRemaining == nil && percentRemaining == nil && creditsUsed == nil
    }

    /// nil unless the allowance is capped per user: unlimited ones, and the zero-entitlement placeholders sent for
    /// pooled seats, have no budget to measure against.
    var usedPercent: Double? {
        guard !unlimited, let entitlement, entitlement > 0 else { return nil }
        let used: Double
        if let quotaRemaining {
            used = (entitlement - quotaRemaining) / entitlement * 100
        } else if let percentRemaining {
            used = 100 - percentRemaining
        } else {
            return nil
        }
        // Past 100 only when GitHub counts overage; otherwise a remainder below zero is rounding, not use.
        return min(max(0, used), (overageCount ?? 0) > 0 ? .infinity : 100)
    }
}
