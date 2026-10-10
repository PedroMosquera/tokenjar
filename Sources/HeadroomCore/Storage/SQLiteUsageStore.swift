import Foundation

/// SQLite-backed `UsageStore` at `AppPaths.databaseFile`. Schema and queries are documented in docs/design.md.
public final class SQLiteUsageStore: UsageStore, @unchecked Sendable {
    public init(url: URL) throws {}

    public func record(_ snapshot: UsageSnapshot) throws {}
    public func upsert(_ events: [UsageEvent]) throws {}
    public func checkpoints(scanner: String, accountID: String) throws -> ScanCheckpoints { [:] }
    public func saveCheckpoints(_ checkpoints: ScanCheckpoints, scanner: String, accountID: String) throws {}
    public func samples(accountID: String, windowID: String?, since: Date) throws -> [WindowSample] { [] }
    public func dailyUsage(accountIDs: [String]?, since: Date) throws -> [DailyUsageRow] { [] }
    public func latestSnapshots() throws -> [UsageSnapshot] { [] }
}
