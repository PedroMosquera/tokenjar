import Foundation
@testable import HeadroomCore

enum StoreKind: String, CaseIterable, Sendable {
    case memory
    case sqlite

    func make(in directory: URL, calendar: Calendar = .current) throws -> any UsageStore {
        switch self {
        case .memory: InMemoryUsageStore(calendar: calendar)
        case .sqlite: try SQLiteUsageStore(url: directory.appending(path: "headroom.sqlite"), calendar: calendar)
        }
    }
}

/// A fresh directory that does not exist yet, so tests also cover creating the store's parent directory.
/// Deleted on deinit: keep it in a suite's stored property, which outlives every store a test opens in it.
final class TemporaryDirectory: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(path: "headroom-store-tests/\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: url) }
}

func fixedCalendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

func usageEvent(
    _ key: String, at timestamp: Date, account: String = "acct", harness: Harness = .claudeCode, model: String = "claude-opus-5-5",
    project: String? = "headroom", input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
    reasoning: Int = 0, cost: Double? = nil
) -> UsageEvent {
    UsageEvent(
        dedupeKey: key, timestamp: timestamp, accountID: account, harness: harness, model: model, project: project,
        inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWrite5mTokens: cacheWrite5m,
        cacheWrite1hTokens: cacheWrite1h, reasoningTokens: reasoning, reportedCostUSD: cost
    )
}

/// The protocol leaves the order of rows that share a day and model unspecified; compare in a total order.
func canonical(_ rows: [DailyUsageRow]) -> [DailyUsageRow] {
    rows.sorted {
        ($0.day, $0.accountID, $0.harness.rawValue, $0.model, $0.project ?? "") < ($1.day, $1.accountID, $1.harness.rawValue, $1.model, $1.project ?? "")
    }
}
