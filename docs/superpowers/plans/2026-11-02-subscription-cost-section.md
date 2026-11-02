# Subscription Cost Section and Display Currency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every subscription card a collapsible "API value" section (today, 30-day plan value, daily bars) and show every API-equivalent estimate in the Mac's currency using the ECB's daily rate.

**Architecture:** Pure logic in `TokenjarCore` (ECB parsing, conversion, fetch schedule, region default), state and fetch triggers in `AppModel` modelled on provider status, and a pure text model (`CostSection`) behind a thin SwiftUI view, following the `MonthCostLine` split. Estimates are converted once, at the row level, right after pricing, so every sum, chart and tile downstream is already in the display currency.

**Tech Stack:** Swift 6 package, SwiftUI, Swift Charts, Swift Testing, Foundation `XMLParser`. Built with the Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-11-02-subscription-cost-section-design.md`

## Global Constraints

- Build and test with `make build` and `make test` (Command Line Tools, no Xcode). Read results with `make test 2>&1 | tail -30`.
- `@State` only through explicit `State<...>` storage (see `BurnUpChart.hoverState`).
- Supported currencies, in picker order: `USD, EUR, GBP, CHF, JPY, CAD, AUD`.
- ECB endpoint, exact: `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`. Headers exactly `User-Agent: Tokenjar`, `Accept: application/xml`. Timeout 10 s.
- Cooldown after a fruitless attempt: 6 hours for automatic triggers, 2 minutes for a user-initiated refresh.
- Currency pick, rates and expanded state live in `AppModel.preferences` (keys `displayCurrency`, `exchangeRates`, `costSectionExpanded`), never in `config.json`. `budgetCurrency` is the only new `config.json` field.
- Copy, verbatim: row label `API value`; `<today> today · <multiple>x plan`; fallback `<today> today · <total> 30d`; tiles `Today`, `Last 30 days`, `30d tokens`, `Plan value` (`7.8x the $100 plan`) or `Top model`; chart caption `Daily, 30 days`; `Avg <x> · Peak <y>`; footer `API-equivalent estimate from this Mac's logs, not a bill.`, `EUR at the ECB rate of Oct 30.`, `Shown in USD until an exchange rate loads.`, `Open in Dashboard`.
- Project comment standard: comments carry only what the code cannot. No em or en dashes anywhere, code comments and test names included.
- Commits: Conventional Commits, `feat:`/`fix:`/`docs:`/`test:`, never `!` or `BREAKING CHANGE`. No AI trailers. Before each commit, grep the staged added lines for em dashes (U+2014) as its own command and expect no hits.

## Review Focus

1. **A non-USD region on first launch offline**: no rates yet. Expect USD amounts with the "Shown in USD until an exchange rate loads." footer, never a EUR symbol on a USD number. Pinned by `CostSectionTests.awaitingARateSaysSo` and `CostCurrencyTests.aMissingRateFallsBackToUSD`.
2. **ECB answer with the same date (holiday) or a 404**: must not refetch on every popover open. Pinned by `AppModelCurrencyTests.aFruitlessFetchCoolsDownForSixHours`.
3. **A budget in EUR on a Mac whose currency is USD**: no bar, no alert, a note saying why, and no fetch. Pinned by `AppModelCurrencyTests.aBudgetInACurrencyWithoutARateIsUntrackedAndFetchesNothing`.
4. **Midnight and the 30-day edge**: the row on day 31 back must not count, today must. Pinned by `CostSectionTests.onlyTheLast30LocalDaysCount`.
5. **Switching currency with the popover or dashboard open**: amounts and symbols change together; a half-converted screen (EUR symbol, USD value) is the bug. Pinned by `CostCurrencyTests.convertedRowsCarryTheCurrencyCode` and every view taking `CostCurrency` as one value rather than a code and a rate separately.

---

### Task 1: Exchange rates, conversion and the region default (Core)

**Files:**
- Create: `Sources/TokenjarCore/Pricing/ExchangeRates.swift`
- Create: `Sources/TokenjarCore/Pricing/CostCurrency.swift`
- Test: `Tests/TokenjarCoreTests/Pricing/ExchangeRatesTests.swift`, `Tests/TokenjarCoreTests/Pricing/CostCurrencyTests.swift`

**Interfaces:**
- Produces:
  - `public struct ExchangeRates: Codable, Hashable, Sendable { public var date: String /* "yyyy-MM-dd", the ECB's Cube time */; public var perEUR: [String: Double] }`
  - `public static func parse(_ data: Data) throws -> ExchangeRates` (throws `FetchError.parse(String)` when no dated Cube or no USD rate)
  - `public func perUSD(_ code: String) -> Double?` (`USD` is 1, `EUR` is `1 / perEUR["USD"]`, others `perEUR[code] / perEUR["USD"]`)
  - `public func convert(usd: Double, to code: String) -> Double?`
  - `public struct CostCurrency: Hashable, Sendable { public let code: String; public let perUSD: Double; public let rateDate: String?; public let awaitingRate: Bool }`
  - `public static let usd: CostCurrency`
  - `public static func resolve(_ wanted: String, rates: ExchangeRates?) -> CostCurrency` (USD with `awaitingRate == true` when `wanted != "USD"` and no rate)
  - `public func amount(_ usd: Double) -> Double`
  - `public func converted(_ rows: [PricedUsageRow]) -> [PricedUsageRow]` (scales `cost`; Task 4 renames `costUSD` to `cost`, so write this against `costUSD` and Task 4 renames it)
  - `public enum DisplayCurrency { public static let supported: [String]; public static func regionDefault(_ locale: Locale) -> String; public static func effective(pick: String?, locale: Locale) -> String }`

- [ ] **Step 1: Write the failing tests**

ECB fixture, inline in `ExchangeRatesTests`:

```swift
static let ecb = Data("""
<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
<gesmes:subject>Reference rates</gesmes:subject>
<Cube><Cube time="2026-10-30"><Cube currency="USD" rate="1.0870"/><Cube currency="JPY" rate="162.50"/><Cube currency="GBP" rate="0.8400"/></Cube></Cube>
</gesmes:Envelope>
""".utf8)
```

Tests and assertions:
- `parsesTheDateAndEveryRate`: `date == "2026-10-30"`, `perEUR == ["USD": 1.087, "JPY": 162.5, "GBP": 0.84]`.
- `convertsFromUSDThroughTheEuro`: `perUSD("USD") == 1`; `abs(perUSD("EUR")! - 0.919963) < 1e-6`; `abs(perUSD("GBP")! - 0.772769) < 1e-6`; `abs(perUSD("JPY")! - 149.494) < 1e-3`; `perUSD("CHF") == nil`.
- `aBodyWithoutUSDOrADateDoesNotParse`: two bodies (no `time`, no USD Cube) each throw `FetchError.parse`.
- `CostCurrencyTests.aMissingRateFallsBackToUSD`: `resolve("EUR", rates: nil)` has `code == "USD"`, `perUSD == 1`, `awaitingRate == true`; `resolve("USD", rates: nil).awaitingRate == false`.
- `CostCurrencyTests.resolvesWithTheRateAndItsDate`: `resolve("EUR", rates: fixture)` has `code == "EUR"`, `rateDate == "2026-10-30"`, `abs(amount(100) - 91.9963) < 1e-3`.
- `CostCurrencyTests.convertedRowsCarryTheCurrencyCode`: converting rows with costs `[10, nil]` to EUR gives `[9.19963, nil]` (within 1e-5) and leaves `isEstimate` and `row` unchanged.
- `CostCurrencyTests.theRegionPicksTheDefault`: `regionDefault(Locale(identifier: "es_ES")) == "EUR"`, `en_GB` gives `GBP`, `ja_JP` gives `JPY`, `pt_BR` gives `USD` (BRL not supported), `en_US` gives `USD`.
- `CostCurrencyTests.aPickWinsOverTheRegion`: `effective(pick: "USD", locale: es_ES) == "USD"`, `effective(pick: nil, locale: es_ES) == "EUR"`, `effective(pick: "XYZ", locale: es_ES) == "EUR"` (an unsupported stored pick is ignored).

- [ ] **Step 2: Run them and confirm they fail** on missing types: `make test 2>&1 | grep -E "error:|ExchangeRates|CostCurrency" | head`.

- [ ] **Step 3: Implement** in the two files above. Parse with `XMLParser` and a small delegate reading `time`, `currency` and `rate` attributes; no regex. `regionDefault` reads `locale.currency?.identifier`.

- [ ] **Step 4: Run** `make test 2>&1 | tail -30`. Expected: both suites pass, nothing else regresses.

- [ ] **Step 5: Commit** `feat(pricing): parse ECB reference rates and resolve a display currency`.

---

### Task 2: The ECB request, its schedule, and the privacy docs (Core + docs)

**Files:**
- Create: `Sources/TokenjarCore/Pricing/ExchangeRateFetcher.swift` (fetcher plus `ExchangeRateSchedule`)
- Modify: `Sources/TokenjarCore/Core/HTTPClient.swift:32-37` (allowlist)
- Modify: `Tests/TokenjarCoreTests/Core/HTTPClientTests.swift:7-15` (`allowlistIsPinned`)
- Modify: `Tests/TokenjarCoreTests/Health/ProviderHealthFetcherTests.swift` (`feedsAreTheOnlyOtherAllowedEndpointsAndPagesAreNeverFetched` expects the ECB entry too)
- Modify: `docs/privacy.md` (Requests Tokenjar makes itself, How HTTPClient enforces it, and the Contacts list under The summary in Settings > About), `Sources/Tokenjar/Settings/AboutSettingsPane.swift:39-42` (a Contacts `Item` with `what: "GET https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"`, `why: "Exchange rates for estimates, only when the currency is not USD. Once a day at most, when you open the popover or dashboard or refresh."`; `AboutSummaryTests` fails until both lists match), `docs/design.md` (Non-goals drops "currency conversion"; hard rule 3 lists the ECB request; the Settings > General description gains the Currency picker)
- Test: `Tests/TokenjarCoreTests/Pricing/ExchangeRateFetcherTests.swift`

**Interfaces:**
- Consumes: `ExchangeRates.parse` (Task 1); `HealthFakeTransport` from `Tests/TokenjarCoreTests/Health/ProviderHealthTestSupport.swift`.
- Produces:
  - `public struct ExchangeRateFetcher: Sendable { public static let url: URL; public static let timeout: TimeInterval = 10; public init(http: HTTPClient = HTTPClient()); public func fetch() async throws -> ExchangeRates }` (errors map like `ProviderHealthFetcher.fetch`: `.timeout`, `.network("HTTP 404")`, `.parse`)
  - `public enum ExchangeRateSchedule { public static let automaticCooldown: TimeInterval = 6 * 3600; public static let userCooldown: TimeInterval = 120; public static func latestPublicationDay(asOf now: Date) -> String; public static func isDue(rates: ExchangeRates?, lastFruitlessAttempt: Date?, now: Date, userInitiated: Bool) -> Bool }`

- [ ] **Step 1: Write the failing tests**
- `sendsOneGETWithNoKeyOrCookie`: one request, `url == ExchangeRateFetcher.url`, method `GET`, `allHTTPHeaderFields == ["User-Agent": "Tokenjar", "Accept": "application/xml"]`, `timeoutInterval == 10`.
- `a404IsANetworkError`: throws `FetchError.network("HTTP 404")`.
- `HTTPClientTests.allowlistIsPinned`: add `"www.ecb.europa.eu": ["/stats/eurofxref/eurofxref-daily.xml"]` to both expectations.
- Schedule, with a `Europe/Berlin` calendar: `latestPublicationDay` at Mon 2026-11-02 15:00 is `"2026-10-30"`; at Mon 16:30 is `"2026-11-02"`; at Sat 2026-10-31 12:00 is `"2026-10-30"`.
- `isDue`: nil rates is due; rates dated `"2026-11-02"` at Mon 17:00 is not due; rates dated `"2026-10-30"` at Mon 17:00 is due; same stale rates with a fruitless attempt 1 hour ago is not due automatically, is due when user-initiated; fruitless attempt 6 h 1 m ago is due automatically; fruitless attempt 60 s ago is not due even when user-initiated.

- [ ] **Step 2: Run and confirm failures** (missing types, and `allowlistIsPinned` red on its assertion once the expectation is updated before the allowlist).

- [ ] **Step 3: Implement** the fetcher (pass `headers: ["Accept": "application/xml"]` to `HTTPClient.get`, which overrides its default Accept), the schedule (publication is 16:00 `Europe/Berlin` on Monday to Friday; holidays are left to the cooldown), and the allowlist entry. Update the docs in this same commit, because `docs/privacy.md` states that adding an endpoint needs the page updated in the same change. The privacy table follows the provider-status table's rows: Request, When (the triggers from the spec's "When it is fetched" list, verbatim in meaning), Headers, Timeout, What is read (the `time`, `currency` and `rate` attributes), Kept (this Mac's preferences, until a newer answer), What the host can infer (your IP, that you run Tokenjar, roughly when you open the popover on a day with a new rate).

- [ ] **Step 4: Run** `make test 2>&1 | tail -30`. Expected: green, including `DocsPinTests` and `AboutSummaryTests`.

- [ ] **Step 5: Commit** `feat(pricing): fetch the ECB daily rates on an allowlisted GET`.

---

### Task 3: Currency state in AppModel and the Settings picker

**Files:**
- Modify: `Sources/Tokenjar/App/AppModel.swift` (init seams near line 174; `popoverWillOpen` line 442; `refresh(force:userInitiated:)` line 628; `showDashboard` line 981; a new `// MARK: Currency` section beside `// MARK: Provider status`)
- Modify: `Sources/Tokenjar/Settings/GeneralSettingsPane.swift` (a `Currency` section next to `providerStatusSection`)
- Test: `Tests/TokenjarTests/App/AppModelCurrencyTests.swift`

**Interfaces:**
- Consumes: `DisplayCurrency`, `CostCurrency`, `ExchangeRates` (Task 1); `ExchangeRateFetcher`, `ExchangeRateSchedule` (Task 2).
- Produces on `AppModel`:
  - init params `rateFetcher: @escaping @Sendable () async throws -> ExchangeRates = { try await ExchangeRateFetcher().fetch() }` and `locale: Locale = .autoupdatingCurrent`
  - `private(set) var currencyPick: String?`, `var effectiveCurrency: String`, `private(set) var exchangeRates: ExchangeRates?`, `var costCurrency: CostCurrency`
  - `func setCurrencyPick(_ code: String?)` (nil means Automatic; a non-USD effective result triggers `checkExchangeRates(userInitiated: true)`)
  - `@discardableResult func checkExchangeRates(userInitiated: Bool) -> Task<Void, Never>?`
  - `static let currencyPickKey = "displayCurrency"`, `static let exchangeRatesKey = "exchangeRates"`

- [ ] **Step 1: Write the failing tests**, with an injected recording `rateFetcher` (pattern: `HealthAsks` in `AppModelHealthTests.swift`) and `MemoryDefaults`:
- `aUSDMacNeverFetches`: locale `en_US`, no pick; `popoverWillOpen()`, `refresh(force: true, userInitiated: true)`, `showDashboard()` give 0 fetches.
- `aEuroRegionDefaultsToEURAndFetchesOnFirstOpen`: locale `es_ES`; `effectiveCurrency == "EUR"`; after `popoverWillOpen()` and awaiting the task, 1 fetch and `costCurrency.code == "EUR"`.
- `aPickOverridesTheRegionAndIsAPreferenceOfThisMac`: locale `es_ES`, `setCurrencyPick("USD")`; preferences `displayCurrency == "USD"`; open gives 0 fetches; `setCurrencyPick(nil)` removes the key and `effectiveCurrency == "EUR"`.
- `freshRatesAreNotAskedForAgain`: stored rates dated today's publication day; open gives 0 fetches.
- `ratesSurviveARelaunch`: a second model on the same `MemoryDefaults` has the same `exchangeRates`.
- `aFruitlessFetchCoolsDownForSixHours`: fetcher returns the stored date; second open 1 h later gives no new fetch; open 6 h 1 m later fetches; a user refresh 3 min after a fruitless attempt fetches.
- `aFailedFetchKeepsTheLastRates`: fetcher throws `.network`; `exchangeRates` unchanged.
- `offlineHoldsTheOpenFetchButARefreshSends`: same network seam as `AppModelNetworkTests`.
- `previewsAndReadOnlyModelsNeverFetch`: an inert model (as `AppModelHealthTests.previewsAndReadOnlyModelsNeverAsk`) fetches nothing.

- [ ] **Step 2: Run and confirm** each fails on its assertion (stub `checkExchangeRates` to return nil first if needed, so failures are not compile errors).

- [ ] **Step 3: Implement.** Mirror `checkProviderHealth`: guard `!isInert`, `effectiveCurrency != "USD"`, `userInitiated || !networkWatch.holdsChecks`, one task in flight, `ExchangeRateSchedule.isDue`. Record `lastFruitlessAttempt` (in memory) when the answer fails or carries a date not newer than the stored one; clear it on a newer answer. Persist rates as JSON `Data`. Log one line per failure under category `exchange-rates`, host and failure kind only. Hook `popoverWillOpen` (automatic), `refresh(userInitiated: true)` (user), `showDashboard` (automatic). Settings: a `Picker` labelled `Currency` with an `Automatic (<region code>)` item first, then the supported codes, caption `This Mac only. Estimates convert at the ECB's daily rate.`; when `costCurrency.rateDate` exists show `Rate of <date>`.

- [ ] **Step 4: Run** `make test 2>&1 | tail -30`. Expected: green.

- [ ] **Step 5: Commit** `feat(settings): pick a display currency, defaulting to the Mac's region`.

---

### Task 4: Convert every estimate (rename `costUSD`, thread `CostCurrency`)

**Files:**
- Modify: `Sources/TokenjarCore/Pricing/PriceTable.swift:64-76` (rename `costUSD` to `cost`; doc comment: in USD as priced, in the display currency after `CostCurrency.converted`)
- Modify every `costUSD` use: `Sources/Tokenjar/App/DevCommands.swift`, `Sources/Tokenjar/Dashboard/DashboardMath.swift`, `Sources/Tokenjar/Dashboard/ActivityCalendarMath.swift`, `Sources/TokenjarCore/Pricing/CostCurrency.swift`, and the tests listed by `grep -rln costUSD Tests`
- Modify: `Sources/Tokenjar/Dashboard/DashboardContent.swift` (`Input` gains `currency: CostCurrency`; rows at lines 108 and 164 go through `input.currency.converted`; line 200 passes `model.costCurrency`)
- Modify: `Sources/Tokenjar/Dashboard/DashboardMath.swift:644-684` (`PlanValue.make` gains `currency: CostCurrency`, converts `monthlyUSD`; `money(_:_:)` formats with `currency.code`; store the code on `PlanValue`)
- Modify the estimate format calls to pass the code: `DashboardView.swift:183,190,207,221`, `SpendChart.swift:157`, `ActivityCalendarMath.swift:104,110`, `TopProjectsTable.swift:10`, `PercentWorthTable.swift:10`, `SpendOverTimeChart.swift` only where it formats an estimate (its spend-limit amounts keep the line's own currency)
- Modify: `Sources/Tokenjar/Popover/MonthCostLine.swift` and `AppModel.monthCostLine` (`text(... currency: CostCurrency = .usd)`; rows converted before summing; the projected amount uses `currency.code`)
- Test: `Tests/TokenjarTests/Dashboard/PlanValueTests.swift`, `Tests/TokenjarTests/Popover/MonthCostLineTests.swift`

**Interfaces:**
- Consumes: `CostCurrency` (Task 1), `AppModel.costCurrency` (Task 3).
- Produces: `PricedUsageRow.cost: Double?`; `PlanValue.make(rows:since:accounts:snapshots:table:currency:)`; `MonthCostLine.text(snapshot:rows:now:calendar:locale:currency:)`.

- [ ] **Step 1: Write the failing tests**
- `PlanValueTests.inEurosBothSidesConvertAndTheMultipleStays`: rows worth $570 against Max 20x ($200), currency EUR at 0.92 per USD (build `CostCurrency.resolve("EUR", rates:)` from rates with `USD: 1/0.92`); `planPrice == 184` (within 1e-6), `multiple` within 1e-9 of 2.85, `caption(locale: en_US) == "vs the €184 plan"`.
- `MonthCostLineTests.inEurosTheLineUsesEuros`: the existing pay-as-you-go fixture with an EUR currency gives `amounts` starting `"€"` and a projected detail starting `"On pace for ~€"`.

- [ ] **Step 2: Run, confirm red on assertions.**

- [ ] **Step 3: Implement.** Do the rename first as its own mechanical edit: `grep -rl costUSD Sources Tests | xargs sed -i '' 's/costUSD/cost/g'`. The match is case-sensitive, so `DailyUsageRow.reportedCostUSD` (capital C) is untouched; check with `git diff --stat` that only the listed files changed. Provider-reported money (`MoneyLine`, `DailySpend`, spend-limit charts) is not touched.

- [ ] **Step 4: Run** `make test 2>&1 | tail -30`. Expected: green.

- [ ] **Step 5: Commit** `feat(dashboard): show API-equivalent estimates in the display currency`.

---

### Task 5: Budgets keep the currency they were typed in

**Files:**
- Modify: `Sources/TokenjarCore/Core/Models.swift:138-175` (`AccountConfig.budgetCurrency: String?`, nil meaning USD; init param; decode)
- Modify: `Sources/TokenjarCore/Core/Config.swift:350-351` (write `budgetCurrency` when it changes, like the budget fields)
- Modify: `Sources/TokenjarCore/Core/MonthlyBudget.swift` (`apply(_:spent:currency:to:now:calendar:)`; `public static func untrackedNote(budgetCurrency: String, displayCurrency: String) -> String`)
- Modify: `Sources/TokenjarCore/Settings/SettingsLogic.swift` (`public static func budgetCurrency(before: Double?, after: Double?, current: String?, display: String) -> String?`)
- Modify: `Sources/Tokenjar/App/AppModel.swift:762-766` (`withMonthlyBudget` converts USD spend into the budget's currency, or adds the untracked note)
- Modify: `Sources/Tokenjar/Settings/AccountDetailView.swift:185-225` (currency code beside both budget fields; saving goes through `SettingsLogic.budgetCurrency`)
- Test: `Tests/TokenjarCoreTests/Core/MonthlyBudgetTests.swift`, `Tests/TokenjarCoreTests/Settings/SettingsLogicTests.swift`, `Tests/TokenjarCoreTests/Core/ConfigStoreTests.swift`, `Tests/TokenjarTests/App/AppModelCurrencyTests.swift`

**Interfaces:**
- Consumes: `ExchangeRates.convert(usd:to:)` (Task 1), `AppModel.exchangeRates` and `effectiveCurrency` (Task 3).
- Produces: the fields and functions above. `budgetCurrency` applies to history-priced accounts only (`MonthlyBudget.applies`); a provider's own cap and a daily amount on it keep the cap's currency, per the spec's non-goal on provider money.

- [ ] **Step 1: Write the failing tests**
- `MonthlyBudgetTests.theBudgetsMoneyLineCarriesItsCurrency`: `apply(150, spent: 30, currency: "EUR", ...)` gives a money line with `currency == "EUR"`, `limit == 150`, `usedPercent` 20.
- `MonthlyBudgetTests.theUntrackedNoteSaysWhatToDo`: `untrackedNote(budgetCurrency: "EUR", displayCurrency: "USD") == "Budget is in EUR. Pick EUR in Settings > General to track it on this Mac."`; with display `"EUR"` it is `"Budget is in EUR. It is tracked once an exchange rate loads."`.
- `SettingsLogicTests.aNewBudgetTakesTheDisplayCurrency`: `(before: nil, after: 150, current: nil, display: "EUR") == "EUR"`; display `"USD"` gives nil; `(before: 150, after: 200, current: "EUR", display: "USD") == "EUR"` (editing keeps it); `(before: 150, after: nil, current: "EUR", display: "EUR") == nil` (clearing drops it).
- `ConfigStoreTests.anOldConfigReadsBudgetsAsUSD`: an account JSON without `budgetCurrency` decodes with nil; one with `"budgetCurrency": "EUR"` round-trips.
- `AppModelCurrencyTests.aEuroBudgetComparesInEuros`: EUR rates loaded (0.92 per USD), budget 92 EUR, $50 spent gives a spend window at 50%.
- `AppModelCurrencyTests.aBudgetInACurrencyWithoutARateIsUntrackedAndFetchesNothing`: locale `en_US`, budget 100 `EUR`, no rates; snapshot has no `spendCapID` window, has the USD-display note, and the rate fetcher was called 0 times.

- [ ] **Step 2: Run, confirm red on assertions.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test 2>&1 | tail -30`. Expected: green.
- [ ] **Step 5: Commit** `feat(budgets): keep each budget in the currency it was typed in`.

---

### Task 6: The API value section on subscription cards

**Files:**
- Create: `Sources/Tokenjar/Popover/CostSection.swift` (pure text model)
- Create: `Sources/Tokenjar/Popover/CostSectionView.swift` (disclosure row, tiles, bars)
- Modify: `Sources/Tokenjar/Popover/AccountCard.swift:281-296` (insert after the money rows, before the per-use cost line; divider above)
- Modify: `Sources/Tokenjar/App/AppModel.swift` (`func costSection(for account: AccountConfig, snapshot: UsageSnapshot, now: Date) -> CostSection.Content?`; `func isCostSectionExpanded(_ accountID: String) -> Bool`; `func setCostSectionExpanded(_ accountID: String, _ open: Bool)`; key `costSectionExpanded` holding `[String]`)
- Test: `Tests/TokenjarTests/Popover/CostSectionTests.swift`, plus one expanded-state test in `AppModelCurrencyTests`

**Interfaces:**
- Consumes: `CostCurrency` (Task 1), `PricedUsageRow.cost` (Task 4), `AppModel.costCurrency`, `pricedUsage`, `priceTable.planPrice(provider:plan:)`, `DashboardMath.cost`, `DashboardMath.tokens(_:)`, `PlanValue.valueText` formatting rule, `Format.money`, `Format.tokens`.
- Produces:

```swift
enum CostSection {
    struct Tile: Equatable { var title: String; var value: String; var detail: String? }
    struct Day: Equatable { var date: Date; var amount: Double }
    struct Content: Equatable {
        var today: String          // "$20.25", always two decimals
        var trailing: String       // "7.8x plan" or "$780 30d"
        var highlightsTrailing: Bool
        var tiles: [Tile]          // four, in grid order
        var days: [Day]            // 30, oldest first, zero-filled
        var average: Double        // total / 30
        var peak: Double
        var summary: String        // "Avg $26 · Peak $61"
        var footer: [String]
    }
    /// nil unless `snapshot.billing == .subscription` and something in the last 30 local days was priced.
    static func make(snapshot: UsageSnapshot, rows: [PricedUsageRow], planPrice: PlanPrice?, currency: CostCurrency,
                     now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> Content?
}
```

`rows` arrive already converted; `planPrice.monthlyUSD` goes through `currency.amount`.

- [ ] **Step 1: Write the failing tests** (`en_US` locale, `America/New_York` calendar, now 2026-11-02 15:30, the row builder from `MonthCostLineTests`):
- `theRowShowsTodayAndThePlanMultiple`: today 20.25, other days summing to 759.75 (total 780), Max 5x at $100: `today == "$20.25"`, `trailing == "7.8x plan"`, `highlightsTrailing`, tiles `[("Today","$20.25"), ("Last 30 days","$780"), ("30d tokens", <Format.tokens of the fixture>), ("Plan value","7.8x", detail "the $100 plan")]`.
- `withoutAPlanPriceTheRowShowsThe30DayTotal`: `trailing == "$780 30d"`, `!highlightsTrailing`, fourth tile title `"Top model"`, and the footer has no `Top model:` line.
- `nothingTodayReadsZero`: `today == "$0.00"`.
- `onlyTheLast30LocalDaysCount`: a $500 row on 2026-10-03 is excluded, a $1 row on 2026-10-04 included; `days.count == 30`, `days.first?.date` is 2026-10-04.
- `theAverageCountsDaysWithoutUse`: two days of $30 give `average == 2`, `peak == 30`, `summary == "Avg $2 · Peak $30"`.
- `theTopModelIsTheCostliest`: footer first line `"Top model: claude-opus-5-5"` when it has the largest 30-day cost.
- `unpricedModelsAreNoted`: footer line 2 is `"API-equivalent estimate from this Mac's logs, not a bill, some models unpriced."`.
- `inEurosTheFooterNamesTheRateDate`: footer contains `"EUR at the ECB rate of Oct 30."` and `today` starts with `"€"`.
- `awaitingARateSaysSo`: `CostSection.make` with `CostCurrency.resolve("EUR", rates: nil)` gives `"$"` amounts and a footer containing `"Shown in USD until an exchange rate loads."`.
- `onlySubscriptionsGetIt`: billing `.payAsYouGo`, `nil` and `.free` return nil; no priced rows return nil.
- `AppModelCurrencyTests.theExpandedStateIsRememberedPerAccount`: `setCostSectionExpanded("a", true)` persists `["a"]`; a second model on the same defaults reports `a` open and `b` closed.

- [ ] **Step 2: Run, confirm red on assertions.**

- [ ] **Step 3: Implement** `CostSection.make`, the `AppModel` accessors (rows from `pricedUsage(accountIDs: [id], since: startOfDay(now) - 29 days)` passed through `costCurrency.converted`), and the view: a `Button` row with a chevron rotating 90 degrees, `API value` in secondary text, the trailing text in `.green` when highlighted; expanded: a two-column `Grid` of tiles, then a Swift Charts `BarMark` per day (today's bar in `Color.accentColor`, others at reduced opacity), a dashed `RuleMark` at `average`, caption `Daily, 30 days` left and the summary right, replaced by `<Mon d>: <amount>` while hovering (explicit `State` like `BurnUpChart.hoverState`), then the footer lines in `.caption` secondary and an `Open in Dashboard` link calling `model.showDashboard(accountID:)` and `model.closePopover()`. Accessibility: the chart gets one label, `"Daily API value, last 30 days, average <x>, peak <y>"`.

- [ ] **Step 4: Run** `make test 2>&1 | tail -30`. Expected: green. Then `make run` and look at a Claude subscription card collapsed and expanded, in both appearances, and with Currency set to EUR.

- [ ] **Step 5: Commit** `feat(popover): add an API value section to subscription cards`.

---

### Task 7: README, final verification, ship

**Files:**
- Modify: `README.md` (Using it: one paragraph on the API value section; the dashboard paragraph says costs follow the Currency setting; the network sentence in the intro names the ECB rate fetch alongside the other requests)

- [ ] **Step 1:** Update the README text. No screenshots unless the repo's render tooling regenerates them in one command.
- [ ] **Step 2:** `make test 2>&1 | tail -5` shows the full suite passing; `make build` is clean of new warnings.
- [ ] **Step 3:** Dash check on staged lines (own command), commit `docs: describe the API value section and display currency`.
- [ ] **Step 4:** Push `git push origin HEAD:main` from the worktree, `git pull --ff-only` in the main checkout, `make install` there, and confirm `pgrep -fl 'Applications/Tokenjar.app'` shows the new process.
