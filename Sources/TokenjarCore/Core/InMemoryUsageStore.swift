import Foundation

/// UsageStore for previews and tests. Same contract as SQLiteUsageStore, no persistence.
public final class InMemoryUsageStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: UsageSnapshot] = [:]
    private var windowSamples: [WindowSample] = []
    private var events: [String: UsageEvent] = [:]
    private var checkpointStore: [String: ScanCheckpoints] = [:]
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    @discardableResult
    public func record(_ snapshot: UsageSnapshot) throws -> Bool {
        lock.withLock {
            snapshots[snapshot.accountID] = snapshot
            for window in snapshot.windows {
                windowSamples.append(WindowSample(accountID: snapshot.accountID, windowID: window.id, timestamp: snapshot.fetchedAt, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            }
            return !snapshot.windows.isEmpty
        }
    }

    public func addSamples(_ samples: [WindowSample]) {
        lock.withLock { windowSamples.append(contentsOf: samples) }
    }

    public func upsert(_ newEvents: [UsageEvent]) throws {
        lock.withLock {
            for event in newEvents {
                guard var existing = events[event.dedupeKey] else {
                    events[event.dedupeKey] = event
                    continue
                }
                existing.inputTokens = max(existing.inputTokens, event.inputTokens)
                existing.outputTokens = max(existing.outputTokens, event.outputTokens)
                existing.cacheReadTokens = max(existing.cacheReadTokens, event.cacheReadTokens)
                existing.cacheWrite5mTokens = max(existing.cacheWrite5mTokens, event.cacheWrite5mTokens)
                existing.cacheWrite1hTokens = max(existing.cacheWrite1hTokens, event.cacheWrite1hTokens)
                existing.reasoningTokens = max(existing.reasoningTokens, event.reasoningTokens)
                existing.webSearchRequests = max(existing.webSearchRequests, event.webSearchRequests)
                if let cost = event.reportedCostUSD { existing.reportedCostUSD = max(existing.reportedCostUSD ?? 0, cost) }
                events[event.dedupeKey] = existing
            }
        }
    }

    public func checkpoints(scanner: String, accountID: String) throws -> ScanCheckpoints {
        lock.withLock { checkpointStore["\(scanner)|\(accountID)"] ?? [:] }
    }

    public func saveCheckpoints(_ checkpoints: ScanCheckpoints, scanner: String, accountID: String) throws {
        lock.withLock { checkpointStore["\(scanner)|\(accountID)"] = checkpoints }
    }

    public func samples(accountID: String, windowID: String?, since: Date) throws -> [WindowSample] {
        lock.withLock {
            windowSamples
                .filter { $0.accountID == accountID && (windowID == nil || $0.windowID == windowID) && $0.timestamp >= since }
                .sorted { $0.timestamp < $1.timestamp }
        }
    }

    public func dailyUsage(accountIDs: [String]?, since: Date) throws -> [DailyUsageRow] {
        struct Key: Hashable { var day: Date; var account: String; var harness: Harness; var model: String; var project: String? }
        let selected = lock.withLock { Array(events.values) }
            .filter { $0.timestamp >= since && (accountIDs == nil || accountIDs!.contains($0.accountID)) }
        var rows: [Key: DailyUsageRow] = [:]
        for e in selected {
            let key = Key(day: calendar.startOfDay(for: e.timestamp), account: e.accountID, harness: e.harness, model: e.model, project: e.project)
            var row = rows[key] ?? DailyUsageRow(
                day: key.day, accountID: e.accountID, harness: e.harness, model: e.model, project: e.project, requests: 0,
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, reasoningTokens: 0,
                reportedCostUSD: nil, unpricedInputTokens: 0, unpricedOutputTokens: 0, unpricedCacheReadTokens: 0,
                unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
            )
            row.requests += 1
            row.inputTokens += e.inputTokens
            row.outputTokens += e.outputTokens
            row.cacheReadTokens += e.cacheReadTokens
            row.cacheWrite5mTokens += e.cacheWrite5mTokens
            row.cacheWrite1hTokens += e.cacheWrite1hTokens
            row.reasoningTokens += e.reasoningTokens
            if let cost = e.reportedCostUSD {
                row.reportedCostUSD = (row.reportedCostUSD ?? 0) + cost
            } else {
                row.unpricedInputTokens += e.inputTokens
                row.unpricedOutputTokens += e.outputTokens
                row.unpricedCacheReadTokens += e.cacheReadTokens
                row.unpricedCacheWrite5mTokens += e.cacheWrite5mTokens
                row.unpricedCacheWrite1hTokens += e.cacheWrite1hTokens
                row.unpricedWebSearchRequests += e.webSearchRequests
            }
            rows[key] = row
        }
        return rows.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    public func latestSnapshots() throws -> [UsageSnapshot] {
        lock.withLock { Array(snapshots.values) }
    }
}
