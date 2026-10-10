import Foundation

public struct CodexHistoryScanner: HistoryScanner {
    public let name = "codex-rollouts"

    public init() {}

    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        ScanResult(events: [], checkpoints: checkpoints)
    }
}
