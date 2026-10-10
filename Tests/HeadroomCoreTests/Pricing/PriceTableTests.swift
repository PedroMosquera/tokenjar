import Foundation
import Testing
@testable import HeadroomCore

struct PriceTableTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/Pricing")
    static let bundled = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/pricing.json")

    static func price(_ input: Double, source: String = "test") -> ModelPrice {
        ModelPrice(input: input, output: input * 5, cacheRead: input / 10, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2, source: source, asOf: "2026-10-10")
    }

    let table = PriceTable(
        prices: [
            "claude-opus-5-5": price(4, source: "opus-5-5"),
            "claude-opus-5": price(5, source: "opus-5"),
            "claude-haiku-4-5": price(1, source: "haiku-4-5"),
            "gpt-5.5": price(5, source: "gpt-5.5"),
        ],
        aliases: ["opus": "claude-opus-5-5"]
    )

    @Test(arguments: [
        ("claude-opus-5-5", "opus-5-5"),
        ("claude-opus-5", "opus-5"),
        ("Claude-Opus-5-5", "opus-5-5"),
        ("opus", "opus-5-5"),
        ("anthropic/claude-opus-5-5", "opus-5-5"),
        ("openai/gpt-5.5", "gpt-5.5"),
        ("anthropic.claude-opus-5-5", "opus-5-5"),
        ("global.anthropic.claude-opus-5-5", "opus-5-5"),
        ("us.anthropic.claude-haiku-4-5-20251001-v1:0", "haiku-4-5"),
        ("claude-haiku-4-5@20251001", "haiku-4-5"),
        ("claude-haiku-4-5-20251001", "haiku-4-5"),
        ("claude-opus-5-5[1m]", "opus-5-5"),
        ("gpt-5.5-2026-04-23", "gpt-5.5"),
        ("claude-opus-5-5-fast", "opus-5-5"),
        ("gpt-5.5-codex", "gpt-5.5"),
    ])
    func resolvesProviderSpellings(model: String, expected: String) {
        #expect(table.price(for: model)?.source == expected)
    }

    @Test(arguments: ["glm-5.2", "<synthetic>", "", "claude-sonnet-5", "gpt-5"])
    func unknownModelsHaveNoPrice(model: String) {
        #expect(table.price(for: model) == nil)
    }

    @Test func normalizationLeavesOrdinaryVersionSuffixesAlone() {
        #expect(PriceTable.normalize("deepseek-v3") == "deepseek-v3")
        #expect(PriceTable.normalize("gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(PriceTable.normalize("claude-3-5-sonnet-20240620") == "claude-3-5-sonnet")
        #expect(PriceTable.normalize("eu.anthropic.claude-sonnet-4-5-20250929-v1:0") == "claude-sonnet-4-5")
    }

    @Test func overrideReplacesEntriesModelByModel() throws {
        let loaded = PriceTable.load(bundled: Self.fixtures.appending(path: "base.json"), override: Self.fixtures.appending(path: "override.json"))

        #expect(loaded.price(for: "model-a")?.input == 1)
        let b = try #require(loaded.price(for: "model-b"))
        #expect(b == ModelPrice(input: 30, output: 150, cacheRead: 3, cacheWrite5m: 37.5, cacheWrite1h: 60, source: "", asOf: ""))
        #expect(loaded.price(for: "model-c")?.source == "my contract")
        #expect(loaded.price(for: "a-legacy")?.input == 1)
        #expect(loaded.price(for: "b-legacy")?.input == 0.5)
    }

    @Test func missingOrInvalidFilesContributeNothing() {
        let base = Self.fixtures.appending(path: "base.json")
        let missing = Self.fixtures.appending(path: "does-not-exist.json")
        #expect(PriceTable.load(bundled: nil, override: nil).prices.isEmpty)
        #expect(PriceTable.load(bundled: missing, override: base).prices.keys.sorted() == ["model-a", "model-b"])
        #expect(PriceTable.load(bundled: base, override: missing).prices.keys.sorted() == ["model-a", "model-b"])
        let wrongUnit = PriceTable.load(bundled: base, override: Self.fixtures.appending(path: "wrong-unit.json"))
        #expect(wrongUnit.price(for: "model-a")?.input == 1)
    }

    // MARK: Cost

    func row(model: String = "claude-opus-5-5", reported: Double? = nil, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) -> DailyUsageRow {
        DailyUsageRow(
            day: Date(timeIntervalSince1970: 0), accountID: "acct", harness: .claudeCode, model: model, project: nil, requests: 1,
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWrite5mTokens: cacheWrite5m, cacheWrite1hTokens: cacheWrite1h,
            reasoningTokens: 0, reportedCostUSD: reported, unpricedInputTokens: input, unpricedOutputTokens: output,
            unpricedCacheReadTokens: cacheRead, unpricedCacheWrite5mTokens: cacheWrite5m, unpricedCacheWrite1hTokens: cacheWrite1h
        )
    }

    @Test func pricesEveryTokenKindPerMillion() throws {
        // claude-opus-5-5 here: input 4, output 20, cache read 0.4, cache write 5m 5, cache write 1h 8 per million.
        let priced = table.priced(row(input: 1_000_000, output: 500_000, cacheRead: 2_000_000, cacheWrite5m: 100_000, cacheWrite1h: 10_000))
        let cost = try #require(priced.costUSD)
        #expect(abs(cost - (4 + 10 + 0.8 + 0.5 + 0.08)) < 1e-9)
        #expect(priced.isEstimate)
    }

    @Test func addsReportedCostToTheEstimateForUnpricedTokens() throws {
        var mixed = row(reported: 1.5, input: 1_000_000)
        mixed.inputTokens = 3_000_000
        let priced = table.priced(mixed)
        #expect(abs(try #require(priced.costUSD) - 5.5) < 1e-9)
        #expect(priced.isEstimate)
    }

    @Test func reportedCostAloneIsNotAnEstimate() {
        var reportedOnly = row(reported: 2.25)
        reportedOnly.inputTokens = 1_000_000
        #expect(table.priced(reportedOnly) == PricedUsageRow(row: reportedOnly, costUSD: 2.25, isEstimate: false))
        #expect(table.priced(row(model: "glm-5.2", reported: 2.25)).costUSD == 2.25)
    }

    @Test func noPriceAndNothingReportedHasNoCost() {
        let priced = table.priced(row(model: "glm-5.2", input: 1_000))
        #expect(priced.costUSD == nil)
        #expect(!priced.isEstimate)
    }

    @Test func knownModelWithNoTokensCostsZero() {
        let priced = table.priced(row())
        #expect(priced.costUSD == 0)
        #expect(!priced.isEstimate)
    }

    // MARK: Bundled table

    @Test func bundledTableIsWellFormedAndSourced() throws {
        let data = try Data(contentsOf: Self.bundled)
        let file = try PriceFile.decode(data)
        #expect(file.version == 1 && file.currency == "USD" && file.unit == "per_million_tokens")
        #expect(!file.models.isEmpty)
        for (id, price) in file.models {
            #expect(id == id.lowercased(), "\(id) is not lowercase")
            #expect(price.source.hasPrefix("https://"), "\(id) has no source URL")
            #expect(price.asOf.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil, "\(id) has no asOf date")
            #expect(price.input > 0 && price.output > price.input, "\(id) input/output look wrong")
            #expect(price.cacheRead < price.input, "\(id) cache read should be cheaper than input")
            #expect(price.cacheWrite5m >= price.input && price.cacheWrite1h >= price.cacheWrite5m, "\(id) cache writes look wrong")
        }
        for (alias, target) in file.aliases ?? [:] {
            #expect(file.models[target] != nil, "alias \(alias) points at missing \(target)")
        }
    }

    /// Model ids Claude Code and Codex wrote to their logs as of 2026-10-10.
    @Test(arguments: [
        "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5", "claude-fable-5-1", "claude-fable-5", "claude-haiku-5-5",
        "claude-haiku-4-5-20251001", "gpt-5.5", "gpt-6.1-sol", "gpt-6-astra",
    ])
    func bundledTablePricesModelsSeenLocally(model: String) {
        let loaded = PriceTable.load(bundled: Self.bundled, override: nil)
        #expect(loaded.price(for: model) != nil)
    }
}
