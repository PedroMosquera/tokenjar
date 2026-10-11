import Foundation
import Testing
import TokenjarCore

struct FixtureShapeTests {
    /// The row ids of section 1 of the plan matrix. A row added there is added here and to its provider's manifest.
    static let planRowIDs = [
        "claude.free", "claude.pro", "claude.max5x", "claude.max20x", "claude.team-standard", "claude.team-premium",
        "claude.enterprise-seat", "claude.enterprise-usage-based", "claude.enterprise-usage-seat-report",
        "claude.enterprise-self-serve", "claude.enterprise-no-code", "claude.team-usage-based", "claude.zero-tier",
        "claude.credits-under-cap", "claude.credits-capped", "claude.credits-unlimited", "claude.fable-credits",
        "claude.all-models", "claude.org-no-meters", "claude.usage-fetch-failing", "claude.console-key",
        "claude.api-key", "claude.api-key-shell", "claude.cloud", "claude.cloud-yes", "claude.cloud-old-login",
        "claude.cloud-managed", "claude.cloud-shell", "claude.platform-lanes", "claude.gateway-env",
        "claude.gateway-managed", "claude.llm-gateway", "claude.setup-token", "claude.keyless-console",
        "claude.contracted-rates", "claude.signed-out",
        "codex.free", "codex.unknown-plan", "codex.go", "codex.plus", "codex.plus-limit-hard",
        "codex.plus-limit-credits", "codex.reset-credits", "codex.pro-weekly", "codex.pro-five-hour", "codex.spark",
        "codex.business-standard", "codex.business-premium", "codex.business-plantype", "codex.member-limit-reached",
        "codex.codex-seat", "codex.codex-seat-depleted", "codex.zero-credit-limit", "codex.enterprise-seat",
        "codex.enterprise-cbp", "codex.enterprise-flexible", "codex.edu", "codex.workspace-hidden", "codex.api-key",
        "codex.bedrock", "codex.local-oss", "codex.outdated-cli",
        "opencode-go.active", "opencode-go.idle", "opencode-go.rate-limited", "opencode-go.monthly-exhausted",
        "opencode-go.use-balance", "opencode-go.plus", "opencode-go.v2-meters", "opencode-go.no-sub",
        "opencode-go.lapsed", "opencode-go.revoked", "opencode-go.legacy-unmigrated", "opencode-go.no-key",
        "opencode-go.connect-oauth", "opencode-go.throttled", "opencode-go.unavailable", "opencode-go.client-error",
        "opencode-zen.payg", "opencode-zen.no-spend", "opencode-zen.free-only", "opencode-zen.no-db",
        "opencode-zen.team-member", "opencode-zen.budget-exceeded", "opencode-zen.balance-zero",
        "opencode-zen.invoiced", "opencode-zen.admin-service-key", "opencode-zen.black", "opencode-zen.byok",
        "opencode-zen.two-workspaces",
        "opencode.enterprise-gateway",
        "agy.starter", "agy.starter-exhausted", "agy.paid-on-starter", "agy.pro", "agy.ultra",
        "agy.ultra-business-locked", "agy.ai-credits", "agy.enterprise-empty", "agy.enterprise-message", "agy.adc",
        "agy.api-key", "agy.code-assist", "agy.all-disabled", "agy.ineligible", "agy.region", "agy.tos-blocked",
        "agy.signed-out", "agy.transport", "agy.renamed-groups", "agy.model-turn", "agy.fraction-omitted",
        "copilot.free", "copilot.free-credits", "copilot.free-exhausted", "copilot.free-no-sku",
        "copilot.free-placeholder", "copilot.never-signed-up", "copilot.student", "copilot.complimentary",
        "copilot.pro", "copilot.pro-plus", "copilot.premium-models", "copilot.max", "copilot.pro-at-allowance",
        "copilot.pro-overage", "copilot.pro-overage-budget-spent", "copilot.legacy", "copilot.legacy-at-allowance",
        "copilot.legacy-overage", "copilot.business-share", "copilot.business-past-share-paid-on",
        "copilot.business-past-share-paid-off", "copilot.business-pool-exhausted", "copilot.pooled-unlimited",
        "copilot.placeholder-credits", "copilot.token-placeholder", "copilot.business-monthly-completions",
        "copilot.enterprise", "copilot.enterprise-unlimited", "copilot.ghecom", "copilot.ghecom-multihost",
        "copilot.no-access", "copilot.saml-403", "copilot.signed-out", "copilot.xdg", "copilot.remaining-only",
        "copilot.overage-percent-only",
        "devin.free", "devin.pro", "devin.max", "devin.teams", "devin.teams-flex", "devin.enterprise",
        "devin.legacy-core", "devin.chatgpt-sharing", "devin.windsurf", "devin.windsurf-enterprise"
    ]

    @Test func everyPlanRowHasOneManifestEntry() throws {
        let ids = try PlanManifest.load().map(\.id)
        #expect(Set(Self.planRowIDs).subtracting(ids).sorted() == [], "rows without an entry")
        #expect(Set(ids).subtracting(Self.planRowIDs).sorted() == [], "entries for no row")
        #expect(Dictionary(grouping: ids) { $0 }.filter { $0.value.count > 1 }.keys.sorted() == [], "ids with more than one entry")
    }

    @Test func everyManifestInputExists() {
        for planCase in PlanManifest.all {
            for input in planCase.inputs.keys.sorted() {
                let path = planCase.url(input)?.path ?? ""
                #expect(FileManager.default.fileExists(atPath: path), "\(planCase.id) \(input): \(planCase.inputs[input] ?? "")")
            }
        }
    }

    @Test func planFixturesCarryNoSecrets() throws {
        let files = try Self.files(under: PlanManifest.folder)
        #expect(files.count >= 170, "the scan found only \(files.count) files")
        for file in files {
            let findings = Self.secretFindings(in: try String(contentsOf: file, encoding: .utf8))
            #expect(findings.isEmpty, "\(file.path.dropFirst(PlanManifest.folder.path.count + 1)): \(findings)")
        }
    }

    /// Key-shaped values are joined at run time so this file never holds one a secret scanner would flag.
    @Test(arguments: ["sk-ant-api03-", "ghp_", "gho_", "oc_sk_"].map { $0 + "Zq8vT2mWbX4kLp9nRc7dYs1fHj6gEu3a" } + [
        "someone@company.com", "3f9c2a71-8b4e-4d6f-a1c3-9e7b5d2f0a84", "/Users/someone/src/project",
    ])
    func theSecretCheckCatchesAPlantedValue(_ planted: String) {
        #expect(!Self.secretFindings(in: "{\"value\": \"\(planted)\"}").isEmpty)
    }

    @Test func theSecretCheckLetsPlaceholdersThrough() {
        let text = """
            {"email": "member-1@example.invalid", "uuid": "00000000-0000-0000-0000-000000000001", "cwd": "/Users/placeholder/src",
             "home": "/Users/PLACEHOLDER/.claude", "key": "sk-ant-API_KEY_PLACEHOLDER_VALUE", "token": "ghp_REDACTED_REDACTED_REDACTED",
             "note": "a legacy (non oc_sk_) key"}
            """
        #expect(Self.secretFindings(in: text).isEmpty)
    }

    /// One finding per line that holds an email outside example.invalid, a key prefix followed by real-looking text, a
    /// UUID that is not a placeholder, or a home folder that is not `/Users/placeholder`. Values are left out, so a real
    /// secret never lands in the test log.
    static func secretFindings(in text: String) -> [String] {
        let email = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
        let key = /(sk-ant-|ghp_|gho_|oc_sk_)[A-Za-z0-9_-]{16,}/
        let uuid = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        let home = /\/Users\/[^\/\s"]+/
        var findings: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineName = "line \(index + 1)"
            if line.matches(of: email).contains(where: { !$0.output.lowercased().hasSuffix("@example.invalid") }) {
                findings.append("\(lineName): email")
            }
            if line.matches(of: key).contains(where: { match in
                let value = match.output.0.uppercased()
                return !value.contains("PLACEHOLDER") && !value.contains("REDACTED")
            }) {
                findings.append("\(lineName): key")
            }
            // A real UUID uses most hex digits; a placeholder such as 00000000-0000-0000-0000-000000000001 uses one or two.
            if line.matches(of: uuid).contains(where: { Set($0.output.lowercased().filter(\.isHexDigit)).count > 2 }) {
                findings.append("\(lineName): uuid")
            }
            if line.matches(of: home).contains(where: { $0.output.lowercased() != "/users/placeholder" }) {
                findings.append("\(lineName): home folder")
            }
        }
        return findings
    }

    private static func files(under folder: URL) throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }
}

struct PlanManifestTests {
    @Test func aFiveHourWindowWithoutALengthIsListed() {
        func window(_ id: String, _ label: String, _ minutes: Int?) -> UsageWindow {
            UsageWindow(id: id, label: label, usedPercent: 40, windowMinutes: minutes)
        }
        let snapshot = UsageSnapshot(accountID: "x", provider: .antigravity, windows: [
            window("session", "5-hour", nil),
            window("gemini:session", "Gemini · 5-hour", 10_080),
            window("pool", "Claude and GPT · 5h", nil),
            window("spark:session", "Spark · 5-hour", 300),
            window("lane", "5-hour", 1_440),
            window("weekly", "Week", nil),
            window("monthly", "Month", 44_640),
        ], fetchedAt: Date(timeIntervalSince1970: 1_791_660_000), source: "test")

        #expect(PlanManifest.shortLaneWindowsKnowTheirLength(snapshot) == ["session", "gemini:session", "pool"])
    }
}
