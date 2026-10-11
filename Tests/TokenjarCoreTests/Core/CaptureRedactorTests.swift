import Foundation
import Testing
@testable import TokenjarCore

struct CaptureRedactorTests {
    /// docs/privacy.md lists these paths. A string reaches the terminal only at one of them, so adding a path is a
    /// privacy decision made here and in the doc together.
    @Test func onlyAllowlistedPathsSurvive() throws {
        let limit = "probe.lines[].usage_report.rate_limits.limits[]"
        let agyGroup = "usage.stdout.**.groups[]"
        #expect(CaptureRedactor.allowlist == [
            .claude: [
                "capture",
                "probe.lines[].type", "probe.lines[].subtype", "probe.lines[].apiKeySource", "probe.lines[].claude_code_version",
                "probe.lines[].local_command", "probe.lines[].local_command_run.command",
                "\(limit).kind", "\(limit).group", "\(limit).severity",
                "\(limit).scope.model.display_name", "\(limit).scope.surface.display_name",
                "probe.lines[].usage_report.rate_limits.extra_usage.currency",
                "claudeJSON.oauthAccount.organizationType", "claudeJSON.oauthAccount.seatTier", "claudeJSON.oauthAccount.billingType",
                "claudeJSON.oauthAccount.organizationRateLimitTier", "claudeJSON.oauthAccount.userRateLimitTier",
                "settingsEnvKeys[]", "managedSettingsEnvKeys[]",
            ],
            .codex: [
                "capture", "error", "classifiedAs",
                "response.result.rateLimits.planType", "response.result.rateLimits.limitId",
                "response.result.rateLimits.limitName", "response.result.rateLimits.rateLimitReachedType",
                "response.result.rateLimitsByLimitId.*.planType", "response.result.rateLimitsByLimitId.*.limitId",
                "response.result.rateLimitsByLimitId.*.limitName", "response.result.rateLimitsByLimitId.*.rateLimitReachedType",
                "response.result.rateLimitResetCredits.**.status", "response.result.rateLimitResetCredits.**.state",
                "response.result.rateLimitResetCredits.**.type", "response.result.rateLimitResetCredits.**.kind",
                "response.result.**.service_tier", "response.result.**.serviceTier",
            ],
            .copilot: [
                "capture",
                "response.copilot_plan", "response.access_type_sku", "response.sku", "response.quota_snapshots.*.quota_id",
                "stderr.phrases[]",
            ],
            .antigravity: [
                "capture",
                "\(agyGroup).name", "\(agyGroup).displayName", "\(agyGroup).display_name", "\(agyGroup).label", "\(agyGroup).title",
                "\(agyGroup).buckets[].window",
                "usage.stderr.phrases[]",
            ],
            .opencodeGo: [
                "capture", "error",
                "response._tag", "response.error.type", "response.**.currency",
                "response.rolling.status", "response.weekly.status", "response.monthly.status",
                "response.usage.rolling.status", "response.usage.weekly.status", "response.usage.monthly.status",
            ],
        ])

        for (provider, paths) in CaptureRedactor.allowlist {
            for path in paths {
                #expect(try rendered(nest(path, "kept-value"), provider).contains("kept-value"), "\(provider) \(path)")
                let sibling = path.split(separator: ".").dropLast().joined(separator: ".") + (path.contains(".") ? ".unlisted" : "unlisted")
                #expect(try !rendered(nest(sibling, "kept-value"), provider).contains("kept-value"), "\(provider) \(sibling)")
                for elsewhere in ["outer.\(path)", "\(path).deeper"] {
                    #expect(try !rendered(nest(elsewhere, "kept-value"), provider).contains("kept-value"), "\(provider) \(elsewhere)")
                }
            }
        }
        #expect(try !rendered(["capture": "kept-value"], .devin).contains("kept-value"))
    }

    @Test func keysBoolsAndNullsAreKept() throws {
        let input: [String: Any] = [
            "enabled": true, "disabled": false, "nothing": NSNull(),
            "nested": ["flag": true, "empty": NSNull(), "list": [true, NSNull(), false]],
            "words": "a person's name",
        ]
        let output = try #require(CaptureRedactor.redact(input, provider: .claude) as? [String: Any])

        #expect(Set(output.keys) == Set(input.keys))
        #expect(output["enabled"] as? Bool == true)
        #expect(output["disabled"] as? Bool == false)
        #expect(output["nothing"] is NSNull)
        let nested = try #require(output["nested"] as? [String: Any])
        #expect(Set(nested.keys) == ["flag", "empty", "list"])
        #expect(nested["flag"] as? Bool == true)
        #expect(nested["empty"] is NSNull)
        let list = try #require(nested["list"] as? [Any])
        #expect(list.count == 3)
        #expect(list[0] as? Bool == true)
        #expect(list[1] is NSNull)
        #expect(list[2] as? Bool == false)
        #expect(output["words"] as? String == CaptureRedactor.placeholder)
    }

    @Test func numericIDsAreRedacted() throws {
        let input = try json(#"""
        {"user_id": 1234, "orgId": 5678, "id": 9, "ID": 10, "account_uuid": 11, "organization_ids": [12, 13],
         "percent": 12.5, "count": 3, "valid": 1, "nested": {"limitId": 14, "used": 15}}
        """#)
        let output = try CaptureRedactor.render(input, provider: .codex)

        for planted in ["1234", "5678", ": 9", ": 10", ": 11", "12,", "13", "14"] {
            #expect(!output.contains(planted), "\(planted)")
        }
        for kept in [#""percent" : 12.5"#, #""count" : 3"#, #""valid" : 1"#, #""used" : 15"#] {
            #expect(output.contains(kept), "\(kept)")
        }
    }

    @Test func aDisplayNameOutsideItsPathIsRedacted() throws {
        let line: [String: Any] = [
            "type": "assistant",
            "message": ["type": "message", "model": "placeholder-model", "display_name": "Jane Placeholder", "name": "Jane"],
            "account": ["name": "Jane Placeholder", "status": "active", "display_name": "Jane Placeholder"],
            "usage_report": ["rate_limits": ["limits": [
                ["kind": "weekly_scoped", "scope": ["model": ["display_name": "Opus"], "owner": ["display_name": "Jane Placeholder"]]],
            ]]],
        ]
        let output = try CaptureRedactor.render(["capture": "claude", "probe": ["lines": [line]]], provider: .claude)

        #expect(!output.contains("Jane"))
        #expect(!output.contains("placeholder-model"))
        #expect(!output.contains("active"))
        #expect(!output.contains(#""type" : "message""#))
        #expect(output.contains(#""display_name" : "Opus""#))
        #expect(output.contains(#""kind" : "weekly_scoped""#))
        #expect(output.contains(#""type" : "assistant""#))
    }

    @Test func anEmailInAnAllowlistedFieldIsStillRedacted() throws {
        let planted = [
            "organizationType": "someone@example.com",
            "seatTier": "123e4567-e89b-12d3-a456-426614174000",
            "billingType": "sk-ant-api03-placeholderplaceholder",
            "organizationRateLimitTier": "0123456789abcdef0123456789abcdef0123456789abcdef",
            "userRateLimitTier": "default_claude_max_20x",
        ]
        let output = try CaptureRedactor.render(["claudeJSON": ["oauthAccount": planted]], provider: .claude)

        for value in planted.values where value != "default_claude_max_20x" {
            #expect(!output.contains(value), "\(value)")
        }
        #expect(!output.contains("example.com"))
        #expect(output.contains(#""userRateLimitTier" : "default_claude_max_20x""#))
    }

    /// Keys are kept so the shape survives, but a key that is itself an email or an id must not carry it out.
    @Test func aKeyThatLooksLikeAnEmailOrAnIdIsReplaced() throws {
        let input = try json(#"{"someone@example.com": {"credits_used": 2}, "123e4567-e89b-12d3-a456-426614174000": true, "premium": 1}"#)
        let output = try CaptureRedactor.render(input, provider: .copilot)

        #expect(!output.contains("example.com"))
        #expect(!output.contains("123e4567"))
        #expect(output.contains(#""credits_used" : 2"#))
        #expect(output.contains(#""premium" : 1"#))
    }

    // MARK: Helpers

    /// A document holding `value` at one concrete instance of an allowlist path: `*` becomes a key, `**` two levels.
    private func nest(_ path: String, _ value: Any) -> Any {
        var segments = path.split(separator: ".").map(String.init)
        if let deep = segments.firstIndex(of: "**") { segments.replaceSubrange(deep...deep, with: ["outer", "inner"]) }
        var node = value
        for segment in segments.reversed() {
            var name = segment
            var depth = 0
            while name.hasSuffix("[]") {
                name.removeLast(2)
                depth += 1
            }
            for _ in 0..<depth { node = [node] }
            node = [name == "*" ? "anykey" : name: node]
        }
        return node
    }

    private func rendered(_ document: Any, _ provider: ProviderID) throws -> String {
        try CaptureRedactor.render(document, provider: provider)
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}
