import Foundation
import Testing
@testable import TokenjarCore

private struct StubScanner: HistoryScanner {
    var name: String
    var fails = false

    func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        if fails { throw CocoaError(.fileReadCorruptFile) }
        let event = UsageEvent(
            dedupeKey: "\(name):1", timestamp: Date(timeIntervalSince1970: 1_791_660_000), accountID: account.id,
            harness: .claudeCode, model: "m", project: "p", inputTokens: 10, outputTokens: 5
        )
        return ScanResult(events: [event], checkpoints: ["log": "100"])
    }
}

/// Finds nothing new, so it hands back the checkpoints it was given.
private struct IdleScanner: HistoryScanner {
    var name = "s"

    func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        ScanResult(events: [], checkpoints: checkpoints)
    }
}

/// Records the order of the writes a scan makes.
private final class CountingStore: UsageStore, @unchecked Sendable {
    let inner = InMemoryUsageStore()
    private let lock = NSLock()
    private var log: [String] = []

    var writes: [String] { lock.withLock { log } }

    func record(_ snapshot: UsageSnapshot) throws -> Bool { try inner.record(snapshot) }
    func upsert(_ events: [UsageEvent]) throws {
        lock.withLock { log.append("upsert") }
        try inner.upsert(events)
    }
    func checkpoints(scanner: String, accountID: String) throws -> ScanCheckpoints { try inner.checkpoints(scanner: scanner, accountID: accountID) }
    func saveCheckpoints(_ checkpoints: ScanCheckpoints, scanner: String, accountID: String) throws {
        lock.withLock { log.append("saveCheckpoints") }
        try inner.saveCheckpoints(checkpoints, scanner: scanner, accountID: accountID)
    }
    func samples(accountID: String, windowID: String?, since: Date) throws -> [WindowSample] { try inner.samples(accountID: accountID, windowID: windowID, since: since) }
    func dailyUsage(accountIDs: [String]?, since: Date) throws -> [DailyUsageRow] { try inner.dailyUsage(accountIDs: accountIDs, since: since) }
    func usage(accountIDs: [String]?, in interval: DateInterval) throws -> [DailyUsageRow] { try inner.usage(accountIDs: accountIDs, in: interval) }
    func latestSnapshots() throws -> [UsageSnapshot] { try inner.latestSnapshots() }
}

/// Stores everything except events, to stand in for a database that rejects a write.
private final class RejectingStore: UsageStore, @unchecked Sendable {
    let inner = InMemoryUsageStore()
    var rejectsEvents = false

    func record(_ snapshot: UsageSnapshot) throws -> Bool { try inner.record(snapshot) }
    func upsert(_ events: [UsageEvent]) throws {
        if rejectsEvents { throw CocoaError(.fileWriteUnknown) }
        try inner.upsert(events)
    }
    func checkpoints(scanner: String, accountID: String) throws -> ScanCheckpoints { try inner.checkpoints(scanner: scanner, accountID: accountID) }
    func saveCheckpoints(_ checkpoints: ScanCheckpoints, scanner: String, accountID: String) throws {
        try inner.saveCheckpoints(checkpoints, scanner: scanner, accountID: accountID)
    }
    func samples(accountID: String, windowID: String?, since: Date) throws -> [WindowSample] { try inner.samples(accountID: accountID, windowID: windowID, since: since) }
    func dailyUsage(accountIDs: [String]?, since: Date) throws -> [DailyUsageRow] { try inner.dailyUsage(accountIDs: accountIDs, since: since) }
    func usage(accountIDs: [String]?, in interval: DateInterval) throws -> [DailyUsageRow] { try inner.usage(accountIDs: accountIDs, in: interval) }
    func latestSnapshots() throws -> [UsageSnapshot] { try inner.latestSnapshots() }
}

struct HistoryScanJobTests {
    private let paths = AppPaths(home: FileManager.default.temporaryDirectory)
    private let a = AccountConfig(id: "a", provider: .claude, label: "A")
    private let b = AccountConfig(id: "b", provider: .claude, label: "B")

    @Test func aRejectedWriteKeepsTheCheckpointsWhereTheyWere() throws {
        let store = RejectingStore()
        store.rejectsEvents = true

        let changed = HistoryScanJob.run([(a, StubScanner(name: "s"))], store: store, paths: paths)

        #expect(!changed)
        #expect(try store.checkpoints(scanner: "s", accountID: "a").isEmpty)
    }

    /// Every 5 minutes each scanner hands back its checkpoints; for Claude that is one per transcript, hundreds of rows.
    @Test func unchangedCheckpointsAreNotRewritten() throws {
        let store = CountingStore()
        try store.inner.saveCheckpoints(["log": "100"], scanner: "s", accountID: "a")

        let changed = HistoryScanJob.run([(a, IdleScanner())], store: store, paths: paths)

        #expect(!changed)
        #expect(store.writes.isEmpty)
    }

    @Test func newEventsAreStoredBeforeTheCheckpointsMove() throws {
        let store = CountingStore()
        try store.inner.saveCheckpoints(["log": "40"], scanner: "s", accountID: "a")

        let changed = HistoryScanJob.run([(a, StubScanner(name: "s"))], store: store, paths: paths)

        #expect(changed)
        #expect(store.writes == ["upsert", "saveCheckpoints"])
        #expect(try store.checkpoints(scanner: "s", accountID: "a") == ["log": "100"])
    }

    @Test func oneFailingSourceDoesNotStopTheOthers() throws {
        let store = RejectingStore()

        let changed = HistoryScanJob.run([(a, StubScanner(name: "s", fails: true)), (b, StubScanner(name: "s"))], store: store, paths: paths)

        #expect(changed)
        #expect(try store.checkpoints(scanner: "s", accountID: "a").isEmpty)
        #expect(try store.checkpoints(scanner: "s", accountID: "b") == ["log": "100"])
        #expect(try store.dailyUsage(accountIDs: ["b"], since: .distantPast).count == 1)
    }
}
