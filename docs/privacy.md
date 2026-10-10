# What Headroom reads, runs, sends and stores

Headroom shows subscription usage limits without ever handling an OAuth token. Claude and Codex numbers come from their own CLIs, which keep their own credentials. The app's only network request of its own is one GET to `opencode.ai`. History comes from local log files. Headroom keeps counts, model ids, timestamps and project folder names, plus what it needs to count each response once: the paths of the log files it has read and the message, request, response or session ids found in them (see [Known gaps](#known-gaps)).

This page is the contract, and every statement on it describes the code on `main`. A change that alters what Headroom reads, runs, sends or stores updates this page in the same commit.

## Known gaps

Places where the code on `main` does less than the design promises. Each one is a known divergence, not a decision, and stays listed here until the code or the design changes.

- **History paths and ids are stored in plain text.** The design calls for SHA-256 digests of the file paths in `scan_state` and of the dedupe keys in `usage_events`. Nothing is hashed today: `headroom.sqlite` keeps full log file paths, which include your home folder name and, for Claude, the encoded project path and session uuid, and the message, request, response and session ids listed under [What it stores](#what-it-stores). They stay in that file on this Mac and are never displayed, logged or sent.
- **A Claude or Codex session run in your home folder is recorded under that folder's name.** The project is the last path component of the session's working directory, so a session started in the home folder itself is stored under your home folder name, usually your macOS account name, and shows under that name in the dashboard's project views. opencode history records that case as `~`, which is what the design asks of all three.
- **The CodexBar import runs without asking when `config.json` is missing.** The design says first run offers the import. Today, whenever Headroom loads its config and finds no `config.json` (first launch, the Reload button in Settings > General, or within about 30 seconds of the file being deleted while Headroom runs), it reads CodexBar's settings, applies them on top of the discovered accounts and writes `config.json`, with no prompt. Import from CodexBar in Settings > General shows the changes and asks before applying them.

## Network

### The one request Headroom makes itself

| | |
|---|---|
| Request | `GET https://opencode.ai/zen/go/v1/usage` |
| When | Each refresh of an OpenCode Go account: at launch; when its interval has passed (`refreshMinutes`, default 10, overridable per account, at least 30 in Low Power Mode; checked every 30 seconds); 8 seconds after wake; when the popover opens 2 minutes or more after the last refresh; from the popover's Refresh button, a card's Retry or Settings' Test; when you change the account in Settings; and for every account when an edit made outside the app changes any account in config. After a 429 the scheduled refresh waits for `Retry-After` or twice the interval, whichever is longer; the other triggers do not wait. Timeout 20 s. |
| Headers | `Authorization: Bearer <key>`, `User-Agent: Headroom`, `Accept: application/json` |
| Key source | The account's `credential` in config: a named entry in a JSON file, or a key you pasted in Settings and Headroom stored in its own Keychain item. Without one, the `opencode-go` entry in opencode's `auth.json`, then the `opencode` entry. |

Enforced by `HTTPClient`:

- The host allowlist is exactly `opencode.ai`. Any other host, including subdomains and look-alikes such as `opencode.ai.evil.example`, is rejected before a request is built.
- HTTPS only, GET only. The transport refuses any other method.
- Redirects are never followed, so the `Authorization` header cannot be carried to another host.
- The URL session is ephemeral: no cookie storage, no cookies sent, no URL cache.
- `HTTPClientTests.allowlistIsExactlyOpenCode` fails if the allowlist changes. Adding a host is a privacy decision that needs this page updated in the same change.

### Traffic that is not Headroom's

- The CLIs Headroom runs (below) talk to their own providers with their own credentials, the same as when you run them in a terminal. Headroom never sees those credentials and does not proxy that traffic.
- Clicking "Open Usage Dashboard", "Open Status Page" or a link in Settings opens the URL in your default browser. Headroom does not fetch it. The dashboard and status defaults are `https://claude.ai/settings/usage`, `https://chatgpt.com/codex/settings/usage`, `https://opencode.ai/auth`, `https://antigravity.google/docs/plans`, `https://status.claude.com` and `https://status.openai.com`. An account's `dashboardURL` overrides its dashboard link, and is used only when it is an http or https URL. The "Install agy" link in an Antigravity account's Settings opens `https://antigravity.google`.

## Commands it runs

Every CLI runs:

- from a fixed, empty working directory, `~/Library/Application Support/Headroom/probe`, so probes never show up as projects in a CLI's history;
- without a login shell, so your shell rc files are never executed. The binary is found in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` or `/usr/bin`, or at the path you set in `cliPaths`;
- with a minimal environment: `HOME`, plus `USER`, `LOGNAME`, `LANG`, `TMPDIR` and `SHELL` when they are set, a fixed `PATH` and `NO_COLOR=1`, plus `CLAUDE_CONFIG_DIR` or `CODEX_HOME` when the account sets a profile directory.

### Claude

```
claude -p /usage --output-format stream-json --verbose --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}'
```

| Part | Why |
|---|---|
| `-p /usage` | Runs the local `/usage` command and exits. It reports plan limits and starts no model turn (0 tokens). |
| `--output-format stream-json --verbose` | Machine-readable output; `stream-json` requires `--verbose` in print mode. Headroom reads only `usage_report.rate_limits` (`limits[]`, `extra_usage`); from the init line, `apiKeySource`, which names where an API key would come from (never the key), to tell an API-key login from being signed out; and from the final `result` line, `local_command`, `is_error`, `num_turns` and `total_cost_usd`, to confirm `/usage` ran locally. If that line shows a model turn or a cost, the account reports "claude CLI ran /usage as a prompt, which spends tokens" and the cached fallback is not used. |
| `--no-session-persistence` | The probe is not saved as a session, so it never appears in `claude --resume` or in the transcripts Headroom scans. |
| `--strict-mcp-config` | With no `--mcp-config` given, no MCP servers start. |
| `--settings '{"disableAllHooks":true}'` | Your hooks do not run for the probe. |

The exact argument list lives in `ClaudeUsageFetcher`; this table must match it.

### Codex

```
codex -s read-only -a never app-server
```

`-s read-only` keeps the sandbox read-only and `-a never` means it never asks for approval. Headroom writes JSON-RPC-style requests to stdin, one JSON object per line (codex's app-server protocol has no `jsonrpc` field), and sends exactly three messages:

1. `initialize`, with `clientInfo` naming Headroom and its version
2. `initialized` (notification)
3. `account/rateLimits/read` with `{"excludeResetCreditDetails": true}`

It never sends `account/read` with `refreshToken: true`, never uses Codex's consume or nudge methods, and sends nothing else.

### Antigravity

```
agy --version
agy -p /usage --output-format json
```

`/usage` is sent only after `agy --version` reports 1.1.11 or later. Older versions have no non-interactive slash commands and could pass `/usage` to the model as a prompt, which spends quota, so a failed or unreadable version check also stops the probe. The JSON shape of `/usage` is not yet verified against a live install.

### OpenCode

No CLI is run. See the network request above and the files below.

### Sign in

"Sign In in Terminal" on an account's Settings page writes that account's login command to a script, `$TMPDIR/headroom-sign-in-<account id>.command` (mode 0700), and opens it in Terminal. Nothing is written or run until you click it, and the script deletes itself when Terminal runs it. The commands are `claude auth login`, `codex login` and `opencode auth login`, using the CLI's full path when Headroom finds it, and prefixed with `CLAUDE_CONFIG_DIR=<dir>` or `CODEX_HOME=<dir>` when the account sets a profile folder. "Copy Command" copies the same line instead. Antigravity has no login command Headroom can hand off to; its Settings page links to `https://antigravity.google` to install agy. Headroom does not see what you type in Terminal.

## Files it reads

| Path | What is read |
|---|---|
| `~/.config/headroom/config.json` and `~/.config/headroom/config.local.json` (`$XDG_CONFIG_HOME/headroom/` instead when that variable is set in Headroom's own environment) | The whole file. Both are secret-free by design. Read at launch and again when either file's modification date changes (checked every 30 seconds). |
| `pricing.json` in the same folder | Optional per-model price overrides. |
| `<claude profile>/projects/**/*.jsonl`, subagent transcripts included. For an account without a profile dir, both `~/.claude/projects` and `~/.config/claude/projects` are read | Only lines that contain `"usage"` are decoded, and only assistant entries count: the token counts in `message.usage`, `message.model`, `timestamp`, the last path component of `cwd`, and `message.id` plus `requestId` (or `sessionId` when a line has no request id) to count each response once. Never `message.content`. Each file is read from where the last scan stopped. |
| `~/.claude.json`, or `.claude.json` inside a custom profile dir; `<claude profile>/.config.json` instead when that older file exists | From `oauthAccount`: the organization type, seat tier and rate-limit tier fields that name the plan (Pro, Max 5x, Team and so on); first-run discovery reads the organization type from `~/.claude.json` to label an account Work or Personal. From `cachedUsageUtilization`: the limits Claude Code itself last fetched, shown only when the CLI cannot report. `oauthAccount.accountUuid` is compared in memory with the cache's account uuid so another login's cache is never shown; neither uuid is stored or logged. Only these fields are decoded into Headroom's types; email, name and organization name fields never are. |
| `<claude profile>/settings.json` | Only the `env` keys `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_FOUNDRY`, to tell a cloud-provider login from being signed out. |
| `<codex home>/sessions/**/rollout-*.jsonl` and `<codex home>/archived_sessions/**/rollout-*.jsonl` (default `~/.codex`) | `token_usage_record` token counts, deduplicated by `response_id` (by file name and byte offset when a record has none); otherwise positive deltas of the cumulative `token_count` totals; the model id from `turn_context`; timestamps; the last path component of the session's working directory. If the codex CLI is missing or the app-server fails for any reason other than being signed out, the last `rate_limits` snapshot from the most recently modified rollouts under `sessions/` (up to 8 files are tried), dated when codex logged it, with windows that have since reset dropped. |
| `~/.codex/auth.json` | Existence only, for first-run discovery. The file is never opened. |
| opencode's `auth.json` in its data folder (the account's `profileDir`, else `$XDG_DATA_HOME/opencode`, else `~/.local/share/opencode`), or the file named in the account's `credential` | The file is read and parsed whole, but only the `opencode-go` entry, then `opencode` (or the entry named in the account's `credential`), is decoded: the `key` of an `api` entry, or the `token` of a `wellknown` entry. That value is sent only to `opencode.ai`. Other entries, OAuth ones included, are never decoded into Headroom's types, stored or logged. First-run discovery decodes only the entry names. |
| opencode's `opencode.db`, in the same data folder | Opened read-only. From the `message` table (opencode 1.x) and the `session_message` table (opencode 2.x), assistant rows of the account's provider (`opencode-go` for Go, `opencode` for Zen): row id, cost, token counts, model id, created and updated timestamps, and the last path component of the working directory (`path.cwd` in the message data, or `session.directory` for `session_message` rows; `~` for the home folder itself). Only those JSON fields, plus the role and provider id used to filter, are extracted; message text and the `part` table are never queried. The OpenCode Zen account sums this month's cost from the same rows and makes no network request. |
| CodexBar's `config.json` (`$XDG_CONFIG_HOME/codexbar`, `~/.config/codexbar` or `~/.codexbar`) and its preferences domain `com.steipete.codexbar` | Read whenever Headroom finds no `config.json` of its own (see [Known gaps](#known-gaps)) and when you click Import from CodexBar in Settings > General: `providers[].id` and `providers[].enabled` from the config, and only the preference keys `refreshFrequency`, `quotaWarningThresholds` and `quotaWarningNotificationsEnabled`. The config file is read whole, but its API key and cookie fields are never decoded; the preferences domain is never enumerated. |
| Headroom's own Keychain item, service `com.pedromosquera.headroom.apikeys` | API keys you pasted in Settings. Nothing else. |

Antigravity has no history source; only the `agy` command above.

## What it stores

| Where | What |
|---|---|
| `~/Library/Application Support/Headroom/headroom.sqlite` (mode 0600) | `snapshots`: the latest snapshot per account (plan label, each limit window's id, label, used %, length and reset time, money lines, source label and plain-language notes), shown at launch until the first refresh lands. |
| same | `window_samples(account_id, window_id, ts, used_percent, resets_at)`: one row per fetch per window, for the charts. A sample identical to the previous one less than 5 minutes later is skipped, and samples older than 180 days are deleted on the first fetch after launch and then at most once a day. |
| same | `usage_events`, one row per response: timestamp, account slug, harness, model id, project folder name, input, output, cache read, cache write (5-minute and 1-hour) and reasoning tokens, cost reported by the harness, and a plain-text dedupe key: `claude:<message.id>:<requestId>` (or `<sessionId>` when the line has no request id), `codex:<response_id>`, `codex:<rollout file name>:<cumulative total>` or `codex:<rollout file name>:@<byte offset>` when codex logged no response id, and `opencode:<message id>`. Rollout file names carry the session's start time and uuid. Rows outlive the logs they came from, because Claude Code deletes transcripts after 30 days; daily totals are computed from them. |
| same | `scan_state(scanner, account_id, path, value)`, one row per log file or opencode table read, so scans are incremental. `scanner` is `claude-transcripts`, `codex-rollouts` or `opencode-db:<provider id>`. `path` is the full file path (for opencode, `<path to opencode.db>#message` or `#session_message`), which includes your home folder name and, for Claude, the encoded project path and session uuid. `value` is `<inode>:<byte offset>` for Claude, a JSON object with the inode, byte offset, last cumulative token totals, current model id and project folder name for Codex, and the largest `time_updated` read for opencode. |
| same | `schema_version`: which schema migrations have run. |
| `~/Library/Application Support/Headroom/alert-state.json` | Alert dedupe state, rewritten after every fetch: keys of the form `<account slug>\|<window id>\|<cycle>\|<threshold, projected or reset>`, the slugs of accounts with an open source problem, and per `<account slug>\|<window id>` the last reset time, last used % and cycle id. No provider account ids, emails or error text. |
| `~/Library/Application Support/Headroom/probe/` | An empty directory, used as the working directory for CLI probes. |
| `$TMPDIR/headroom-sign-in-<account id>.command` (mode 0700) | Written only when you click Sign In in Terminal: that account's login command, including the expanded profile folder path when the account sets one. The script deletes itself when Terminal runs it. |
| `~/.config/headroom/config.json` | Your settings, written when you change them in Settings and when Headroom finds no `config.json` (discovered accounts plus any CodexBar import, see [Known gaps](#known-gaps)), through the stow symlink if there is one. `config.local.json` is never written. |
| Headroom's own Keychain item | API keys you paste in Settings. |

`account_id` everywhere is the slug you chose in config (for example `claude-work`), not a provider account id.

Never stored, logged or displayed: prompts, outputs, message or file contents, emails, names or organization names from your provider accounts, provider account ids, OAuth tokens, API keys (outside the Keychain item), raw error bodies. `headroom.sqlite` does keep log file paths and per-response message, request, response and session ids (see `usage_events`, `scan_state` and [Known gaps](#known-gaps)); they stay on this Mac and are never displayed or logged.

Notifications are local macOS notifications. Their text carries no emails, ids or raw errors.

## What it never does

- **Read, store, print or refresh an OAuth token**, or call any OAuth token or refresh endpoint. Refreshing a CLI-owned token from another process rotates a single-use refresh token and signs the CLI out, so Claude and Codex credentials stay entirely with their CLIs.
- **Read another app's Keychain items.** The app's Keychain wrapper adds Headroom's own service name to every query, and that is the only service the app uses.
- **Send anything that changes account state**: no POST, nothing that spends a reset credit or other credits, sends an email, starts a model turn or onboards a project.
- **Telemetry, analytics, crash reporting, update checks or auto-update feeds.** There are none.
- **Cookies**: no browser cookie import, and its own HTTP session neither stores nor sends cookies.
- **Status-page polling or embedded web views.**

## Checking it yourself

- The allowlist is `HTTPClient.allowedHosts` in `Sources/HeadroomCore/Core/HTTPClient.swift`; `make test` fails if it changes.
- While Headroom runs, `nettop -p Headroom` or `lsof -i -a -c Headroom` lists its own connections. Expect `opencode.ai` only, and only if you have an OpenCode Go account.
- Settings > About shows a short summary of this page.
