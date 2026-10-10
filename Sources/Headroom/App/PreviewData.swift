import Foundation
import HeadroomCore

/// Deterministic sample data for `--render-snapshots` and visual checks. Prices here are placeholders, not real.
extension AppModel {
    static func preview(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = AppModel()
        model.now = now
        model.lastRefreshAt = now.addingTimeInterval(-90)
        model.config = AppConfig(
            refreshMinutes: 10,
            accounts: [
                AccountConfig(id: "claude-personal", provider: .claude, label: "Personal"),
                AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work", alertThresholds: [70, 90]),
                AccountConfig(id: "codex", provider: .codex, label: "Plus"),
                AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/.local/share/opencode/auth.json", key: "opencode-go")),
                AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", showInMenuBar: false),
                AccountConfig(id: "antigravity", provider: .antigravity, label: "Google", showInMenuBar: false),
            ]
        )
        model.previewMode = true

        func window(_ id: String, _ label: String, _ used: Double, _ minutes: Int, resetIn: TimeInterval, notStarted: Bool = false) -> UsageWindow {
            UsageWindow(id: id, label: label, usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetIn), notStarted: notStarted)
        }

        let snapshots: [UsageSnapshot] = [
            UsageSnapshot(
                accountID: "claude-personal", provider: .claude, plan: "Max 20x",
                windows: [
                    window("session", "5-hour", 42, 300, resetIn: 2 * 3600 + 10 * 60),
                    window("weekly", "Week", 63, 10_080, resetIn: 2 * 86_400 + 4 * 3600),
                    window("weekly:Fable", "Week · Fable", 12, 10_080, resetIn: 2 * 86_400 + 4 * 3600),
                ],
                fetchedAt: now.addingTimeInterval(-90), source: "claude CLI"
            ),
            UsageSnapshot(
                accountID: "claude-work", provider: .claude, plan: "Enterprise",
                windows: [
                    window("session", "5-hour", 88, 300, resetIn: 50 * 60),
                    window("weekly", "Week", 71, 10_080, resetIn: 3 * 86_400 + 6 * 3600),
                ],
                money: [MoneyLine(label: "Extra usage", amount: 12.40, limit: 100)],
                fetchedAt: now.addingTimeInterval(-95), source: "claude CLI"
            ),
            UsageSnapshot(
                accountID: "codex", provider: .codex, plan: "Plus",
                windows: [
                    window("session", "5-hour", 8, 300, resetIn: 4 * 3600 + 20 * 60),
                    window("weekly", "Week", 34, 10_080, resetIn: 5 * 86_400 + 2 * 3600),
                ],
                money: [MoneyLine(label: "Credits", amount: 0)],
                fetchedAt: now.addingTimeInterval(-80), source: "codex app-server"
            ),
            UsageSnapshot(
                accountID: "opencode-go", provider: .opencodeGo, plan: "Go",
                windows: [
                    window("session", "5-hour", 0, 300, resetIn: 5 * 3600, notStarted: true),
                    window("weekly", "Week", 45, 10_080, resetIn: 1 * 86_400 + 9 * 3600),
                    window("monthly", "Month", 61, 43_200, resetIn: 12 * 86_400),
                ],
                fetchedAt: now.addingTimeInterval(-120), source: "opencode API"
            ),
            UsageSnapshot(
                accountID: "opencode-zen", provider: .opencodeZen, plan: "Pay as you go",
                money: [MoneyLine(label: "Spent this month (this Mac)", amount: 8.17)],
                fetchedAt: now.addingTimeInterval(-120), source: "opencode.db",
                notes: ["Balance needs a console sign-in; showing local spend only."]
            ),
        ]
        for snapshot in snapshots {
            model.statuses[snapshot.accountID] = AccountStatus(snapshot: snapshot, error: nil, lastAttempt: snapshot.fetchedAt)
        }
        model.statuses["antigravity"] = AccountStatus(snapshot: nil, error: .cliNotFound("agy"), lastAttempt: now.addingTimeInterval(-60))

        let store = InMemoryUsageStore()
        var rng = PreviewRandom(seed: 7)
        // Window history: a sawtooth per window that resets at each window boundary, sampled every 15 minutes for 30 days.
        for snapshot in snapshots {
            for w in snapshot.windows {
                guard let minutes = w.windowMinutes, let resetsAt = w.resetsAt else { continue }
                let length = Double(minutes) * 60
                var samples: [WindowSample] = []
                var t = now.addingTimeInterval(-30 * 86_400)
                while t <= now {
                    let untilReset = resetsAt.timeIntervalSince(t).truncatingRemainder(dividingBy: length)
                    let cycleReset = t.addingTimeInterval(untilReset < 0 ? untilReset + length : untilReset)
                    let elapsed = 1 - cycleReset.timeIntervalSince(t) / length
                    let target = w.usedPercent / max(0.05, 1 - resetsAt.timeIntervalSince(now) / length)
                    let used = min(100, max(0, elapsed * target * (0.85 + rng.next() * 0.3)))
                    samples.append(WindowSample(accountID: snapshot.accountID, windowID: w.id, timestamp: t, usedPercent: used, resetsAt: cycleReset))
                    t = t.addingTimeInterval(15 * 60)
                }
                if let last = samples.indices.last { samples[last].usedPercent = w.usedPercent }
                store.addSamples(samples)
            }
        }

        // Daily usage events for 30 days across harnesses, models and projects.
        let projects = ["headroom", "dotfiles", "mobile-app", "data-pipeline"]
        let mixes: [(String, Harness, String, Double, Bool)] = [
            ("claude-personal", .claudeCode, "claude-opus-5-5", 1.0, false),
            ("claude-personal", .claudeCode, "claude-fable-5-1", 0.4, false),
            ("claude-work", .claudeCode, "claude-sonnet-5-5", 0.8, false),
            ("codex", .codex, "gpt-5.5-codex", 0.5, false),
            ("opencode-go", .opencode, "glm-5.2", 0.3, true),
            ("opencode-zen", .opencode, "kimi-k3", 0.2, true),
        ]
        var events: [UsageEvent] = []
        for day in 0..<30 {
            let dayStart = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(day) * 86_400 + 10 * 3600)
            let weekday = Calendar.current.component(.weekday, from: dayStart)
            let weekendFactor = (weekday == 1 || weekday == 7) ? 0.35 : 1.0
            for (index, mix) in mixes.enumerated() {
                let requests = Int(Double(40 + Int(rng.next() * 80)) * mix.3 * weekendFactor)
                for r in 0..<requests {
                    let project = projects[(r + index + day) % projects.count]
                    let input = 2_000 + Int(rng.next() * 6_000)
                    let output = 300 + Int(rng.next() * 1_800)
                    let cacheRead = 40_000 + Int(rng.next() * 120_000)
                    events.append(UsageEvent(
                        dedupeKey: "preview:\(day):\(index):\(r)", timestamp: dayStart.addingTimeInterval(Double(r) * 120),
                        accountID: mix.0, harness: mix.1, model: mix.2, project: project,
                        inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWrite5mTokens: input / 2,
                        reportedCostUSD: mix.4 ? Double(input + output * 4) / 1_000_000 * 1.2 : nil
                    ))
                }
            }
        }
        try? store.upsert(events)
        model.store = store
        model.priceTable = PriceTable(prices: [
            "claude-opus-5-5": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10, source: "preview placeholder", asOf: "preview"),
            "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 20, source: "preview placeholder", asOf: "preview"),
            "claude-sonnet-5-5": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6, source: "preview placeholder", asOf: "preview"),
            "gpt-5.5-codex": ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 1.25, cacheWrite1h: 1.25, source: "preview placeholder", asOf: "preview"),
        ])
        return model
    }
}

struct PreviewRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
