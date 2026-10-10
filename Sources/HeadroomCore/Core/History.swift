import Foundation

/// Opaque per-source progress markers, keyed by file path (byte offsets, inode, last row id). Owned by each scanner.
public typealias ScanCheckpoints = [String: String]

public struct ScanResult: Sendable {
    public var events: [UsageEvent]
    public var checkpoints: ScanCheckpoints

    public init(events: [UsageEvent], checkpoints: ScanCheckpoints) {
        self.events = events
        self.checkpoints = checkpoints
    }
}

/// Reads a harness's local logs incrementally. Must decode only counts, model ids, timestamps and the
/// working directory's last path component; never prompt or output text, emails, or account ids.
public protocol HistoryScanner: Sendable {
    /// Stable name used to namespace checkpoints in storage.
    var name: String { get }
    func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult
}

public enum UsageGrouping: String, CaseIterable, Sendable {
    case model
    case harness
    case project
    case account
}

public protocol UsageStore: Sendable {
    func record(_ snapshot: UsageSnapshot) throws
    /// Upsert by dedupeKey, keeping the larger token counts for each field.
    func upsert(_ events: [UsageEvent]) throws
    func checkpoints(scanner: String, accountID: String) throws -> ScanCheckpoints
    func saveCheckpoints(_ checkpoints: ScanCheckpoints, scanner: String, accountID: String) throws
    func samples(accountID: String, windowID: String?, since: Date) throws -> [WindowSample]
    /// One row per (local day, account, harness, model, project). Callers price rows per model first,
    /// then regroup with `UsageGrouping`, because a row that mixes models cannot be priced.
    func dailyUsage(accountIDs: [String]?, since: Date) throws -> [DailyUsageRow]
    /// Latest stored snapshot per account, used to show last-known values right after launch.
    func latestSnapshots() throws -> [UsageSnapshot]
}
