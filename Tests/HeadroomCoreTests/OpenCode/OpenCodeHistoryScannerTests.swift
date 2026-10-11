import Foundation
import Testing
@testable import HeadroomCore

struct OpenCodeHistoryScannerTests {
    let t0: Int64 = 1_791_000_000_000

    private func account(_ dir: OpenCodeTempDirectory) -> AccountConfig {
        AccountConfig(id: "go", provider: .opencodeGo, label: "Go", profileDir: dir.url.path)
    }

    private func scan(_ dir: OpenCodeTempDirectory, providers: Set<String> = ["opencode-go"], checkpoints: ScanCheckpoints = [:]) throws -> ScanResult {
        try OpenCodeHistoryScanner(providerIDs: providers, environment: [:])
            .scan(account(dir), checkpoints: checkpoints, paths: AppPaths(home: dir.url))
    }

    private func database(_ dir: OpenCodeTempDirectory) -> URL { dir.url.appending(path: "opencode.db") }

    private func checkpointKey(_ dir: OpenCodeTempDirectory, _ table: String) -> String { sha256Hex(database(dir).path + "#" + table) }

    @Test func keepsOnlyAssistantRowsOfTheScannedProviders() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir))
        try db.createV1Tables()
        try db.insertV1(id: "msg_go_1", provider: "opencode-go", cost: "0.0123", input: 100, output: 50, reasoning: 7, cacheRead: 1_000, cacheWrite: 20, cwd: "/work/alpha", created: t0, updated: t0 + 5_000)
        try db.insertV1(id: "msg_zen_1", provider: "opencode", model: "kimi-k3", created: t0 + 1)
        try db.insertV1(id: "msg_openai_1", provider: "openai", model: "gpt-6-astra", cost: "0", created: t0 + 2)
        try db.insertV1(id: "msg_user_1", role: "user", provider: "opencode-go", created: t0 + 3)

        let result = try scan(dir)
        #expect(result.events.map(\.dedupeKey) == ["opencode:msg_go_1"])
        let event = try #require(result.events.first)
        #expect(event.timestamp == Date(timeIntervalSince1970: TimeInterval(t0) / 1_000))
        #expect(event.accountID == "go")
        #expect(event.harness == .opencode)
        #expect(event.model == "glm-5.2")
        #expect(event.project == "alpha")
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 50)
        #expect(event.reasoningTokens == 7)
        #expect(event.cacheReadTokens == 1_000)
        #expect(event.cacheWrite5mTokens == 20)
        #expect(event.cacheWrite1hTokens == 0)
        #expect(event.reportedCostUSD == 0.0123)

        let both = try scan(dir, providers: ["opencode-go", "opencode"])
        #expect(Set(both.events.map(\.dedupeKey)) == ["opencode:msg_go_1", "opencode:msg_zen_1"])
    }

    @Test func integerCostIsReadAsDollars() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir))
        try db.createV1Tables()
        try db.insertV1(id: "msg_zero", provider: "opencode-go", cost: "0", created: t0)
        try db.insertV1(id: "msg_two", provider: "opencode-go", cost: "2", created: t0 + 1)
        let costs = Dictionary(uniqueKeysWithValues: try scan(dir).events.map { ($0.dedupeKey, $0.reportedCostUSD) })
        #expect(costs["opencode:msg_zero"] == .some(0))
        #expect(costs["opencode:msg_two"] == .some(2))
    }

    @Test func resumesFromTheLastUpdateAndRereadsRowsThatChanged() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir))
        try db.createV1Tables()
        try db.insertV1(id: "msg_old", provider: "opencode-go", created: t0, updated: t0 + 500)
        try db.insertV1(id: "msg_a", provider: "opencode-go", cost: "0", created: t0 + 600, updated: t0 + 1_000)
        try db.insertV1(id: "msg_b", provider: "opencode-go", created: t0 + 1_500, updated: t0 + 2_000)

        let first = try scan(dir)
        #expect(first.events.count == 3)
        #expect(first.checkpoints[checkpointKey(dir, "message")] == "\(t0 + 2_000)")

        try db.updateV1(id: "msg_a", cost: "0.5", updated: t0 + 4_000)
        try db.insertV1(id: "msg_c", provider: "opencode-go", created: t0 + 3_000)

        let second = try scan(dir, checkpoints: first.checkpoints)
        // msg_b sits exactly on the checkpoint and is re-read on purpose; msg_old is not.
        #expect(second.events.map(\.dedupeKey) == ["opencode:msg_b", "opencode:msg_c", "opencode:msg_a"])
        #expect(second.events.last?.reportedCostUSD == 0.5)
        #expect(second.checkpoints[checkpointKey(dir, "message")] == "\(t0 + 4_000)")
    }

    /// Both tables live side by side once opencode has created `session_message`. Rows that exist only there,
    /// including ones older than the newest `message` row, count; copies of `message` rows do not.
    @Test func readsBothTablesAndSkipsV2CopiesOfV1Rows() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir))
        try db.createV1Tables()
        try db.createV2Tables()
        try db.insertSession("ses_1", directory: "/work/alpha")
        try db.insertSession("ses_2", directory: "/work/beta")
        try db.insertV1(id: "msg_1", provider: "opencode-go", created: t0)
        try db.insertV1(id: "msg_2", provider: "opencode-go", created: t0 + 10_000)
        try db.insertV2(id: "msg_1", provider: "opencode-go", created: t0 + 1, seq: 1)
        try db.insertV2(id: "msg_2_new_id", provider: "opencode-go", created: t0 + 10_000, seq: 2)
        try db.insertV2(id: "msg_v2_older", session: "ses_2", provider: "opencode-go", created: t0 + 5_000, seq: 1)
        try db.insertV2(id: "msg_v2_newer", session: "ses_2", provider: "opencode-go", created: t0 + 20_000, seq: 2)

        let result = try scan(dir)
        #expect(result.events.map(\.dedupeKey).sorted() == ["opencode:msg_1", "opencode:msg_2", "opencode:msg_v2_newer", "opencode:msg_v2_older"])
        #expect(result.events.first { $0.dedupeKey == "opencode:msg_v2_older" }?.project == "beta")
        #expect(result.checkpoints[checkpointKey(dir, "message")] == "\(t0 + 10_000)")
        #expect(result.checkpoints[checkpointKey(dir, "session_message")] == "\(t0 + 20_000)")
    }

    /// A newer checkpoint in one table must not hide rows the other table gained after its own checkpoint.
    @Test func eachTableResumesFromItsOwnCheckpoint() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir))
        try db.createV1Tables()
        try db.createV2Tables()
        try db.insertV1(id: "msg_v1_a", provider: "opencode-go", created: t0 + 1_000)
        try db.insertV2(id: "msg_v2_a", session: "ses_2", provider: "opencode-go", created: t0 + 9_000, seq: 1)
        let first = try scan(dir)
        #expect(first.events.count == 2)

        try db.insertV1(id: "msg_v1_b", provider: "opencode-go", created: t0 + 2_000)
        let second = try scan(dir, checkpoints: first.checkpoints)
        #expect(second.events.map(\.dedupeKey) == ["opencode:msg_v1_a", "opencode:msg_v1_b", "opencode:msg_v2_a"])
    }

    @Test func readsTheV2TableWhenTheV1TableIsGone() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir))
        try db.createV2Tables()
        try db.insertSession("ses_1", directory: "/work/beta")
        try db.insertV2(id: "msg_1", provider: "opencode-go", model: "glm-5.2", cost: "1", input: 11, output: 22, created: t0, seq: 1)
        try db.insertV2(id: "msg_user", type: "user", provider: "opencode-go", created: t0 + 1, seq: 2)
        try db.insertV2(id: "msg_zen", provider: "opencode", created: t0 + 2, seq: 3)

        let result = try scan(dir)
        #expect(result.events.map(\.dedupeKey) == ["opencode:msg_1"])
        let event = try #require(result.events.first)
        #expect(event.model == "glm-5.2")
        #expect(event.project == "beta")
        #expect(event.inputTokens == 11)
        #expect(event.outputTokens == 22)
        #expect(event.reportedCostUSD == 1)
        #expect(result.checkpoints[checkpointKey(dir, "session_message")] == "\(t0)")
        #expect(result.checkpoints[checkpointKey(dir, "message")] == nil)
    }

    @Test func missingDatabaseYieldsNothingAndKeepsCheckpoints() throws {
        let dir = try OpenCodeTempDirectory()
        let result = try scan(dir, checkpoints: ["other": "x"])
        #expect(result.events.isEmpty)
        #expect(result.checkpoints == ["other": "x"])
    }

    /// opencode not running: WAL database, no -wal or -shm, and a directory we cannot write to.
    @Test func opensAQuiescentWALDatabaseInAReadOnlyDirectory() throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: database(dir), wal: true)
        try db.createV1Tables()
        try db.insertV1(id: "msg_1", provider: "opencode-go", created: t0)
        db.close()
        #expect(!FileManager.default.fileExists(atPath: database(dir).path + "-wal"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path) }

        #expect(try scan(dir).events.map(\.dedupeKey) == ["opencode:msg_1"])
    }

    @Test func projectIsTheLastPathComponentAndNeverTheUserName() {
        let home = URL(fileURLWithPath: "/Users/placeholder")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/work/headroom", home: home) == "headroom")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/work/headroom/", home: home) == "headroom")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder", home: home) == "~")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/", home: home) == "~")
        #expect(UsageEvent.project(fromWorkingDirectory: "/", home: home) == nil)
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/work/site/.claude/worktrees/agent-a3fc8a67", home: home) == "site")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/work/site/.claude/worktrees/chat-persona/web", home: home) == "site")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/.claude/worktrees/x", home: home) == "~")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/work/site/.superpowers/sdd/2026-09-30-plan", home: home) == "site")
        #expect(UsageEvent.project(fromWorkingDirectory: "/Users/placeholder/.config/nvim", home: home) == "nvim")
        #expect(UsageEvent.project(fromWorkingDirectory: "relative/dir", home: home) == nil)
        #expect(UsageEvent.project(fromWorkingDirectory: nil, home: home) == nil)
    }
}

struct OpenCodeZenUsageFetcherTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func context(_ dir: OpenCodeTempDirectory, now: Date) -> FetchContext {
        FetchContext(http: HTTPClient(transport: OpenCodeFakeTransport(HTTPResponse(status: 500, body: Data()))),
                     secrets: InMemorySecretStore(), paths: AppPaths(home: dir.url), now: { now })
    }

    @Test func reportsMonthToDateZenSpendFromTheLocalDatabase() async throws {
        let dir = try OpenCodeTempDirectory()
        let db = try OpenCodeFixtureDatabase(at: dir.url.appending(path: "opencode.db"))
        try db.createV1Tables()
        let ms = { (iso: String) in Int64(DateParsing.iso8601(iso)!.timeIntervalSince1970 * 1_000) }
        try db.insertV1(id: "zen_this_1", provider: "opencode", cost: "1.5", created: ms("2026-10-01T00:00:00Z"))
        try db.insertV1(id: "zen_this_2", provider: "opencode", cost: "2", created: ms("2026-10-09T12:00:00Z"))
        try db.insertV1(id: "zen_last_month", provider: "opencode", cost: "4", created: ms("2026-09-30T23:59:59Z"))
        try db.insertV1(id: "go_this", provider: "opencode-go", cost: "9", created: ms("2026-10-05T00:00:00Z"))
        try db.createV2Tables()
        try db.insertV2(id: "zen_this_1", provider: "opencode", cost: "1.5", created: ms("2026-10-01T00:00:00Z"), seq: 1)
        try db.insertV2(id: "zen_v2_only", session: "ses_2", provider: "opencode", cost: "0.5", created: ms("2026-10-02T00:00:00Z"), seq: 1)

        let account = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen", profileDir: dir.url.path)
        let now = DateParsing.iso8601("2026-10-10T12:00:00Z")!
        let s = try await OpenCodeZenUsageFetcher(environment: [:], calendar: utc).fetch(account, context: context(dir, now: now))
        #expect(s.money == [MoneyLine(label: "Spent this month (this Mac)", amount: 4)])
        #expect(s.plan == "Pay as you go")
        #expect(s.source == "opencode.db")
        #expect(s.notes == ["Balance needs a console sign-in; showing local spend only."])
        #expect(s.windows.isEmpty)
        #expect(s.provider == .opencodeZen)
    }

    @Test func noDatabaseIsUnsupported() async throws {
        let dir = try OpenCodeTempDirectory()
        let account = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen", profileDir: dir.url.path)
        await #expect(throws: FetchError.unsupported("OpenCode has not been used on this Mac")) {
            try await OpenCodeZenUsageFetcher(environment: [:], calendar: utc).fetch(account, context: context(dir, now: Date()))
        }
    }
}
