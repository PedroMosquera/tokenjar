import Foundation
import Testing
@testable import TokenjarCore

private let fixtureProjects = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/Claude/projects")

/// A temp home with the fixture transcripts copied to `~/.claude/projects`, so tests can append and replace files.
private struct TranscriptHome {
    let home: URL
    var projects: URL { home.appending(path: ".claude/projects") }
    var main: URL { projects.appending(path: "-Users-PLACEHOLDER-work-demo/SESSION_A.jsonl") }
    var subagent: URL { projects.appending(path: "-Users-PLACEHOLDER-work-demo/SESSION_A/subagents/agent-1.jsonl") }

    init() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "headroom-claude-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp.appending(path: ".claude"), withIntermediateDirectories: true)
        // The enumerator reports /var/folders as /private/var/folders, and resolvingSymlinksInPath strips /private again.
        let real = try #require(realpath(temp.path, nil))
        defer { free(real) }
        home = URL(fileURLWithPath: String(cString: real))
        try FileManager.default.copyItem(at: fixtureProjects, to: projects)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func scan(_ checkpoints: ScanCheckpoints = [:], account: AccountConfig = AccountConfig(id: "claude-personal", provider: .claude, label: "Personal")) throws -> ScanResult {
        try ClaudeHistoryScanner().scan(account, checkpoints: checkpoints, paths: AppPaths(home: home))
    }

    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func size(_ file: URL) throws -> UInt64 {
        try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64)
    }
}

private func assistantLine(
    id: String, request: String, output: Int, at timestamp: String = "2026-10-09T13:00:00.000Z", cwd: String = "/Users/PLACEHOLDER/work/demo"
) -> String {
    #"{"type":"assistant","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[{"type":"text","text":"OUTPUT_TEXT"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}},"requestId":"\#(request)","timestamp":"\#(timestamp)","cwd":"\#(cwd)","sessionId":"SESSION_A"}"#
}

struct ClaudeHistoryScannerTests {
    @Test func readsAssistantUsageIncludingSubagentsAndSkipsEverythingElse() throws {
        let box = try TranscriptHome()
        defer { box.remove() }

        let events = try box.scan().events

        // msg_A arrives in two streaming chunks. User lines, the summary, the <synthetic> error and the non-assistant
        // msg_P line (which carries a message with usage) are skipped.
        #expect(events.map(\.dedupeKey).sorted() == [
            "claude:msg_A:req_A", "claude:msg_A:req_A", "claude:msg_B:req_B", "claude:msg_C:req_C",
            "claude:msg_D:SESSION_A", "claude:msg_E:req_E",
        ])
        #expect(events.allSatisfy { $0.accountID == "claude-personal" && $0.harness == .claudeCode })
        #expect(!events.contains { $0.model == "<synthetic>" })
        #expect(!events.contains { $0.inputTokens == 900 }, "a tool result's nested usage is not a response")

        let agent = try #require(events.first { $0.dedupeKey == "claude:msg_E:req_E" })
        #expect(agent.project == "demo-agent")
        #expect(agent.timestamp == DateParsing.iso8601("2026-10-09T10:01:05.000Z"))
        #expect(events.first { $0.dedupeKey == "claude:msg_D:SESSION_A" }?.project == nil)
    }

    @Test func homeFolderIsStoredAsTildeNeverTheAccountName() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let session = box.projects.appending(path: "-home/SESSION_H.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            assistantLine(id: "msg_H1", request: "req_H1", output: 1, cwd: box.home.path),
            assistantLine(id: "msg_H2", request: "req_H2", output: 1, cwd: box.home.path + "/"),
            assistantLine(id: "msg_H3", request: "req_H3", output: 1, cwd: box.home.appending(path: "work/x").path),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: session)

        let events = try box.scan().events.filter { $0.dedupeKey.hasPrefix("claude:msg_H") }.sorted { $0.dedupeKey < $1.dedupeKey }

        #expect(events.map(\.project) == ["~", "~", "x"])
    }

    @Test func cacheWritesSplitByTTLAndDefaultToFiveMinutes() throws {
        let box = try TranscriptHome()
        defer { box.remove() }

        let events = Dictionary(try box.scan().events.map { ($0.dedupeKey, $0) }, uniquingKeysWith: { a, _ in a })

        let legacy = try #require(events["claude:msg_B:req_B"])
        #expect(legacy.cacheWrite5mTokens == 70)
        #expect(legacy.cacheWrite1hTokens == 0)
        #expect(legacy.model == "claude-sonnet-5")
        let oneHour = try #require(events["claude:msg_C:req_C"])
        #expect(oneHour.cacheWrite5mTokens == 0)
        #expect(oneHour.cacheWrite1hTokens == 300)
        #expect(oneHour.cacheReadTokens == 20)
    }

    /// Haiku 5.5 bills every token of a request whose prompt (input plus cache reads and writes) is over 100,000 tokens
    /// at a higher rate, so such a request is recorded under that tier's own price id.
    @Test(arguments: [
        (150_000, 0, 0, "claude-haiku-5-5>100k"),
        (90_000, 0, 0, "claude-haiku-5-5"),
        (0, 60_000, 50_000, "claude-haiku-5-5>100k"),
    ])
    func longHaikuPromptsUseTheLongPromptTier(cacheRead: Int, write5m: Int, write1h: Int, expected: String) {
        let line = #"{"type":"assistant","message":{"id":"msg_L","model":"claude-haiku-5-5","usage":{"input_tokens":20,"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)},"output_tokens":5}},"requestId":"req_L","timestamp":"2026-10-09T13:00:00.000Z","sessionId":"SESSION_A"}"#
        var events: [UsageEvent] = []

        _ = ClaudeHistoryScanner.parse(Data((line + "\n").utf8), accountID: "a", home: URL(fileURLWithPath: "/Users/PLACEHOLDER"), decoder: JSONDecoder(), into: &events)

        #expect(events.map(\.model) == [expected])
        #expect(events.map(\.cacheReadTokens) == [cacheRead])
    }

    @Test func streamingChunksCollapseToTheLargestCountsInTheStore() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let store = InMemoryUsageStore(calendar: Calendar(identifier: .gregorian).with(timeZone: .gmt))

        try store.upsert(box.scan().events)
        let rows = try store.dailyUsage(accountIDs: nil, since: .distantPast)

        let opusDemo = try #require(rows.first { $0.model == "claude-opus-5-5" && $0.project == "demo" })
        // msg_A (two chunks, output 10 then 42) plus msg_C (output 2): a sum of chunks would give 54.
        #expect(opusDemo.requests == 2)
        #expect(opusDemo.outputTokens == 44)
        #expect(opusDemo.inputTokens == 4)
        #expect(opusDemo.cacheReadTokens == 120)
        #expect(opusDemo.cacheWrite5mTokens == 50)
        #expect(opusDemo.cacheWrite1hTokens == 300)
        #expect(rows.reduce(0) { $0 + $1.requests } == 5)
    }

    @Test func resumesFromCheckpointsAndOnlyReadsAppendedLines() throws {
        let box = try TranscriptHome()
        defer { box.remove() }

        let first = try box.scan()
        #expect(first.checkpoints.count == 2)
        let mainCheckpoint = try #require(first.checkpoints[sha256Hex(box.main.path)])
        #expect(mainCheckpoint.hasSuffix(":\(try box.size(box.main))"))

        let unchanged = try box.scan(first.checkpoints)
        #expect(unchanged.events.isEmpty)
        #expect(unchanged.checkpoints == first.checkpoints)

        try box.append(assistantLine(id: "msg_F", request: "req_F", output: 5) + "\n", to: box.main)
        let appended = try box.scan(unchanged.checkpoints)
        #expect(appended.events.map(\.dedupeKey) == ["claude:msg_F:req_F"])
        #expect(appended.checkpoints[sha256Hex(box.subagent.path)] == first.checkpoints[sha256Hex(box.subagent.path)])
    }

    @Test func leavesAPartialLastLineForTheNextScan() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let first = try box.scan()
        let completeSize = try box.size(box.main)

        let line = assistantLine(id: "msg_G", request: "req_G", output: 9)
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try box.append(String(line[..<cut]), to: box.main)
        let partial = try box.scan(first.checkpoints)
        #expect(partial.events.isEmpty)
        #expect(partial.checkpoints[sha256Hex(box.main.path)]?.hasSuffix(":\(completeSize)") == true)

        try box.append(String(line[cut...]) + "\n", to: box.main)
        let completed = try box.scan(partial.checkpoints)
        #expect(completed.events.map(\.dedupeKey) == ["claude:msg_G:req_G"])
        #expect(completed.events.first?.outputTokens == 9)
    }

    @Test func rescansFromTheStartWhenTheFileIsReplacedOrTruncated() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let first = try box.scan()

        // Same bytes under a new inode: the offset would say "nothing new", the inode says it is another file.
        let original = try Data(contentsOf: box.subagent)
        try FileManager.default.removeItem(at: box.subagent)
        try original.write(to: box.subagent)
        let replaced = try box.scan(first.checkpoints)
        #expect(replaced.events.map(\.dedupeKey) == ["claude:msg_E:req_E"])

        // Same inode, now shorter than the checkpoint offset.
        let handle = try FileHandle(forWritingTo: box.main)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((assistantLine(id: "msg_H", request: "req_H", output: 3) + "\n").utf8))
        try handle.close()
        let truncated = try box.scan(replaced.checkpoints)
        #expect(truncated.events.map(\.dedupeKey) == ["claude:msg_H:req_H"])
    }

    /// Dropping it would only cost a full rescan of that file later, but the scan should resume where it left off.
    @Test func keepsTheCheckpointOfAFileItCannotRead() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let first = try box.scan()
        try box.append(assistantLine(id: "msg_U", request: "req_U", output: 1) + "\n", to: box.main)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.main.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.main.path) }

        let blocked = try box.scan(first.checkpoints)

        #expect(blocked.events.isEmpty)
        #expect(blocked.checkpoints[sha256Hex(box.main.path)] == first.checkpoints[sha256Hex(box.main.path)])
    }

    @Test func dropsCheckpointsOfDeletedFiles() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let first = try box.scan()

        try FileManager.default.removeItem(at: box.subagent)
        let after = try box.scan(first.checkpoints)

        #expect(after.checkpoints.keys.sorted() == [sha256Hex(box.main.path)])
    }

    @Test func profileDirScansOnlyItsOwnProjects() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let workProjects = box.home.appending(path: ".claude-work/projects/-Users-PLACEHOLDER-work-other")
        try FileManager.default.createDirectory(at: workProjects, withIntermediateDirectories: true)
        try Data((assistantLine(id: "msg_W", request: "req_W", output: 1) + "\n").utf8).write(to: workProjects.appending(path: "SESSION_W.jsonl"))

        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        let events = try box.scan(account: work).events

        #expect(events.map(\.dedupeKey) == ["claude:msg_W:req_W"])
        #expect(events.first?.accountID == "claude-work")
    }

    @Test func defaultAccountAlsoReadsTheXDGConfigLocation() throws {
        let box = try TranscriptHome()
        defer { box.remove() }
        let xdg = box.home.appending(path: ".config/claude/projects/-Users-PLACEHOLDER-work-xdg")
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        try Data((assistantLine(id: "msg_X", request: "req_X", output: 1) + "\n").utf8).write(to: xdg.appending(path: "SESSION_X.jsonl"))

        let keys = Set(try box.scan().events.map(\.dedupeKey))

        #expect(keys.contains("claude:msg_X:req_X"))
        #expect(keys.contains("claude:msg_A:req_A"))
    }

    @Test(arguments: [
        "2026-10-09T10:00:01.250Z",
        "2026-10-09T11:30:00Z",
        "2024-02-29T23:59:59.999999+02:00",
        "1999-12-31T00:00:00-05:30",
        "2026-01-01T00:00:00.123456789Z",
        "1970-01-01T00:00:00Z",
    ])
    func timestampParserAgreesWithDateParsing(_ string: String) throws {
        let fast = try #require(ClaudeHistoryScanner.timestamp(string))
        let reference = try #require(DateParsing.iso8601(string))
        #expect(abs(fast.timeIntervalSince(reference)) < 0.000_001)
    }

    @Test func timestampParserRejectsOtherShapes() {
        #expect(ClaudeHistoryScanner.timestamp("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(ClaudeHistoryScanner.timestamp("2026-10-09 10:00:00") == nil)
        #expect(ClaudeHistoryScanner.timestamp("2026-13-09T10:00:00Z") == nil)
        #expect(ClaudeHistoryScanner.timestamp("") == nil)
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar {
        var copy = self
        copy.timeZone = timeZone
        return copy
    }
}
