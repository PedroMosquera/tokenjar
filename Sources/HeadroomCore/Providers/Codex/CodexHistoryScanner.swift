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

    /// Where the next scan of a rollout resumes: the byte offset after the last complete line, plus what the
    /// lines before it established, so only the tail is read. A changed inode or a file shorter than `offset`
    /// means codex replaced or truncated the rollout, and the scan starts over.
    struct Checkpoint: Codable, Equatable {
        var inode: UInt64
        var offset: Int
        var context: Context
    }

    /// `totals` is the last cumulative `token_count` usage, so the first delta after a checkpoint is right.
    struct Context: Codable, Equatable {
        var totals: CodexTokenUsage?
        var model: String?
        var project: String?
        var recordsStarted = false
    }

    static func scanFile(_ url: URL, from checkpoint: Checkpoint?, accountID: String) throws -> ([UsageEvent], Checkpoint) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0

        var resume = Checkpoint(inode: inode, offset: 0, context: Context())
        if let checkpoint, checkpoint.inode == inode, checkpoint.offset <= size {
            if checkpoint.offset == size { return ([], checkpoint) }
            resume = checkpoint
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(resume.offset))
        let tail = try handle.readToEnd() ?? Data()

        var reader = FileReader(fileName: url.lastPathComponent, accountID: accountID, context: resume.context)
        var end = resume.offset
        for range in CodexRollouts.lineRanges(in: tail) {
            reader.read(tail[range], at: resume.offset + range.lowerBound)
            end = resume.offset + range.upperBound + 1
        }
        return (reader.events, Checkpoint(inode: inode, offset: end, context: reader.context))
    }

    /// Walks the lines of one rollout in order, starting from the context its checkpoint carried.
    struct FileReader {
        let fileName: String
        let accountID: String
        var context: Context
        var events: [UsageEvent] = []

        init(fileName: String, accountID: String, context: Context = Context()) {
            self.fileName = fileName
            self.accountID = accountID
            self.context = context
        }

        private static let relevantTypes = ["turn_context", "session_meta", "token_usage_record", "token_count"].map { Data("\"\($0)\"".utf8) }

        mutating func read(_ line: Data, at offset: Int) {
            guard Self.relevantTypes.contains(where: { CodexRollouts.contains(line, $0) }),
                  let decoded = CodexRolloutLine.decode(line), let payload = decoded.payload else { return }

            switch decoded.type {
            case "session_meta":
                if let cwd = payload.cwd { context.project = Self.projectName(cwd) }
            case "turn_context":
                if let model = payload.model, !model.isEmpty { context.model = model }
                if let cwd = payload.cwd { context.project = Self.projectName(cwd) }
            case "token_usage_record":
                context.recordsStarted = true
                guard let usage = payload.usage else { return }
                let key = payload.responseId.map { "codex:\($0)" } ?? "codex:\(fileName):@\(offset)"
                append(usage, key: key, at: decoded.date)
            case "event_msg" where payload.type == "token_count":
                guard !context.recordsStarted, let info = payload.info, let current = info.totalTokenUsage else { return }
                countDelta(to: current, contextWindow: info.modelContextWindow, at: decoded.date)
            default:
                return
            }
        }

        private mutating func countDelta(to current: CodexTokenUsage, contextWindow: Int?, at date: Date?) {
            let previous = context.totals ?? CodexTokenUsage()
            context.totals = current
            // Only strictly rising totals count, which also keeps the total-based keys below unique within a file.
            guard current.totalTokens > previous.totalTokens else { return }
            // codex's fill_to_context_window sets the session total to the window size without a model call.
            if let contextWindow, current.totalTokens == contextWindow, current.outputTokens <= previous.outputTokens { return }
            // Keyed by the cumulative total rather than the byte offset: codex has rewritten rollouts in place, which
            // moves offsets but keeps totals.
            append(current.subtracting(previous), key: "codex:\(fileName):\(current.totalTokens)", at: date)
        }

        private mutating func append(_ usage: CodexTokenUsage, key: String, at date: Date?) {
            guard let model = context.model, let date else { return }
            let cached = max(0, usage.cachedInputTokens)
            let input = max(0, usage.inputTokens - cached)
            let output = max(0, usage.outputTokens)
            guard input + cached + output > 0 else { return }
            events.append(UsageEvent(
                dedupeKey: key, timestamp: date, accountID: accountID, harness: .codex, model: model, project: context.project,
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

extension CodexHistoryScanner.Checkpoint {
    /// Stored as JSON because model ids (`gpt-oss:20b`) and folder names can contain any separator.
    init?(_ encoded: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)), decoded.offset >= 0 else { return nil }
        self = decoded
    }

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
