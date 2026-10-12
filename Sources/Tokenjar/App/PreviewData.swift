import Foundation
import TokenjarCore

extension AppPaths {
    /// Preview renders end up in the README and in PRs, so they never see the local home folder, stow links or XDG
    /// variables.
    static let preview = AppPaths(home: URL(fileURLWithPath: "/Users/you"), environment: [:], systemRoot: URL(fileURLWithPath: "/var/empty"))
}

/// Deterministic sample data for `--render-snapshots` and visual checks. Prices here are placeholders, not real.
extension AppModel {
    static func preview(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = AppModel(paths: .preview)
        model.now = now
        model.popoverNow = now
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
                AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
                AccountConfig(id: "devin", provider: .devin, label: "Devin", showInMenuBar: false),
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
                accountID: "claude-work", provider: .claude, plan: "Team",
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
        let antigravity = UsageSnapshot(
            accountID: "antigravity", provider: .antigravity,
            windows: [
                window("gemini:session", "Gemini · 5-hour", 22, 300, resetIn: 3 * 3600 + 5 * 60),
                window("gemini:weekly", "Gemini · Week", 38, 10_080, resetIn: 4 * 86_400),
                window("claude-and-gpt:weekly", "Claude and GPT · Week", 71, 10_080, resetIn: 4 * 86_400),
            ],
            fetchedAt: now.addingTimeInterval(-300), source: "agy CLI"
        )
        // A Pro plan includes 1,500 AI credits a month; this cycle ends 2026-11-01 00:00 UTC.
        let copilot = UsageSnapshot(
            accountID: "copilot", provider: .copilot, plan: "Pro",
            windows: [window("monthly", "AI credits", 300.0 / 1_500 * 100, 44_640, resetIn: 1_793_491_200 - now.timeIntervalSince1970)],
            fetchedAt: now.addingTimeInterval(-100), source: "gh CLI"
        )
        for snapshot in snapshots + [antigravity, copilot, devinLink(now: now)] {
            model.statuses[snapshot.accountID] = AccountStatus(snapshot: snapshot, error: nil, lastAttempt: snapshot.fetchedAt)
        }

        let store = InMemoryUsageStore()
        var rng = PreviewRandom(seed: 7)
        // Window history for 30 days at 15-minute samples. Usage only grows inside a cycle and drops at each reset;
        // the current cycle ends exactly at the snapshot's value.
        for snapshot in snapshots + [antigravity, copilot] {
            for w in snapshot.windows {
                guard let minutes = w.windowMinutes, let resetsAt = w.resetsAt else { continue }
                let length = Double(minutes) * 60
                let start = now.addingTimeInterval(-30 * 86_400)
                var cycleEnd = resetsAt
                while cycleEnd.addingTimeInterval(-length) > start { cycleEnd = cycleEnd.addingTimeInterval(-length) }
                var samples: [WindowSample] = []
                while cycleEnd.addingTimeInterval(-length) <= now {
                    let cycleStart = cycleEnd.addingTimeInterval(-length)
                    let isCurrent = cycleEnd > now
                    let last = isCurrent ? now : cycleEnd
                    var times: [Date] = []
                    var t = max(cycleStart, start)
                    while t <= last { times.append(t); t = t.addingTimeInterval(15 * 60) }
                    let increments = times.map { time -> Double in
                        let hour = Calendar.current.component(.hour, from: time)
                        return (9...19).contains(hour) ? 0.4 + rng.next() * 1.2 : rng.next() * 0.1
                    }
                    let total = max(increments.reduce(0, +), 0.0001)
                    let peak = isCurrent ? w.usedPercent : min(96, 25 + rng.next() * 60)
                    var running = 0.0
                    for (time, increment) in zip(times, increments) {
                        running += increment
                        samples.append(WindowSample(accountID: snapshot.accountID, windowID: w.id, timestamp: time, usedPercent: running / total * peak, resetsAt: cycleEnd))
                    }
                    cycleEnd = cycleEnd.addingTimeInterval(length)
                }
                store.addSamples(samples)
            }
        }

        // Daily usage events for 30 days across harnesses, models and projects.
        let projects = ["tokenjar", "website", "mobile-app", "data-pipeline"]
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

extension AppModel {
    /// Edge states for visual review: stale, refreshing, full window, signed out, no subscription, network error,
    /// a window whose reset has passed since the last check, and a pasted key the Keychain refused.
    static func previewStates(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = AppModel(paths: .preview)
        model.previewMode = true
        model.now = now
        model.popoverNow = now
        model.lastRefreshAt = now.addingTimeInterval(-40)
        model.config = AppConfig(accounts: [
            AccountConfig(id: "full", provider: .claude, label: "Personal"),
            AccountConfig(id: "stale", provider: .codex, label: "Plus"),
            AccountConfig(id: "refreshing", provider: .claude, label: "Work"),
            AccountConfig(id: "signed-out", provider: .codex, label: "Work"),
            AccountConfig(id: "no-sub", provider: .opencodeGo, label: "Go"),
            AccountConfig(id: "offline", provider: .claude, label: "Team"),
            AccountConfig(id: "no-limits", provider: .claude, label: "API"),
            AccountConfig(id: "devin", provider: .devin, label: "Devin"),
            AccountConfig(id: "past-reset", provider: .claude, label: "Max"),
            AccountConfig(id: "pasted-key", provider: .opencodeGo, label: "Pasted key", credential: .keychain(account: "pasted-key")),
        ])
        func window(_ id: String, _ label: String, _ used: Double, _ minutes: Int, resetIn: TimeInterval) -> UsageWindow {
            UsageWindow(id: id, label: label, usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetIn))
        }
        model.statuses = [
            "full": AccountStatus(snapshot: UsageSnapshot(accountID: "full", provider: .claude, plan: "Pro", windows: [
                window("session", "5-hour", 100, 300, resetIn: 47 * 60), window("weekly", "Week", 58, 10_080, resetIn: 3 * 86_400),
            ], fetchedAt: now.addingTimeInterval(-60), source: "claude CLI")),
            "stale": AccountStatus(snapshot: UsageSnapshot(accountID: "stale", provider: .codex, plan: "Plus", windows: [
                window("session", "5-hour", 31, 300, resetIn: 2 * 3600), window("weekly", "Week", 12, 10_080, resetIn: 6 * 86_400),
            ], fetchedAt: now.addingTimeInterval(-3 * 3600), source: "Codex session log")),
            "refreshing": AccountStatus(snapshot: UsageSnapshot(accountID: "refreshing", provider: .claude, plan: "Enterprise", windows: [
                window("session", "5-hour", 54, 300, resetIn: 3600), window("weekly", "Week", 81, 10_080, resetIn: 86_400),
            ], fetchedAt: now.addingTimeInterval(-600), source: "claude CLI"), isRefreshing: true),
            "signed-out": AccountStatus(error: .notSignedIn, lastAttempt: now.addingTimeInterval(-30)),
            "no-sub": AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key"), lastAttempt: now.addingTimeInterval(-30)),
            "offline": AccountStatus(snapshot: UsageSnapshot(accountID: "offline", provider: .claude, plan: "Team", windows: [
                window("session", "5-hour", 12, 300, resetIn: 4 * 3600),
            ], fetchedAt: now.addingTimeInterval(-50 * 60), source: "Claude Code cache"), error: .network("offline"), lastAttempt: now.addingTimeInterval(-20)),
            "no-limits": AccountStatus(snapshot: UsageSnapshot(accountID: "no-limits", provider: .claude, fetchedAt: now.addingTimeInterval(-60), source: "claude CLI", notes: ["No plan limits for this login"])),
            // In the menu bar on purpose: a link card must never be its worst account or count as needing attention.
            "devin": AccountStatus(snapshot: devinLink(now: now)),
            // Checked before its 5-hour window reset 5 minutes ago; the 100 % belongs to the cycle that ended.
            "past-reset": AccountStatus(snapshot: UsageSnapshot(accountID: "past-reset", provider: .claude, plan: "Max 5x", windows: [
                window("session", "5-hour", 100, 300, resetIn: -5 * 60), window("weekly", "Week", 64, 10_080, resetIn: 3 * 86_400),
            ], fetchedAt: now.addingTimeInterval(-8 * 60), source: "claude CLI")),
            "pasted-key": AccountStatus(error: .keychainDenied, lastAttempt: now.addingTimeInterval(-30)),
        ]
        model.store = InMemoryUsageStore()
        return model
    }
}

extension AppModel {
    /// A Mac where no account is set up or found.
    static func previewEmpty(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = AppModel(paths: .preview)
        model.previewMode = true
        model.now = now
        model.popoverNow = now
        model.store = InMemoryUsageStore()
        return model
    }
}

extension AppModel {
    /// What DevinUsageFetcher returns for an account without a usage page override.
    fileprivate static func devinLink(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: "devin", provider: .devin, fetchedAt: now.addingTimeInterval(-60), source: DevinUsageFetcher.source,
            notes: [DevinUsageFetcher.noQuotaNote, DevinUsageFetcher.windsurfNote]
        )
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
