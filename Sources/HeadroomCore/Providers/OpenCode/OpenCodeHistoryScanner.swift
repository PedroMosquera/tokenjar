import Foundation

public struct OpenCodeHistoryScanner: HistoryScanner {
    public let name: String
    public let providerIDs: Set<String>

    public init(providerIDs: Set<String>) {
        self.providerIDs = providerIDs
        self.name = "opencode-db:" + providerIDs.sorted().joined(separator: ",")
    }

    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        ScanResult(events: [], checkpoints: checkpoints)
    }
}
