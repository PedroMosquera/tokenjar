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
                AccountConfig(id: "codex", provider: .codex, label: "Pro"),
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
                accountID: "claude-personal", provider: .claude, plan: "Max 5x",
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
                money: [MoneyLine(label: "Extra usage", amount: 18.75, limit: 100)],
                fetchedAt: now.addingTimeInterval(-95), source: "claude CLI"
            ),
            UsageSnapshot(
                accountID: "codex", provider: .codex, plan: "Pro",
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
    /// Claude's 5-hour window is full while Codex has barely started, so the header names Codex under the red title.
    static func previewLimitHit(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = AppModel(paths: .preview)
        model.previewMode = true
        model.now = now
        model.popoverNow = now
        model.lastRefreshAt = now.addingTimeInterval(-60)
        model.config = AppConfig(refreshMinutes: 10, accounts: [
            AccountConfig(id: "claude-personal", provider: .claude, label: "Personal"),
            AccountConfig(id: "codex", provider: .codex, label: "Plus"),
            AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/.local/share/opencode/auth.json", key: "opencode-go")),
            AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", showInMenuBar: false),
            AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
        ])
        func window(_ id: String, _ label: String, _ used: Double, _ minutes: Int, resetIn: TimeInterval, notStarted: Bool = false) -> UsageWindow {
            UsageWindow(id: id, label: label, usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetIn), notStarted: notStarted)
        }
        let checked = now.addingTimeInterval(-60)
        let snapshots = [
            UsageSnapshot(
                accountID: "claude-personal", provider: .claude, plan: "Max 5x",
                windows: [
                    window("session", "5-hour", 100, 300, resetIn: 87 * 60),
                    window("weekly", "Week", 40, 10_080, resetIn: 3 * 86_400 + 5 * 3_600),
                    window("weekly:Fable", "Week · Fable", 56, 10_080, resetIn: 3 * 86_400 + 5 * 3_600),
                ],
                fetchedAt: checked, source: ClaudeUsageFetcher.source
            ),
            UsageSnapshot(
                accountID: "codex", provider: .codex, plan: "Plus",
                windows: [
                    window("session", "5-hour", 2, 300, resetIn: 4 * 3_600 + 40 * 60),
                    window("weekly", "Week", 0, 10_080, resetIn: 7 * 86_400, notStarted: true),
                ],
                fetchedAt: checked, source: "codex app-server"
            ),
            UsageSnapshot(
                accountID: "opencode-zen", provider: .opencodeZen, plan: "Pay as you go",
                money: [MoneyLine(label: "Spent this month (this Mac)", amount: 8.17)],
                fetchedAt: checked, source: "opencode.db", notes: ["Balance needs a console sign-in; showing local spend only."]
            ),
            UsageSnapshot(
                accountID: "copilot", provider: .copilot, plan: "Enterprise",
                windows: [window("monthly", "Premium requests", 15, 44_640, resetIn: 19 * 86_400 + 14 * 3_600)],
                fetchedAt: checked, source: "gh CLI"
            ),
        ]
        for snapshot in snapshots {
            model.statuses[snapshot.accountID] = AccountStatus(snapshot: snapshot, lastAttempt: checked)
        }
        model.statuses["opencode-go"] = AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key"), lastAttempt: checked)
        model.store = InMemoryUsageStore()
        return model
    }
}

extension AppModel {
    /// Status pages report a problem for each provider with a feed, one kind of row each, under "All clear": a titled
    /// outage of the three Claude products the feed names in most incidents, with one more item, on both Claude cards; an
    /// untitled outage of four Codex products plus maintenance, answered 40 minutes ago; and two Copilot incidents matched
    /// by name with a long title, answered over an hour ago. The last Codex check could not read its answer and the last
    /// Copilot check timed out, which only Settings shows.
    static func previewIncident(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = healthPreview(now: now, accounts: [
            AccountConfig(id: "claude-personal", provider: .claude, label: "Personal"),
            AccountConfig(id: "claude-work", provider: .claude, label: "Work"),
            AccountConfig(id: "codex", provider: .codex, label: "Plus"),
            AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
        ])
        model.providerHealth = [
            .claude: health(now: now, answeredAgo: 60, askedAgo: 120, [
                ProviderHealthItem(level: .partialOutage, names: ["Claude Code", "claude.ai", "Claude API"], title: "Elevated errors for Claude Opus 5.5"),
                ProviderHealthItem(level: .maintenance, names: ["claude.ai"], title: "Scheduled maintenance of claude.ai"),
            ]),
            .codex: health(now: now, answeredAgo: 40 * 60, askedAgo: 41 * 60, failure: .parse("page data has no group"), [
                ProviderHealthItem(level: .partialOutage, names: ["Codex CLI", "Codex Web", "Codex API", "Codex VS Code extension"]),
                ProviderHealthItem(level: .maintenance, names: ["Codex in ChatGPT Desktop"]),
            ]),
            .copilot: health(now: now, answeredAgo: 65 * 60, askedAgo: 66 * 60, failure: .timeout, [
                ProviderHealthItem(level: .incident, names: ["Copilot"], title: "Copilot Code Review is unable to complete reviews on pull requests in some large repositories"),
                ProviderHealthItem(level: .incident, names: ["Copilot"], title: "Disruption with Copilot for access to some models"),
            ]),
        ]
        return model
    }

    /// Everything calm, and only GitHub Copilot, the last card, in a major outage: the header's caption says so. Claude's
    /// maintenance and Codex's degraded performance stay on their cards; Codex's row, the longest watched name with one
    /// more item and an answer over an hour old, must keep its count and age.
    static func previewAllClearOutage(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = healthPreview(now: now, accounts: [
            AccountConfig(id: "claude-personal", provider: .claude, label: "Personal"),
            AccountConfig(id: "codex", provider: .codex, label: "Plus"),
            AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/.local/share/opencode/auth.json", key: "opencode-go")),
            AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", showInMenuBar: false),
            AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
        ])
        model.providerHealth = [
            .claude: health(now: now, answeredAgo: 60, askedAgo: 60, [
                ProviderHealthItem(level: .maintenance, names: ["Claude Code"], title: "Planned database maintenance"),
            ]),
            .codex: health(now: now, answeredAgo: 65 * 60, askedAgo: 66 * 60, [
                ProviderHealthItem(level: .degradedPerformance, names: ["Codex in ChatGPT Desktop"]),
                ProviderHealthItem(level: .maintenance, names: ["Codex VS Code extension"]),
            ]),
            .copilot: health(now: now, answeredAgo: 60, askedAgo: 60, [
                ProviderHealthItem(level: .majorOutage, names: ["Copilot"], title: "Incident with GitHub.com"),
            ]),
        ]
        return model
    }

    /// Calm usage on every account, so the header reads "All clear", with provider status on.
    private static func healthPreview(now: Date, accounts: [AccountConfig]) -> AppModel {
        let model = AppModel(paths: .preview)
        model.previewMode = true
        model.setProviderStatus(true)
        model.now = now
        model.popoverNow = now
        model.lastRefreshAt = now.addingTimeInterval(-60)
        model.config = AppConfig(refreshMinutes: 10, accounts: accounts)
        let checked = now.addingTimeInterval(-60)
        for account in accounts {
            let windows: [UsageWindow]
            switch account.provider {
            case .claude: windows = [
                    UsageWindow(id: "session", label: "5-hour", usedPercent: 24, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3_600 + 20 * 60)),
                    UsageWindow(id: "weekly", label: "Week", usedPercent: 38, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400)),
                ]
            case .codex: windows = [UsageWindow(id: "session", label: "5-hour", usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(4 * 3_600))]
            case .copilot: windows = [UsageWindow(id: "monthly", label: "Premium requests", usedPercent: 15, windowMinutes: 44_640, resetsAt: now.addingTimeInterval(19 * 86_400))]
            default: windows = []
            }
            switch account.provider {
            case .opencodeGo:
                model.statuses[account.id] = AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key"), lastAttempt: checked)
            case .opencodeZen:
                model.statuses[account.id] = AccountStatus(snapshot: UsageSnapshot(
                    accountID: account.id, provider: .opencodeZen, plan: "Pay as you go", money: [MoneyLine(label: "Spent this month (this Mac)", amount: 8.17)],
                    fetchedAt: checked, source: "opencode.db", notes: ["Balance needs a console sign-in; showing local spend only."]
                ), lastAttempt: checked)
            default:
                model.statuses[account.id] = AccountStatus(
                    snapshot: UsageSnapshot(accountID: account.id, provider: account.provider, windows: windows, fetchedAt: checked, source: "preview"), lastAttempt: checked
                )
            }
        }
        model.store = InMemoryUsageStore()
        return model
    }

    /// An answer that arrived `answeredAgo`, from a check started `askedAgo`, then a failed check a minute ago when
    /// `failure` is set.
    private static func health(
        now: Date, answeredAgo: TimeInterval, askedAgo: TimeInterval, failure: FetchError? = nil, _ items: [ProviderHealthItem]
    ) -> ProviderHealth {
        var health = ProviderHealth()
        health.asked(at: now.addingTimeInterval(-askedAgo))
        health.record(.success(ProviderHealthAnswer(items: items, answeredAt: now.addingTimeInterval(-answeredAgo))))
        if let failure {
            health.asked(at: now.addingTimeInterval(-60))
            health.record(.failure(failure))
        }
        return health
    }
}

extension AppModel {
    /// A Mac offline for 25 minutes. Every network check is held, so the cards keep their last numbers; the last batch
    /// of checks ended a minute ago, which the header must not call "Updated".
    static func previewOffline(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = outagePreview(now: now, accounts: outageAccounts)
        model.statuses = outageStatuses(now: now, claude: outageClaude(now: now, ago: 25 * 60), codexFailure: .network, goError: nil, copilotError: .timeout)
        model.connectivity = .offline
        return model
    }

    /// Online, but no provider answers: a VPN, a proxy or a Wi-Fi sign-in page.
    static func previewNoAnswer(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = outagePreview(now: now, accounts: outageAccounts)
        var claude = outageClaude(now: now, ago: 3 * 3_600)
        claude.source = ClaudeUsageFetcher.cacheSource
        claude.liveCheckFailure = .timeout
        claude.notes = [ClaudeUsageFetcher.cacheNote]
        model.statuses = outageStatuses(now: now, claude: claude, codexFailure: .network, goError: .network("dial tcp"), copilotError: .timeout)
        model.connectivity = .noAnswer
        return model
    }

    /// Online, and only GitHub Copilot can't be reached: the header names it in gray and its card keeps Retry.
    static func previewPartialOutage(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = outagePreview(now: now, accounts: Array(outageAccounts.prefix(5)))
        var statuses = outageStatuses(now: now, claude: outageClaude(now: now, ago: 60), codexFailure: nil, goError: nil, copilotError: .network("dial tcp"))
        statuses["opencode-go"] = AccountStatus(snapshot: UsageSnapshot(
            accountID: "opencode-go", provider: .opencodeGo, plan: "Go",
            windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: 18, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400))],
            fetchedAt: now.addingTimeInterval(-60), source: "opencode API"
        ), lastAttempt: now.addingTimeInterval(-60))
        statuses["claude-personal"] = nil
        statuses["codex-work"] = nil
        model.statuses = statuses
        return model
    }

    /// config.json failed to load at launch, so nothing at all is loaded.
    static func previewSettingsUnloaded(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = previewEmpty(now: now)
        model.showFailedLoad(of: "config.json", nothingLoaded: true)
        return model
    }

    private static let outageAccounts = [
        AccountConfig(id: "claude-team", provider: .claude, label: "Team"),
        AccountConfig(id: "codex", provider: .codex, label: "ChatGPT"),
        AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go", credential: .file(path: "~/.local/share/opencode/auth.json", key: "opencode-go")),
        AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen", showInMenuBar: false),
        AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
        AccountConfig(id: "claude-personal", provider: .claude, label: "Personal"),
        AccountConfig(id: "codex-work", provider: .codex, label: "Work"),
    ]

    private static func outagePreview(now: Date, accounts: [AccountConfig]) -> AppModel {
        let model = AppModel()
        model.previewMode = true
        model.now = now
        model.popoverNow = now
        model.lastRefreshAt = now.addingTimeInterval(-60)
        model.config = AppConfig(refreshMinutes: 10, accounts: accounts)
        model.store = InMemoryUsageStore()
        return model
    }

    private static func outageClaude(now: Date, ago: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            accountID: "claude-team", provider: .claude, plan: "Team",
            windows: [
                UsageWindow(id: "session", label: "5-hour", usedPercent: 16, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3_600)),
                UsageWindow(id: "weekly", label: "Week", usedPercent: 41, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400)),
            ],
            fetchedAt: now.addingTimeInterval(-ago), source: ClaudeUsageFetcher.source
        )
    }

    /// The accounts every outage preview shows. `codexFailure` makes Codex's card the copy it logged two days ago;
    /// `goError` and `copilotError` are those accounts' latest check.
    private static func outageStatuses(
        now: Date, claude: UsageSnapshot, codexFailure: LiveCheckFailure?, goError: FetchError?, copilotError: FetchError?
    ) -> [String: AccountStatus] {
        let attempt = now.addingTimeInterval(-60)
        let codexAge: TimeInterval = codexFailure == nil ? 60 : 2 * 86_400
        let codex = UsageSnapshot(
            accountID: "codex", provider: .codex, plan: "Plus",
            windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: 2, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400 + 2 * 3_600))],
            fetchedAt: now.addingTimeInterval(-codexAge), source: codexFailure == nil ? "codex app-server" : "Codex session log",
            notes: codexFailure == nil ? [] : ["Live check unavailable; showing the last limits Codex logged."], liveCheckFailure: codexFailure
        )
        let copilotAge: TimeInterval = copilotError == nil ? 60 : 25 * 60
        let copilot = UsageSnapshot(
            accountID: "copilot", provider: .copilot, plan: "Pro",
            windows: [UsageWindow(id: "monthly", label: "AI credits", usedPercent: 300.0 / 1_500 * 100, windowMinutes: 44_640, resetsAt: now.addingTimeInterval(19 * 86_400 + 14 * 3_600))],
            fetchedAt: now.addingTimeInterval(-copilotAge), source: "gh CLI"
        )
        let zen = UsageSnapshot(
            accountID: "opencode-zen", provider: .opencodeZen, plan: "Pay as you go",
            money: [MoneyLine(label: "Spent this month (this Mac)", amount: 0)],
            fetchedAt: now.addingTimeInterval(-60), source: "opencode.db", notes: ["Balance needs a console sign-in; showing local spend only."]
        )
        let personal = UsageSnapshot(
            accountID: "claude-personal", provider: .claude, plan: "Max 5x",
            windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 97, windowMinutes: 300, resetsAt: now.addingTimeInterval(70 * 60))],
            fetchedAt: now.addingTimeInterval(-25 * 60), source: ClaudeUsageFetcher.source
        )
        var statuses: [String: AccountStatus] = [
            "claude-team": AccountStatus(snapshot: claude, lastAttempt: attempt),
            "codex": AccountStatus(snapshot: codex, lastAttempt: attempt),
            "opencode-zen": AccountStatus(snapshot: zen, lastAttempt: attempt),
            "copilot": AccountStatus(snapshot: copilot, error: copilotError, lastAttempt: attempt),
            "claude-personal": AccountStatus(snapshot: personal, lastAttempt: personal.fetchedAt),
            "codex-work": AccountStatus(error: .notSignedIn, lastAttempt: attempt),
        ]
        if let goError { statuses["opencode-go"] = AccountStatus(error: goError, lastAttempt: attempt) }
        return statuses
    }

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

extension AppModel {
    /// A seat billed per use, with a spend limit and the recommended daily budget on, for the README's spend-limit image.
    /// $520 of $1,500 spent, $490 of it before today.
    static func previewSpendLimit(now: Date = Date(timeIntervalSince1970: 1_791_660_000)) -> AppModel {
        let model = AppModel(paths: .preview)
        model.now = now
        model.popoverNow = now
        model.lastRefreshAt = now.addingTimeInterval(-60)
        model.config = AppConfig(accounts: [AccountConfig(id: "claude-company", provider: .claude, label: "Company", dailyBudget: DailyBudget())])
        model.previewMode = true

        // This cycle ends 2026-11-01 00:00 UTC.
        let resetsAt = Date(timeIntervalSince1970: 1_793_491_200)
        let minutes = UsageWindow.monthMinutes(endingAt: resetsAt) ?? 44_640
        let cycleStart = resetsAt.addingTimeInterval(-Double(minutes) * 60)
        let limit = 1_500.0, spent = 520.0, spentBeforeToday = 490.0
        let window = UsageWindow(
            id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: spent / limit * 100, windowMinutes: minutes, resetsAt: resetsAt
        )
        let snapshot = UsageSnapshot(
            accountID: "claude-company", provider: .claude, plan: "Enterprise (usage-based)", windows: [window],
            money: [MoneyLine(label: "Extra usage", amount: spent, limit: limit)], fetchedAt: now.addingTimeInterval(-60), source: "claude CLI"
        )
        model.statuses[snapshot.accountID] = AccountStatus(snapshot: snapshot, error: nil, lastAttempt: snapshot.fetchedAt)

        // Hourly samples that climb to $490 by the end of yesterday and to $520 now.
        let todayStart = Calendar.current.startOfDay(for: now)
        var samples: [WindowSample] = []
        var time = cycleStart
        while time <= now {
            let amount = time < todayStart
                ? spentBeforeToday * time.timeIntervalSince(cycleStart) / todayStart.timeIntervalSince(cycleStart)
                : spentBeforeToday + (spent - spentBeforeToday) * time.timeIntervalSince(todayStart) / now.timeIntervalSince(todayStart)
            samples.append(WindowSample(
                accountID: snapshot.accountID, windowID: window.id, timestamp: time, usedPercent: amount / limit * 100, resetsAt: resetsAt
            ))
            time = time.addingTimeInterval(3_600)
        }
        let store = InMemoryUsageStore()
        store.addSamples(samples)
        model.store = store
        return model
    }
}
