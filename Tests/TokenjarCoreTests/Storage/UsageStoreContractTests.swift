import Foundation
import Testing
@testable import TokenjarCore

/// Behavior both `UsageStore` implementations must share. Every test runs once per store.
struct UsageStoreContractTests {
    let temp = TemporaryDirectory()
    let tokyo = fixedCalendar("Asia/Tokyo")
    var dayStart: Date { tokyo.date(from: DateComponents(year: 2026, month: 10, day: 10))! }
    var noon: Date { dayStart.addingTimeInterval(12 * 3600) }

    /// Every field rises on one upsert and falls on another, and each call mixes directions, so neither "last write
    /// wins", "first write wins" nor a whole-row replace passes.
    @Test(arguments: StoreKind.allCases)
    func upsertKeepsTheLargerValuePerField(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([usageEvent("k", at: noon, input: 100, output: 10, cacheRead: 7, cacheWrite5m: 5, cacheWrite1h: 1, reasoning: 3)])
        try store.upsert([usageEvent("k", at: noon, input: 90, output: 40, cacheRead: 2, cacheWrite5m: 9, cacheWrite1h: 0, reasoning: 8)])
        try store.upsert([usageEvent("k", at: noon, input: 120, output: 1, cacheRead: 9, cacheWrite5m: 1, cacheWrite1h: 2, reasoning: 1)])
        try store.upsert([usageEvent("k", at: noon, input: 1, output: 1, cacheRead: 1, cacheWrite5m: 1, cacheWrite1h: 0, reasoning: 1)])

        let row = try #require(store.dailyUsage(accountIDs: nil, since: .distantPast).first)
        #expect(row.requests == 1)
        #expect(row.inputTokens == 120)
        #expect(row.outputTokens == 40)
        #expect(row.cacheReadTokens == 9)
        #expect(row.cacheWrite5mTokens == 9)
        #expect(row.cacheWrite1hTokens == 2)
        #expect(row.reasoningTokens == 8)
    }

    /// Claude Code writes one transcript line per content block of a streamed response, each carrying the usage so far.
    @Test(arguments: StoreKind.allCases)
    func chunksOfOneResponseCountOnce(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([
            usageEvent("claude:msg_1:req_1", at: noon, input: 3, output: 1, cacheRead: 40_000, cacheWrite5m: 1_200),
            usageEvent("claude:msg_1:req_1", at: noon.addingTimeInterval(2), input: 3, output: 250, cacheRead: 40_000, cacheWrite5m: 1_200),
            usageEvent("claude:msg_2:req_2", at: noon.addingTimeInterval(30), input: 5, output: 90),
        ])
        // A rescan of the same file later must not double count.
        try store.upsert([usageEvent("claude:msg_1:req_1", at: noon, input: 3, output: 250, cacheRead: 40_000, cacheWrite5m: 1_200)])

        let row = try #require(store.dailyUsage(accountIDs: nil, since: .distantPast).first)
        #expect(row.requests == 2)
        #expect(row.inputTokens == 8)
        #expect(row.outputTokens == 340)
        #expect(row.cacheReadTokens == 40_000)
        #expect(row.cacheWrite5mTokens == 1_200)
    }

    @Test(arguments: StoreKind.allCases)
    func reportedCostKeepsTheLargerAndIgnoresMissing(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([usageEvent("k", at: noon, harness: .opencode, input: 10)])
        try store.upsert([usageEvent("k", at: noon, harness: .opencode, input: 10, cost: 0.5)])
        try store.upsert([usageEvent("k", at: noon, harness: .opencode, input: 10)])
        try store.upsert([usageEvent("k", at: noon, harness: .opencode, input: 10, cost: 0.25)])

        let row = try #require(store.dailyUsage(accountIDs: nil, since: .distantPast).first)
        #expect(row.reportedCostUSD == 0.5)
        #expect(row.unpricedInputTokens == 0)
    }

    @Test(arguments: StoreKind.allCases)
    func bucketsByLocalDayOfTheInjectedCalendar(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([
            usageEvent("before", at: dayStart.addingTimeInterval(-1), input: 1),
            usageEvent("at", at: dayStart, input: 10),
            usageEvent("late", at: dayStart.addingTimeInterval(86_400 - 1), input: 100),
            usageEvent("next", at: dayStart.addingTimeInterval(86_400), input: 1_000),
        ])

        let rows = try store.dailyUsage(accountIDs: nil, since: .distantPast)
        #expect(rows.map(\.day) == [dayStart.addingTimeInterval(-86_400), dayStart, dayStart.addingTimeInterval(86_400)])
        #expect(rows.map(\.inputTokens) == [1, 110, 1_000])
    }

    @Test(arguments: StoreKind.allCases)
    func bucketsAcrossADaylightSavingChange(kind: StoreKind) throws {
        let newYork = fixedCalendar("America/New_York")
        let store = try kind.make(in: temp.url, calendar: newYork)
        // US clocks fall back on 2026-11-01, so that local day is 25 hours long.
        let nov1 = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let nov2 = newYork.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        #expect(nov2.timeIntervalSince(nov1) == 25 * 3600)
        try store.upsert([
            usageEvent("a", at: nov2.addingTimeInterval(-1), input: 1),
            usageEvent("b", at: nov2, input: 2),
        ])

        let rows = try store.dailyUsage(accountIDs: nil, since: .distantPast)
        #expect(rows.map(\.day) == [nov1, nov2])
    }

    @Test(arguments: StoreKind.allCases)
    func splitsReportedAndUnpricedTokensWithinARow(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([
            usageEvent(
                "reported-1", at: noon, harness: .opencode, model: "glm-5.2", input: 100, output: 10, cacheRead: 1_000, cacheWrite5m: 19, cacheWrite1h: 23,
                cost: 0.25
            ),
            usageEvent("reported-2", at: noon, harness: .opencode, model: "glm-5.2", input: 200, output: 20, cost: 0.5),
            usageEvent("unpriced", at: noon, harness: .opencode, model: "glm-5.2", input: 7, output: 3, cacheRead: 11, cacheWrite5m: 13, cacheWrite1h: 17),
            usageEvent("other-model", at: noon, harness: .opencode, model: "kimi-k3", input: 1),
        ])

        let rows = canonical(try store.dailyUsage(accountIDs: nil, since: .distantPast))
        #expect(rows.count == 2)
        let mixed = try #require(rows.first { $0.model == "glm-5.2" })
        #expect(mixed.requests == 3)
        #expect(mixed.inputTokens == 307)
        #expect(mixed.outputTokens == 33)
        #expect(mixed.cacheReadTokens == 1_011)
        #expect(mixed.cacheWrite5mTokens == 32)
        #expect(mixed.cacheWrite1hTokens == 40)
        #expect(mixed.reportedCostUSD == 0.75)
        #expect(mixed.unpricedInputTokens == 7)
        #expect(mixed.unpricedOutputTokens == 3)
        #expect(mixed.unpricedCacheReadTokens == 11)
        #expect(mixed.unpricedCacheWrite5mTokens == 13)
        #expect(mixed.unpricedCacheWrite1hTokens == 17)

        let unreported = try #require(rows.first { $0.model == "kimi-k3" })
        #expect(unreported.reportedCostUSD == nil)
        #expect(unreported.unpricedInputTokens == 1)
    }

    @Test(arguments: StoreKind.allCases)
    func groupsByAccountHarnessModelAndProject(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([
            usageEvent("1", at: noon, project: nil, input: 1),
            usageEvent("2", at: noon, project: nil, input: 2),
            usageEvent("3", at: noon, project: "dotfiles", input: 4),
            usageEvent("4", at: noon, account: "work", input: 8),
            usageEvent("5", at: noon, harness: .codex, model: "gpt-5.5", input: 16),
        ])

        let rows = canonical(try store.dailyUsage(accountIDs: nil, since: .distantPast))
        let keys = rows.map { "\($0.accountID)|\($0.harness.rawValue)|\($0.model)|\($0.project ?? "-")|\($0.inputTokens)" }
        #expect(keys == [
            "acct|claude-code|claude-opus-5-5|-|3",
            "acct|claude-code|claude-opus-5-5|dotfiles|4",
            "acct|codex|gpt-5.5|tokenjar|16",
            "work|claude-code|claude-opus-5-5|tokenjar|8",
        ])
    }

    @Test(arguments: StoreKind.allCases)
    func filtersByAccountAndStart(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url, calendar: tokyo)
        try store.upsert([
            usageEvent("old", at: noon.addingTimeInterval(-3 * 86_400), input: 1),
            usageEvent("a", at: noon, account: "a", input: 2),
            usageEvent("b", at: noon, account: "b", input: 4),
        ])

        #expect(try store.dailyUsage(accountIDs: nil, since: noon).map(\.inputTokens).reduce(0, +) == 6)
        #expect(try store.dailyUsage(accountIDs: ["a"], since: noon).map(\.accountID) == ["a"])
        #expect(try store.dailyUsage(accountIDs: ["a", "b"], since: .distantPast).map(\.accountID).sorted() == ["a", "b"])
        #expect(try store.dailyUsage(accountIDs: nil, since: .distantPast).count == 3)
        #expect(try store.dailyUsage(accountIDs: [], since: .distantPast).isEmpty)
        #expect(try store.dailyUsage(accountIDs: nil, since: noon.addingTimeInterval(1)).isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func checkpointsRoundTripAndReplaceWhole(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url)
        #expect(try store.checkpoints(scanner: "claude", accountID: "acct").isEmpty)

        try store.saveCheckpoints(["/a.jsonl": "1:100", "/b.jsonl": "2:200"], scanner: "claude", accountID: "acct")
        try store.saveCheckpoints(["/c.jsonl": "3:300"], scanner: "claude", accountID: "work")
        try store.saveCheckpoints(["/d.jsonl": "4"], scanner: "codex", accountID: "acct")
        #expect(try store.checkpoints(scanner: "claude", accountID: "acct") == ["/a.jsonl": "1:100", "/b.jsonl": "2:200"])

        try store.saveCheckpoints(["/b.jsonl": "2:900"], scanner: "claude", accountID: "acct")
        #expect(try store.checkpoints(scanner: "claude", accountID: "acct") == ["/b.jsonl": "2:900"])
        #expect(try store.checkpoints(scanner: "claude", accountID: "work") == ["/c.jsonl": "3:300"])
        #expect(try store.checkpoints(scanner: "codex", accountID: "acct") == ["/d.jsonl": "4"])
    }

    @Test(arguments: StoreKind.allCases)
    func latestSnapshotsKeepsTheLastRecordedPerAccount(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url)
        let first = UsageSnapshot(
            accountID: "acct", provider: .claude, plan: "Max 20x",
            windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 10, windowMinutes: 300, resetsAt: noon.addingTimeInterval(3600))],
            fetchedAt: noon, source: "claude CLI"
        )
        var second = first
        second.fetchedAt = noon.addingTimeInterval(600)
        second.windows[0].usedPercent = 12.5
        second.money = [MoneyLine(label: "Extra usage", amount: 1.5, limit: 100)]
        second.notes = ["note"]
        let other = UsageSnapshot(accountID: "codex", provider: .codex, fetchedAt: noon.addingTimeInterval(0.25), source: "codex app-server")
        try store.record(first)
        try store.record(other)
        try store.record(second)

        let latest = try store.latestSnapshots().sorted { $0.accountID < $1.accountID }
        #expect(latest == [second, other].sorted { $0.accountID < $1.accountID })
    }

    @Test(arguments: StoreKind.allCases)
    func samplesFilterByWindowAndStartInTimeOrder(kind: StoreKind) throws {
        let store = try kind.make(in: temp.url)
        let reset = noon.addingTimeInterval(4 * 3600)
        for (offset, used) in [(0.0, 10.0), (900, 20), (1800, 30)] {
            try store.record(UsageSnapshot(
                accountID: "acct", provider: .claude,
                windows: [
                    UsageWindow(id: "session", label: "5-hour", usedPercent: used, resetsAt: reset),
                    UsageWindow(id: "weekly", label: "Week", usedPercent: used / 2, resetsAt: nil),
                ],
                fetchedAt: noon.addingTimeInterval(offset), source: "test"
            ))
        }
        try store.record(UsageSnapshot(
            accountID: "other", provider: .codex, windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 99)], fetchedAt: noon, source: "test"
        ))

        let session = try store.samples(accountID: "acct", windowID: "session", since: noon.addingTimeInterval(900))
        #expect(session == [
            WindowSample(accountID: "acct", windowID: "session", timestamp: noon.addingTimeInterval(900), usedPercent: 20, resetsAt: reset),
            WindowSample(accountID: "acct", windowID: "session", timestamp: noon.addingTimeInterval(1800), usedPercent: 30, resetsAt: reset),
        ])
        let all = try store.samples(accountID: "acct", windowID: nil, since: .distantPast)
        #expect(all.map(\.windowID) == ["session", "weekly", "session", "weekly", "session", "weekly"])
        #expect(all[1].resetsAt == nil)
        #expect(all[1].usedPercent == 5)
    }
}
