import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

// Rate fetches go through an injected fetcher and in-memory preferences: no test reaches the ECB or this Mac's
// preferences.

/// Counts the fetches and answers with what the test set.
private nonisolated final class RateAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    private var outcome: Result<ExchangeRates, FetchError>

    init(_ outcome: Result<ExchangeRates, FetchError>) { self.outcome = outcome }

    var total: Int { lock.withLock { asked } }
    func answer(_ next: Result<ExchangeRates, FetchError>) { lock.withLock { outcome = next } }

    func fetch() async throws -> ExchangeRates {
        try lock.withLock { () -> Result<ExchangeRates, FetchError> in
            asked += 1
            return outcome
        }.get()
    }
}

@MainActor
struct AppModelCurrencyTests {
    private struct Rig {
        let model: AppModel
        let asks: RateAsks
        let clock: TestClock
        let defaults: MemoryDefaults
        let network: FakeNetworkStatus
    }

    private func rates(_ date: String) -> ExchangeRates {
        ExchangeRates(date: date, perEUR: ["USD": 1.1, "GBP": 0.85])
    }

    private func today(_ clock: TestClock) -> String { ExchangeRateSchedule.latestPublicationDay(asOf: clock.now) }

    private func rig(
        _ localeID: String, stored: ExchangeRates? = nil, outcome: Result<ExchangeRates, FetchError>? = nil,
        defaults: MemoryDefaults = MemoryDefaults(), clock: TestClock = TestClock()
    ) throws -> Rig {
        if let stored { defaults.set(try JSONEncoder().encode(stored), forKey: AppModel.exchangeRatesKey) }
        let asks = RateAsks(outcome ?? .success(rates(ExchangeRateSchedule.latestPublicationDay(asOf: clock.now))))
        let network = FakeNetworkStatus()
        let model = AppModel(
            paths: .preview, clock: { clock.now }, network: network, defaults: defaults,
            rateFetcher: { try await asks.fetch() }, locale: Locale(identifier: localeID)
        )
        return Rig(model: model, asks: asks, clock: clock, defaults: defaults, network: network)
    }

    private func open(_ rig: Rig) async {
        rig.model.popoverWillOpen()
        await rig.model.rateCheck?.value
    }

    @Test func aUSDMacNeverFetches() async throws {
        let rig = try rig("en_US")
        await open(rig)
        await rig.model.refresh(force: true, userInitiated: true)?.value
        rig.model.showDashboard()
        #expect(rig.model.checkExchangeRates(userInitiated: true) == nil)
        #expect(rig.asks.total == 0)
        #expect(rig.model.costCurrency == .usd)
    }

    @Test func aEuroRegionDefaultsToEURAndFetchesOnFirstOpen() async throws {
        let rig = try rig("es_ES")
        #expect(rig.model.effectiveCurrency == "EUR")
        await open(rig)
        #expect(rig.asks.total == 1)
        #expect(rig.model.costCurrency.code == "EUR")
    }

    @Test func aPickOverridesTheRegionAndIsAPreferenceOfThisMac() async throws {
        let rig = try rig("es_ES")
        rig.model.setCurrencyPick("USD")
        #expect(rig.defaults.object(forKey: "displayCurrency") as? String == "USD")
        #expect(rig.model.effectiveCurrency == "USD")
        await open(rig)
        #expect(rig.asks.total == 0)

        rig.model.setCurrencyPick(nil)
        #expect(rig.defaults.object(forKey: "displayCurrency") == nil)
        #expect(rig.model.effectiveCurrency == "EUR")
        await rig.model.rateCheck?.value
    }

    @Test func pickingACurrencyFetchesAtOnce() async throws {
        let rig = try rig("en_US")
        let task = rig.model.checkExchangeRates(userInitiated: false)
        #expect(task == nil)
        rig.model.setCurrencyPick("GBP")
        await rig.model.rateCheck?.value
        #expect(rig.asks.total == 1)
        #expect(rig.model.costCurrency.code == "GBP")
    }

    @Test func theExpandedStateIsRememberedPerAccount() throws {
        let first = try rig("en_US")
        #expect(!first.model.isCostSectionExpanded("a"))
        first.model.setCostSectionExpanded("a", true)
        #expect(first.defaults.object(forKey: "costSectionExpanded") as? [String] == ["a"])

        let second = try rig("en_US", defaults: first.defaults)
        #expect(second.model.isCostSectionExpanded("a"))
        #expect(!second.model.isCostSectionExpanded("b"))
        second.model.setCostSectionExpanded("a", false)
        #expect(second.defaults.object(forKey: "costSectionExpanded") as? [String] == [])
    }

    /// $11 of this account's use at 1.1 USD per euro is €10 against the €100 plan; another account's use stays out.
    @Test func theCostSectionPricesThisAccountInTheDisplayCurrency() throws {
        let rig = try rig("es_ES", stored: rates(today(TestClock())))
        let now = rig.clock.now
        let store = InMemoryUsageStore()
        try store.upsert([
            UsageEvent(dedupeKey: "a", timestamp: now, accountID: "claude", harness: .claudeCode, model: "m", project: "p", inputTokens: 1_000_000),
            UsageEvent(dedupeKey: "b", timestamp: now, accountID: "other", harness: .claudeCode, model: "m", project: "p", inputTokens: 5_000_000),
        ])
        rig.model.store = store
        rig.model.priceTable = PriceTable(
            prices: ["m": ModelPrice(input: 11, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, source: "test", asOf: "test")],
            plans: ["claude": ["Max 5x": PlanPrice(monthlyUSD: 110, source: "test", asOf: "test")]]
        )
        let account = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let section = try #require(rig.model.costSection(for: account, snapshot: usageSnapshot(account, plan: "Max 5x", fetchedAt: now), now: now))
        #expect(section.today == Format.money(10, currency: "EUR", fractionDigits: 2, locale: .autoupdatingCurrent))
        #expect(section.tiles.last == CostSection.Tile(title: "Plan value", value: PlanValue.multipleText(0.1, locale: .autoupdatingCurrent), detail: "the \(Format.money(100, currency: "EUR", fractionDigits: 0, locale: .autoupdatingCurrent)) plan"))
    }

    @Test func freshRatesAreNotAskedForAgain() async throws {
        let clock = TestClock()
        let rig = try rig("es_ES", stored: rates(ExchangeRateSchedule.latestPublicationDay(asOf: clock.now)), clock: clock)
        await open(rig)
        rig.model.showDashboard()
        #expect(rig.asks.total == 0)
        #expect(rig.model.costCurrency.code == "EUR")
    }

    @Test func ratesSurviveARelaunch() async throws {
        let first = try rig("es_ES")
        await open(first)
        let second = try rig("es_ES", defaults: first.defaults, clock: first.clock)
        #expect(second.model.exchangeRates != nil)
        #expect(second.model.exchangeRates == first.model.exchangeRates)
    }

    @Test func aFruitlessFetchCoolsDownForSixHours() async throws {
        let clock = TestClock()
        let stale = rates("2020-01-01")
        let rig = try rig("es_ES", stored: stale, outcome: .success(stale), clock: clock)
        await open(rig)
        #expect(rig.asks.total == 1)
        clock.advance(3600)
        await open(rig)
        #expect(rig.asks.total == 1)
        clock.advance(5 * 3600 + 60)
        await open(rig)
        #expect(rig.asks.total == 2)
        clock.advance(180)
        await rig.model.refresh(force: true, userInitiated: true)?.value
        await rig.model.rateCheck?.value
        #expect(rig.asks.total == 3)
    }

    @Test func aFailedFetchKeepsTheLastRates() async throws {
        let stale = rates("2020-01-01")
        let rig = try rig("es_ES", stored: stale, outcome: .failure(.network("down")))
        await open(rig)
        #expect(rig.asks.total == 1)
        #expect(rig.model.exchangeRates == stale)
        #expect(rig.model.costCurrency.code == "EUR")
    }

    @Test func offlineHoldsTheOpenFetchButARefreshSends() async throws {
        let rig = try rig("es_ES")
        rig.model.networkPathChanged(.unusable)
        rig.clock.advance(NetworkWatch.offlineSettle)
        rig.model.settleNetwork()
        await open(rig)
        rig.model.showDashboard()
        #expect(rig.asks.total == 0)
        await rig.model.refresh(force: true, userInitiated: true)?.value
        await rig.model.rateCheck?.value
        #expect(rig.asks.total == 1)
    }

    @Test func previewsAndReadOnlyModelsNeverFetch() async throws {
        let asks = RateAsks(.success(rates("2026-10-30")))
        let preview = AppModel(paths: .preview, rateFetcher: { try await asks.fetch() }, locale: Locale(identifier: "es_ES"))
        preview.previewMode = true
        preview.popoverWillOpen()
        #expect(preview.checkExchangeRates(userInitiated: true) == nil)

        let home = try ModelHome()
        defer { home.remove() }
        try home.writeConfig(AppConfig(accounts: []))
        let readOnly = AppModel(paths: home.paths, rateFetcher: { try await asks.fetch() }, locale: Locale(identifier: "es_ES"))
        readOnly.loadReadOnly(store: InMemoryUsageStore())
        #expect(readOnly.checkExchangeRates(userInitiated: true) == nil)
        #expect(asks.total == 0)
    }

    /// A pay-as-you-go account with a budget in `currency` and $50 of priced spend this month.
    private func budgetedModel(
        _ home: ModelHome, budget: Double, currency: String, stored: ExchangeRates? = nil, asks: RateAsks, locale: String,
        log: FetchLog = FetchLog()
    ) throws -> (AppModel, AccountConfig) {
        var gateway = AccountConfig(id: "gateway", provider: .claude, label: "LiteLLM")
        gateway.monthlyBudget = budget
        gateway.budgetCurrency = currency
        try home.writeConfig(AppConfig(accounts: [gateway]))
        let clock = TestClock()
        let defaults = MemoryDefaults()
        if let stored { defaults.set(try JSONEncoder().encode(stored), forKey: AppModel.exchangeRatesKey) }
        let model = AppModel(
            paths: home.paths,
            fetcher: { _ in FakeFetcher(log: log, result: { account in
                .success(UsageSnapshot(accountID: account.id, provider: .claude, billing: .payAsYouGo, fetchedAt: Date(), source: "test"))
            }) },
            clock: { clock.now }, defaults: defaults, rateFetcher: { try await asks.fetch() }, locale: Locale(identifier: locale)
        )
        model.isAvailable = { _ in true }
        model.loadState()
        try model.store?.upsert([UsageEvent(
            dedupeKey: "gateway:1", timestamp: clock.now.addingTimeInterval(-3600), accountID: "gateway", harness: .claudeCode,
            model: "claude-opus-5-5", project: "tokenjar", inputTokens: 100, reportedCostUSD: 50
        )])
        return (model, gateway)
    }

    @Test func aEuroBudgetComparesInEuros() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let asks = RateAsks(.failure(.network("unused")))
        let (model, gateway) = try budgetedModel(
            home, budget: 92, currency: "EUR", stored: ExchangeRates(date: "2026-10-30", perEUR: ["USD": 1 / 0.92]), asks: asks, locale: "en_US"
        )
        await model.tick()?.value

        let snapshot = try #require(model.status(for: gateway).snapshot)
        let money = try #require(snapshot.spendLimitMoney)
        #expect(money.currency == "EUR")
        #expect(abs(money.amount - 46) < 0.001)
        #expect(abs(try #require(snapshot.windows.first { $0.id == UsageWindow.spendCapID }).usedPercent - 50) < 0.001)
    }

    @Test func aBudgetInACurrencyWithoutARateIsUntrackedAndFetchesNothing() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let asks = RateAsks(.success(rates("2026-10-30")))
        let (model, gateway) = try budgetedModel(home, budget: 100, currency: "EUR", asks: asks, locale: "en_US")
        await model.tick()?.value
        await model.rateCheck?.value

        let snapshot = try #require(model.status(for: gateway).snapshot)
        #expect(!snapshot.windows.contains { $0.id == UsageWindow.spendCapID })
        #expect(snapshot.notes.contains("Budget is in EUR. Pick EUR in Settings > General to track it on this Mac."))
        #expect(asks.total == 0)
    }

    @Test func ratesArrivingTrackAnUntrackedBudgetWithoutAskingTheProvider() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let asks = RateAsks(.success(rates("2026-10-30")))
        let log = FetchLog()
        let (model, gateway) = try budgetedModel(home, budget: 100, currency: "EUR", asks: asks, locale: "es_ES", log: log)
        await model.tick()?.value
        let untracked = try #require(model.status(for: gateway).snapshot)
        #expect(untracked.notes.contains("Budget is in EUR. It is tracked once an exchange rate loads."))
        #expect(!untracked.windows.contains { $0.id == UsageWindow.spendCapID })

        await model.checkExchangeRates(userInitiated: true)?.value
        let tracked = try #require(model.status(for: gateway).snapshot)
        #expect(!tracked.notes.contains { $0.hasPrefix("Budget is in") })
        let money = try #require(tracked.spendLimitMoney)
        #expect(money.currency == "EUR")
        #expect(abs(money.amount - 50 / 1.1) < 0.001)
        #expect(tracked.windows.filter { $0.id == UsageWindow.spendCapID }.count == 1)
        #expect(log.count("gateway") == 1)
        #expect(asks.total == 1)
    }
}
