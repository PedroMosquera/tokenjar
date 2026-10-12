import Foundation
import TokenjarCore

/// One preview account for a plan matrix case. `status` is the case's manifest `expect` written as Swift, which
/// `PreviewPlansTests` holds to the manifest.
struct PreviewPlanRow {
    var id: String
    var provider: ProviderID
    var label: String
    var status: AccountStatus
    /// Gives the account 30 days of usage events, so a cost line drawn from local history has a figure to show.
    var history: Bool
}

/// Preview pages with one account per plan matrix case, for `--render-windows --only popover-plans-<provider>`.
enum PreviewPlans {
    /// The same instant as `AppModel.preview()`, so rows written against it render the same countdowns.
    static let now = Date(timeIntervalSince1970: 1_791_660_000)

    static var rows: [PreviewPlanRow] {
        claudeRows + codexRows + openCodeRows + antigravityRows + copilotDevinRows
    }

    static func pages(now: Date = PreviewPlans.now) -> [(name: String, model: AppModel)] {
        pages(now: now, rows: rows)
    }

    /// How many rows each page holds, so every page exists before any row lands. Rows past a provider's last page go on
    /// further pages of six: a popover taller than six cards no longer fits one capture.
    private static let pageSizes: [ProviderID: [Int]] = [
        .claude: [6, 6, 6, 6, 6, 6], .codex: [6, 5, 5, 5, 5], .opencodeGo: [6, 5, 5], .opencodeZen: [5, 4, 3],
        .antigravity: [6, 5, 5, 5], .copilot: [6, 6, 6, 6, 6, 6], .devin: [5, 5],
    ]

    static func pages(now: Date, rows: [PreviewPlanRow]) -> [(name: String, model: AppModel)] {
        let prices = AppModel.preview(now: now).priceTable
        return ProviderID.allCases.flatMap { provider in
            var remaining = rows.filter { $0.provider == provider }[...]
            var pageRows: [[PreviewPlanRow]] = []
            for size in pageSizes[provider] ?? [] {
                pageRows.append(Array(remaining.prefix(size)))
                remaining = remaining.dropFirst(size)
            }
            while !remaining.isEmpty {
                pageRows.append(Array(remaining.prefix(6)))
                remaining = remaining.dropFirst(6)
            }
            return pageRows.enumerated().map { index, rows in
                (name: "plans-\(provider.rawValue)-\(index + 1)", model: model(rows, now: now, prices: prices))
            }
        }
    }

    private static func model(_ rows: [PreviewPlanRow], now: Date, prices: PriceTable) -> AppModel {
        let model = AppModel(paths: .preview)
        // Before the config, so no account is looked for on this Mac.
        model.previewMode = true
        model.now = now
        model.popoverNow = now
        model.lastRefreshAt = now.addingTimeInterval(-90)
        model.config = AppConfig(accounts: rows.map { AccountConfig(id: $0.id, provider: $0.provider, label: $0.label) })
        for row in rows { model.statuses[row.id] = row.status }
        let store = InMemoryUsageStore()
        try? store.upsert(rows.enumerated().filter(\.element.history).flatMap { usage(for: $0.element, seed: UInt64($0.offset + 1), now: now) })
        model.store = store
        model.priceTable = prices
        return model
    }

    /// 30 days of requests on the provider's harness, on models `AppModel.preview()` prices or with opencode's own
    /// recorded cost. A provider without a harness has no local history to show.
    private static func usage(for row: PreviewPlanRow, seed: UInt64, now: Date) -> [UsageEvent] {
        guard let harness = row.provider.harness else { return [] }
        let model = switch harness {
        case .claudeCode: "claude-sonnet-5-5"
        case .codex: "gpt-5.5-codex"
        case .opencode: "kimi-k3"
        }
        var rng = PreviewRandom(seed: seed)
        var events: [UsageEvent] = []
        for day in 0..<30 {
            let dayStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(day) * 86_400 + 10 * 3600)
            for request in 0..<(10 + Int(rng.next() * 30)) {
                let input = 2_000 + Int(rng.next() * 6_000)
                let output = 300 + Int(rng.next() * 1_800)
                events.append(UsageEvent(
                    dedupeKey: "plans:\(row.id):\(day):\(request)", timestamp: dayStart.addingTimeInterval(Double(request) * 120),
                    accountID: row.id, harness: harness, model: model, project: "tokenjar",
                    inputTokens: input, outputTokens: output, cacheReadTokens: input * 10,
                    reportedCostUSD: harness == .opencode ? Double(input + output * 4) / 1_000_000 * 1.2 : nil
                ))
            }
        }
        return events
    }
}
