import Foundation

/// Reads token usage from codex rollout logs in `$CODEX_HOME/sessions` and `archived_sessions`.
///
/// Newer codex writes one `token_usage_record` per response, deduped by response id. Older files only have
/// `token_count` events carrying cumulative session totals, so usage there is the positive difference
/// between consecutive totals. From a file's first `token_usage_record` on, its `token_count` events are
/// ignored, because codex writes both for the same response (record first).
///
/// Lines before any `turn_context` have no model and are not counted: codex writes them for sessions it
/// imported from other agents, which did not run through Codex.
public struct CodexHistoryScanner: HistoryScanner {
    public let name = "codex-rollouts"

    public init() {}

    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        let home = CodexRollouts.home(for: account, paths: paths)
        let files = CodexRollouts.files(in: home.appending(path: "sessions")) + CodexRollouts.files(in: home.appending(path: "archived_sessions"))
        var events: [UsageEvent] = []
        var next: ScanCheckpoints = [:]
        for url in files {
            let key = url.path
            do {
                let (fileEvents, checkpoint) = try Self.scanFile(url, from: checkpoints[key].flatMap(Checkpoint.init), accountID: account.id)
                events += fileEvents
                next[key] = checkpoint.encoded
            } catch {
                if let previous = checkpoints[key] { next[key] = previous }
            }
        }
        return ScanResult(events: events, checkpoints: next)
    }

    /// "inode:offset:input,cached,output,reasoning,total". The totals are the last cumulative `token_count`
    /// usage before `offset`, so the next delta is right after an incremental rescan.
    struct Checkpoint: Equatable {
        var inode: UInt64
        var offset: Int
        var totals: CodexTokenUsage?

        init(inode: UInt64, offset: Int, totals: CodexTokenUsage?) {
            self.inode = inode
            self.offset = offset
            self.totals = totals
        }

        init?(_ encoded: String) {
            let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let inode = UInt64(parts[0]), let offset = Int(parts[1]), offset >= 0 else { return nil }
            self.inode = inode
            self.offset = offset
            let numbers = parts[2].split(separator: ",").compactMap { Int($0) }
            totals = numbers.count == 5
                ? CodexTokenUsage(inputTokens: numbers[0], cachedInputTokens: numbers[1], outputTokens: numbers[2], reasoningOutputTokens: numbers[3], totalTokens: numbers[4])
                : nil
        }

        var encoded: String {
            let t = totals.map { "\($0.inputTokens),\($0.cachedInputTokens),\($0.outputTokens),\($0.reasoningOutputTokens),\($0.totalTokens)" } ?? ""
            return "\(inode):\(offset):\(t)"
        }
    }

    static func scanFile(_ url: URL, from checkpoint: Checkpoint?, accountID: String) throws -> ([UsageEvent], Checkpoint) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0

        var start = 0
        var totals: CodexTokenUsage?
        if let checkpoint, checkpoint.inode == inode, checkpoint.offset <= size {
            if checkpoint.offset == size { return ([], checkpoint) }
            start = checkpoint.offset
            totals = checkpoint.totals
        }

        let data = try Data(contentsOf: url)
        var reader = FileReader(fileName: url.lastPathComponent, accountID: accountID, totals: totals)
        var end = start
        for range in CodexRollouts.lineRanges(in: data) {
            reader.read(data[range], at: range.lowerBound, counting: range.lowerBound >= start)
            end = max(end, range.upperBound + 1)
        }
        return (reader.events, Checkpoint(inode: inode, offset: end, totals: reader.totals))
    }

    /// Walks one rollout in order. Lines before the checkpoint are read only for context (model, project,
    /// whether records have started); lines after it also produce events.
    struct FileReader {
        let fileName: String
        let accountID: String
        var totals: CodexTokenUsage?
        var model: String?
        var project: String?
        var recordsStarted = false
        var events: [UsageEvent] = []

        init(fileName: String, accountID: String, totals: CodexTokenUsage?) {
            self.fileName = fileName
            self.accountID = accountID
            self.totals = totals
        }

        private static let turnContext = Data("\"turn_context\"".utf8)
        private static let sessionMeta = Data("\"session_meta\"".utf8)
        private static let usageRecord = Data("\"token_usage_record\"".utf8)
        private static let tokenCount = Data("\"token_count\"".utf8)

        mutating func read(_ line: Data, at offset: Int, counting: Bool) {
            let relevant = CodexRollouts.contains(line, Self.turnContext) || CodexRollouts.contains(line, Self.sessionMeta)
                || CodexRollouts.contains(line, Self.usageRecord) || (counting && CodexRollouts.contains(line, Self.tokenCount))
            guard relevant, let decoded = CodexRolloutLine.decode(line), let payload = decoded.payload else { return }

            switch decoded.type {
            case "session_meta":
                if let cwd = payload.cwd { project = Self.projectName(cwd) }
            case "turn_context":
                if let model = payload.model, !model.isEmpty { self.model = model }
                if let cwd = payload.cwd { project = Self.projectName(cwd) }
            case "token_usage_record":
                recordsStarted = true
                guard counting, let usage = payload.usage else { return }
                let key = payload.responseId.map { "codex:\($0)" } ?? "codex:\(fileName):@\(offset)"
                append(usage, key: key, at: decoded.date)
            case "event_msg" where payload.type == "token_count":
                guard counting, !recordsStarted, let info = payload.info, let current = info.totalTokenUsage else { return }
                countDelta(to: current, contextWindow: info.modelContextWindow, at: decoded.date)
            default:
                return
            }
        }

        private mutating func countDelta(to current: CodexTokenUsage, contextWindow: Int?, at date: Date?) {
            let previous = totals ?? CodexTokenUsage()
            totals = current
            // Only strictly rising totals count, which also keeps the total-based keys below unique within a file.
            guard current.totalTokens > previous.totalTokens else { return }
            // codex's fill_to_context_window sets the session total to the window size without a model call.
            if let contextWindow, current.totalTokens == contextWindow, current.outputTokens <= previous.outputTokens { return }
            // Keyed by the cumulative total rather than the byte offset: codex has rewritten rollouts in place, which
            // moves offsets but keeps totals.
            append(current.subtracting(previous), key: "codex:\(fileName):\(current.totalTokens)", at: date)
        }

        private mutating func append(_ usage: CodexTokenUsage, key: String, at date: Date?) {
            guard let model, let date else { return }
            let cached = max(0, usage.cachedInputTokens)
            let input = max(0, usage.inputTokens - cached)
            let output = max(0, usage.outputTokens)
            guard input + cached + output > 0 else { return }
            events.append(UsageEvent(
                dedupeKey: key, timestamp: date, accountID: accountID, harness: .codex, model: model, project: project,
                inputTokens: input, outputTokens: output, cacheReadTokens: cached,
                reasoningTokens: max(0, usage.reasoningOutputTokens)
            ))
        }

        static func projectName(_ cwd: String) -> String? {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty || name == "/" ? nil : name
        }
    }
}
