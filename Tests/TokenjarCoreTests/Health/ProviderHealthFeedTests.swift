import Foundation
import Testing
@testable import TokenjarCore

/// Fixtures are trimmed copies of the providers' real answers and incident history (see Fixtures/README.md).
struct ProviderHealthFeedTests {
    // MARK: Claude

    /// status.claude.com said "Partially Degraded Service" for five days over a Claude Console incident while Claude Code
    /// and claude.ai were fine. The page-wide indicator must never reach a Claude card.
    @Test func aConsoleOnlyIncidentShowsNothingForClaude() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-console-only.json")) == [])
    }

    @Test func anIncidentShowsItsLevelProductsAndTitle() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-login-degraded.json")) == [
            "Degraded performance on Claude Code and claude.ai: Issues logging into Claude.ai",
        ])
    }

    @Test func oneIncidentAcrossThreeProductsIsOneItem() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-opus-errors.json")) == [
            "Partial outage on Claude Code, claude.ai and Claude API: Elevated errors for Claude Opus 5.5",
        ])
    }

    /// Still in monitoring, but every component it lists is operational again: the provider says nothing is broken now.
    @Test func anIncidentWhoseComponentsRecoveredShowsNothing() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-sonnet-recovered.json")) == [])
    }

    /// "Elevated errors across all models" was filed with no components while its updates took three watched products
    /// to major outage. They read as one item, not one per product.
    @Test func componentsDownWithNoIncidentListingThemAreOneItem() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-all-models.json")) == [
            "Major outage on Claude Code, claude.ai and Claude API",
        ])
    }

    /// The components were back to operational when the incident's update named Claude Code; it was still open.
    @Test func aComponentlessIncidentNamingTheProductShowsAsAnIncident() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-many-models.json")) == [
            "Incident on Claude Code and claude.ai: Elevated errors across many models",
        ])
    }

    @Test func aComponentlessIncidentNamingTheProductTitlesTheComponentsDown() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-many-models-down.json")) == [
            "Partial outage on Claude Code, claude.ai and Claude API: Elevated errors across many models",
        ])
    }

    /// "Issue with spend limits" names Claude Code with impact none. Had it been posted while open, it still should not show.
    @Test func aComponentlessIncidentWithImpactNoneShowsNothing() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-spend-limits.json")) == [])
    }

    /// An upcoming maintenance never names a component that is already under maintenance.
    @Test func maintenanceTakesTheNameOfTheMaintenanceInProgress() throws {
        let items = try ProviderHealthFeed.forProvider(.claude)!.items(from: HealthFixtures.data("claude-maintenance.json"))
        #expect(items.map(\.text) == ["Maintenance on Claude Code: Planned maintenance", "Maintenance on claude.ai"])
        #expect(items.map(\.level) == [.maintenance, .maintenance])
    }

    @Test func itemsReadWorstFirst() throws {
        #expect(try HealthFixtures.texts(.claude, HealthFixtures.data("claude-mixed.json")) == [
            "Partial outage on Claude Code: Elevated errors on Claude Code and Claude Cowork",
            "Degraded performance on claude.ai: Issues logging into Claude.ai",
            "Incident on Claude Code and claude.ai: Elevated errors across many models",
            "Maintenance on Claude API: Planned maintenance",
        ])
    }

    @Test func aStatusThisBuildDoesNotKnowReadsAsAProblem() throws {
        let body = try HealthFixtures.statuspage("claude-console-only.json", statuses: ["yyzkbfz2thpt": "degraded"])
        #expect(try HealthFixtures.texts(.claude, body) == ["Problem on Claude Code"])
    }

    // MARK: GitHub Copilot

    /// Seven of the nine Copilot incidents in ten weeks of history were filed with no components at all.
    @Test func aComponentlessIncidentNamingCopilotInItsTitleShows() throws {
        #expect(try HealthFixtures.texts(.copilot, HealthFixtures.data("github-code-review.json")) == [
            "Incident on Copilot: Copilot Code Review is unable to complete reviews",
        ])
    }

    @Test func aComponentlessIncidentNamingCopilotOnlyInAnUpdateShows() throws {
        #expect(try HealthFixtures.texts(.copilot, HealthFixtures.data("github-agent-tasks.json")) == [
            "Incident on Copilot: Intermittent failures creating agent tasks",
        ])
    }

    /// It named Copilot only in its resolving update, which this snapshot is from before.
    @Test func aComponentlessIncidentThatNeverNamesCopilotShowsNothing() throws {
        #expect(try HealthFixtures.texts(.copilot, HealthFixtures.data("github-some-services.json")) == [])
    }

    @Test func copilotDownUnderAnIncidentOfManyComponentsShowsThatIncident() throws {
        #expect(try HealthFixtures.texts(.copilot, HealthFixtures.data("github-github-com.json")) == [
            "Major outage on Copilot: Incident with GitHub.com",
        ])
    }

    /// Copilot AI Model Providers carries per-model upstream errors; its name containing "Copilot" must not match it, and
    /// an incident that lists it is not component-less, so its text is not read either.
    @Test func copilotModelProvidersAloneShowsNothing() throws {
        #expect(try HealthFixtures.texts(.copilot, HealthFixtures.data("github-model-providers.json")) == [])
    }

    // MARK: Codex

    static let cli = "01KMKFAMWKNQ84Z1766MV08ZDE"
    static let web = "01JVCV8YSWZFRSM1G5CVP253SK"
    static let codexAPI = "01KMP3KP5MGE23B80K1EK4S8PV"
    static let vsCode = "01KMP3KP5M8X0EBTVW6KN327EE"
    static let desktop = "01KMKFAMWKQ81YWSE1Z18R6VHR"
    static let chatGPTLogin = "01JMXBNJXG1S2D9V65P1ZZTD94"
    static let apiLogin = "01JSM5RTJWHRWDTS6Q604VEW3B"
    static let chatCompletions = "01JMXBRMFE6N2NNT7DG6XZQ6PW"

    @Test func codexWithNothingAffectedShowsNothing() throws {
        #expect(try HealthFixtures.texts(.codex, HealthFixtures.openAI()) == [])
    }

    @Test func anAffectedCodexComponentShowsUnderItsCodexName() throws {
        #expect(try HealthFixtures.texts(.codex, HealthFixtures.openAI(affected: [(Self.cli, "partial_outage")])) == [
            "Partial outage on Codex CLI",
        ])
    }

    /// "Issues with Codex" (2026-09-25) touched all four components of the Codex group.
    @Test func fourCodexComponentsReadAsTwoNamesAndACount() throws {
        let affected = [(Self.vsCode, "partial_outage"), (Self.web, "partial_outage"), (Self.cli, "partial_outage"), (Self.codexAPI, "degraded_performance")]
        #expect(try HealthFixtures.texts(.codex, HealthFixtures.openAI(affected: affected)) == ["Partial outage on Codex CLI, Codex Web and 2 more"])
    }

    /// "Some users are unable to access Codex" (2026-07-18) touched the CLI and Codex in ChatGPT Desktop. The APIs group,
    /// its own Login included, is not watched.
    @Test func codexDesktopAndChatGPTLoginAreWatchedButAPIsAreNot() throws {
        #expect(try HealthFixtures.texts(.codex, HealthFixtures.openAI(affected: [(Self.cli, "partial_outage"), (Self.desktop, "partial_outage")])) == [
            "Partial outage on Codex CLI and Codex in ChatGPT Desktop",
        ])
        #expect(try HealthFixtures.texts(.codex, HealthFixtures.openAI(affected: [(Self.chatCompletions, "full_outage"), (Self.apiLogin, "full_outage")])) == [])
        #expect(try HealthFixtures.texts(.codex, HealthFixtures.openAI(affected: [(Self.chatGPTLogin, "full_outage")])) == ["Major outage on ChatGPT login"])
    }

    @Test func aNewComponentInTheCodexGroupIsWatchedUnderACodexName() throws {
        let body = try HealthFixtures.openAI(affected: [("01NEWCODEXCLOUDCOMPONENT00", "degraded_performance")]) { summary in
            Self.editCodexStructure(&summary) { group in
                guard group["id"] as? String == "01KMKF9EBTCD8BN9PG8DJZXRSQ" else { return }
                group["components"] = (group["components"] as! [[String: Any]]) + [["component_id": "01NEWCODEXCLOUDCOMPONENT00", "name": "Cloud", "hidden": false]]
            }
        }
        #expect(try HealthFixtures.texts(.codex, body) == ["Degraded performance on Codex Cloud"])
    }

    // MARK: Shared rules

    @Test(arguments: [
        ("operational", nil), ("", nil), ("degraded_performance", .degradedPerformance), ("partial_outage", .partialOutage),
        ("major_outage", .majorOutage), ("full_outage", .majorOutage), ("under_maintenance", .maintenance), ("degraded", .unknown),
    ] as [(String, ProviderHealthItem.Level?)])
    func componentStatusesMapToLevels(status: String, level: ProviderHealthItem.Level?) {
        #expect(ProviderHealthItem.Level(componentStatus: status) == level)
    }

    @Test func namesPastThreeBecomeACount() {
        let names = ["Codex CLI", "Codex Web", "Codex API", "Codex VS Code extension", "ChatGPT login"]
        let whos = (1...5).map { ProviderHealthItem(level: .partialOutage, names: Array(names.prefix($0))).who }
        #expect(whos == [
            "Codex CLI", "Codex CLI and Codex Web", "Codex CLI, Codex Web and Codex API", "Codex CLI, Codex Web and 2 more",
            "Codex CLI, Codex Web and 3 more",
        ])
    }

    @Test func withinALevelTheNewestReadsFirst() {
        let older = ProviderHealthItem(level: .partialOutage, names: ["Claude Code"], title: "Older", since: Date(timeIntervalSince1970: 100))
        let newer = ProviderHealthItem(level: .partialOutage, names: ["claude.ai"], title: "Newer", since: Date(timeIntervalSince1970: 200))
        let worse = ProviderHealthItem(level: .majorOutage, names: ["Claude API"], title: "Worse", since: Date(timeIntervalSince1970: 50))
        #expect(ProviderHealthItem.worstFirst([older, newer, worse]).compactMap(\.title) == ["Worse", "Newer", "Older"])
    }

    @Test func titlesAreShownTrimmed() {
        #expect(ProviderHealthItem(level: .partialOutage, names: ["Codex CLI"], title: "Issues with Codex ").text == "Partial outage on Codex CLI: Issues with Codex")
        #expect(ProviderHealthItem(level: .partialOutage, names: ["Codex CLI"], title: "  ").title == nil)
    }

    // MARK: Feeds that changed under Tokenjar

    /// The OpenAI 404 page stands in for any body that is not the feed.
    @Test(arguments: [ProviderID.claude, .codex, .copilot])
    func aBodyThatIsNotTheFeedIsUnreadable(provider: ProviderID) {
        #expect(throws: FetchError.self) { try HealthFixtures.texts(provider, Data("<!DOCTYPE html><html></html>".utf8)) }
        #expect(throws: FetchError.self) { try HealthFixtures.texts(provider, Data("{}".utf8)) }
    }

    /// A watched component that disappears would otherwise read as "all fine" for good.
    @Test func aFeedMissingAWatchedComponentIsUnreadable() throws {
        var github = try HealthFixtures.object("github-code-review.json")
        github["components"] = (github["components"] as! [[String: Any]]).filter { $0["id"] as? String != "pjmpxvq2cmr2" }
        #expect(throws: FetchError.parse("summary lists no component pjmpxvq2cmr2")) {
            try HealthFixtures.texts(.copilot, JSONSerialization.data(withJSONObject: github))
        }
        let noChatGPTLogin = try HealthFixtures.openAI { summary in
            Self.editCodexStructure(&summary) { group in
                guard group["id"] as? String == "01K5H8S53SY1KMS4GQMNMZXTR1" else { return }
                group["components"] = (group["components"] as! [[String: Any]]).filter { $0["component_id"] as? String != Self.chatGPTLogin }
            }
        }
        #expect(throws: FetchError.parse("page data lists no component \(Self.chatGPTLogin)")) { try HealthFixtures.texts(.codex, noChatGPTLogin) }
    }

    /// A Codex group re-created under a new id would stop new Codex products from being watched.
    @Test func aFeedWithoutTheCodexGroupIsUnreadable() throws {
        let body = try HealthFixtures.openAI { summary in
            Self.editCodexStructure(&summary) { group in
                if group["id"] as? String == "01KMKF9EBTCD8BN9PG8DJZXRSQ" { group["id"] = "01NEWCODEXGROUP00000000000" }
            }
        }
        #expect(throws: FetchError.parse("page data has no group 01KMKF9EBTCD8BN9PG8DJZXRSQ")) { try HealthFixtures.texts(.codex, body) }
    }

    private static func editCodexStructure(_ summary: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var structure = summary["structure"] as! [String: Any]
        structure["items"] = (structure["items"] as! [[String: Any]]).map { item in
            guard var group = item["group"] as? [String: Any] else { return item }
            edit(&group)
            return ["group": group]
        }
        summary["structure"] = structure
    }
}
