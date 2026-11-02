import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct CostSectionTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 2026-11-02 15:30 in New York, the day after the clocks went back.
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 15, minute: 30))!
    let locale = Locale(identifier: "en_US")
    let max5x = PlanPrice(monthlyUSD: 100, source: "test", asOf: "test")
    let euro = CostCurrency.resolve("EUR", rates: ExchangeRates(date: "2026-10-30", perEUR: ["USD": 1 / 0.92]))

    func day(_ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    func row(_ day: Date, cost: Double?, model: String = "m", input: Int = 100) -> PricedUsageRow {
        let daily = DailyUsageRow(
            day: day, accountID: "claude", harness: .claudeCode, model: model, project: "p", requests: 1,
            inputTokens: input, outputTokens: 0, cacheReadTokens: 0, cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            reasoningTokens: 0, reportedCostUSD: nil, unpricedInputTokens: input, unpricedOutputTokens: 0,
            unpricedCacheReadTokens: 0, unpricedCacheWrite5mTokens: 0, unpricedCacheWrite1hTokens: 0
        )
        return PricedUsageRow(row: daily, cost: cost, isEstimate: cost != nil)
    }

    func snapshot(billing: Billing? = nil, windows: [UsageWindow] = [UsageWindow(id: "weekly", label: "Week", usedPercent: 40)]) -> UsageSnapshot {
        UsageSnapshot(accountID: "claude", provider: .claude, plan: "Max 5x", billing: billing, windows: windows, fetchedAt: now, source: "test")
    }

    func make(_ rows: [PricedUsageRow], planPrice: PlanPrice? = nil, snapshot: UsageSnapshot? = nil, currency: CostCurrency = .usd) -> CostSection.Content? {
        CostSection.make(
            snapshot: snapshot ?? self.snapshot(), rows: currency.converted(rows), planPrice: planPrice, currency: currency,
            now: now, calendar: Self.calendar, locale: locale
        )
    }

    /// $780 over 30 days: $20.25 today, the rest earlier in the window.
    var month: [PricedUsageRow] {
        [
            row(day(11, 2), cost: 20.25, input: 1_000_000),
            row(day(10, 20), cost: 500, input: 2_000_000),
            row(day(10, 4), cost: 259.75, input: 100_000),
        ]
    }

    @Test func theRowShowsTodayAndThePlanMultiple() throws {
        let content = try #require(make(month, planPrice: max5x))
        #expect(content.today == "$20.25")
        #expect(content.trailing == "7.8x plan")
        #expect(content.multiple == "7.8x")
        #expect(content.highlightsTrailing)
        #expect(content.tiles == [
            CostSection.Tile(title: "Today", value: "$20.25"),
            CostSection.Tile(title: "Last 30 days", value: "$780"),
            CostSection.Tile(title: "30d tokens", value: Format.tokens(3_100_000, locale: locale)),
            CostSection.Tile(title: "Plan value", value: "7.8x", detail: "the $100 plan", highlighted: true),
        ])
    }

    /// Green says the plan paid for itself, so a plan used for less than its price stays uncoloured.
    @Test func belowThePlanPriceTheMultipleIsNotHighlighted() throws {
        let content = try #require(make([row(day(11, 2), cost: 50)], planPrice: max5x))
        #expect(content.trailing == "0.5x plan")
        #expect(content.multiple == "0.5x")
        #expect(!content.highlightsTrailing)
        #expect(content.tiles.last == CostSection.Tile(title: "Plan value", value: "0.5x", detail: "the $100 plan", highlighted: false))
    }

    @Test func withoutAPlanPriceTheRowShowsThe30DayTotal() throws {
        let content = try #require(make(month))
        #expect(content.trailing == "$780 30d")
        #expect(content.multiple == nil)
        #expect(!content.highlightsTrailing)
        #expect(content.tiles.last == CostSection.Tile(title: "Top model", value: "m"))
        #expect(content.footer == ["API-equivalent estimate from this Mac's logs, not a bill."])
    }

    @Test func nothingTodayReadsZero() throws {
        #expect(try #require(make([row(day(10, 20), cost: 5)])).today == "$0.00")
    }

    @Test func onlyTheLast30LocalDaysCount() throws {
        let content = try #require(make([row(day(10, 3), cost: 500), row(day(10, 4), cost: 1)]))
        #expect(content.trailing == "$1 30d")
        #expect(content.days.count == 30)
        #expect(content.days.first?.date == day(10, 4))
        #expect(content.days.last?.date == day(11, 2))
        #expect(content.days.first?.amount == 1)
    }

    @Test func theAverageCountsDaysWithoutUse() throws {
        let content = try #require(make([row(day(10, 10), cost: 30), row(day(11, 1), cost: 30)]))
        #expect(content.average == 2)
        #expect(content.peak == 30)
        #expect(content.summary == "Avg $2 · Peak $30")
        #expect(content.spoken == "Daily API value, last 30 days, average $2, peak $30")
        #expect(content.days.filter { $0.amount > 0 }.map(\.date) == [day(10, 10), day(11, 1)])
    }

    @Test func hoveringADayReadsItsDateAndAmount() throws {
        let content = try #require(make([row(day(10, 30), cost: 5)]))
        let hovered = Self.calendar.date(byAdding: .hour, value: 14, to: day(10, 30))!
        let found = try #require(content.day(at: hovered, calendar: Self.calendar))
        #expect(found == CostSection.Day(date: day(10, 30), amount: 5))
        #expect(content.readout(found, calendar: Self.calendar, locale: locale) == "Oct 30: $5.00")
        #expect(content.day(at: day(9, 30), calendar: Self.calendar) == nil)
    }

    /// The sum per model decides, not the single costliest day.
    @Test func theTopModelIsTheCostliest() throws {
        let rows = [
            row(day(11, 1), cost: 10, model: "claude-fable-5-1"),
            row(day(11, 2), cost: 8, model: "claude-opus-5-5"),
            row(day(10, 30), cost: 5, model: "claude-opus-5-5"),
        ]
        #expect(try #require(make(rows, planPrice: max5x)).footer.first == "Top model: claude-opus-5-5")
        #expect(try #require(make(rows)).tiles.last == CostSection.Tile(title: "Top model", value: "claude-opus-5-5"))
    }

    @Test func unpricedModelsAreNoted() throws {
        let priced = try #require(make([row(day(11, 2), cost: 3)], planPrice: max5x))
        #expect(priced.footer[1] == "API-equivalent estimate from this Mac's logs, not a bill.")
        let mixed = try #require(make([row(day(11, 2), cost: 3), row(day(11, 1), cost: nil)], planPrice: max5x))
        #expect(mixed.footer[1] == "API-equivalent estimate from this Mac's logs, not a bill, some models unpriced.")
    }

    @Test func inEurosTheFooterNamesTheRateDate() throws {
        let content = try #require(make(month, planPrice: max5x, currency: euro))
        #expect(content.today == "€18.63")
        #expect(content.trailing == "7.8x plan")
        #expect(content.tiles.last == CostSection.Tile(title: "Plan value", value: "7.8x", detail: "the €92 plan", highlighted: true))
        #expect(content.footer.contains("EUR at the ECB rate of Oct 30."))
        #expect(content.currency == "EUR")
    }

    /// Yen has no minor unit, so neither today nor a hovered day gets decimals.
    @Test func inYenAmountsHaveNoDecimals() throws {
        let yen = CostCurrency.resolve("JPY", rates: ExchangeRates(date: "2026-10-30", perEUR: ["USD": 1, "JPY": 162.5]))
        let content = try #require(make(month, planPrice: max5x, currency: yen))
        #expect(content.today == "¥3,291")
        #expect(content.tiles.first == CostSection.Tile(title: "Today", value: "¥3,291"))
        let hovered = try #require(content.day(at: day(10, 20), calendar: Self.calendar))
        #expect(content.readout(hovered, calendar: Self.calendar, locale: locale) == "Oct 20: ¥81,250")
    }

    /// Settings dates the rate as the footer does, so the two never read "2026-10-30" and "Oct 30".
    @Test @MainActor func settingsDatesTheRateAsTheFooterDoes() {
        #expect(GeneralSettingsPane.rateCaption(euro) == "Rate of Oct 30")
        #expect(GeneralSettingsPane.rateCaption(.usd) == nil)
    }

    @Test func awaitingARateSaysSo() throws {
        let content = try #require(make(month, planPrice: max5x, currency: CostCurrency.resolve("EUR", rates: nil)))
        #expect(content.today == "$20.25")
        #expect(content.footer.contains("Shown in USD until an exchange rate loads."))
        #expect(!content.footer.contains { $0.contains("ECB") })
    }

    @Test func onlyPlanCardsGetIt() {
        let rows = [row(day(11, 2), cost: 3)]
        #expect(make(rows, snapshot: snapshot(billing: nil)) != nil)
        #expect(make(rows, snapshot: snapshot(billing: .subscription)) != nil)
        for billing in [Billing.payAsYouGo, .usageBased, .pooled] {
            #expect(make(rows, snapshot: snapshot(billing: billing)) == nil)
        }
        #expect(make(rows, snapshot: snapshot(windows: [])) == nil)
        let cap = UsageWindow(id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: 10)
        #expect(make(rows, snapshot: snapshot(windows: [cap])) == nil)
        #expect(make([row(day(11, 2), cost: nil)]) == nil)
        #expect(make([]) == nil)
    }

    /// "$0.00 today · 0.0x plan" says nothing, so a window priced at zero gets no section, as the dashboard's plan value.
    @Test func aWindowPricedAtNothingHasNoSection() {
        #expect(make([row(day(11, 2), cost: 0), row(day(10, 30), cost: 0)], planPrice: max5x) == nil)
    }

    /// An Enterprise seat's spend limit already has its own bar, so the section stays off even beside a plan window.
    @Test func aSpendLimitKeepsItOff() {
        let cap = UsageWindow(id: UsageWindow.spendCapID, label: "Spend limit", usedPercent: 10)
        var limited = snapshot(windows: [UsageWindow(id: "weekly", label: "Week", usedPercent: 40), cap])
        limited.money = [MoneyLine(label: "Spend limit", amount: 10, limit: 100)]
        #expect(make([row(day(11, 2), cost: 3)], snapshot: limited) == nil)
    }
}
