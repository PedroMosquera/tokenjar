import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func answer(_ items: [ProviderHealthItem], ago: TimeInterval = 60) -> ProviderHealthAnswer {
    ProviderHealthAnswer(items: items, answeredAt: now.addingTimeInterval(-ago))
}

private func health(_ items: [ProviderHealthItem]) -> ProviderHealth {
    var health = ProviderHealth()
    health.asked(at: now.addingTimeInterval(-60))
    health.record(.success(answer(items)))
    return health
}

private let opusErrors = ProviderHealthItem(level: .partialOutage, names: ["Claude Code"], title: "Elevated errors for Claude Opus 5.5")
private let claudeMaintenance = ProviderHealthItem(level: .maintenance, names: ["claude.ai"], title: "Scheduled maintenance of claude.ai")
private let codexDown = ProviderHealthItem(level: .partialOutage, names: ["Codex CLI", "Codex Web", "Codex API", "Codex VS Code extension"])

@MainActor
struct HealthRowTests {
    /// The answer lists items worst first; the row leads with that one and counts the rest.
    @Test func theRowLeadsWithTheWorstItemAndCountsTheRest() throws {
        let text = try #require(HealthRowText(provider: .claude, answer: answer([opusErrors, claudeMaintenance]), now: now))
        #expect(text.lead == "Partial outage on Claude Code: Elevated errors for Claude Opus 5.5")
        #expect(text.trailing == " and 1 more")
        #expect(text.symbol == "megaphone")
    }

    @Test func anAnswerPastFiveMinutesSaysHowOldItIs() throws {
        let old = try #require(HealthRowText(provider: .claude, answer: answer([opusErrors, claudeMaintenance], ago: 40 * 60), now: now))
        #expect(old.trailing == " and 1 more · as of 40m ago")
        let alone = try #require(HealthRowText(provider: .codex, answer: answer([codexDown], ago: 40 * 60), now: now))
        #expect(alone.lead + alone.trailing == "Partial outage on Codex CLI, Codex Web and 2 more · as of 40m ago")
        let fresh = try #require(HealthRowText(provider: .claude, answer: answer([opusErrors], ago: 4 * 60), now: now))
        #expect(fresh.trailing == "")
    }

    /// Planned work must not read as an outage at a glance.
    @Test func maintenanceShowsTheWrench() throws {
        let text = try #require(HealthRowText(provider: .claude, answer: answer([claudeMaintenance]), now: now))
        #expect(text.symbol == "wrench.and.screwdriver")
        #expect(text.lead == "Maintenance on claude.ai: Scheduled maintenance of claude.ai")
    }

    @Test func nothingReportedShowsNoRow() {
        #expect(HealthRowText(provider: .copilot, answer: answer([]), now: now) == nil)
    }

    /// The line is the provider's claim, relayed: the tooltip names the host, every product in full and the answer's age.
    @Test func theTooltipNamesTheHostEveryProductAndTheAge() throws {
        let codex = try #require(HealthRowText(provider: .codex, answer: answer([codexDown], ago: 40 * 60), now: now))
        #expect(codex.tooltip == "status.openai.com reports a partial outage of Codex CLI, Codex Web, Codex API and Codex VS Code extension. Answer from 40m ago.")
        let claude = try #require(HealthRowText(provider: .claude, answer: answer([opusErrors, claudeMaintenance], ago: 20), now: now))
        #expect(claude.tooltip == "status.claude.com reports a partial outage of Claude Code: Elevated errors for Claude Opus 5.5. It also reports maintenance on claude.ai: Scheduled maintenance of claude.ai. Answer from under a minute ago.")
        let review = ProviderHealthItem(level: .incident, names: ["Copilot"], title: "Copilot Code Review is unable to complete reviews")
        let copilot = try #require(HealthRowText(provider: .copilot, answer: answer([review]), now: now))
        #expect(copilot.lead == "Incident on Copilot: Copilot Code Review is unable to complete reviews")
        #expect(copilot.tooltip == "www.githubstatus.com reports an incident that mentions Copilot, without naming an affected component: Copilot Code Review is unable to complete reviews. Answer from 1m ago.")
    }

    @Test func voiceOverHearsTheProviderTheLevelAndTheAge() throws {
        let text = try #require(HealthRowText(provider: .claude, answer: answer([opusErrors, claudeMaintenance], ago: 40 * 60), now: now))
        #expect(text.spoken == "Claude status page: partial outage on Claude Code. Elevated errors for Claude Opus 5.5. And 1 more. As of 40 minutes ago")
    }

    /// When the row runs out of room the title gives up words, never the count or the age.
    @Test func shorterFormsCutTheTitleAndKeepTheCountAndTheAge() throws {
        let text = try #require(HealthRowText(provider: .claude, answer: answer([opusErrors, claudeMaintenance], ago: 40 * 60), now: now))
        #expect(text.candidates.first == "Partial outage on Claude Code: Elevated errors for Claude Opus 5.5 and 1 more · as of 40m ago")
        #expect(text.candidates.dropFirst().first == "Partial outage on Claude Code: Elevated errors for Claude Opus… and 1 more · as of 40m ago")
        #expect(text.candidates.last == "Partial outage on Claude Code: … and 1 more · as of 40m ago")
        #expect(text.candidates.allSatisfy { $0.hasSuffix(" and 1 more · as of 40m ago") })
        #expect(zip(text.candidates, text.candidates.dropFirst()).allSatisfy { $0.count > $1.count })
        let codex = try #require(HealthRowText(provider: .codex, answer: answer([codexDown], ago: 40 * 60), now: now))
        #expect(codex.candidates == [
            "Partial outage on Codex CLI, Codex Web and 2 more · as of 40m ago",
            "Partial outage on Codex CLI and 3 more · as of 40m ago",
            "Partial outage on Codex CLI… · as of 40m ago",
        ])
    }

    /// Two Claude accounts both show Claude's row; a Codex card shows nothing from Claude's page.
    @Test func theRowIsOnThatProvidersCardsOnly() throws {
        let statuses: [ProviderID: ProviderHealth] = [.claude: health([opusErrors])]
        #expect(AccountCard.healthText(provider: .claude, health: statuses, now: now)?.lead == opusErrors.text)
        #expect(AccountCard.healthText(provider: .codex, health: statuses, now: now) == nil)
        #expect(AccountCard.healthText(provider: .copilot, health: [.copilot: health([])], now: now) == nil)
    }
}

@MainActor
struct StatusCaptionTests {
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let codex = AccountConfig(id: "codex", provider: .codex, label: "Plus")
    private let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")

    private var calm: [String: AccountStatus] {
        func using(_ id: String, _ used: Double) -> AccountStatus {
            AccountStatus(snapshot: UsageSnapshot(
                accountID: id, provider: .claude,
                windows: [UsageWindow(id: "main", label: "5-hour", usedPercent: used, windowMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3_600))],
                fetchedAt: now, source: "test"
            ), lastAttempt: now)
        }
        return ["claude": using("claude", 10), "codex": using("codex", 2), "copilot": using("copilot", 15)]
    }

    /// Cards keep config order and Copilot can sit below the fold, so "All clear" must not hide its outage.
    @Test func allClearNamesTheStatusPageThatReportsAnOutage() {
        let summary = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: calm, config: AppConfig(), now: now, outages: [.copilot])
        #expect(summary == PopoverSummary(tone: .clear, text: "All clear · next reset in 2h", outage: "GitHub Copilot status page reports an outage"))
    }

    @Test func severalOutagesAreNamedInCardOrder() {
        let summary = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: calm, config: AppConfig(), now: now, outages: [.copilot, .claude])
        #expect(summary.outage == "Status pages report outages for Claude and GitHub Copilot")
    }

    /// The title already says something needs a look; the card carries the detail.
    @Test func onlyAllClearGetsTheCaption() {
        var full = calm
        full["claude"] = AccountStatus(snapshot: UsageSnapshot(
            accountID: "claude", provider: .claude,
            windows: [UsageWindow(id: "main", label: "5-hour", usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(3_600))],
            fetchedAt: now, source: "test"
        ), lastAttempt: now)
        let red = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: full, config: AppConfig(), now: now, outages: [.copilot])
        #expect(red.tone == .critical)
        #expect(red.outage == nil)
        let offline = PopoverSummary.make(accounts: [claude, codex, copilot], statuses: calm, config: AppConfig(), now: now, connectivity: .offline, outages: [.copilot])
        #expect(offline.outage == nil)
    }

    /// Degraded performance, maintenance and incidents matched only by name stay on the card. A provider with no
    /// account here is not named.
    @Test func onlyAPartialOrMajorOutageReachesTheHeader() {
        let model = AppModel.previewAllClearOutage()
        model.providerHealth = [
            .claude: health([ProviderHealthItem(level: .degradedPerformance, names: ["Claude Code"])]),
            .codex: health([ProviderHealthItem(level: .maintenance, names: ["Codex Web"])]),
            .copilot: health([ProviderHealthItem(level: .incident, names: ["Copilot"], title: "Copilot Code Review is unable to complete reviews")]),
            .devin: health([ProviderHealthItem(level: .majorOutage, names: ["Devin"])]),
        ]
        #expect(model.statusOutages.isEmpty)
        #expect(PopoverHeader.summary(of: model, voice: .written).outage == nil)

        model.providerHealth[.codex] = health([ProviderHealthItem(level: .partialOutage, names: ["Codex CLI"])])
        model.providerHealth[.copilot] = health([ProviderHealthItem(level: .majorOutage, names: ["Copilot"]), ProviderHealthItem(level: .partialOutage, names: ["Copilot"])])
        #expect(model.statusOutages == [.codex: .partialOutage, .copilot: .majorOutage])
        let summary = PopoverHeader.summary(of: model, voice: .written)
        #expect(summary.tone == .clear)
        #expect(summary.outage == "Status pages report outages for Codex and GitHub Copilot")
    }

    /// Partial outages on status.claude.com are routine and short, so only a major outage moves the room hint.
    @Test func theRoomHintSkipsOnlyAProviderInMajorOutage() {
        let model = AppModel.previewLimitHit()
        #expect(PopoverHeader.summary(of: model, voice: .written).room == "Codex has room: 5-hour 2% used")
        model.providerHealth = [.codex: health([ProviderHealthItem(level: .partialOutage, names: ["Codex CLI"])])]
        #expect(PopoverHeader.summary(of: model, voice: .written).room == "Codex has room: 5-hour 2% used")
        model.providerHealth = [.codex: health([ProviderHealthItem(level: .majorOutage, names: ["Codex CLI"])])]
        #expect(PopoverHeader.summary(of: model, voice: .written).room == "GitHub Copilot has room: Premium requests 15% used")
    }

    /// The menu bar's slash and dot mean Tokenjar can't refresh or something needs you; an outage is neither.
    @Test func anOutageLeavesTheMenuBarAlone() {
        let model = AppModel.previewAllClearOutage()
        let before = model.menuBarState
        model.providerHealth = [.claude: health([ProviderHealthItem(level: .majorOutage, names: ["Claude Code"])])]
        #expect(!model.menuBarState.showsDot)
        #expect(!model.menuBarState.isSlashed)
        #expect(model.menuBarState.entries.map(\.severity) == before.entries.map(\.severity))
    }
}
