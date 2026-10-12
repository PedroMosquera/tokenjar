import Foundation

/// Makes a `--capture` document safe to paste into an issue. Every key, bool and null is kept, so the shape survives.
/// A number is kept unless its key names an id. A string survives only at a path pinned for that provider, and even
/// there only when it does not look like an email, a UUID or a key; at a path pinned as a date or an amount it must
/// also have that exact form. A key that looks like a secret is replaced too.
/// The Copilot half of this runs inside gh, as `jqProgram`, so gh's answer is redacted before it reaches Tokenjar.
public enum CaptureRedactor {
    public static let placeholder = "<redacted>"

    private static let claudeLimit = "probe.lines[].usage_report.rate_limits.limits[]"
    private static let goWindows = ["rolling", "weekly", "monthly"]

    /// Paths from the root of each provider's capture document: keys joined by ".", "[]" for each array level, "*" for
    /// any one key and "**" for any run of keys. docs/privacy.md lists them; widening one is a privacy decision.
    static let allowlist: [ProviderID: [String]] = {
        let limit = claudeLimit
        let agyGroup = "usage.stdout.**.groups[]"
        let codexLimitFields = ["planType", "limitId", "limitName", "rateLimitReachedType"]
        return [
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
            .codex: ["capture", "error", "classifiedAs"]
                + codexLimitFields.map { "response.result.rateLimits.\($0)" }
                + codexLimitFields.map { "response.result.rateLimitsByLimitId.*.\($0)" }
                + ["status", "state", "type", "kind"].map { "response.result.rateLimitResetCredits.**.\($0)" }
                + ["response.result.**.service_tier", "response.result.**.serviceTier"],
            .copilot: [
                "capture",
                "response.copilot_plan", "response.access_type_sku", "response.sku", "response.quota_snapshots.*.quota_id",
                "stderr.phrases[]",
            ],
            .antigravity: ["capture"]
                + ["name", "displayName", "display_name", "label", "title"].map { "\(agyGroup).\($0)" }
                + ["\(agyGroup).buckets[].window", "usage.stderr.phrases[]"],
            .opencodeGo: ["capture", "error", "response._tag", "response.error.type", "response.**.currency"]
                + goWindows.map { "response.\($0).status" }
                + goWindows.map { "response.usage.\($0).status" },
        ]
    }()

    /// Reset dates sent as strings, which a capture exists partly to show. Kept only in `datePattern`'s form.
    static let dateAllowlist: [ProviderID: [String]] = [
        .claude: ["\(claudeLimit).resets_at"],
        // CodexBar decodes the inventory this way; no recorded answer here shows it yet.
        .codex: ["response.result.rateLimitResetCredits.credits[].expiresAt"],
        .copilot: ["response.quota_reset_date_utc", "response.quota_reset_date"],
        .opencodeGo: goWindows.map { "response.\($0).resetsAt" } + goWindows.map { "response.usage.\($0).resetsAt" },
    ]

    /// Balances and spend limits Codex sends as decimal strings. Kept only in `decimalPattern`'s form.
    static let amountAllowlist: [ProviderID: [String]] = {
        let amounts = ["credits.balance", "individualLimit.limit", "individualLimit.used", "individualLimit.remaining"]
        return [
            .codex: amounts.map { "response.result.rateLimits.\($0)" }
                + amounts.map { "response.result.rateLimitsByLimitId.*.\($0)" }
                // A guess: nothing recorded or decoded names the inventory's amount field yet.
                + ["response.result.rateLimitResetCredits.credits[].amount"],
        ]
    }()

    /// The whole string, no more: free text cannot pass. `\A` and `\z` because `$` in Oniguruma (the system jq) and in
    /// NSRegularExpression also matches before a final newline.
    static let datePattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)?)?\z"#
    static let decimalPattern = #"\A-?[0-9]+(\.[0-9]+)?\z"#

    /// An email, a UUID, a token with a known key prefix, or a long run of key-like characters. Written for ICU, RE2
    /// (gh's jq) and Oniguruma (the system jq the tests run) alike, so no lookaround and no word-boundary escapes.
    static let secretPattern = [
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
        #"(^|[^A-Za-z0-9_])(sk-|sk_|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|oc_sk_|xox[abpr]-|AKIA|AIza|ya29\.|eyJ)[A-Za-z0-9_.-]{8,}"#,
        #"[A-Za-z0-9]{32,}"#,
        #"[A-Za-z0-9_.+/=-]{48,}"#,
    ].joined(separator: "|")

    public static func redact(_ value: Any, provider: ProviderID) -> Any {
        redact(value, path: "", key: "", pins: pins(for: provider).map { (pathRegex($0.path), $0.format) })
    }

    /// Every pinned path of `provider` with the pattern a string there must match, nil for any string.
    private static func pins(for provider: ProviderID) -> [(path: String, format: String?)] {
        (allowlist[provider] ?? []).map { ($0, nil) }
            + (dateAllowlist[provider] ?? []).map { ($0, datePattern) }
            + (amountAllowlist[provider] ?? []).map { ($0, decimalPattern) }
    }

    /// Redacts `document` and prints it as sorted, pretty JSON.
    public static func render(_ document: Any, provider: ProviderID) throws -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        return String(decoding: try JSONSerialization.data(withJSONObject: redact(document, provider: provider), options: options), as: UTF8.self)
    }

    /// The rules of `redact` as a jq program, for the part of `provider`'s document under `prefix`. gh runs it, so only
    /// what survives it leaves gh's process.
    static func jqProgram(for provider: ProviderID, under prefix: String) -> String {
        let entries: [[Any]] = pins(for: provider).compactMap { pin in
            pin.path.hasPrefix(prefix + ".") ? [pathRegex(String(pin.path.dropFirst(prefix.count + 1))), pin.format ?? NSNull()] : nil
        }
        let suffixes = idSuffixes.map { "endswith(\(jqLiteral($0)))" }.joined(separator: " or ")
        return [
            "def secret: test(\(jqLiteral(secretPattern)));",
            "def idkey: ascii_downcase | (\(suffixes));",
            "def pinned($p): . as $v | any(\(jqLiteral(entries))[]; . as [$re, $format] | ($p | test($re)) and ($format == null or ($v | test($format))));",
            "def r($p; $k): if type == \"object\" then to_entries | [range(0; length) as $i | .[$i]",
            "| (if (.key | secret) then \"<redacted-key-\\($i)>\" else .key end) as $name",
            "| {key: $name, value: (.value | r(if $p == \"\" then $name else \"\\($p).\\($name)\" end; $name))}] | from_entries",
            "elif type == \"array\" then map(r(\"\\($p)[]\"; $k))",
            "elif type == \"string\" then (if pinned($p) and (secret | not) then . else \(jqLiteral(placeholder)) end)",
            "elif type == \"number\" then (if ($k | idkey) then \(jqLiteral(placeholder)) else . end)",
            "else . end;",
            "r(\"\"; \"\")",
        ].joined(separator: " ")
    }

    /// Any key ending in "id" or "ids", whatever its case. Numbers under `valid` or `paid` go too: no narrower rule tells
    /// those from an all-lowercase `userid` or `orgid` without guessing.
    static func isIDKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return idSuffixes.contains { lower.hasSuffix($0) }
    }

    static func looksSecret(_ text: String) -> Bool {
        text.range(of: secretPattern, options: .regularExpression) != nil
    }

    private static let idSuffixes = ["id", "ids"]

    private static func redact(_ value: Any, path: String, key: String, pins: [(path: String, format: String?)]) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (index, name) in object.keys.sorted().enumerated() {
                let safe = looksSecret(name) ? "<redacted-key-\(index)>" : name
                out[safe] = redact(object[name] as Any, path: path.isEmpty ? safe : "\(path).\(safe)", key: safe, pins: pins)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redact($0, path: path + "[]", key: key, pins: pins) }
        }
        if let string = value as? String {
            let pinned = pins.contains { pin in
                path.range(of: pin.path, options: .regularExpression) != nil
                    && (pin.format.map { string.range(of: $0, options: .regularExpression) != nil } ?? true)
            }
            return pinned && !looksSecret(string) ? string : placeholder
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return isIDKey(key) ? placeholder : number
        }
        return value is NSNull ? value : placeholder
    }

    /// An anchored regex for one allowlist path. "*" never crosses a "." or an array level; "**" may match nothing.
    static func pathRegex(_ path: String) -> String {
        let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var regex = "^"
        for (index, segment) in segments.enumerated() {
            if segment == "**" {
                regex += #"([^.]+\.)*"#
                continue
            }
            regex += segment == "*" ? #"[^.\[\]]+"# : NSRegularExpression.escapedPattern(for: segment)
            if index < segments.count - 1 { regex += #"\."# }
        }
        return regex + "$"
    }

    private static func jqLiteral(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
