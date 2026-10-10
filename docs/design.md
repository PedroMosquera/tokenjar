# Headroom design

Headroom is a personal macOS menu bar app that answers one question at a glance: how much room is left on each AI subscription before the next limit, and will the current pace run out before the window resets.

It is an alternative to CodexBar that you build from source, so no third-party binary handles your AI credentials.

## Goals

- Show every limit window each account reports (5-hour, weekly, weekly per model, monthly), as used %, with a reset countdown and a pace marker.
- Show money only where it exists: Claude extra usage and OpenCode Zen's local spend this month. Codex credits are not dollars, so they appear as a note ("Credits: 125.5" or "Credits: unlimited").
- Keep a local history so charts show utilization over time and API-equivalent cost per day, model, harness and project.
- Several accounts per provider (for example a personal plan and a company seat on the same Mac).
- Open each provider's own usage dashboard in one click.
- Per-account settings, alerts, and a secret-free config file that syncs through the dotfiles repo.

## Non-goals

Widgets, iCloud sync, browser cookie import, embedded web views, auto-update feeds, telemetry, plugins, status-page polling, currency conversion, and any provider beyond Claude, Codex, OpenCode and Google Antigravity.

## Hard rules

These are the reason the app exists, so they are enforced in code and covered by tests.

1. **The app never reads, stores, or refreshes an OAuth token.** Claude and Codex usage comes from their own CLIs (`claude -p /usage`, `codex app-server`). Those CLIs own their credentials and their refresh. Refreshing a CLI-owned token from another process rotates a single-use refresh token and logs the CLI out.
2. **The app never touches the Keychain items of other apps.** Its only Keychain use is its own item for API keys the user pastes in Settings.
3. **One outbound host.** The only HTTP request the app makes itself is `GET https://opencode.ai/zen/go/v1/usage`. `HTTPClient` rejects any other host and any redirect, and a test fails if the allowlist grows silently.
4. **No content leaves a local file.** History scanners decode only numeric usage fields, model ids, timestamps, project directory names and the message, request, response or session ids that keep each response counted once. Prompts, outputs, emails and account ids are never stored, logged or displayed.
5. **No mutating calls.** Nothing the app sends can spend a reset credit, send an email, start a model turn, or onboard a project.

## Data sources

| Account type | Live limits | History | Notes |
|---|---|---|---|
| Claude Pro/Max/Team/Enterprise seat | `claude -p /usage --output-format stream-json`, read `usage_report.rate_limits` (`limits[]`, `extra_usage`) | `<configDir>/projects/**/*.jsonl` (no profile dir: `~/.claude/projects` and `~/.config/claude/projects`), assistant `message.usage`, deduped per response | Runs with hooks and MCP off, no session persistence, from a fixed private cwd. 0 tokens, about 1.5 s. Plan label from `oauthAccount` in `.claude.json`. When the CLI is missing or cannot report, shows `cachedUsageUtilization` from `.claude.json` (same account uuid only) with a note; never after a run that turned into a model turn. |
| Claude API key / Bedrock / Vertex | none | same transcripts | Card says "No plan limits for this login" and shows local cost. |
| Codex (ChatGPT plan) | `codex app-server` over stdio: `initialize`, `initialized`, `account/rateLimits/read {excludeResetCreditDetails:true}` | `$CODEX_HOME/sessions/**/rollout-*.jsonl` and `$CODEX_HOME/archived_sessions/**/rollout-*.jsonl` (`token_usage_record` deduped by `response_id`, else positive deltas of `token_count`) | Fallback when the CLI is missing or the app-server fails (except signed out): the last `rate_limits` snapshot from the newest rollouts under `sessions/`, dated when logged, so it shows as stale once older than two refresh intervals. About 0.5 s. |
| OpenCode Go | `GET https://opencode.ai/zen/go/v1/usage`, Bearer key from opencode's `auth.json` (`opencode-go`, then `opencode`) or a pasted key | `opencode.db` read-only: assistant cost and tokens by provider and model | 403 `EntitlementError` means "no active Go subscription", not a bad key. `percent == 0` means the window has not started. |
| OpenCode Zen | none in v1 (balance needs a console web session) | same `opencode.db`, provider `opencode` | Card shows "Spent this month (this Mac)" from the local `opencode.db` cost; the dashboard charts the same rows. |
| Google Antigravity | `agy --version` (must report 1.1.11 or later, else the probe stops), then `agy -p /usage --output-format json` | none | Unverified live: agy is not installed on the build machine. Gemini CLI quota for consumer accounts ended 2026-06-18. |

Codex `account/read` must never be sent with `refreshToken: true`, and the app never uses the codex consume or nudge methods.

## Architecture

SwiftPM package, Swift 6, macOS 14 or later, built with Command Line Tools only (no Xcode).

- `HeadroomCore` (library, no UI): models, fetchers, history scanners, SQLite store, pace math, alert engine, config, pricing, process runner, HTTP client. Everything testable lives here.
- `Headroom` (executable): AppKit `NSStatusItem` + `NSPopover` hosting SwiftUI, plus AppKit-owned windows for Dashboard and Settings. AppKit owns the windows because SwiftUI's settings opener is unreliable for accessory apps on macOS 26, and those windows must toggle the activation policy to come to the front.
- `HeadroomCoreTests` (core) and `HeadroomTests` (app-module logic such as popover verdicts and dashboard math): Swift Testing. `make test` runs both and passes the plugin and framework paths Command Line Tools needs.

Each fetcher conforms to `UsageFetcher` and returns a `UsageSnapshot`: a list of `UsageWindow`s keyed by a stable id, money lines, plan, source and notes. Ids: `session` (5-hour), `weekly`, `weekly:<model>` (Claude per-model weeks) and `monthly` (OpenCode Go). Codex adds `<minutes>m` for other window lengths, `<limitId>:<id>` for extra limits such as `codex_spark:weekly`, and `spend-cap`. Antigravity uses `<pool>:session` and `<pool>:weekly` per quota pool (for example `gemini:weekly`). A Claude limit kind or an Antigravity window Headroom does not recognize keeps its raw name in the id. Windows are keyed by duration or kind, never by position, because Codex Pro has no 5-hour window; only a Codex window with no reported length falls back to `primary` or `secondary`. The ids also key `window_samples` and alert state, so they must not change.

## Information layout

**Menu bar.** The template logo of the account with the least headroom, plus its tightest used %. Monochrome below `menuBar.warnAt` (default 80 %), amber at `warnAt` or when a window is projected to run out (at least 50 % used, at least 10 % elapsed, ETA 15 minutes or more before reset), red at `menuBar.criticalAt` (default 95 %). At 100 % the number becomes the reset countdown (`showResetCountdownWhenFull`, on by default). Half opacity when data is older than twice the refresh interval, and a dot on the logo when the last check failed. Other modes: `bars` (one thin bar per account) and `icon` (logo only, tinted by the worst state).

**Popover (about 360 pt).** Header with a one-line summary and "updated 2m ago". One card per account in config order (order never changes by severity; color carries severity). A card has the colored logo, label, plan pill and a menu (open dashboard, settings for this account). Each window is a bar with a pace tick, its label and "62% · 1h 48m" (used % and time to reset), or "not started". Below the bars, one verdict line for the card's most urgent window: "On pace", "Ahead of pace +N%" or "Under pace -N%" (5-point band), "Runs out ~40m before reset" (same rule as amber), or "Limit reached, resets in ...". Then a small burn-up chart of the week against an even-pace diagonal, and a money row when present. Footer: Dashboard, Settings, Quit.

**Dashboard window.** Sidebar: All, then each account. KPI tiles for API-equivalent cost today, 7 days and this month. Chart of used % over time per window with reset markers and an even-pace guide (24 h, 7 d, 30 d). Stacked daily cost by model, switchable to by harness or by project. Table of top projects.

**Settings window.** General (launch at login, refresh interval, menu bar mode, config file path, import from CodexBar), Accounts (grouped by provider: label, profile dir, credential, show in menu bar, thresholds, dashboard URL, "Sign in" which opens the provider CLI login in Terminal, "Test"), Alerts, About (a short summary of what the app runs, reads, contacts and writes; [privacy.md](privacy.md) is the full list).

## Pace

Linear since window start. `elapsed = window - (resetsAt - now)`, `expected = elapsed / window * 100`, `rate = used / elapsed`, `eta = (100 - used) / rate`. Hidden until 5 % of the window has elapsed, and for windows that have not started or report no length or reset time. The "Runs out" verdict, the amber color and the projected-exhaustion alert all need at least 50 % used, at least 10 % elapsed and `resetsAt - now - eta` of 15 minutes or more.

## Alerts

Projected exhaustion, window reset and source problem alerts each have a toggle under `alerts` (`projectedExhaustion` and `sourceProblems` on by default, `windowResets` off); `alerts.enabled` turns every alert off.

- Threshold crossings, default 80 % and 95 % used, per window; an account can set its own (`alertThresholds`). Only the highest newly crossed threshold fires, and it withdraws the lower one's notification. Dedupe key is account, window, cycle and threshold; the cycle is the reset time rounded to 10 minutes when first seen (the poll time for a window with no reset time). A new cycle starts when the reset time jumps forward by more than half the window or used % drops by 30 points or more; it withdraws the old cycle's notifications and re-arms every alert for that window.
- Projected exhaustion, once per cycle, when the window is at least 50 % and below 100 % used, at least 10 % elapsed, and the ETA is 15 minutes or more before the reset.
- Window reset, only when the previous cycle reached 80 % or more.
- Source problem (CLI missing, signed out, no subscription, credential rejected, unreadable output, unsupported CLI), once per failure episode, withdrawn on the next success. Network errors, timeouts and rate limiting never open an episode. No emails, ids or raw errors in the text.
- Not-started windows never fire a threshold or projection (they can still get a reset alert), and windows whose reset time has passed are skipped.
- An account's first successful poll after launch, and any failure before it, only record a baseline. With alerts off the state is still tracked, so turning them on does not replay old crossings. State persists in `alert-state.json`, so a restart does not repeat alerts.

## Config and sync

`~/.config/headroom/config.json` (`$XDG_CONFIG_HOME/headroom/config.json` when that variable is set in the app's own environment) holds non-secret settings: `version`, `refreshMinutes`, `menuBar` (`mode`, `warnAt`, `criticalAt`, `showResetCountdownWhenFull`), `alerts` (`enabled`, `thresholds`, `projectedExhaustion`, `windowResets`, `sourceProblems`), `cliPaths`, `launchAtLogin`, and `accounts` (`id`, `provider`, `label`, `enabled`, `profileDir`, `credential`, `showInMenuBar`, `refreshMinutes`, `alertThresholds`, `dashboardURL`). It is safe to stow from the dotfiles repo. `config.local.json` next to it holds machine overrides and wins on merge. Accounts whose profile dir or credential file is missing on a machine are hidden there, so one shared file works on every Mac.

The app writes the config only through the symlink's resolved path, so a stow symlink survives a save.

First run (no `config.json`): detect `~/.claude` (labelled Work for a Team or Enterprise `oauthAccount.organizationType` in `~/.claude.json`, else Personal), `~/.codex/auth.json` (existence only), the `opencode-go` and `opencode` entry names in opencode's `auth.json` (Zen is added with `showInMenuBar: false`), and `agy` on the CLI search path. If CodexBar left settings on this Mac, they are applied on top without asking: its enabled providers switch matching accounts on or off, its global warning thresholds become Headroom thresholds (CodexBar stores % remaining, Headroom % used), and its refresh interval and notification toggle carry over. The result is written to `config.json` at once. The same happens whenever the config loads and `config.json` is missing (the Reload button, or the 30-second check after the file is deleted). Settings > General > Import from CodexBar runs the same import later and shows the changes before applying them. Known gap: the design intended first run to offer the CodexBar import, not apply it; see [privacy.md](privacy.md#known-gaps).

## Storage

`~/Library/Application Support/Headroom/headroom.sqlite` (mode 0600, WAL). `schema_version` records which entries of `SQLiteUsageStore.migrations` have run; migrations are append-only.

- `snapshots(account_id, fetched_at, json)`: the latest `UsageSnapshot` per account, shown at launch until the first fetch lands.
- `window_samples(account_id, window_id, ts, used_percent, resets_at)`: one row per fetch per window. A sample identical to the previous one less than 5 minutes later is skipped; rows older than 180 days are pruned on the first fetch after launch and then at most once a day.
- `usage_events(dedupe_key, ts, account_id, harness, model, project, input, output, cache_read, cache_write_5m, cache_write_1h, reasoning, reported_cost)`: one row per model response, upserted by `dedupe_key` keeping the larger value of each count. Raw events rather than rollups, because Claude Code deletes transcripts after 30 days and writes a response on several lines while it streams. Daily totals per local day, account, harness, model and project are computed at query time.
- `scan_state(scanner, account_id, path, value)`: one checkpoint per log file (Claude, Codex) or per opencode table, keyed by file path (`<opencode.db path>#<table>` for opencode). `value` is `<inode>:<offset>` for Claude, a JSON object with inode, offset and running context (last cumulative totals, model, project) for Codex, and the largest `time_updated` for opencode.

Known gap: `scan_state.path` and `usage_events.dedupe_key` hold plain-text paths and ids, while the design calls for SHA-256 digests of both; see [privacy.md](privacy.md#known-gaps).

History is scanned off the main thread at launch and then every 5 minutes. Alert state lives next to the database in `alert-state.json`.

## Pricing

`Resources/pricing.json` maps model ids to USD per million tokens (input, cache write 5m, cache write 1h, cache read, output), with the source URL and date for each entry. Users can override it with `~/.config/headroom/pricing.json`. Costs are labelled "API-equivalent estimate". OpenCode costs come from `opencode.db` and are not repriced.

## Distribution

`make install` builds from source with `swift build -c release`, assembles `Headroom.app` (Info.plist with `LSUIElement`; the committed `Resources/AppIcon.icns`, `Resources/Logos/` and `Resources/pricing.json` copied in), clears extended attributes, signs it ad-hoc with the hardened runtime, copies it to `~/Applications` and launches it. `Scripts/make-icon.sh` rebuilds the `.icns` from `Resources/AppIcon.svg` with `sips` and `iconutil`; run it by hand after editing the SVG. No admin rights, no quarantine, no Gatekeeper prompt. The linker gets `-platform_version macos 14.0 26.0` so the binary is stamped with a real SDK version (SwiftPM's default build system stamps the deployment target, which makes macOS run the app in compatibility mode).

Constraints found while packaging:

- No `.xcassets` or `.xcstrings` (they need Xcode). Logos ship as SVG in `Contents/Resources/Logos` and load with `NSImage(contentsOf:)` through `Bundle.main`, never `Bundle.module`.
- Notifications only work from the installed copy in `~/Applications`, not from a build folder.
- Ad-hoc signatures change on every build, so Keychain grants for the app's own item re-prompt after a rebuild. Only pasted API keys live there.
- On a Mac that only runs approved software, an allowlisting tool blocks new ad-hoc binaries on every build.

A GitHub Actions release zip and a Homebrew cask are deferred. Homebrew 6 removed `--no-quarantine`, so a cask adds a Gatekeeper prompt without adding anything for a single user.

## Phases

1. Claude, Codex and OpenCode Go/Zen fetchers and scanners; the Antigravity fetcher (unverified live); menu bar, popover, dashboard, settings; alerts; config; packaging.
2. Antigravity live check: the fetcher is on `main`, but the `/usage` JSON shape stays unverified until agy can be installed.
3. Optional: OpenCode Zen balance through a console web session, Codex workspace switching, Anthropic and OpenAI admin cost APIs.
