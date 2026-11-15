import Foundation
import Testing
@testable import TokenjarCore

/// Line shapes recorded from Kimi Code 2.5.3, with prompt and tool text replaced.
final class KimiHistoryScannerTests {
    let temp = TemporaryDirectory()
    var home: URL { temp.url }
    let account = AccountConfig(id: "kimi", provider: .kimi, label: "Kimi Code")
    let session = ".kimi-code/sessions/wd_tokenjar_0404c5fa6c71/session_1"

    static let wire = [
        #"{"type":"metadata","protocol_version":"1.5","created_at":1794748115311}"#,
        #"{"type":"turn.prompt","agentId":"main","content":[{"type":"text","text":"usage.record placeholder prompt"}],"time":1794748115320}"#,
        #"{"type":"llm.request","agentId":"main","model":"kimi-for-coding","modelAlias":"kimi-code/kimi-for-coding","time":1794748115370}"#,
        #"{"type":"usage.record","agentId":"main","model":"kimi-code/kimi-for-coding","usage":{"inputOther":1740,"output":451,"inputCacheRead":12288,"inputCacheCreation":0},"usageScope":"turn","time":1794748127027}"#,
        #"{"type":"token_counting.measured","agentId":"main","length":3,"tokens":14479,"time":1794748127028}"#,
        #"{"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":1506,"output":806,"inputCacheRead":13824,"inputCacheCreation":64},"usageScope":"turn","time":1794748140000}"#,
    ].joined(separator: "\n") + "\n"

    private func writeSession(wire: String = KimiHistoryScannerTests.wire, agent: String = "main", session: String? = nil) throws -> URL {
        let session = session ?? self.session
        _ = try temp.write(#"{"id":"session_1","cwd":"\#(home.path)/workspace/tokenjar","title":"placeholder","lastPrompt":"placeholder"}"#, to: "\(session)/state.json")
        return try temp.write(wire, to: "\(session)/agents/\(agent)/wire.jsonl")
    }

    private func scan(_ checkpoints: ScanCheckpoints = [:]) throws -> ScanResult {
        try KimiHistoryScanner().scan(account, checkpoints: checkpoints, paths: AppPaths(home: home))
    }

    @Test func eachUsageRecordIsOneRequest() throws {
        _ = try writeSession()
        let events = try scan().events.sorted { $0.timestamp < $1.timestamp }

        #expect(events.count == 2)
        let first = try #require(events.first)
        #expect(first.model == "kimi-for-coding")
        #expect(first.harness == .kimiCode)
        #expect(first.project == "tokenjar")
        #expect(first.inputTokens == 1740)
        #expect(first.outputTokens == 451)
        #expect(first.cacheReadTokens == 12288)
        #expect(first.cacheWrite5mTokens == 0)
        #expect(first.timestamp == Date(timeIntervalSince1970: 1_794_748_127.027))
        #expect(events.last?.model == "k3")
        #expect(events.last?.cacheWrite5mTokens == 64)
    }

    @Test func subagentLogsCountToo() throws {
        _ = try writeSession()
        _ = try writeSession(wire: Self.wire.replacingOccurrences(of: #""agentId":"main""#, with: #""agentId":"explorer""#), agent: "explorer")
        #expect(Set(try scan().events.map(\.dedupeKey)).count == 4)
    }

    /// `/fork` copies the source session's wire, times included, into a new session folder.
    @Test func aForkedSessionsCopiedRequestsCountOnce() throws {
        _ = try writeSession()
        _ = try writeSession(session: ".kimi-code/sessions/wd_tokenjar_0404c5fa6c71/session_2")
        let events = try scan().events
        #expect(events.count == 4)
        #expect(Set(events.map(\.dedupeKey)).count == 2)
    }

    @Test func aRescanFromTheCheckpointReadsOnlyNewLines() throws {
        let file = try writeSession()
        let first = try scan()
        #expect(try scan(first.checkpoints).events.isEmpty)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":5},"time":1794748150000}"# + "\n").utf8))
        try handle.close()

        let next = try scan(first.checkpoints)
        #expect(next.events.map(\.inputTokens) == [10])
    }

    @Test func aLineStillBeingWrittenWaitsForItsNewline() throws {
        _ = try writeSession(wire: #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":5},"time":1794748150000}"#)
        #expect(try scan().events.isEmpty)
    }

    @Test func aMissingStateFileLeavesTheProjectEmpty() throws {
        _ = try temp.write(Self.wire, to: "\(session)/agents/main/wire.jsonl")
        let events = try scan().events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.project == nil })
    }

    @Test func aProfileFolderIsKimiCodeHome() throws {
        _ = try temp.write(Self.wire, to: "other/sessions/wd_x/session_2/agents/main/wire.jsonl")
        var account = self.account
        account.profileDir = "~/other"
        #expect(try KimiHistoryScanner().scan(account, checkpoints: [:], paths: AppPaths(home: home)).events.count == 2)
        #expect(try scan().events.isEmpty)
    }

    @Test func checkpointKeysHoldNoPath() throws {
        _ = try writeSession()
        let keys = try scan().checkpoints.keys
        #expect(keys.count == 1)
        #expect(keys.allSatisfy { !$0.contains("/") && $0.count == 64 })
    }
}
