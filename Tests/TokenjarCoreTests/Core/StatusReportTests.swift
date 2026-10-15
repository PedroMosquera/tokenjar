import Foundation
import Testing
@testable import TokenjarCore

struct StatusReportTests {
    let now = DateParsing.iso8601("2026-10-10T20:00:00Z")!

    func config(_ accounts: [AccountConfig]) -> AppConfig {
        AppConfig(refreshMinutes: 10, accounts: accounts)
    }

    func window(_ id: String, used: Double, startedHoursAgo: Double, lengthHours: Double) -> UsageWindow {
        UsageWindow(
            id: id, label: id, usedPercent: used, windowMinutes: Int(lengthHours * 60),
            resetsAt: now.addingTimeInterval((lengthHours - startedHoursAgo) * 3600)
        )
    }

    @Test func listsEnabledAccountsInConfigOrderWithTheirLastNumbers() throws {
        let accounts = [
            AccountConfig(id: "work", provider: .claude, label: "Work"),
            AccountConfig(id: "off", provider: .codex, label: "Off", enabled: false),
            AccountConfig(id: "plus", provider: .codex, label: "Plus"),
        ]
        let snapshots = [
            UsageSnapshot(accountID: "plus", provider: .codex, plan: "Plus", windows: [window("weekly", used: 10, startedHoursAgo: 24, lengthHours: 168)], fetchedAt: now.addingTimeInterval(-60), source: "t"),
            UsageSnapshot(accountID: "work", provider: .claude, plan: "Max 5x", windows: [
                window("session", used: 80, startedHoursAgo: 2, lengthHours: 5),
                window("weekly", used: 30, startedHoursAgo: 72, lengthHours: 168),
            ], fetchedAt: now.addingTimeInterval(-60), source: "t"),
        ]

        let report = StatusReport.make(config: config(accounts), snapshots: snapshots, now: now)

        #expect(report.version == 1)
        #expect(report.accounts.map(\.id) == ["work", "plus"])
        let work = try #require(report.accounts.first)
        #expect(work.label == "Work")
        #expect(work.provider == "claude")
        #expect(work.plan == "Max 5x")
        #expect(work.stale == false)
        #expect(work.tightestWindowID == "session")
        #expect(work.windows.map(\.id) == ["session", "weekly"])
        let session = try #require(work.windows.first)
        #expect(session.usedPercent == 80)
        #expect(session.expectedPercent == 40)
        #expect(session.runsOutBeforeReset == true)
    }

    /// `now` is a Saturday, so this weekly window has run into a weekend, where working-day pace differs from every-day pace.
    @Test func paceMatchesThePopoverEvenWithWorkingDays() throws {
        let account = AccountConfig(id: "work", provider: .claude, label: "Work")
        let weekly = window("weekly", used: 30, startedHoursAgo: 72, lengthHours: 168)
        let snapshot = UsageSnapshot(accountID: "work", provider: .claude, windows: [weekly], fetchedAt: now, source: "t")
        let config = AppConfig(refreshMinutes: 10, accounts: [account], paceDays: .workingDays)

        let reported = try #require(StatusReport.make(config: config, snapshots: [snapshot], now: now).accounts.first?.windows.first)

        let pace = try #require(Pace.compute(weekly, now: now))
        #expect(reported.expectedPercent == pace.expectedPercent)
        #expect(reported.runsOutBeforeReset == pace.runsOutBeforeReset)
    }

    @Test func aWindowPastItsResetIsLeftOut() {
        let account = AccountConfig(id: "work", provider: .claude, label: "Work")
        let snapshot = UsageSnapshot(accountID: "work", provider: .claude, windows: [
            window("session", used: 95, startedHoursAgo: 6, lengthHours: 5),
            window("weekly", used: 30, startedHoursAgo: 72, lengthHours: 168),
        ], fetchedAt: now.addingTimeInterval(-60), source: "t")

        let report = StatusReport.make(config: config([account]), snapshots: [snapshot], now: now)

        #expect(report.accounts.first?.windows.map(\.id) == ["weekly"])
        #expect(report.accounts.first?.tightestWindowID == "weekly")
    }

    @Test func oldOrMissingDataIsMarked() {
        let accounts = [AccountConfig(id: "old", provider: .claude, label: "Old"), AccountConfig(id: "new", provider: .codex, label: "New")]
        let old = UsageSnapshot(accountID: "old", provider: .claude, fetchedAt: now.addingTimeInterval(-21 * 60), source: "t")

        let report = StatusReport.make(config: config(accounts), snapshots: [old], now: now)

        #expect(report.accounts.map(\.stale) == [true, false])
        #expect(report.accounts.last?.fetchedAt == nil)
    }

    @Test func printsOneSortedJSONObjectWithISODates() throws {
        let account = AccountConfig(id: "work", provider: .claude, label: "Work")
        let snapshot = UsageSnapshot(accountID: "work", provider: .claude, windows: [window("session", used: 50, startedHoursAgo: 1, lengthHours: 5)], fetchedAt: now, source: "t")

        let text = String(decoding: try StatusReport.make(config: config([account]), snapshots: [snapshot], now: now).json(), as: UTF8.self)

        #expect(text.hasPrefix(#"{"accounts":[{"fetchedAt":"2026-10-10T20:00:00Z","id":"work""#))
        #expect(text.contains(#""generatedAt":"2026-10-10T20:00:00Z""#))
        #expect(!text.contains("\n"))
    }
}
