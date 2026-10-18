import Foundation
import Testing
@testable import TokenjarCore

struct TraySummaryTests {
    private let now = Date(timeIntervalSince1970: 1_791_660_000)
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let codex = AccountConfig(id: "codex", provider: .codex, label: "ChatGPT")

    private func snapshot(_ account: AccountConfig, used: Double, fetchedAt: Date? = nil, plan: String? = nil) -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id, provider: account.provider, plan: plan,
            windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: used, windowMinutes: 300, resetsAt: now.addingTimeInterval(7_800))],
            fetchedAt: fetchedAt ?? now, source: "test"
        )
    }

    private func summary(
        _ accounts: [AccountConfig], _ snapshots: [UsageSnapshot], checks: [String: RefreshEngine.Check] = [:],
        latched: [String: ProbeLatch.CLI] = [:], configProblem: String? = nil
    ) -> TraySummary {
        var config = AppConfig()
        config.accounts = accounts
        return TraySummary.make(
            report: StatusReport.make(config: config, snapshots: snapshots, now: now), config: config, checks: checks,
            latched: latched, configProblem: configProblem, now: now
        )
    }

    @Test func theIconCarriesTheFullestAccountShownInTheMenuBar() {
        var hidden = codex
        hidden.showInMenuBar = false
        let result = summary([claude, hidden], [snapshot(claude, used: 42), snapshot(hidden, used: 90)])

        #expect(result.iconText == "42")
        #expect(result.level == .ok)
        #expect(result.tooltip == "Tokenjar: Claude 42%")
        #expect(result.sections.map(\.accountID) == ["claude", "codex"])
    }

    @Test func eachWindowGetsALineWithItsReset() throws {
        let result = summary([claude], [snapshot(claude, used: 41.6, plan: "Max")])

        let section = try #require(result.sections.first)
        #expect(section.title == "Claude · Personal (Max)")
        #expect(section.lines == ["5-hour: 42% · resets in 2h 10m"])
        #expect(section.problem == nil)
    }

    @Test func nothingCheckedYetShowsADash() {
        let result = summary([claude], [])

        #expect(result.iconText == "-")
        #expect(result.level == .none)
        #expect(result.tooltip == "Tokenjar")
        #expect(result.sections.first?.problem == "Not checked yet.")
    }

    @Test func aFailedCheckSaysWhyInTheMacAppsWords() {
        let result = summary([codex], [snapshot(codex, used: 10)], checks: ["codex": RefreshEngine.Check(at: now, error: .timeout)])

        #expect(result.sections.first?.problem == FetchError.timeout.userMessage(provider: .codex))
    }

    @Test func numbersTheCLISavedSayWhyAndHowOldTheyAre() {
        var cached = snapshot(claude, used: 11, fetchedAt: now.addingTimeInterval(-45_900))
        cached.notes = ["Can't find the claude command. Showing the last values Claude Code saved."]
        let result = summary([claude], [cached])

        #expect(result.sections.first?.problem == "Can't find the claude command. Showing the last values Claude Code saved. These numbers are 12h 45m old.")
    }

    @Test func aLatchedAccountSaysItsProbeStartedAModelTurn() {
        let result = summary([claude], [snapshot(claude, used: 10)], checks: ["claude": RefreshEngine.Check(at: now, error: .timeout)], latched: ["claude": .claude])

        #expect(result.sections.first?.problem == ProbeLatch.CLI.claude.modelTurnError.userMessage)
        #expect(result.sections.first?.isLatched == true)
    }

    @Test func theIconColorsByTheMenuBarThresholds() {
        var config = AppConfig()
        config.accounts = [claude]
        func level(_ used: Double) -> TraySummary.Level {
            TraySummary.make(
                report: StatusReport.make(config: config, snapshots: [snapshot(claude, used: used)], now: now), config: config,
                checks: [:], latched: [:], configProblem: nil, now: now
            ).level
        }
        let warnAt = Double(config.menuBar.warnAt), criticalAt = Double(config.menuBar.criticalAt)

        #expect(level(warnAt - 1) == .ok)
        #expect(level(warnAt) == .warning)
        #expect(level(criticalAt) == .critical)
    }

    @Test func theTextListsEachSectionWithItsProblem() {
        let result = summary([claude, codex], [snapshot(claude, used: 42)])

        #expect(result.text == """
        Claude · Personal
          5-hour: 42% · resets in 2h 10m

        Codex · ChatGPT
          Not checked yet.
        """)
    }

    @Test func aConfigProblemTakesTheTooltipAndALongOneIsCut() {
        let long = String(repeating: "x", count: 200)
        let result = summary([claude], [snapshot(claude, used: 10)], configProblem: long)

        #expect(result.tooltip.count == TraySummary.tooltipLimit)
        #expect(result.tooltip.hasPrefix("Tokenjar: xxx"))
        #expect(result.tooltip.hasSuffix("…"))
    }

    private static let countdowns: [(TimeInterval, String)] = [
        (0, "under a minute"), (59, "under a minute"), (2_700, "45m"), (7_200, "2h"), (7_800, "2h 10m"), (259_200, "3d"),
        (273_600, "3d 4h"), (-60, "under a minute"),
    ]

    @Test(arguments: countdowns)
    func countdown(seconds: TimeInterval, expected: String) {
        #expect(TraySummary.countdown(from: now, to: now.addingTimeInterval(seconds)) == expected)
    }
}
