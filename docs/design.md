# Headroom design

Headroom is a personal macOS menu bar app that answers one question at a glance: how much room is left on each AI subscription before the next limit, and will the current pace run out before the window resets.

It is an alternative to CodexBar that you build from source, so no third-party binary handles your AI credentials.

## Goals

- Show every limit window each account reports (5-hour, weekly, weekly per model, monthly), as used %, with a reset countdown and a pace marker.
- Show money only where it exists: Claude extra usage, Codex credits, OpenCode spend.
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
4. **No content leaves a local file.** History scanners decode only numeric usage fields, model ids, timestamps and project directory names. Prompts, outputs, emails and account ids are never stored, logged or displayed.
5. **No mutating calls.** Nothing the app sends can spend a reset credit, send an email, start a model turn, or onboard a project.

## Data sources

| Account type | Live limits | History | Notes |
|---|---|---|---|
| Claude Pro/Max/Team/Enterprise seat | `claude -p /usage --output-format stream-json`, read `usage_report.rate_limits` (`limits[]`, `extra_usage`) | `<configDir>/projects/**/*.jsonl` assistant `message.usage`, deduped per response | Runs with hooks and MCP off, no session persistence, from a fixed private cwd. 0 tokens, about 0.7 s. Plan label from `oauthAccount` in `.claude.json`. |
| Claude API key / Bedrock / Vertex | none | same transcripts | Card says "No plan limits for this login" and shows local cost. |
| Codex (ChatGPT plan) | `codex app-server` over stdio: `initialize`, `initialized`, `account/rateLimits/read {excludeResetCreditDetails:true}` | `$CODEX_HOME/sessions/**/rollout-*.jsonl` (`token_usage_record` deduped by `response_id`, else positive deltas of `token_count`) | Fallback when the CLI is missing: last `rate_limits` snapshot in the newest rollout, marked stale. About 0.5 s. |
| OpenCode Go | `GET https://opencode.ai/zen/go/v1/usage`, Bearer key from opencode's `auth.json` (`opencode-go`, then `opencode`) or a pasted key | `opencode.db` read-only: assistant cost and tokens by provider and model | 403 `EntitlementError` means "no active Go subscription", not a bad key. `percent == 0` means the window has not started. |
| OpenCode Zen | none in v1 (balance needs a console web session) | same `opencode.db`, provider `opencode` | Spend chart only. |
| Google Antigravity | `agy -p /usage --output-format json` (agy 1.1.11 or later) | none | Unverified live: agy is not installed on the build machine. Gemini CLI quota for consumer accounts ended 2026-06-18. |

Codex `account/read` must never be sent with `refreshToken: true`, and the app never uses the codex consume or nudge methods.

## Architecture

SwiftPM package, Swift 6, macOS 14 or later, built with Command Line Tools only (no Xcode).

- `HeadroomCore` (library, no UI): models, fetchers, history scanners, SQLite store, pace math, alert engine, config, pricing, process runner, HTTP client. Everything testable lives here.
- `Headroom` (executable): AppKit `NSStatusItem` + `NSPopover` hosting SwiftUI, plus AppKit-owned windows for Dashboard and Settings. AppKit owns the windows because SwiftUI's settings opener is unreliable for accessory apps on macOS 26, and those windows must toggle the activation policy to come to the front.
- `HeadroomCoreTests`: Swift Testing. `make test` passes the plugin and framework paths Command Line Tools needs.

Each fetcher conforms to `UsageFetcher` and returns a `UsageSnapshot`: a list of `UsageWindow`s keyed by a stable id (`session`, `weekly`, `weekly:<model>`, `monthly`), money lines, plan, source and notes. Windows are keyed by duration or kind, never by position, because Codex Pro has no 5-hour window.

## Information layout

**Menu bar.** The template logo of the account with the least headroom, plus its tightest used %. Monochrome below 80 %, amber at 80 % or when exhaustion is projected before reset, red at 95 %. At 100 % the number becomes the reset countdown. Half opacity when data is stale. Alternative mode: one thin bar per account.

**Popover (about 360 pt).** Header with a one-line summary and "updated 2m ago". One card per account in config order (order never changes by severity; color carries severity). A card has the colored logo, label, plan pill and a menu (open dashboard, settings for this account). Each window is a bar with a pace tick and "62 % · resets 1h48m", followed by a one-line verdict ("On pace", "Runs out about 40m before reset"). Then a small burn-up chart of the week against an even-pace diagonal, and a money row when present. Footer: Dashboard, Settings, Quit.

**Dashboard window.** Sidebar: All, then each account. KPI tiles for API-equivalent cost today, 7 days and this month. Chart of used % over time per window with reset markers and an even-pace guide (24 h, 7 d, 30 d). Stacked daily cost by model, switchable to by harness or by project. Table of top projects.

**Settings window.** General (launch at login, refresh interval, menu bar mode, config file path, import from CodexBar), Accounts (grouped by provider: label, profile dir, credential, show in menu bar, thresholds, dashboard URL, "Sign in" which opens the provider CLI login in Terminal, "Test"), Alerts, About (shows exactly what the app reads and contacts).

## Pace

Linear since window start. `elapsed = window - (resetsAt - now)`, `expected = elapsed / window * 100`, `rate = used / elapsed`, `eta = (100 - used) / rate`. Hidden until 5 % of the window has elapsed. "Runs out before reset" when `eta < resetsAt - now`.

## Alerts

- Threshold crossings, default 80 % and 95 % used, per window. Dedupe key is account, window, reset time and threshold. Re-armed when the reset time moves forward. Only the highest crossed threshold fires.
- Projected exhaustion, once per window cycle, when the window is at least 50 % used, at least 10 % elapsed, and the ETA is 15 minutes or more before the reset.
- Window reset, off by default.
- Source broken (CLI missing, signed out), once per failure episode, cleared on the next success. No emails, ids or raw errors in the text.
- Nothing fires on the first poll after launch; it only sets the baseline.

## Config and sync

`~/.config/headroom/config.json` holds non-secret settings: accounts (id, provider, label, profile dir, credential reference), refresh interval, thresholds, menu bar mode, dashboard overrides. It is safe to stow from the dotfiles repo. `config.local.json` next to it holds machine overrides and wins on merge. Accounts whose profile dir or credential file is missing on a machine are hidden there, so one shared file works on every Mac.

The app writes the config only through the symlink's resolved path, so a stow symlink survives a save.

First run with no config: detect `~/.claude`, `~/.codex/auth.json`, opencode's `auth.json` entries and `agy`, then offer a one-shot import of CodexBar's enabled providers and thresholds (CodexBar stores thresholds as % remaining; Headroom stores % used).

## Storage

`~/Library/Application Support/Headroom/headroom.sqlite`:

- `window_samples(account_id, window_id, ts, used_percent, resets_at)`: one row per fetch per window.
- `usage_daily(day, account_id, harness, model, project, input, output, cache_read, cache_write, reasoning, requests, cost_usd, cost_source)`: rollups, because Claude Code deletes transcripts after 30 days.
- `scan_state(path, inode, size, offset)`: incremental scanning by byte offset.

## Pricing

`Resources/pricing.json` maps model ids to USD per million tokens (input, cache write 5m, cache write 1h, cache read, output), with the source URL and date for each entry. Users can override it with `~/.config/headroom/pricing.json`. Costs are labelled "API-equivalent estimate". OpenCode costs come from `opencode.db` and are not repriced.

## Distribution

`make install` builds from source with `swift build -c release`, assembles `Headroom.app` (Info.plist with `LSUIElement`, `.icns` built with `sips` and `iconutil`), signs it ad-hoc with the hardened runtime, and copies it to `~/Applications`. No admin rights, no quarantine, no Gatekeeper prompt. The linker gets `-platform_version macos 14.0 26.0` so the binary is stamped with a real SDK version (SwiftPM's default build system stamps the deployment target, which makes macOS run the app in compatibility mode).

Constraints found while packaging:

- No `.xcassets` or `.xcstrings` (they need Xcode). Logos ship as SVG in `Contents/Resources` and load with `NSImage(contentsOf:)` through `Bundle.main`, never `Bundle.module`.
- Notifications only work from the installed copy in `~/Applications`, not from a build folder.
- Ad-hoc signatures change on every build, so Keychain grants for the app's own item re-prompt after a rebuild. Only pasted API keys live there.
- On a Mac that only runs approved software, an allowlisting tool blocks new ad-hoc binaries on every build.

A GitHub Actions release zip and a Homebrew cask are deferred. Homebrew 6 removed `--no-quarantine`, so a cask adds a Gatekeeper prompt without adding anything for a single user.

## Phases

1. Claude, Codex and OpenCode Go/Zen fetchers and scanners; menu bar, popover, dashboard, settings; alerts; config; packaging.
2. Antigravity, once agy can be installed and its JSON checked live.
3. Optional: OpenCode Zen balance through a console web session, Codex workspace switching, Anthropic and OpenAI admin cost APIs.
