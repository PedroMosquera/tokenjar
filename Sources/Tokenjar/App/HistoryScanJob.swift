import Foundation
import TokenjarCore

enum HistoryScanJob {
    /// Scans each account's local logs and stores the events. A scanner's checkpoints move only after its events
    /// are stored: moving them first would skip those events for good if the write failed. One unreadable source
    /// does not stop the others; it is retried on the next scan. Checkpoints a scan hands back unchanged are not
    /// rewritten. Returns whether any events were stored.
    nonisolated static func run(_ jobs: [(AccountConfig, any HistoryScanner)], store: any UsageStore, paths: AppPaths) -> Bool {
        var changed = false
        for (account, scanner) in jobs {
            do {
                let checkpoints = try store.checkpoints(scanner: scanner.name, accountID: account.id)
                let result = try scanner.scan(account, checkpoints: checkpoints, paths: paths)
                if !result.events.isEmpty {
                    try store.upsert(result.events)
                    changed = true
                }
                if result.checkpoints != checkpoints {
                    try store.saveCheckpoints(result.checkpoints, scanner: scanner.name, accountID: account.id)
                }
            } catch {
                continue
            }
        }
        return changed
    }
}
