import Foundation
import Testing
@testable import TokenjarCore

struct CodexHistoryScannerTests {
    private let scanner = CodexHistoryScanner()

    private func account(_ temp: CodexTempDirectory) -> AccountConfig {
        AccountConfig(id: "codex-test", provider: .codex, label: "Test", profileDir: temp.url.appending(path: "codex-home").path)
    }

    private func scan(_ temp: CodexTempDirectory, _ checkpoints: ScanCheckpoints = [:]) throws -> ScanResult {
        try scanner.scan(account(temp), checkpoints: checkpoints, paths: AppPaths(home: temp.url))
    }

    @Test func usageRecordsAreUsedAndTokenCountsInTheSameFileIgnored() throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-records.jsonl", to: "codex-home/sessions/2026/10/09/rollout-r.jsonl")

        let events = try scan(temp).events

        #expect(events.map(\.dedupeKey) == ["codex:resp_placeholder_1", "codex:resp_placeholder_2"])
        #expect(events.map(\.inputTokens) == [4_000, 3_000])
        #expect(events.map(\.cacheReadTokens) == [8_000, 12_000])
        #expect(events.map(\.outputTokens) == [900, 500])
        #expect(events.map(\.reasoningTokens) == [300, 100])
        #expect(events.allSatisfy { $0.model == "gpt-6.1-sol" && $0.project == "tokenjar" && $0.harness == .codex && $0.accountID == "codex-test" })
        #expect(events.first?.timestamp == .codexFixture("2026-10-09T11:28:30.000Z"))
        #expect(events.allSatisfy { $0.cacheWrite5mTokens == 0 && $0.cacheWrite1hTokens == 0 && $0.reportedCostUSD == nil })
    }

    @Test func tokenCountOnlyFilesCountPositiveDeltas() throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-t.jsonl")

        let events = try scan(temp).events

        // A repeat of the same total, an event without info and the jump to the context window are skipped.
        #expect(events.map(\.dedupeKey) == ["codex:rollout-t.jsonl:10500", "codex:rollout-t.jsonl:26500", "codex:rollout-t.jsonl:266700"])
        #expect(events.map(\.inputTokens) == [4_000, 3_000, 3_000])
        #expect(events.map(\.cacheReadTokens) == [6_000, 12_000, 5_000])
        #expect(events.map(\.outputTokens) == [500, 1_000, 300])
        #expect(events.map(\.reasoningTokens) == [200, 400, 100])
        #expect(events.allSatisfy { $0.model == "gpt-5.5" && $0.project == "dotfiles" })
        #expect(events.map(\.timestamp) == [.codexFixture("2026-10-09T10:05:00Z"), .codexFixture("2026-10-09T10:10:00Z"), .codexFixture("2026-10-09T10:20:00.500Z")])
    }

    @Test func homeFolderIsStoredAsTildeNeverTheAccountName() throws {
        let temp = try CodexTempDirectory()
        func rollout(cwd: String, response: String) -> String {
            [
                #"{"timestamp":"2026-10-09T10:00:00Z","type":"session_meta","payload":{"cwd":"\#(cwd)"}}"#,
                #"{"timestamp":"2026-10-09T10:00:01Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","cwd":"\#(cwd)"}}"#,
                #"{"timestamp":"2026-10-09T10:00:02Z","type":"token_usage_record","payload":{"response_id":"\#(response)","usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}}"#,
            ].joined(separator: "\n") + "\n"
        }
        try temp.write(rollout(cwd: temp.url.path, response: "resp_home"), to: "codex-home/sessions/2026/10/09/rollout-a.jsonl")
        try temp.write(rollout(cwd: temp.url.path + "/", response: "resp_slash"), to: "codex-home/sessions/2026/10/09/rollout-b.jsonl")
        try temp.write(rollout(cwd: temp.url.appending(path: "work/x").path, response: "resp_x"), to: "codex-home/sessions/2026/10/09/rollout-c.jsonl")

        let events = try scan(temp).events

        #expect(events.map(\.dedupeKey) == ["codex:resp_home", "codex:resp_slash", "codex:resp_x"])
        #expect(events.map(\.project) == ["~", "~", "x"])
    }

    /// Both bad lines name a relevant type, so they get past the cheap filter and reach the decoder.
    @Test func skipsMalformedLinesAndKeepsReadingPastThem() throws {
        let temp = try CodexTempDirectory()
        let record = { (response: String) in
            #"{"timestamp":"2026-10-09T10:00:02Z","type":"token_usage_record","payload":{"response_id":"\#(response)","usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}}"#
        }
        let cutShort = record("resp_cut")
        let file = try temp.write([
            #"{"timestamp":"2026-10-09T10:00:01Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","cwd":"/x/p"}}"#,
            record("resp_before"),
            #"{"timestamp":"2026-10-09T10:00:03Z","type":"token_usage_record","payload":{"#,
            String(cutShort.prefix(cutShort.count / 2)),
            record("resp_after"),
        ].joined(separator: "\n") + "\n", to: "codex-home/sessions/2026/10/09/rollout-m.jsonl")

        let result = try scan(temp)

        #expect(result.events.map(\.dedupeKey) == ["codex:resp_before", "codex:resp_after"])
        #expect(result.events.allSatisfy { $0.model == "gpt-6.1-sol" && $0.project == "p" })
        let checkpoint = try #require(result.checkpoints.values.first.flatMap(CodexHistoryScanner.Checkpoint.init))
        #expect(checkpoint.offset == (try Data(contentsOf: file)).count)
    }

    @Test func jumpToTheContextWindowWithoutOutputIsNotUsage() {
        var reader = CodexHistoryScanner.FileReader(fileName: "f", accountID: "a", home: URL(fileURLWithPath: "/Users/placeholder"))
        let lines = [
            #"{"timestamp":"2026-10-09T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/x/p"}}"#,
            #"{"timestamp":"2026-10-09T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100},"model_context_window":5000}}}"#,
            #"{"timestamp":"2026-10-09T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4900,"cached_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":5000},"model_context_window":5000}}}"#,
            #"{"timestamp":"2026-10-09T10:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5400,"cached_input_tokens":0,"output_tokens":150,"reasoning_output_tokens":0,"total_tokens":5550},"model_context_window":5000}}}"#,
        ]
        for (index, line) in lines.enumerated() { reader.read(Data(line.utf8), at: index * 1_000) }

        #expect(reader.events.map(\.inputTokens) == [1_000, 500])
        #expect(reader.events.map(\.outputTokens) == [100, 50])
    }

    /// Cache writes are priced at their own rate, and like cached reads they are part of `input_tokens`.
    @Test func cacheWritesAreSplitOutOfInputInBothFormats() {
        var reader = CodexHistoryScanner.FileReader(fileName: "f", accountID: "a", home: URL(fileURLWithPath: "/Users/placeholder"))
        let lines = [
            #"{"timestamp":"2026-10-09T10:00:00Z","type":"turn_context","payload":{"model":"gpt-6-astra","cwd":"/x/p"}}"#,
            #"{"timestamp":"2026-10-09T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":6000,"cache_write_input_tokens":1500,"output_tokens":500,"total_tokens":10500}}}}"#,
            #"{"timestamp":"2026-10-09T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16000,"cached_input_tokens":11000,"cache_write_input_tokens":2000,"output_tokens":800,"total_tokens":16800}}}}"#,
            #"{"timestamp":"2026-10-09T10:03:00Z","type":"token_usage_record","payload":{"response_id":"resp_w","usage":{"input_tokens":12000,"cached_input_tokens":8000,"cache_write_input_tokens":1000,"output_tokens":900,"total_tokens":12900}}}"#,
        ]
        for (index, line) in lines.enumerated() { reader.read(Data(line.utf8), at: index * 1_000) }

        #expect(reader.events.map(\.cacheWrite5mTokens) == [1_500, 500, 1_000])
        #expect(reader.events.map(\.inputTokens) == [2_500, 500, 3_000])
        #expect(reader.events.map(\.cacheReadTokens) == [6_000, 5_000, 8_000])
        #expect(reader.events.allSatisfy { $0.cacheWrite1hTokens == 0 })
    }

    @Test func importedSessionsWithoutTurnContextAreNotCodexUsage() throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-imported.jsonl", to: "codex-home/sessions/2026/06/20/rollout-i.jsonl")

        let result = try scan(temp)

        #expect(result.events.isEmpty)
        #expect(result.checkpoints.count == 1)
    }

    @Test func archivedSessionsAreIncluded() throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-records.jsonl", to: "codex-home/archived_sessions/rollout-r.jsonl")
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-t.jsonl")

        #expect(try scan(temp).events.count == 5)
    }

    @Test func incrementalScansContinueDeltasFromTheCheckpoint() throws {
        let temp = try CodexTempDirectory()
        let lines = try CodexFixtures.lines("rollout-token-count.jsonl")
        let path = "codex-home/sessions/2026/10/09/rollout-t.jsonl"
        let whole = try {
            let other = try CodexTempDirectory()
            try other.copyFixture("rollout-token-count.jsonl", to: path)
            return try scan(other).events
        }()

        // First scan sees one delta, a repeat of its total, and half of a line codex is still writing.
        try temp.write(lines[..<6].joined(separator: "\n") + "\n" + lines[6].prefix(40), to: path)
        let first = try scan(temp)
        #expect(first.events.map(\.dedupeKey) == ["codex:rollout-t.jsonl:10500"])
        #expect(first.checkpoints.count == 1)
        let checkpoint = try #require(first.checkpoints.values.first.flatMap(CodexHistoryScanner.Checkpoint.init))
        #expect(checkpoint.offset == lines[..<6].map { $0.utf8.count + 1 }.reduce(0, +))
        #expect(checkpoint.context.totals?.totalTokens == 10_500)

        let unchanged = try scan(temp, first.checkpoints)
        #expect(unchanged.events.isEmpty)
        #expect(unchanged.checkpoints == first.checkpoints)

        try temp.write(lines.joined(separator: "\n") + "\n", to: path)
        let second = try scan(temp, first.checkpoints)
        #expect(second.events.map(\.dedupeKey) == ["codex:rollout-t.jsonl:26500", "codex:rollout-t.jsonl:266700"])
        #expect(second.events.map(\.inputTokens) == [3_000, 3_000])
        #expect(second.events.allSatisfy { $0.model == "gpt-5.5" && $0.project == "dotfiles" })
        #expect(first.events + second.events == whole)
    }

    @Test func incrementalScansReadOnlyTheTailAndKeepRecordModeAndContext() throws {
        let temp = try CodexTempDirectory()
        let lines = try CodexFixtures.lines("rollout-records.jsonl")
        let path = "codex-home/sessions/2026/10/09/rollout-r.jsonl"

        try temp.write(lines[..<4].joined(separator: "\n") + "\n", to: path)
        let first = try scan(temp)
        #expect(first.events.map(\.dedupeKey) == ["codex:resp_placeholder_1"])

        // The model, project and record mode can only come from the checkpoint once the head is blanked in place.
        let blankHead = lines[..<4].map { String(repeating: " ", count: $0.utf8.count) }
        try temp.write((blankHead + lines[4...]).joined(separator: "\n") + "\n", to: path)
        let second = try scan(temp, first.checkpoints)
        #expect(second.events.map(\.dedupeKey) == ["codex:resp_placeholder_2"])
        #expect(second.events.first?.model == "gpt-6.1-sol")
        #expect(second.events.first?.project == "tokenjar")
    }

    @Test func replacedFileIsRescannedFromTheStartWithStableKeys() throws {
        let temp = try CodexTempDirectory()
        let path = "codex-home/sessions/2026/10/09/rollout-t.jsonl"
        let file = try temp.copyFixture("rollout-token-count.jsonl", to: path)
        let first = try scan(temp)

        try FileManager.default.removeItem(at: file)
        try temp.copyFixture("rollout-token-count.jsonl", to: path)
        let second = try scan(temp, first.checkpoints)

        #expect(second.events == first.events)
    }

    @Test func truncatedFileIsRescannedFromTheStart() throws {
        let temp = try CodexTempDirectory()
        let lines = try CodexFixtures.lines("rollout-token-count.jsonl")
        let path = "codex-home/sessions/2026/10/09/rollout-t.jsonl"
        try temp.write(lines.joined(separator: "\n") + "\n", to: path)
        let first = try scan(temp)

        try temp.write(lines[..<5].joined(separator: "\n") + "\n", to: path)
        let second = try scan(temp, first.checkpoints)

        #expect(second.events.map(\.dedupeKey) == ["codex:rollout-t.jsonl:10500"])
    }

    @Test func keepsTheCheckpointOfAFileItCannotRead() throws {
        let temp = try CodexTempDirectory()
        let lines = try CodexFixtures.lines("rollout-token-count.jsonl")
        let path = "codex-home/sessions/2026/10/09/rollout-t.jsonl"
        let file = try temp.write(lines[..<6].joined(separator: "\n") + "\n", to: path)
        let first = try scan(temp)
        try temp.write(lines.joined(separator: "\n") + "\n", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let blocked = try scan(temp, first.checkpoints)

        #expect(blocked.events.isEmpty)
        #expect(!first.checkpoints.isEmpty)
        #expect(blocked.checkpoints == first.checkpoints)
    }

    @Test func checkpointsForDeletedFilesAreDropped() throws {
        let temp = try CodexTempDirectory()
        let result = try scan(temp, ["/gone/rollout-x.jsonl": "1:2:"])
        #expect(result.checkpoints.isEmpty)
        #expect(result.events.isEmpty)
    }

    @Test func checkpointRoundTripsModelIdsAndFolderNamesWithSeparators() {
        let context = CodexHistoryScanner.Context(
            totals: CodexTokenUsage(inputTokens: 1, cachedInputTokens: 2, outputTokens: 3, reasoningOutputTokens: 4, totalTokens: 5),
            model: "gpt-oss:20b", project: "a:b,c", recordsStarted: true
        )
        let checkpoint = CodexHistoryScanner.Checkpoint(inode: 12, offset: 345, context: context)
        #expect(CodexHistoryScanner.Checkpoint(checkpoint.encoded) == checkpoint)
        #expect(CodexHistoryScanner.Checkpoint(CodexHistoryScanner.Checkpoint(inode: 1, offset: 0, context: .init()).encoded)?.context == .init())
    }

    @Test(arguments: ["", "12:345:1,2,3,4,5", #"{"inode":1,"offset":-1,"context":{"recordsStarted":false}}"#])
    func unreadableCheckpointsMeanAFullRescan(encoded: String) {
        #expect(CodexHistoryScanner.Checkpoint(encoded) == nil)
    }

    @Test func eventsCarryNoTextFromTheLog() throws {
        let temp = try CodexTempDirectory()
        try temp.copyFixture("rollout-records.jsonl", to: "codex-home/sessions/2026/10/09/rollout-r.jsonl")
        try temp.copyFixture("rollout-token-count.jsonl", to: "codex-home/sessions/2026/10/09/rollout-t.jsonl")

        let encoded = String(decoding: try JSONEncoder().encode(scan(temp).events), as: UTF8.self)

        for placeholder in ["PROMPT_PLACEHOLDER", "INSTRUCTIONS_PLACEHOLDER", "SESSION_ID_PLACEHOLDER", "THREAD_ID_PLACEHOLDER", "TURN_ID_PLACEHOLDER", "placeholder/work", "placeholder/src"] {
            #expect(!encoded.contains(placeholder))
        }
    }
}
