# Subscription cost section and display currency

Date: 2026-11-02. Status: approved in conversation, mockup agreed.

## Why

A subscription card in the popover (Claude Max, Codex Pro, and so on) shows how much of each limit is used, but nothing about money. The two questions a subscriber asks when they open the popover are "how heavy has today been" and "is this plan paying for itself". Tokenjar already prices every request at API list prices from local logs, but that number lives only on the dashboard and on the cards of accounts billed per use. CodexBar shows a cost block on every card; Tokenjar should answer the same questions in its own, more compact way, and in the user's currency.

## Goals

1. Every subscription card whose provider keeps local logs gets a collapsible **API value** section under the burn-up chart.
2. Collapsed, it is one line: today's API-equivalent cost and the 30-day plan value multiple, `$20.25 today · 7.8x plan`.
3. Expanded, it shows a 2x2 grid, a 30-day daily bar chart, the top model, an estimate note and a link to the dashboard.
4. A display currency setting (USD by default, EUR and a few others) converts every API-equivalent estimate in the app, using the ECB's daily reference rate.

## Non-goals

- Changing the dashboard's layout. It already has the depth (Plan value tile, daily chart, activity calendar); this change only makes it honour the currency setting.
- A break-even chart or "paid for itself on day N". Tokenjar does not know when a subscription renews, so a rolling 30 days has no day 1.
- A plan-price-per-day line on the bars. At typical multiples every bar clears it, so it carries no information.
- Converting money the provider reports in its own currency (Claude extra usage, an Enterprise spend limit, OpenCode Zen spend). Those keep the currency the provider sent.
- Fetching exchange rates on a timer or in the background.

## Anti-goals

- The popover getting taller by default. Collapsed is one line; nothing else on the card moves.
- The popover and the dashboard disagreeing about a cost. Both read the same priced rows through the same functions.
- Any cost reading like a bill. Every surface that shows it says it is an API-equivalent estimate.

## The section (as agreed in the mockup)

Mockup: `.superpowers/brainstorm/50372-1793617173/content/cost-section-mix.html` in the main checkout (not committed).

Placement: inside `SnapshotBody` in `Sources/Tokenjar/Popover/AccountCard.swift`, after the burn-up chart and the money rows, separated by a thin divider.

**Collapsed row**, one line, clickable with a chevron:

- Left: `API value` in secondary text.
- Right: `<today> today · <multiple>x plan`, the multiple in the success colour.
- Plan price unknown: `<today> today · <30d total> 30d`.
- Nothing priced today: today reads `$0.00` (the `0` formatted in the display currency), so the line keeps its shape.

**Expanded**, in order:

1. 2x2 grid: Today, Last 30 days, 30d tokens, Plan value (`7.8x the $100 plan`). Without a known plan price the fourth tile is Top model.
2. 30 daily bars ending today. Today's bar uses the accent colour, the others a lighter tint. A faint dashed line marks the average day, counting days without use as zero, as the dashboard does. A caption reads `Daily, 30 days` on the left; on the right `Avg <x> · Peak <y>`, replaced by `<date>: <amount>` while hovering a bar.
3. Footer: `Top model: <id>` (omitted when it is already a tile), then `API-equivalent estimate from this Mac's logs, not a bill.`, then, when the display currency is not USD, `EUR at the ECB rate of <date>.`, then an `Open in Dashboard` link that opens the dashboard on this account.

**Which cards get it**: accounts that are on a plan (not billed per use, which already have `MonthCostLine`) and whose provider keeps local logs: Claude, Codex, OpenCode Go. Antigravity, Copilot and Devin have no logs and never show it. An account with no priced usage in the last 30 days shows no section.

**Expanded state** is remembered per account, on this Mac only, in `UserDefaults`, the same way the menu bar pin is (`AppModel.pinnedAccountKey`). It is not config, because `config.json` can be shared between Macs through dotfiles. Default collapsed.

## Numbers

- Source: `AppModel.pricedUsage(accountIDs: [id], since: <30 days ago at local midnight>)`, so the popover and dashboard share pricing.
- Today: `DashboardMath.cost(rows, since: startOfDay(now))`.
- Last 30 days: the 30 local calendar days ending today, today included.
- 30d tokens: the sum of all token types in those rows, formatted like the dashboard (`3.1B`).
- Plan value: 30-day cost divided by the plan's monthly list price from `PriceTable.planPrice(provider:plan:)`. Formatted with the existing `PlanValue.valueText` rule (`5.7x`, `12x` from 10 up). The popover uses 30 days and the dashboard tile uses the calendar month; the popover labels its figure `30d` in the expanded tile so they are not read as the same number.
- Top model: the model with the largest 30-day cost.
- Unpriced models: if some rows have no list price, the footer adds `, some models unpriced`, matching `MonthCostLine`.

## Display currency

**Setting**: Settings > General, a `Currency` picker: USD, EUR, GBP, CHF, JPY, CAD, AUD, labelled "this Mac only".

**Default (user's decision: no setup step on install)**: the currency of the Mac's region (`Locale.autoupdatingCurrent.currency`, from System Settings > General > Language & Region) when it is in the list, else USD. Reading the region needs no permission, no Location Services and no network. Only an explicit pick is stored; with nothing stored the default follows the region, so a region change moves it, while a stored pick stays put. The picker offers "Automatic (EUR)" as its first item to return to following the region. A Mac in a euro region therefore makes its first ECB request on the first popover open after install, with no setting touched.

The pick is stored in the app's own preferences (`UserDefaults`), not in `config.json`. A non-USD value is what turns the ECB request on, and `docs/design.md` keeps every setting that causes outbound traffic out of the shared config (the precedent is Check provider status pages), so picking EUR on one Mac never makes another Mac that shares the dotfiles start contacting the ECB.

**What converts**: every API-equivalent estimate and every plan list price, everywhere: the new section, `MonthCostLine` on per-use cards, and all dashboard costs, tiles and charts. The multiple does not change, since both sides convert. Provider-reported money does not convert (see non-goals).

**Rates**: the ECB's daily reference rates, `GET https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`. The file gives units of each currency per 1 EUR; USD to X is `rate[X] / rate[USD]`, and EUR is `1 / rate[USD]`.

When it is fetched, modelled on the provider status check so it adds no background traffic:

- Only while the effective currency (the pick, else the region default) is not USD. With USD nothing is ever fetched.
- When the popover opens or the dashboard opens, if the saved rate's ECB date is older than the most recent ECB publication (working days, published around 16:00 CET).
- From the popover's refresh button, Command-R and Refresh Now, under the same staleness rule.
- Right after the user picks a non-USD currency.
- Never on a timer, at launch, at wake or on network return. While macOS reports no usable path, the popover-open and dashboard-open fetches are skipped; explicit refreshes still send it.
- At most one request in flight.
- Cooldown: after an attempt that fails or brings back no newer date than the saved one (TARGET holidays such as 1 Jan, Good Friday, Easter Monday, 1 May, 25 and 26 Dec publish nothing), automatic triggers wait 6 hours before asking again. An explicit refresh waits 2 minutes, the same floor provider status uses. No holiday calendar.

Kept: the last good rates and their ECB date in the app's own preferences on this Mac, so a restart or an offline Mac still converts. A failed fetch keeps the last rates and logs one line.

No rate yet (first run offline, or the fetch failed before any success): amounts stay in USD and the footer says `Shown in USD until an exchange rate loads.` Nothing pretends to be converted.

### Budgets (user's decision: a budget keeps the currency it was typed in)

Applies to accounts billed per use with a Monthly budget (`MonthlyBudget.apply`) or a fixed Daily budget amount. Today both are bare numbers in `config.json` and count as USD.

- Each account gains `budgetCurrency` in `config.json` (an ISO code, default `USD`), covering both its monthly budget and its fixed daily amount. Existing configs decode as USD, so nothing changes for anyone who never picks another currency.
- A new budget typed in Settings is saved in this Mac's display currency. The Settings field shows the budget's own currency next to the amount. Editing the amount keeps that currency; to move a budget to another currency, clear it and type a new one.
- Comparison happens in the budget's currency: the priced USD spend is converted into it before `usedPercent` is computed. The `MoneyLine` the budget creates carries that currency, so the card's bar, the menu bar amount, `DailySpend`, the alerts and the dashboard's spend-limit chart all read it from there, as they already do for a provider's cap.
- The used % can move slightly from day to day as the rate changes. That is accepted.
- Edge case, my call: `budgetCurrency` lives in shared config but rates are fetched only on a Mac whose display currency is not USD. On a Mac with no rate for the budget's currency, the budget bar is not drawn and the card says `Budget is in EUR. Pick EUR in Settings > General to track it on this Mac.` Alerts for that budget do not fire on that Mac. A budget never triggers a fetch by itself.
- Provider-reported spend limits (an Enterprise seat's cap) are untouched: they already carry the provider's currency.

**Privacy and allowlist**: this reverses the "currency conversion" item in `docs/design.md` Non-goals and adds an endpoint under hard rule 3. Following the rule as written:

- Add `www.ecb.europa.eu` `/stats/eurofxref/eurofxref-daily.xml` to `HTTPClient.allowedEndpoints` and update `HTTPClientTests.allowlistIsPinned`.
- Headers: `User-Agent: Tokenjar` and `Accept: application/xml`. No key, cookie or account data. Timeout 10 s, caches ignored, like the status feeds.
- Add a table for the request to `docs/privacy.md` > Requests Tokenjar makes itself, the endpoint to its Contacts list and to the Settings > About summary, and update `docs/design.md` hard rule 3 and Non-goals.

## Constraints

- Swift package built with the Command Line Tools, no Xcode. `@State` is used through explicit `State<...>` storage (see `BurnUpChart.hoverState`) because the macro plugin ships only with Xcode.
- Formatting goes through `Format.money` and its siblings in `Sources/Tokenjar/Shared/Formatting.swift`, extended to take the display currency, rather than a parallel formatter.
- Tests: Swift Testing suites under `Tests/TokenjarTests/Popover` and `Tests/TokenjarCoreTests`. The section's text, the fallback rows, the currency conversion, the ECB parsing and the staleness rule each need tests that can fail.
- The README's Using it section and the popover screenshots describe the card; update the text in the same change. Regenerating screenshots is left to the builder if the repo's render tooling makes it cheap.

## Calls made in the design, not by the user

- Collapsed by default, expanded state per account per Mac.
- Today's bar in the accent colour; average line dashed and faint.
- Currency list beyond USD and EUR (GBP, CHF, JPY, CAD, AUD).
- Currency applies app-wide to estimates, not only the popover.
- An "Automatic" picker item to go back to following the region.
- `currency` is a per-Mac preference, following the provider-status precedent in `docs/design.md`.
- A 6-hour cooldown after a fetch that brings no newer rate, instead of a holiday calendar.
- 30 local calendar days, today included, for every 30d figure.
- One `budgetCurrency` per account for both budgets; editing keeps the currency; a budget in a currency this Mac has no rate for is shown as untracked rather than triggering a fetch.

## Left to the builder

- View decomposition and naming of the new popover view and its text model (follow `MonthCostLine`'s split of pure text logic from the view).
- XML parsing approach for the ECB file (`XMLParser` is enough).
- How the dashboard threads the currency through its existing money helpers.
- Accessibility labels for the bars, matching what `BurnUpChart` already does.
