# Using Tokenjar

How each part of the app behaves. The [README](../README.md) has the short tour; this page has the details.

- [Menu bar](#menu-bar)
- [Popover](#popover)
- [Accounts billed per use](#accounts-billed-per-use)
- [Claude logins without plan limits](#claude-logins-without-plan-limits)
- [API value](#api-value)
- [Currency](#currency)
- [Dashboard](#dashboard)
- [Settings and accounts](#settings-and-accounts)
- [Updates](#updates)
- [Alerts](#alerts)
- [In scripts](#in-scripts)

## Menu bar

The menu bar item shows the used percent of the account with the least room left. To follow one account instead, use Pin to Menu Bar in its card's ⋯ menu. The pin is kept for that Mac only, and the right-click menu can unpin it.

What the item tells you:

- **Color.** It turns amber at 80% and red at 95% by default. It turns sooner when a window that is at least half used is on pace to run out before it resets.
- **A countdown.** When a window is full, the item counts down to its reset instead of showing a percent.
- **A slash across the icon.** Tokenjar can't refresh right now, because the Mac is offline or no provider answered.
- **Faded numbers.** They are out of date.
- **A dot.** Something needs you: a failed check you can fix, or settings that can't be read.

Devin and OpenCode Zen never show up there. An account billed per use counts by its spend limit, like any other limit.

Settings > General changes both color levels. It can also switch the item to one thin bar per account or to the icon alone, and show the amount spent instead of the percent for an account billed per use. That amount is off by default, since anyone near your screen can read it.

Right-click the item, or Control-click it, for Refresh Now, Open Dashboard, Settings and Quit Tokenjar. Quitting from that menu, the popover or Command-Q asks first. Hold Option in the menu to quit without being asked.

## Popover

Clicking the menu bar item opens the popover, with one card per account.

- Each limit window gets a bar with a tick where an even pace would be, and the time until it resets.
- The line under the bars says how you are tracking, such as "Under pace -6%" or "Runs out ~1d 17h before reset". A chart below it shows how the window filled up this cycle against that even pace.
- A failed check says what went wrong and offers the fix.
- When a limit is full, the header also names the account with the most room left, such as "Codex has room: 5-hour 2% used".
- When the Mac is offline or no provider answers, the header says so once, and the cards keep their last numbers with their age.

Command-R refreshes, and a click outside the popover or Escape closes it.

The cards follow the order of the accounts in Settings. Settings > General can group them by provider or put the account with the least room left on top.

An account that can't connect, because its CLI is missing or it has never been signed in, stays out of the popover until it does. One that worked and then signed out keeps its card, since that needs you. Hide and Stop Checking in a card's ⋯ menu turns an account off, and the footer counts what is hidden ("2 hidden"). Clicking that count opens Settings, where Enabled turns an account back on.

## Accounts billed per use

An Enterprise seat billed per use has one limit: the money it may spend this month. Its card shows that spend limit in money, such as "$70 of $200", with the share used and the time until it resets. It resets on the 1st, at midnight UTC. Claude's `/usage` does not report that date, so it comes from the calendar month.

Spending past the limit is allowed on these seats. Past 100%, the card, the header and the menu bar keep counting ("108%", "$240 over") instead of calling it full, and you get one notification when spend first passes the limit.

### Daily budget

Turn on Daily budget on the account's page in Settings to add a Today bar: today's spend against what you can spend per day and still end the month under the limit. Type an amount to use a fixed budget instead.

The bar keeps counting past 100% to show how far over today is, and you get one notification a day when it goes over. Claude reports only the month's total, so Tokenjar works out today from its own checks: the total now, minus the total at its last check before midnight.

## Claude logins without plan limits

API key, gateway (such as LiteLLM), Bedrock, Vertex and Foundry logins have no plan limits. Their card shows this month's and today's spend instead, estimated at list price from the local logs, and where the month is headed at that rate. Tokenjar finds these logins in Claude's `settings.json`, not in your shell.

Set a Monthly budget on the account's page in Settings to turn that spend into a bar. The bar counts in the menu bar and alerts like a spend limit. A budget keeps the currency it was typed in.

## API value

On the card of an account on a plan, a collapsed API value row answers "is the subscription paying for itself?". It shows what today's usage would have cost at API list prices. When the plan has a known list price, it also shows how many times that price the last 30 days came to, such as "7.8x plan". Without a known price, it shows the 30-day total instead, such as "$780 30d".

Click the row to open it. Inside are:

- today, the last 30 days and the tokens used in them,
- the plan value (or the top model, without a known plan price),
- 30 daily bars, with a line at zero and a dotted line at the average day,
- a link to the dashboard for that account.

Click the row again to close it. Each card remembers whether it is open, on this Mac only.

It is an estimate from this Mac's logs, not a bill, so it can read low if you use the account elsewhere. Only Claude, Codex and OpenCode Go accounts have it, since the other providers keep no local logs. Plan prices are US monthly list prices, kept with their source in `Resources/pricing.json`; [configuration.md](configuration.md#plan-prices) shows how to set your own.

## Currency

Costs show in the currency set in Settings > General > Currency, which is kept on this Mac only. Automatic follows the Mac's region and falls back to USD. The choices are USD, EUR, GBP, CHF, JPY, CAD and AUD.

A currency other than USD converts the estimates at the European Central Bank's daily rate. Tokenjar fetches it when you open the popover or dashboard or refresh, and never while the currency is USD. Until a rate has loaded, amounts stay in USD.

Money the providers report, such as a spend limit, is not converted. A budget keeps the currency it was typed in.

## Dashboard

The dashboard (Command-D) has an account sidebar and a page for all accounts together or for one.

**Limits.** It charts each limit over time, with its resets.

**Cost.** It estimates what your usage would have cost at API prices, in the display currency, split by model, harness, project or account. Every cost on the dashboard is an API-equivalent estimate, not a bill.

- A **Projected** tile carries this month's cost to the end of the month at its rate so far, and compares that with last month's total once Tokenjar's history has any cost last month.
- A **Plan value** tile, for an account on a plan with a known list price, compares this month's API-equivalent spend with the plan's monthly price, such as 5.7x the $200 plan.
- **Cache hit rate** is the share of the input your models read from cache, overall and per model.

**Daily chart.** Faint rules mark the average day, counting days without usage as zero, and the peak day. The chart can also stack tokens by type (cache reads, cache writes, input and output, reasoning counted once as output), with each type's share of the range written out, so output stays readable next to cache reads.

**Activity calendar.** It shades each day of the last 12 months by its API-equivalent cost, GitHub style, for one account or all of them.

**What 1% buys.** On an account's page, this lists each weekly or monthly limit cycle with the tokens and API-equivalent cost your local logs recorded per 1% of that limit. A drop from one cycle to the next shows when a limit got tighter. It counts only this Mac's logs: use on other Macs, on the web or in other apps adds to the provider's percent but not to Tokenjar's figures, so they can read high.

**Seats billed per use.** For these, the dashboard charts what was actually spent each hour, day or week, worked out from the spend limit at each of Tokenjar's checks, with the daily budget as a dashed line.

Charts start where Tokenjar's history does, so a new install fills in over the first days. Antigravity and Copilot keep no local logs, so they show limits only.

## Settings and accounts

Each account gets its own page in Settings with its status, the fix when a check fails, and buttons to check it now or sign in from Terminal.

- Adding an account asks for its name first.
- Drag accounts in the list to reorder them.
- The ⋯ button on a row, also on right-click, renames an account, hides it from the menu bar, moves it or removes it.

## Updates

Settings > About shows the version you run and a Check for updates setting. On Manual, the default, Tokenjar asks GitHub only when you click Check Now. On Automatic it asks once a day and sends one notification per new version. Clicking the notification opens About, and its Update Now button starts the update and opens About to show it building. After an update, the new version posts one notification saying it was updated.

When a newer version exists, About links to its release notes on GitHub. Update Now builds the new version in the background, which takes a few minutes, then Tokenjar quits and opens the new version. If the build fails, the copy you are running is not changed, and About says what failed and where the log is. Update Now needs the Command Line Tools and a folder Tokenjar can write to; when it cannot run, About says why. Update in Terminal opens Terminal and runs the update for the copy you are running, which quits and reopens when it is done. If you opened Tokenjar straight from Homebrew's folder instead of `~/Applications`, the new version goes to `~/Applications` and the old one keeps running until you quit it. The commands for Homebrew, curl and make are listed too, each with a Copy button. Tokenjar installs nothing until you click Update Now or Update in Terminal. Check Now needs the installed app.

## Alerts

Alerts are local notifications. By default you get one when:

- a window crosses 80% or 95%,
- the pace says you will run out before the reset,
- a provider resets a window early, so there is room again,
- a source stops working,
- with a daily budget on, a day first goes over it.

Settings > Alerts changes the levels and has a reset alert, which is off by default. Until you click Allow Banners there, alerts go to Notification Center without a banner.

## In scripts

`Tokenjar --status` prints each enabled account's last numbers as one line of JSON: its plan, when it was checked, whether that is out of date, and each limit window with its used percent, reset time, where an even pace would be and whether it runs out before the reset.

It runs no check and writes nothing, so a tmux, SketchyBar or Claude Code status line can call it every few seconds while the app keeps the numbers fresh. `version` changes only when a field changes meaning or goes away.

```sh
alias tokenjar=~/Applications/Tokenjar.app/Contents/MacOS/Tokenjar
tokenjar --status | jq -r '.accounts[] | .label as $label | .tightestWindowID as $t | .windows[] | select(.id == $t) | "\($label) \(.usedPercent | round)%"'
```

That prints one line per account with the number the menu bar uses, such as `Personal 81%`.
