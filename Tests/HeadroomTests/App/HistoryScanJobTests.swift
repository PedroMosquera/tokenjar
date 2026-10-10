import Foundation
import Testing
@testable import Headroom
import HeadroomCore

private nonisolated struct StubScanner: HistoryScanner {
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

/// Stores everything except events, to stand in for a database that rejects a write.
private nonisolated final class RejectingStore: UsageStore, @unchecked Sendable {
    let inner = InMemoryUsageStore()
    var rejectsEvents = false

    func record(_ snapshot: UsageSnapshot) throws { try inner.record(snapshot) }
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

    @Test func oneFailingSourceDoesNotStopTheOthers() throws {
        let store = RejectingStore()

        let changed = HistoryScanJob.run([(a, StubScanner(name: "s", fails: true)), (b, StubScanner(name: "s"))], store: store, paths: paths)

        #expect(changed)
        #expect(try store.checkpoints(scanner: "s", accountID: "a").isEmpty)
        #expect(try store.checkpoints(scanner: "s", accountID: "b") == ["log": "100"])
        #expect(try store.dailyUsage(accountIDs: ["b"], since: .distantPast).count == 1)
    }
}
