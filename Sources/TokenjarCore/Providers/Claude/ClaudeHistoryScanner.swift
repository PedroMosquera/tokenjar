import Foundation

/// Reads token counts from Claude Code transcripts (`<configDir>/projects/**/*.jsonl`, subagent files included).
/// Each response is written on several lines while it streams; every line becomes an event with the same
/// dedupe key and the store keeps the largest count per field.
///
/// Checkpoints are `"<inode>:<offset>"` per file, keyed by `sha256Hex` of its path. A file is rescanned from the start
/// when its inode changes or it shrinks below the offset, and a trailing line without a newline is left for the next scan.
public struct ClaudeHistoryScanner: HistoryScanner {
    public let name = "claude-transcripts"

    public init() {}

    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        let decoder = JSONDecoder()
        var events: [UsageEvent] = []
        var next: ScanCheckpoints = [:]
        for file in Self.roots(account, paths: paths).flatMap(Self.transcripts) {
            // readToEnd returns autoreleased NSData. Without a pool per file, every transcript stays in memory until the
            // whole first scan returns, which is the size of the projects folder.
            autoreleasepool {
                let path = file.path, key = sha256Hex(path)
                var info = stat()
                guard stat(path, &info) == 0 else { return }
                let inode = UInt64(info.st_ino), size = UInt64(info.st_size)
                var offset: UInt64 = 0
                if let previous = checkpoints[key].flatMap(Checkpoint.init), previous.inode == inode, previous.offset <= size {
                    offset = previous.offset
                }
                guard offset < size else {
                    next[key] = Checkpoint(inode: inode, offset: offset).description
                    return
                }
                guard let data = Self.read(file, from: offset) else {
                    if let previous = checkpoints[key] { next[key] = previous }
                    return
                }
                let consumed = Self.parse(data, accountID: account.id, home: paths.home, decoder: decoder, into: &events)
                next[key] = Checkpoint(inode: inode, offset: offset + UInt64(consumed)).description
            }
        }
        return ScanResult(events: events, checkpoints: next)
    }

    /// The profile folder as Settings resolves it, so a default account and one naming `~/.claude` match.
    public func sharedSourceKey(for account: AccountConfig, paths: AppPaths) -> String? {
        SettingsLogic.resolvedProfile(account, paths: paths).map(sha256Hex)
    }

    static func roots(_ account: AccountConfig, paths: AppPaths) -> [URL] {
        if let profileDir = account.profileDir { return [paths.expand(profileDir).appending(path: "projects")] }
        return [paths.home.appending(path: ".claude/projects"), paths.home.appending(path: ".config/claude/projects")]
    }

    static func transcripts(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private static func read(_ file: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// Appends one event per assistant usage line in `data` and returns how many bytes were consumed, which is
    /// everything up to and including the last newline.
    static func parse(_ data: Data, accountID: String, home: URL, decoder: JSONDecoder, into events: inout [UsageEvent]) -> Int {
        let marker = Array(#""usage""#.utf8)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var start = 0
            while start < buffer.count, let newline = memchr(base + start, Int32(UInt8(ascii: "\n")), buffer.count - start) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                // Most lines are prompts and tool output; skipping them before JSON decoding keeps a full scan fast.
                if memmem(base + start, line.count, marker, marker.count) != nil,
                   let entry = try? decoder.decode(TranscriptLine.self, from: Data(line)),
                   let event = entry.event(accountID: accountID, home: home) {
                    events.append(event)
                }
                start = end + 1
            }
            return start
        }
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)` by hand. ICU-backed formatters cost about 25 µs per call, which was
    /// half of a full scan; any other shape goes through `DateParsing`.
    static func timestamp(_ string: String) -> Date? {
        var copy = string
        return copy.withUTF8(parseTimestamp) ?? DateParsing.iso8601(string)
    }

    private static func parseTimestamp(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
        func number(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= b.count else { return nil }
            var value = 0
            for i in at..<(at + count) {
                let digit = b[i] &- UInt8(ascii: "0")
                guard digit < 10 else { return nil }
                value = value * 10 + Int(digit)
            }
            return value
        }
        func byte(_ at: Int, is char: Unicode.Scalar) -> Bool { at < b.count && b[at] == UInt8(ascii: char) }

        guard let year = number(0, 4), byte(4, is: "-"), let month = number(5, 2), byte(7, is: "-"), let day = number(8, 2),
              byte(10, is: "T"), let hour = number(11, 2), byte(13, is: ":"), let minute = number(14, 2), byte(16, is: ":"),
              let second = number(17, 2), (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
        else { return nil }

        var i = 19
        var fraction = 0.0
        if byte(i, is: ".") {
            i += 1
            var digits = 0, value = 0
            while i < b.count, b[i] &- UInt8(ascii: "0") < 10 {
                if digits < 9 { value = value * 10 + Int(b[i] - UInt8(ascii: "0")); digits += 1 }
                i += 1
            }
            guard digits > 0 else { return nil }
            fraction = Double(value) / pow(10, Double(digits))
        }

        var offset = 0
        if byte(i, is: "Z"), i + 1 == b.count {
            offset = 0
        } else if byte(i, is: "+") || byte(i, is: "-"), i + 6 == b.count, let h = number(i + 1, 2), byte(i + 3, is: ":"), let m = number(i + 4, 2) {
            offset = (h * 3600 + m * 60) * (byte(i, is: "-") ? -1 : 1)
        } else {
            return nil
        }

        // Days since 1970-01-01 in the proleptic Gregorian calendar (Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    struct Checkpoint: CustomStringConvertible {
        var inode: UInt64
        var offset: UInt64

        init(inode: UInt64, offset: UInt64) {
            self.inode = inode
            self.offset = offset
        }

        init?(_ string: String) {
            let parts = string.split(separator: ":")
            guard parts.count == 2, let inode = UInt64(parts[0]), let offset = UInt64(parts[1]) else { return nil }
            self.init(inode: inode, offset: offset)
        }

        var description: String { "\(inode):\(offset)" }
    }

    /// Only counts, ids, model, speed, timestamp and the working directory. Message content is never decoded.
    private struct TranscriptLine: Decodable {
        var type: String?
        var timestamp: String?
        var requestId: String?
        var sessionId: String?
        var cwd: String?
        var message: Message?

        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheReadInputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheCreation: CacheCreation?
            var serverToolUse: ServerToolUse?
            var speed: String?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheCreation = "cache_creation"
                case serverToolUse = "server_tool_use"
                case speed
            }
        }

        struct ServerToolUse: Decodable {
            var webSearchRequests: Int?

            enum CodingKeys: String, CodingKey {
                case webSearchRequests = "web_search_requests"
            }
        }

        struct CacheCreation: Decodable {
            var ephemeral5m: Int?
            var ephemeral1h: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens"
                case ephemeral1h = "ephemeral_1h_input_tokens"
            }
        }

        func event(accountID: String, home: URL) -> UsageEvent? {
            guard type == "assistant", let message, let id = message.id, let usage = message.usage,
                  let model = message.model, model != "<synthetic>",
                  let timestamp = timestamp.flatMap(ClaudeHistoryScanner.timestamp)
            else { return nil }
            let write5m: Int, write1h: Int
            if let split = usage.cacheCreation {
                write5m = split.ephemeral5m ?? 0
                write1h = split.ephemeral1h ?? 0
            } else {
                write5m = usage.cacheCreationInputTokens ?? 0
                write1h = 0
            }
            let input = usage.inputTokens ?? 0, cacheRead = usage.cacheReadInputTokens ?? 0
            return UsageEvent(
                dedupeKey: "claude:\(id):\(requestId ?? sessionId ?? "")", timestamp: timestamp, accountID: accountID,
                harness: .claudeCode,
                model: PriceTable.billedModel(model, promptTokens: input + cacheRead + write5m + write1h, fast: usage.speed == "fast"),
                project: UsageEvent.project(fromWorkingDirectory: cwd, home: home),
                inputTokens: input, outputTokens: usage.outputTokens ?? 0,
                cacheReadTokens: cacheRead, cacheWrite5mTokens: write5m, cacheWrite1hTokens: write1h,
                webSearchRequests: usage.serverToolUse?.webSearchRequests ?? 0
            )
        }
    }
}
