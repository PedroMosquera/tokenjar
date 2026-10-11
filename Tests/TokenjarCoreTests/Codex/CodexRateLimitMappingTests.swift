import Foundation
import Testing
@testable import TokenjarCore

struct CodexRateLimitMappingTests {
    /// 2026-10-10T19:27:45Z, exactly 300 minutes before the plus fixture's 5-hour reset.
    let now = Date(timeIntervalSince1970: 1_791_660_465)

    private func snapshot(_ fixture: String, at date: Date? = nil) throws -> UsageSnapshot {
        let result = try CodexFixtures.rateLimitsResult(fixture)
        return try #require(CodexRateLimitMapping.snapshot(from: result, accountID: "codex-test", fetchedAt: date ?? now, source: "codex app-server"))
    }

    @Test func plusResponseMapsWindowsByDuration() throws {
        let s = try snapshot("rate-limits-plus.json")
        #expect(s.plan == "Plus")
        #expect(s.provider == .codex)
        #expect(s.windows.map(\.id) == ["session", "weekly"])
        #expect(s.windows.map(\.label) == ["5-hour", "Week"])
        #expect(s.windows.map(\.usedPercent) == [0, 2])
        #expect(s.windows.map(\.windowMinutes) == [300, 10_080])
        #expect(s.windows[1].resetsAt == Date(timeIntervalSince1970: 1_792_150_113))
        #expect(s.windows[0].notStarted)
        #expect(!s.windows[1].notStarted)
        #expect(s.notes.isEmpty)
        #expect(s.money.isEmpty)
    }

    @Test func accountIdNeverReachesTheSnapshot() throws {
        let s = try snapshot("rate-limits-plus.json")
        let encoded = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!encoded.contains("ACCOUNT_ID_PLACEHOLDER"))
    }

    @Test func proResponseWithoutFiveHourWindowKeysTheWeekByDuration() throws {
        let s = try snapshot("rate-limits-pro.json")
        #expect(s.plan == "Pro")
        let main = s.windows.filter { !$0.id.contains(":") }
        #expect(main.map(\.id) == ["weekly"])
        #expect(main.first?.usedPercent == 37)
        #expect(!s.windows.contains { $0.id == "session" })
    }

    @Test func fiveHourWindowInTheSecondarySlotIsStillTheSession() {
        let limits = CodexRateLimitSnapshot(
            limitId: "codex",
            primary: .init(usedPercent: 9, windowDurationMins: 10_080, resetsAt: 1_792_150_113),
            secondary: .init(usedPercent: 3, windowDurationMins: 300, resetsAt: 1_791_670_000)
        )

        #expect(CodexRateLimitMapping.windows(limits, extraLimitID: nil, now: now).map(\.id) == ["weekly", "session"])
    }

    @Test func extraLimitIdsGetPrefixedWindows() throws {
        let s = try snapshot("rate-limits-pro.json")
        let extra = s.windows.filter { $0.id.hasPrefix("codex_spark:") }
        #expect(extra.map(\.id) == ["codex_spark:session", "codex_spark:weekly"])
        #expect(extra.map(\.label) == ["Spark · 5-hour", "Spark · Week"])
        #expect(extra.map(\.usedPercent) == [12.5, 4])
        #expect(!s.windows.contains { $0.id.hasPrefix("codex:") })
    }

    @Test func extraLimitWithoutNameFallsBackToItsId() {
        let limits = CodexRateLimitSnapshot(limitId: "codex_other", primary: .init(usedPercent: 5, windowDurationMins: 300, resetsAt: 1_791_670_000), secondary: nil)
        let windows = CodexRateLimitMapping.windows(limits, extraLimitID: "codex_other", now: now)
        #expect(windows.map(\.label) == ["codex_other · 5-hour"])
    }

    @Test func creditsBecomeANoteNotMoney() throws {
        let s = try snapshot("rate-limits-pro.json")
        #expect(s.notes == ["Credits: 125.5"])
        #expect(s.money.isEmpty)
    }

    @Test func individualLimitAddsSpendCapWindowAndNote() throws {
        let s = try snapshot("rate-limits-business-spend-cap.json")
        #expect(s.plan == "Business")
        let cap = try #require(s.windows.first { $0.id == "spend-cap" })
        #expect(cap.label == "Spend cap")
        #expect(cap.usedPercent == 25)
        #expect(cap.resetsAt == Date(timeIntervalSince1970: 1_792_100_000))
        #expect(s.notes == ["Spend cap: 12.5 of 50 used"])
        #expect(s.windows.map(\.id) == ["session", "weekly", "spend-cap"])
    }

    @Test func spendCapPercentFallsBackToRemainingPercent() throws {
        let json = #"{"limit":"40","remainingPercent":70,"resetsAt":"2026-10-12T09:00:00Z"}"#
        let cap = try JSONDecoder().decode(CodexRateLimitSnapshot.SpendCap.self, from: Data(json.utf8))
        #expect(cap.percentUsed == 30)
        #expect(cap.resetsAt == Date(timeIntervalSince1970: 1_791_795_600))
    }

    static let idleCases: [(used: Double, resetIn: TimeInterval, expected: Bool)] = [
        (0, 18_000, true),
        (0, 18_090, true),
        (0, 17_910, true),
        (0, 18_180, false),
        (0, 7_200, false),
        (1, 18_000, false),
    ]

    @Test(arguments: idleCases)
    func notStartedOnlyWhenIdleAndResetIsSynthetic(used: Double, resetIn: TimeInterval, expected: Bool) {
        #expect(CodexRateLimitMapping.isNotStarted(usedPercent: used, windowMinutes: 300, resetsAt: now.addingTimeInterval(resetIn), now: now) == expected)
    }

    /// The `plan_type` values codex 0.162.0 declares (`hc` aside, its meaning is unknown), plus a made-up one for the fallback.
    static let planCases: [(raw: String, label: String?)] = [
        ("free", "Free"), ("go", "Go"), ("plus", "Plus"), ("pro", "Pro"), ("prolite", "Pro"), ("promax", "Pro"),
        ("team", "Business"), ("business", "Business"), ("self_serve_business_prolite", "Business"),
        ("self_serve_business_usage_based", "Business"), ("enterprise", "Enterprise"), ("ent26", "Enterprise"),
        ("enterprise_cbp_automation", "Enterprise"), ("enterprise_cbp_usage_based", "Enterprise"), ("enterprise_cbp_trial", "Enterprise"),
        ("edu", "Edu"), ("education", "Edu"), ("edu_plus", "Edu"), ("edu_pro", "Edu"), ("unknown", nil), ("", nil),
        ("usage_based", "Usage Based"),
    ]

    @Test(arguments: planCases)
    func planLabels(raw: String, label: String?) {
        #expect(CodexRateLimitMapping.planLabel(raw) == label)
    }

    @Test func unknownPlanShowsNoPill() throws {
        let json = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":9,"windowDurationMins":300},"planType":"unknown"}}"#
        let result = try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(json.utf8))
        let s = try #require(CodexRateLimitMapping.snapshot(from: result, accountID: "a", fetchedAt: now, source: "s"))
        #expect(s.plan == nil)
    }

    @Test func unknownDurationsGetMinuteIdsAndReadableLabels() {
        #expect(CodexRateLimitMapping.windowIdentity(minutes: 1_440, slot: "primary") == ("1440m", "1-day"))
        #expect(CodexRateLimitMapping.windowIdentity(minutes: 120, slot: "primary") == ("120m", "2-hour"))
        #expect(CodexRateLimitMapping.windowIdentity(minutes: 45, slot: "primary") == ("45m", "45-minute"))
        #expect(CodexRateLimitMapping.windowIdentity(minutes: nil, slot: "secondary") == ("secondary", "Limit"))
    }

    @Test func missingRateLimitsIsNotASnapshot() {
        #expect(CodexRateLimitMapping.snapshot(from: CodexRateLimitsResult(rateLimits: nil), accountID: "a", fetchedAt: now, source: "s") == nil)
    }

    @Test func unexpectedFieldTypesDropTheFieldNotTheResponse() throws {
        let json = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":"oops","windowDurationMins":300},"secondary":{"usedPercent":9,"windowDurationMins":10080,"resetsAt":1792150113},"credits":7,"planType":"plus"}}"#
        let result = try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(json.utf8))
        let s = try #require(CodexRateLimitMapping.snapshot(from: result, accountID: "a", fetchedAt: now, source: "s"))
        #expect(s.windows.map(\.id) == ["weekly"])
        #expect(s.notes.isEmpty)
    }
}
