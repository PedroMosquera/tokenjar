import Foundation

/// What a tray icon and its menu show, worked out from `RefreshEngine` so the drawing code only draws. The icon carries
/// the fullest tightest window among the accounts shown in the menu bar, the Mac menu bar's number, and the menu has one
/// section per enabled account in config order.
public struct TraySummary: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var accountID: String
        /// "Claude · Personal (Max)".
        public var title: String
        /// One per window: "5-hour: 42% · resets in 2h 10m".
        public var lines: [String]
        /// Why the numbers are missing or old, in the words the Mac app uses; nil when the last check answered.
        public var problem: String?
        /// Its probe started a model turn, so only an explicit retry checks it again.
        public var isLatched: Bool
        public var usagePage: URL
    }

    /// The icon's color, from the menu bar's `warnAt` and `criticalAt`. `none` while no account has a number.
    public enum Level: Equatable, Sendable { case none, ok, warning, critical }

    /// The icon's number without a percent sign, "-" while no account has one yet.
    public var iconText: String
    public var level: Level
    /// Windows cuts a tray tooltip at 127 characters.
    public var tooltip: String
    public var sections: [Section]

    public static let tooltipLimit = 127

    /// Before the first check ends.
    public static let empty = TraySummary(iconText: "-", level: .none, tooltip: "Tokenjar", sections: [])

    public static func make(
        report: StatusReport, config: AppConfig, checks: [String: RefreshEngine.Check], latched: [String: ProbeLatch.CLI],
        configProblem: String?, now: Date
    ) -> TraySummary {
        let accounts = Dictionary(config.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sections: [Section] = []
        var shown: [(label: String, percent: Double)] = []
        for entry in report.accounts {
            guard let account = accounts[entry.id] else { continue }
            let tightest = entry.windows.first { $0.id == entry.tightestWindowID }
            if account.showInMenuBar, let tightest { shown.append((account.provider.displayName, tightest.usedPercent)) }
            let plan = entry.plan.map { " (\($0))" } ?? ""
            let lines = entry.windows.map { window in
                var line = "\(window.label): \(percent(window.usedPercent))"
                if let resetsAt = window.resetsAt { line += " · resets in \(countdown(from: now, to: resetsAt))" }
                if window.runsOutBeforeReset == true { line += " · on pace to run out" }
                return line
            }
            var problem: String?
            if let cli = latched[entry.id] {
                problem = cli.modelTurnError.userMessage
            } else if let error = checks[entry.id]?.error {
                problem = error.userMessage(provider: account.provider)
            } else if entry.stale, let fetchedAt = entry.fetchedAt {
                problem = "Last checked \(countdown(from: fetchedAt, to: now)) ago."
            } else if entry.fetchedAt == nil, checks[entry.id] == nil {
                problem = "Not checked yet."
            }
            sections.append(Section(
                accountID: entry.id, title: account.displayName + plan, lines: lines, problem: problem,
                isLatched: latched[entry.id] != nil, usagePage: account.resolvedDashboardURL
            ))
        }

        let fullest = shown.max { $0.percent < $1.percent }
        var tooltip = shown.isEmpty ? "Tokenjar" : "Tokenjar: " + shown.map { "\($0.label) \(percent($0.percent))" }.joined(separator: ", ")
        if let configProblem { tooltip = "Tokenjar: " + configProblem }
        if tooltip.count > tooltipLimit { tooltip = String(tooltip.prefix(tooltipLimit - 1)) + "…" }
        let level: Level = switch fullest?.percent {
        case nil: .none
        case let percent? where percent >= Double(config.menuBar.criticalAt): .critical
        case let percent? where percent >= Double(config.menuBar.warnAt): .warning
        default: .ok
        }
        return TraySummary(
            iconText: fullest.map { String(Int($0.percent.rounded())) } ?? "-", level: level, tooltip: tooltip, sections: sections
        )
    }

    /// The menu as plain text, one section after another, for `tokenjar --check`.
    public var text: String {
        sections.map { section in
            ([section.title] + section.lines.map { "  " + $0 } + (section.problem.map { ["  " + $0] } ?? [])).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "2h 10m", "3d 4h", "45m", or "under a minute".
    static func countdown(from start: Date, to end: Date) -> String {
        let minutes = Int(max(0, end.timeIntervalSince(start)) / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }
}
