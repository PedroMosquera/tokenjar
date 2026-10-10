import Foundation

/// Live limits from Google Antigravity's CLI: `agy -p /usage --output-format json`. agy owns its sign-in;
/// this never reads its token files or Keychain items and never talks to the Antigravity app.
public struct AntigravityUsageFetcher: UsageFetcher {
    static let minimumVersion = [1, 1, 11]

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        guard let agy = context.cli.locate("agy") else { throw FetchError.cliNotFound("agy") }
        let environment = context.cli.baseEnvironment()
        let probe = context.paths.probeDirectory
        try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)

        let versionRun = try await context.process.run(
            agy, arguments: ["--version"], environment: environment, currentDirectory: probe,
            stdin: nil, timeout: 15, outputLimit: 64 * 1024
        )
        if versionRun.timedOut { throw FetchError.timeout }
        // agy before 1.1.11 has no non-interactive slash commands and can send "/usage" to the model as a
        // prompt, which spends quota. An unreadable version is refused for the same reason.
        guard let version = Self.version(in: Self.text(versionRun.stdout + versionRun.stderr)) else {
            throw FetchError.unsupported("Could not read the agy version")
        }
        guard Self.isSupported(version) else { throw FetchError.unsupported("Update agy to 1.1.11 or later") }

        let usageRun = try await context.process.run(
            agy, arguments: ["-p", "/usage", "--output-format", "json"], environment: environment,
            currentDirectory: probe, stdin: nil, timeout: 100, outputLimit: 1 << 20
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
    /// First dotted number in `agy --version` output as [major, minor, patch].
    static func version(in text: String) -> [Int]? {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/) else { return nil }
        let parts = [match.1, match.2, match.3 ?? "0"].compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    static func isSupported(_ version: [Int]) -> Bool {
        !version.lexicographicallyPrecedes(minimumVersion)
    }

    // Unverified live: agy was not installed on the build machine. The shape comes from CodexBar's synthetic
    // agy test fixture, {"command":{"data":{"groups":[{"name","buckets":[{"window","remaining_fraction",
    // "reset_time","disabled"}]}]}}}, so `groups` is looked up at any depth and both key casings are accepted.
    static func windows(fromUsageOutput data: Data) throws -> [UsageWindow] {
        guard let root = jsonRoot(data) else { throw FetchError.parse("agy /usage output is not JSON") }
        guard let groups = groups(in: root) else { return [] }
        var windows: [UsageWindow] = []
        var seen: Set<String> = []
        for (index, group) in groups.enumerated() {
            let pool = poolLabel(string(group, "name", "displayName", "display_name", "label", "title") ?? "Pool \(index + 1)")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                if bucket["disabled"] as? Bool == true { continue }
                guard let rawWindow = string(bucket, "window", "windowId", "window_id", "period"),
                      let kind = windowKind(rawWindow),
                      let remaining = number(bucket, "remaining_fraction", "remainingFraction") else { continue }
                let id = "\(slug(pool)):\(kind.id)"
                guard seen.insert(id).inserted else { continue }
                windows.append(UsageWindow(
                    id: id, label: "\(pool) · \(kind.label)", usedPercent: max(0, (1 - remaining) * 100),
                    windowMinutes: kind.minutes, resetsAt: date(bucket, "reset_time", "resetTime", "resetsAt", "resets_at")
                ))
            }
        }
        return windows
    }

    static func windowKind(_ raw: String) -> (id: String, label: String, minutes: Int?)? {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "": return nil
        case "weekly", "week", "7d": return ("weekly", "Week", 10_080)
        case "fivehour", "5hour", "5h", "session": return ("session", "5-hour", 300)
        default: return (key, raw, nil)
        }
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

    /// Breadth-first, so the shallowest `groups` array wins.
    private static func groups(in root: Any) -> [[String: Any]]? {
        var queue: [Any] = [root]
        var next = 0
        while next < queue.count {
            let node = queue[next]
            next += 1
            if let object = node as? [String: Any] {
                if let groups = object["groups"] as? [[String: Any]] { return groups }
                queue.append(contentsOf: object.keys.sorted().compactMap { object[$0] })
            } else if let array = node as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
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
            if let value = object[key] as? String, let date = DateParsing.iso8601(value) ?? Double(value).map(DateParsing.epoch) { return date }
            if let value = object[key] as? Double { return DateParsing.epoch(value) }
        }
        return nil
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
