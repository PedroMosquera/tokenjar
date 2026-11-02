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
}
