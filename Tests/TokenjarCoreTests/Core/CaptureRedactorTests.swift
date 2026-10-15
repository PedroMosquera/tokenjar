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

        let codexAmounts = ["credits.balance", "individualLimit.limit", "individualLimit.used", "individualLimit.remaining"]
        #expect(CaptureRedactor.dateAllowlist == [
            .claude: ["\(limit).resets_at"],
            .codex: [
                "response.result.rateLimitResetCredits.credits[].expiresAt",
                "response.result.rateLimits.individualLimit.resetsAt", "response.result.rateLimitsByLimitId.*.individualLimit.resetsAt",
            ],
            .copilot: ["response.quota_reset_date_utc", "response.quota_reset_date"],
            .opencodeGo: [
                "response.rolling.resetsAt", "response.weekly.resetsAt", "response.monthly.resetsAt",
                "response.usage.rolling.resetsAt", "response.usage.weekly.resetsAt", "response.usage.monthly.resetsAt",
            ],
        ])
        #expect(CaptureRedactor.amountAllowlist == [
            .codex: codexAmounts.map { "response.result.rateLimits.\($0)" }
                + codexAmounts.map { "response.result.rateLimitsByLimitId.*.\($0)" }
                + ["response.result.rateLimitResetCredits.credits[].amount"],
        ])

        let date = "2026-11-01T00:00:00Z", amount = "12.5"
        for (list, valid, wrongFormat) in [(CaptureRedactor.dateAllowlist, date, amount), (CaptureRedactor.amountAllowlist, amount, date)] {
            for (provider, paths) in list {
                for path in paths {
                    #expect(try rendered(nest(path, valid), provider).contains(valid), "\(provider) \(path)")
                    for value in ["kept-value", wrongFormat] {
                        #expect(try !rendered(nest(path, value), provider).contains(value), "\(provider) \(path) \(value)")
                    }
                    let sibling = path.split(separator: ".").dropLast().joined(separator: ".") + ".unlisted"
                    for elsewhere in [sibling, "outer.\(path)", "\(path).deeper"] {
                        #expect(try !rendered(nest(elsewhere, valid), provider).contains(valid), "\(provider) \(elsewhere)")
                    }
                }
            }
        }
    }

    /// Captures exist partly to learn when quotas reset, so a reset date survives where it is pinned.
    @Test func aResetDateAtItsPinnedPathIsKept() throws {
        let claudeLines = try fixtureText("Claude/stream-plan-limits.jsonl")
            .split(separator: "\n").map { try json(String($0)) }
        let inventory = try json(#"{"result": {"rateLimitResetCredits": {"availableCount": 1, "credits": [{"status": "available", "expiresAt": "2026-10-20T00:00:00Z"}]}}}"#)
        let cases: [(ProviderID, Any, [String])] = [
            (.claude, ["probe": ["lines": claudeLines]], [
                #""resets_at" : "2026-10-10T22:29:59.750000+00:00""#, #""resets_at" : "2026-10-12T09:00:00+00:00""#,
            ]),
            (.copilot, ["response": try json(fixture("Copilot/user-enterprise.json"))], [
                #""quota_reset_date_utc" : "2026-11-01T00:00:00.000Z""#, #""quota_reset_date" : "2026-11-01""#,
            ]),
            (.opencodeGo, ["response": try json(fixture("OpenCode/go-usage.json"))], [
                #""resetsAt" : "2026-10-10T14:20:00.000Z""#, #""resetsAt" : "2026-11-05T12:00:00.000Z""#,
            ]),
            (.codex, ["response": inventory], [#""expiresAt" : "2026-10-20T00:00:00Z""#]),
        ]

        for (provider, document, kept) in cases {
            let output = try rendered(document, provider)
            for line in kept {
                #expect(output.contains(line), "\(provider) \(line)")
            }
        }
    }

    /// The decoder accepts a spend cap's reset as an ISO string as well as a number, so a capture must show the string
    /// form too, and only that form.
    @Test func aCodexSpendCapResetDateIsKeptInDateFormOnly() throws {
        let reset = "2026-11-01T00:00:00Z"
        let cap: [String: Any] = ["limit": "50", "used": "12.5", "remainingPercent": 75, "resetsAt": reset]
        let response: [String: Any] = ["result": ["rateLimits": ["individualLimit": cap], "rateLimitsByLimitId": ["codex": ["individualLimit": cap]]]]
        let output = try rendered(["response": response], .codex)
        #expect(output.components(separatedBy: #""resetsAt" : "\#(reset)""#).count - 1 == 2)

        let paths = ["response.result.rateLimits.individualLimit.resetsAt", "response.result.rateLimitsByLimitId.*.individualLimit.resetsAt"]
        for path in paths {
            for value in ["next week", "2026-11-01 00:00:00", "2026-11-01T00:00:00Z placeholder-login", "12.5"] {
                #expect(try !rendered(nest(path, value), .codex).contains(value), "\(path) \(value.debugDescription)")
            }
        }
    }

    /// Codex sends balances and spend limits as decimal strings. Those survive at their pinned paths in the plain shape
    /// only; a numeric string anywhere else, such as an id, never does.
    @Test func anAmountStringAtItsPinnedPathIsKept() throws {
        var body = try #require(try json(fixture("Codex/rate-limits-business-spend-cap.json")) as? [String: Any])
        body["accountId"] = "1234567"
        let output = try rendered(["response": body], .codex)

        for kept in [#""limit" : "50""#, #""used" : "12.5""#, #""remaining" : "37.5""#] {
            #expect(output.contains(kept), "\(kept)")
        }
        #expect(!output.contains("1234567"))

        let balance = "response.result.rateLimitsByLimitId.*.credits.balance"
        for value in ["740", "0", "-1.5"] {
            #expect(try rendered(nest(balance, value), .codex).contains(#""balance" : "\#(value)""#), "\(value)")
        }
        for value in ["0E-10", "1e3", "1,000", "12.5 USD", "$5", "1.2.3", "--1", " 5", "5.", ".5", "740\n", "Infinity"] {
            #expect(try rendered(nest(balance, value), .codex).contains(#""balance" : "<redacted>""#), "\(value.debugDescription)")
        }
    }

    @Test func aDateShapedStringElsewhereIsRedacted() throws {
        let copilot = try json(#"""
        {"quota_reset_date_utc": "2026-11-01T00:00:00.000Z", "assigned_date": "2026-01-02T03:04:05Z",
         "quota_snapshots": {"premium_interactions": {"timestamp_utc": "2026-10-11T12:00:00Z", "quota_reset_date": "2026-10-13"}},
         "organization_list": [{"quota_reset_date_utc": "2026-10-14T00:00:00Z"}]}
        """#)
        let copilotOutput = try rendered(["response": copilot], .copilot)
        #expect(copilotOutput.contains("2026-11-01T00:00:00.000Z"))
        for leaked in ["2026-01-02", "2026-10-11", "2026-10-13", "2026-10-14"] {
            #expect(!copilotOutput.contains(leaked), "\(leaked)")
        }

        let claudeLine: [String: Any] = [
            "resets_at": "2026-10-15T00:00:00Z",
            "usage_report": ["rate_limits": ["resets_at": "2026-10-16T00:00:00Z", "extra_usage": ["resets_at": "2026-10-17T00:00:00Z"]]],
        ]
        let claudeOutput = try rendered(["probe": ["lines": [claudeLine]]], .claude)
        for leaked in ["2026-10-15", "2026-10-16", "2026-10-17"] {
            #expect(!claudeOutput.contains(leaked), "\(leaked)")
        }

        #expect(try !rendered(["response": ["quota_reset_date_utc": "2026-10-18T00:00:00Z"]], .codex).contains("2026-10-18"))
        #expect(try !rendered(["response": ["quota_reset_date_utc": "2026-10-19T00:00:00Z"]], .devin).contains("2026-10-19"))
    }

    /// Only the whole string in date form passes, so a name, an address or a message cannot ride along with a date.
    @Test func freeTextAtAPinnedDatePathIsRedacted() throws {
        let values = [
            "soon", "next Tuesday", "Reset on 2026-11-01", "2026-11-01 for placeholder-login", "2026-11-01\n",
            "2026-11-01T00:00:00Z\nplaceholder-login", "2026-11-01 00:00:00", "2026-11-01T00:00:00Z placeholder", "someone@example.com",
            "12.5", "",
        ]
        for value in values {
            for (provider, path) in [(ProviderID.copilot, "response.quota_reset_date_utc"), (.claude, "probe.lines[].usage_report.rate_limits.limits[].resets_at")] {
                let output = try rendered(nest(path, value), provider)
                #expect(output.contains(CaptureRedactor.placeholder), "\(provider) \(value.debugDescription)")
            }
        }
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
         "userid": 7001, "orgid": 7002, "accountid": 7003, "ACCOUNTID": 7004, "valid": 7005,
         "percent": 12.5, "count": 3, "nested": {"limitId": 14, "used": 15}}
        """#)
        let output = try CaptureRedactor.render(input, provider: .codex)

        for planted in ["1234", "5678", ": 9", ": 10", ": 11", "12,", "13", "14", "7001", "7002", "7003", "7004", "7005"] {
            #expect(!output.contains(planted), "\(planted)")
        }
        for kept in [#""percent" : 12.5"#, #""count" : 3"#, #""used" : 15"#] {
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
        try json(Data(text.utf8))
    }

    private func json(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
