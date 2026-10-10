import Foundation

public struct ClaudeHistoryScanner: HistoryScanner {
    public let name = "claude-transcripts"

    public init() {}

    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        ScanResult(events: [], checkpoints: checkpoints)
    }
}
