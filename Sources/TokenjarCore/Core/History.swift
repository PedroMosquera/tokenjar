import CryptoKit
import Foundation

/// Opaque per-source progress markers (byte offsets, inode, last row id), keyed by `sha256Hex` of the file path so the
/// database never holds a path with the home folder name, project paths or session uuids in it. Owned by each scanner.
public typealias ScanCheckpoints = [String: String]

/// Lowercase hex SHA-256 of the UTF-8 bytes, for identifiers the store keeps only to recognize a file or response again.
func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

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
    /// Equal non-nil keys mean two accounts read the same local source, so its rows belong under one of them only.
    /// A digest, never a path: callers may store or log it. nil means the account's source is its own.
    func sharedSourceKey(for account: AccountConfig, paths: AppPaths) -> String?
}

extension HistoryScanner {
    public func sharedSourceKey(for account: AccountConfig, paths: AppPaths) -> String? { nil }
}

public enum UsageGrouping: String, CaseIterable, Sendable {
    case model
    case harness
    case project
    case account
}

public protocol UsageStore: Sendable {
    /// Keeps the snapshot as the account's latest and stores a sample per window. Returns whether any sample was
    /// stored, so callers reload history only when it changed.
    @discardableResult
    func record(_ snapshot: UsageSnapshot) throws -> Bool
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
