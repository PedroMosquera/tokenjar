import Foundation

/// The fields Headroom reads from one line of a codex rollout log (`$CODEX_HOME/sessions/**/rollout-*.jsonl`).
/// Only counts, model ids, timestamps, the working directory and rate limits are declared, so message
/// text, instructions and account ids are never decoded into memory that outlives the line.
struct CodexRolloutLine: Decodable {
    struct Payload: Decodable {
        var type: String?
        var model: String?
        var cwd: String?
        var info: Info?
        var rateLimits: CodexRateLimitSnapshot?
        var responseId: String?
        var usage: CodexTokenUsage?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.codexLenient(String.self, .type)
            model = c.codexLenient(String.self, .model)
            cwd = c.codexLenient(String.self, .cwd)
            info = c.codexLenient(Info.self, .info)
            rateLimits = c.codexLenient(CodexRateLimitSnapshot.self, .rateLimits)
            responseId = c.codexLenient(String.self, .responseId)
            usage = c.codexLenient(CodexTokenUsage.self, .usage)
        }

        private enum CodingKeys: String, CodingKey {
            case type, model, cwd, info, rateLimits, responseId, usage
        }
    }

    struct Info: Decodable {
        var totalTokenUsage: CodexTokenUsage?
        var modelContextWindow: Int?
    }

    var timestamp: String?
    var type: String?
    var payload: Payload?

    static func decode(_ line: Data) -> CodexRolloutLine? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(CodexRolloutLine.self, from: line)
    }

    var date: Date? { timestamp.flatMap(DateParsing.iso8601) }
}

/// Token counts in codex's shape. `cachedInputTokens` is a subset of `inputTokens`, and
/// `reasoningOutputTokens` a subset of `outputTokens`.
struct CodexTokenUsage: Decodable, Sendable, Equatable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var reasoningOutputTokens = 0
    var totalTokens = 0

    init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0, reasoningOutputTokens: Int = 0, totalTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = c.codexLenient(Int.self, .inputTokens) ?? 0
        cachedInputTokens = c.codexLenient(Int.self, .cachedInputTokens) ?? 0
        outputTokens = c.codexLenient(Int.self, .outputTokens) ?? 0
        reasoningOutputTokens = c.codexLenient(Int.self, .reasoningOutputTokens) ?? 0
        totalTokens = c.codexLenient(Int.self, .totalTokens) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens, totalTokens
    }

    /// Field-wise `self - earlier`, clamped at zero.
    func subtracting(_ earlier: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            inputTokens: max(0, inputTokens - earlier.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - earlier.cachedInputTokens),
            outputTokens: max(0, outputTokens - earlier.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - earlier.reasoningOutputTokens),
            totalTokens: max(0, totalTokens - earlier.totalTokens)
        )
    }
}

enum CodexRollouts {
    static func home(for account: AccountConfig, paths: AppPaths) -> URL {
        account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".codex")
    }

    /// Every `rollout-*.jsonl` below `directory`, at any depth.
    static func files(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Ranges of newline-terminated lines. A trailing line without a newline is still being written and is left out.
    static func lineRanges(in data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(hit))
                ranges.append(start..<end)
                start = end + 1
            }
        }
        return ranges
    }

    static func contains(_ line: Data, _ needle: Data) -> Bool {
        line.range(of: needle) != nil
    }

    /// The last rate limits codex logged in the most recently modified rollout that has any, as a snapshot dated
    /// when codex wrote them. Windows that have reset since are dropped; nil when none are left.
    static func lastLoggedSnapshot(codexHome: URL, accountID: String, now: Date, filesToTry: Int = 8) -> UsageSnapshot? {
        let sessions = codexHome.appending(path: "sessions")
        let newestFirst = files(in: sessions)
            .map { url in (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        for url in newestFirst.prefix(filesToTry) {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard var snapshot = lastLoggedSnapshot(in: data, accountID: accountID) else { continue }
            snapshot.windows.removeAll { ($0.resetsAt ?? .distantFuture) <= now }
            guard !snapshot.windows.isEmpty else { return nil }
            return snapshot
        }
        return nil
    }

    static let sessionLogSource = "Codex session log"
    static let sessionLogNote = "Live check unavailable; showing the last limits Codex logged."

    /// Newest `rate_limits` per limit id in one rollout, read from the end.
    static func lastLoggedSnapshot(in data: Data, accountID: String) -> UsageSnapshot? {
        let tokenCount = Data("token_count".utf8), rateLimits = Data("rate_limits".utf8)
        var byID: [String: CodexRateLimitSnapshot] = [:]
        var newest: Date?
        for range in lineRanges(in: data).reversed() {
            let line = data[range]
            guard contains(line, tokenCount), contains(line, rateLimits),
                  let decoded = CodexRolloutLine.decode(line), decoded.type == "event_msg",
                  decoded.payload?.type == "token_count", let limits = decoded.payload?.rateLimits, let date = decoded.date
            else { continue }
            let id = limits.limitId ?? CodexRateLimitMapping.mainLimitID
            guard byID[id] == nil else { continue }
            byID[id] = limits
            newest = max(newest ?? date, date)
            if byID[CodexRateLimitMapping.mainLimitID] != nil { break }
        }
        guard let newest else { return nil }
        let result = CodexRateLimitsResult(rateLimits: byID[CodexRateLimitMapping.mainLimitID], rateLimitsByLimitId: byID)
        guard var snapshot = CodexRateLimitMapping.snapshot(from: result, accountID: accountID, fetchedAt: newest, source: sessionLogSource) else {
            return nil
        }
        snapshot.notes.append(sessionLogNote)
        return snapshot
    }
}
