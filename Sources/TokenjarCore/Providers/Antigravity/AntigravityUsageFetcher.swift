import Foundation

/// Live limits from Google Antigravity's CLI: `agy -p /usage --output-format json`. agy owns its sign-in;
/// this never reads its token files or Keychain items and never talks to the Antigravity app.
public struct AntigravityUsageFetcher: UsageFetcher {
    static let minimumVersion = [1, 1, 11]
    /// What a check runs, shared with `--capture antigravity` so a capture sends agy exactly what the app sends.
    static let versionCommand = (arguments: ["--version"], timeout: TimeInterval(15), outputLimit: 64 * 1024)
    static let usageCommand = (arguments: ["-p", "/usage", "--output-format", "json"], timeout: TimeInterval(100), outputLimit: 1 << 20)
    public static let modelTurnMessage = "Antigravity ran /usage as a prompt, which spends quota. Checks for this account are paused until agy updates or you click Try Once More."

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        guard let agy = context.cli.locate("agy") else { throw FetchError.cliNotFound("agy") }
        let environment = context.cli.baseEnvironment()
        let probe = context.paths.probeDirectory
        _ = try? context.paths.createProbeDirectory()

        let versionRun = try await context.process.run(
            agy, arguments: Self.versionCommand.arguments, environment: environment, currentDirectory: probe,
            stdin: nil, timeout: Self.versionCommand.timeout, outputLimit: Self.versionCommand.outputLimit
        )
        if versionRun.timedOut { throw FetchError.timeout }
        // agy before 1.1.11 has no non-interactive slash commands and can send "/usage" to the model as a
        // prompt, which spends quota. A failed or unreadable version check is refused for the same reason.
        guard versionRun.exitCode == 0, let version = Self.version(in: Self.text(versionRun.stdout)) else {
            throw FetchError.unsupported("Could not read the agy version")
        }
        guard Self.isSupported(version) else { throw FetchError.unsupported("Update agy to 1.1.11 or later") }

        let usageRun = try await context.process.run(
            agy, arguments: Self.usageCommand.arguments, environment: environment,
            currentDirectory: probe, stdin: nil, timeout: Self.usageCommand.timeout, outputLimit: Self.usageCommand.outputLimit
        )
        if usageRun.timedOut { throw FetchError.timeout }
        guard usageRun.exitCode == 0 else {
            if Self.mentionsSignIn(Self.text(usageRun.stdout + usageRun.stderr)) { throw FetchError.notSignedIn }
            throw FetchError.parse("agy exited with status \(usageRun.exitCode)")
        }
        let windows = try Self.windows(fromUsageOutput: usageRun.stdout)
        return UsageSnapshot(
            accountID: account.id, provider: .antigravity, windows: windows, fetchedAt: context.now(),
            source: "agy CLI", notes: windows.isEmpty ? ["No usage limits reported for this account"] : []
        )
    }
}

extension AntigravityUsageFetcher {
    /// [major, minor, patch] from `agy --version` output: the first line that names agy before its version,
    /// else the first line that holds only a version. Any other dotted number (a runtime, a URL) is ignored.
    static func version(in text: String) -> [Int]? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let named = /(?:agy|antigravity(?:\s+cli)?)(?:\s+version)?[\s\/:]*v?(\d+)\.(\d+)(?:\.(\d+))?(?:[\s(+-].*)?/.ignoresCase()
        let bare = /v?(\d+)\.(\d+)(?:\.(\d+))?/
        guard let match = lines.lazy.compactMap({ $0.wholeMatch(of: named) }).first
            ?? lines.lazy.compactMap({ $0.wholeMatch(of: bare) }).first else { return nil }
        let parts = [match.1, match.2, match.3 ?? "0"].compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    static func isSupported(_ version: [Int]) -> Bool {
        !version.lexicographicallyPrecedes(minimumVersion)
    }

    // Unverified live: agy was not installed on the build machine. The shape comes from CodexBar's synthetic
    // agy test fixture, {"command":{"data":{"groups":[{"name","buckets":[{"window","remaining_fraction",
    // "reset_time","disabled"}]}]}}}, so `groups` is looked up at any depth and both key casings are accepted.
    /// An empty result means agy reported no limits: a `groups` array with no enabled buckets, or a `data.message`
    /// saying usage is not available. Anything else without `groups` throws, so a renamed field shows up as a broken
    /// source rather than as an account without limits, and a model reply says the probe spent quota.
    static func windows(fromUsageOutput data: Data) throws -> [UsageWindow] {
        guard let root = jsonRoot(data) else { throw FetchError.parse("agy /usage output is not JSON") }
        guard let groups = firstValue(forKey: "groups", in: root, as: [[String: Any]].self) else {
            if let error = firstValue(forKey: "error", in: root, as: Any.self).flatMap(errorText) {
                if mentionsSignIn(error) { throw FetchError.notSignedIn }
                throw FetchError.parse("agy /usage reported an error")
            }
            if let message = firstValue(forKey: "data", in: root, as: [String: Any].self)?["message"] as? String, !message.isEmpty {
                return []
            }
            if isModelReply(root) { throw FetchError.unsupported(modelTurnMessage) }
            throw FetchError.parse("agy /usage has no groups")
        }
        var windows: [UsageWindow] = []
        var seen: Set<String> = []
        var unrecognized = 0
        for (index, group) in groups.enumerated() {
            let pool = poolLabel(string(group, "name", "displayName", "display_name", "label", "title") ?? "Pool \(index + 1)")
            guard let buckets = group["buckets"] as? [[String: Any]] else {
                unrecognized += 1
                continue
            }
            for bucket in buckets {
                if bucket["disabled"] as? Bool == true { continue }
                guard let rawWindow = string(bucket, "window", "windowId", "window_id", "period"),
                      let kind = windowKind(rawWindow),
                      let remaining = number(bucket, "remaining_fraction", "remainingFraction"),
                      (0...1).contains(remaining) else {
                    unrecognized += 1
                    continue
                }
                let id = "\(slug(pool)):\(kind.id)"
                guard seen.insert(id).inserted else { continue }
                windows.append(UsageWindow(
                    id: id, label: "\(pool) · \(kind.label)", usedPercent: (1 - remaining) * 100,
                    windowMinutes: kind.minutes, resetsAt: date(bucket, "reset_time", "resetTime", "resetsAt", "resets_at")
                ))
            }
        }
        if windows.isEmpty, unrecognized > 0 { throw FetchError.parse("agy /usage buckets not recognized") }
        return windows
    }

    static func windowKind(_ raw: String) -> (id: String, label: String, minutes: Int?)? {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "": return nil
        case "weekly", "week", "7d", "7day", "sevenday": return ("weekly", "Week", 10_080)
        case "fivehour", "fivehours", "5hour", "5hours", "5h", "session": return ("session", "5-hour", 300)
        default: return (key, raw, nil)
        }
    }

    /// Any top-level marker of the headless reply agy and Gemini CLI print when a prompt reached the model: `response`
    /// text, a `stats` object or a `num_turns` count. agy answers a local slash command in that same envelope, with
    /// `num_turns` 0 and a `command` object, so that shape is a model reply only when it also shows something spent.
    private static func isModelReply(_ root: Any) -> Bool {
        guard let object = root as? [String: Any] else { return false }
        let stats = object["stats"] is [String: Any]
        let spentTokens = (object["usage"] as? [String: Any])?.values.contains { ($0 as? Double ?? 0) > 0 } == true
        if object["num_turns"] as? Double == 0, object["command"] is [String: Any], !stats, !spentTokens { return false }
        return object["response"] is String || stats || object["num_turns"] != nil
    }

    static func mentionsSignIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["sign in", "sign-in", "signed in", "log in", "logged in", "login", "authenticat"].contains { lower.contains($0) }
    }

    private static func jsonRoot(_ data: Data) -> Any? {
        if let root = try? JSONSerialization.jsonObject(with: data) { return root }
        // Tolerates an update notice or warning printed around the payload.
        let output = text(data)
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))
    }

    /// Breadth-first, so the shallowest `key` holding a `T` wins.
    private static func firstValue<T>(forKey key: String, in root: Any, as type: T.Type) -> T? {
        var queue: [Any] = [root]
        var next = 0
        while next < queue.count {
            let node = queue[next]
            next += 1
            if let object = node as? [String: Any] {
                if let value = object[key], let match = value as? T { return match }
                queue.append(contentsOf: object.keys.sorted().compactMap { object[$0] })
            } else if let array = node as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
    }

    /// Only for matching sign-in wording; never logged or shown, since agy may echo account details here.
    private static func errorText(_ value: Any) -> String? {
        if let message = value as? String { return message.isEmpty ? nil : message }
        guard let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return text(data)
    }

    private static func poolLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasSuffix(" models") ? String(trimmed.dropLast(" models".count)) : trimmed
    }

    private static func slug(_ label: String) -> String {
        label.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }

    private static func number(_ object: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = object[key] as? Double, value.isFinite { return value }
            if let value = (object[key] as? String).flatMap(Double.init), value.isFinite { return value }
        }
        return nil
    }

    private static func date(_ object: [String: Any], _ keys: String...) -> Date? {
        for key in keys {
            if let value = object[key] as? String, let date = isoDate(value) ?? Double(value).map(DateParsing.epoch) { return date }
            if let value = object[key] as? Double { return DateParsing.epoch(value) }
        }
        return nil
    }

    /// agy's timestamps are UTC, and a string without a zone designator is read as such.
    private static func isoDate(_ value: String) -> Date? {
        if let date = DateParsing.iso8601(value) { return date }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let t = trimmed.firstIndex(of: "T"), !trimmed[t...].contains(where: { "Zz+-".contains($0) }) else { return nil }
        return DateParsing.iso8601(trimmed + "Z")
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
