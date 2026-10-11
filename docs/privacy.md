# What Tokenjar reads, runs, sends and stores

Tokenjar shows subscription usage limits without ever handling an OAuth token. Claude, Codex and Antigravity numbers come from their own CLIs, which keep their own credentials. The app's only network request of its own is one GET to one path on `opencode.ai`. History comes from local log files. Tokenjar keeps counts, model ids, timestamps and project folder names; the log paths and response ids it needs to count each response once are stored only as SHA-256 digests.

This page is the contract, and every statement on it describes the code on `main`. A change that alters what Tokenjar reads, runs, sends or stores updates this page in the same commit.

In the tables below, "account id" is the slug you chose in config (for example `claude-work`), never a provider account id.

## Network

### The one request Tokenjar makes itself

| | |
|---|---|
| Request | `GET https://opencode.ai/zen/go/v1/usage` |
| When | Each check of an OpenCode Go account: at launch; on the 30-second tick once its interval has passed (`refreshMinutes` of the account, else the global one, default 10, at least 30 in Low Power Mode); 8 seconds after wake; when the popover opens 2 minutes or more after the last refresh; from the popover's refresh button; from the card's Retry or Settings' Test; when the account changes in Settings or in the config file; and again at once if the account was edited while its request ran. After a 429, only Retry and Test send it again before the longer of `Retry-After` and twice the interval has passed, unless the account was edited while a request for it ran: that result is dropped, the backoff with it, and the request is sent again at once. |
| Headers | Tokenjar sets `Authorization: Bearer <key>`, `User-Agent: Tokenjar` and `Accept: application/json`. URLSession adds its standard headers: `Host`, `Connection`, `Accept-Encoding`, `Accept-Language` (your preferred languages) and `Cache-Control: no-cache` from the cache policy. |
| Timeout | 20 s. Local and remote caches are ignored. |
| Key source | The account's `credential` in config: a named entry in a JSON file (`{"file": {"path": ..., "key": ...}}`), or a key you pasted in Settings and Tokenjar stored in its own Keychain item (`{"keychain": {"account": ...}}`). Without one, the `opencode-go` entry, then the `opencode` entry, of opencode's `auth.json`. Only the `key` of an `api` entry or the `token` of a `wellknown` entry is used. |

### How HTTPClient enforces it

- `HTTPClient.allowedEndpoints` is exactly `["opencode.ai": ["/zen/go/v1/usage"]]`, and `HTTPClient.allowedHosts` is derived from it.
- `HTTPClient.validate` runs before a request is built. It accepts only `https`, only the host `opencode.ai` (subdomains and look-alikes such as `opencode.ai.evil.example` are rejected), only the path `/zen/go/v1/usage`, only the default port (none, or 443), and no user info, query or fragment. Any other URL on that host is rejected too.
- `URLSessionTransport.send` refuses every method but GET and validates the URL again, so code that uses the transport directly cannot reach another host or path either.
- Redirects are never followed, so the `Authorization` header cannot be carried anywhere else.
- The URL session is ephemeral: no cookie storage, no cookies sent, no URL cache.
- Tests: `HTTPClientTests.allowlistIsExactlyOpenCode` pins `allowedHosts` and `allowedEndpoints`. `onlyTheGoUsageEndpointIsAllowedOnTheHost`, `getRejectsDisallowedURLsBeforeTheTransport`, `transportRejectsDisallowedHostsWithoutConnecting`, `transportRefusesAnythingButGET` and `transportNeverFollowsRedirects` cover URL validation, the transport's second check, the GET rule and the redirect refusal. No test pins the ephemeral, cookie-free session. Adding an endpoint is a privacy decision that needs this page updated in the same change.

### Traffic that is not Tokenjar's

- The CLIs Tokenjar runs (below) talk to their own providers with their own credentials, the same as when you run them in a terminal. Tokenjar never sees those credentials and does not proxy that traffic.
- "Open Usage Page" (card title, card menu, dashboard header, an account's Settings page), "Open Status Page" (card menu, Claude and Codex only), the provider links in Settings > About and "Install agy" open a URL in your default browser. Tokenjar does not fetch it. The usage page defaults are `https://claude.ai/settings/usage`, `https://chatgpt.com/settings/usage`, `https://opencode.ai/auth` and `https://antigravity.google/docs/plans`; the status pages are `https://status.claude.com` and `https://status.openai.com`; "Install agy" is `https://antigravity.google`. An account's `dashboardURL` replaces its usage page, and is used only when it is an http or https URL.
- "Open Notification Settings" in Settings > Alerts opens System Settings at Tokenjar's notification page.

## Commands it runs

Every CLI runs:

- from a fixed, empty working directory, `~/Library/Application Support/Tokenjar/probe` (mode 0700), so probes never show up as projects in a CLI's history;
- directly, never through a shell, so your shell rc files are never executed. The binary is the path set in `cliPaths` for that CLI when there is one (only that path is tried), else the first executable found in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` or `/usr/bin`;
- with a minimal environment: `HOME` (your home folder), plus `USER`, `LOGNAME`, `LANG`, `TMPDIR` and `SHELL` when they are set, a fixed `PATH` (the folders above plus `/bin`, `/usr/sbin`, `/sbin`) and `NO_COLOR=1`, plus `CLAUDE_CONFIG_DIR` or `CODEX_HOME` when the account sets a profile folder. Nothing else passes through, so API keys or config folders in Tokenjar's own environment never reach a CLI;
- with a timeout, after which it gets SIGTERM and, 2 seconds later, SIGKILL.

### Claude

```
claude -p /usage --output-format stream-json --verbose --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}'
```

| Part | Why |
|---|---|
| `-p /usage` | Runs the local `/usage` command and exits. It reports plan limits and is meant to start no model turn (0 tokens). |
| `--output-format stream-json --verbose` | Machine-readable output; `stream-json` requires `--verbose` in print mode. |
| `--no-session-persistence` | The probe is not saved as a session, so it never appears in `claude --resume` or in the transcripts Tokenjar scans. |
| `--strict-mcp-config` | With no `--mcp-config` given, no MCP servers start. |
| `--settings '{"disableAllHooks":true}'` | Your hooks do not run for the probe. |

Stdin is closed at once, the timeout is 45 seconds, and at most 2 MiB each of stdout and stderr is kept (stderr is never read). From the output Tokenjar reads only: each line's `type`; from the init line, `apiKeySource`, which names where an API key would come from (never the key), to tell an API-key login from being signed out; from an assistant line, `usage_report.rate_limits` (`limits[]` with `kind`, `percent`, `resets_at` and the scope's `display_name`; `extra_usage` with `is_enabled`, `monthly_limit`, `used_credits`, `currency`, `decimal_places`) and whether `local_command_run` is present; from a `result` line, `local_command`, `is_error`, `num_turns` and `total_cost_usd`.

The read stops at the first assistant line with `usage_report` (the answer) or the first result line that shows a turn or a cost (the model). If neither appears, an assistant line that carried neither `usage_report` nor `local_command_run` means the run went to the model. The account then reports "claude CLI ran /usage as a prompt, which spends tokens. Checks for this account are paused until claude updates or you click Try once more.", the cached fallback is not used, and the account is latched (see `probe-latch.json` below). The exact argument list lives in `ClaudeUsageFetcher.arguments`; this section must match it.

### Codex

```
codex -s read-only -a never app-server
```

`-s read-only` keeps the sandbox read-only and `-a never` means it never asks for approval. Tokenjar writes at most three newline-terminated JSON lines to stdin and nothing else (codex's app-server protocol has no `jsonrpc` field). Key order inside each object can vary.

```
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tokenjar","version":"<app version>"}}}
{"method":"initialized"}
{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}
```

`<app version>` is the app's `CFBundleShortVersionString`, or `dev` outside the app bundle. The second and third lines are sent only after the answer to `initialize` arrives. Tokenjar reads stdout line by line, ignores notifications, server requests and other ids, discards stderr, and ends the process once it has the answer to request 2, or after 20 seconds. Each stdout line is parsed whole to find the answer by its id. From the answer to request 2, Tokenjar decodes only `rateLimits` and `rateLimitsByLimitId`: `limitId`, `limitName`, `primary` and `secondary` (`usedPercent`, `windowDurationMins` or `windowMinutes`, `resetsAt`), `credits` (`hasCredits`, `unlimited`, `balance`), `individualLimit` (limit, used, remaining, percentages and reset time) and `planType`. `accountId` is never decoded or kept. An error's message is matched only to classify the failure and is never shown or stored.

It never sends `account/read` with `refreshToken: true`, never uses Codex's consume or nudge methods, and sends nothing else.

### Antigravity

```
agy --version
agy -p /usage --output-format json
```

`/usage` is sent only after `agy --version` (15 s timeout, up to 64 KiB of stdout and of stderr kept) reports 1.1.11 or later. Older versions have no non-interactive slash commands and could pass `/usage` to the model as a prompt, which spends quota, so a failed or unreadable version check also stops the probe. The `/usage` run has a 100 s timeout and keeps up to 1 MiB of each stream. Neither run gets a profile variable.

From the JSON Tokenjar reads `groups` (at any depth): each group's name, and each bucket's window name, remaining fraction, reset time and `disabled` flag. Only when there are no groups does it look at an `error` field and `data.message` (both at any depth) and at a top-level `response`, `stats` or `num_turns`. If a run that exited 0 prints a model reply (one of those three keys, with no groups and no error), Tokenjar reports "agy ran /usage as a prompt, which spends quota. Checks for this account are paused until agy updates or you click Try once more." and latches the account. Without groups, any non-empty `data.message` reads as no limits for the account; other output is a broken source. An `error` field, and the output of a failed run, are matched only for sign-in wording; they are never shown or stored. The JSON shape of `/usage` is not yet verified against a live install.

### OpenCode

No CLI is run. See the network request above and the files below.

### Sign in

"Sign In in Terminal..." on an account's Settings page writes that account's login command to a script, `$TMPDIR/tokenjar-sign-in-<account id>.command` (mode 0700, the file name keeps only letters, digits, `-` and `_` of the id), and opens it in Terminal. Nothing is written or run until you click it. The script deletes itself first, prints "Tokenjar: sign in to <provider> (<label>)", then runs the command. The commands are `claude auth login`, `codex login` and `opencode auth login`, using the CLI's full path when Tokenjar finds it, and prefixed with `CLAUDE_CONFIG_DIR=<dir>` or `CODEX_HOME=<dir>` (the expanded path) when the account sets a profile folder. "Copy Command" copies the same line to the clipboard instead. Antigravity has no login command Tokenjar can hand off to; its Settings page links to `https://antigravity.google` to install agy. Tokenjar does not see what you type in Terminal.

## Files it reads

| Path | What is read, and when |
|---|---|
| `~/.config/tokenjar/config.json` and `~/.config/tokenjar/config.local.json` (`$XDG_CONFIG_HOME/tokenjar/` instead when that variable is set in Tokenjar's own environment) | The whole file. Both are secret-free by design. Read at launch, when either file's modification date changes (checked every 30 seconds, through a symlink), before each Settings edit, and on Reload. |
| `pricing.json` in the same folder | Optional per-model price overrides, read at launch. |
| `<claude profile>/projects/**/*.jsonl`, subagent transcripts included. For an account without a profile dir, both `~/.claude/projects` and `~/.config/claude/projects` | Each file from where the last scan stopped (from the start when its inode changed or it shrank). Lines that do not contain `"usage"` are skipped before decoding, and only assistant entries count: `message.usage` token counts (input, output, cache read, cache creation and its 5-minute and 1-hour split), `message.model`, `timestamp`, the last path component of `cwd` (`~` for the home folder itself, and the repo folder for a Claude Code worktree or a hidden tool folder inside a repo), and `message.id` plus `requestId` (or `sessionId` when a line has no request id) to count each response once. Never `message.content`. |
| `~/.claude.json`, or `.claude.json` inside a custom profile dir; `<claude profile>/.config.json` instead when that older file exists | On each Claude check. From `oauthAccount`: the organization type, seat tier and rate-limit tier fields that name the plan (Pro, Max 5x, Team and so on). From `cachedUsageUtilization`: the limits Claude Code itself last fetched, shown only when the CLI cannot report. `oauthAccount.accountUuid` is compared in memory with the cache's account uuid so another login's cache is never shown; neither uuid is stored or logged. Email, name and organization name fields are never decoded. |
| `<claude profile>/settings.json` | Only the `env` keys `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_FOUNDRY`, to tell a cloud-provider login from being signed out. |
| `<codex home>/sessions/**/rollout-*.jsonl` and `<codex home>/archived_sessions/**/rollout-*.jsonl` (default `~/.codex`) | Each file from where the last scan stopped. Only lines that mention `turn_context`, `session_meta`, `token_usage_record` or `token_count` are decoded, and only these fields: the line's `timestamp` and `type`, and from its payload `type`, `model`, `cwd` (last path component, `~` for the home folder itself, the repo folder for a Claude Code worktree or a hidden tool folder inside a repo), `response_id`, `usage`, `info.total_token_usage` (input, cached input, cache write input, output, reasoning output and total tokens; cache writes are stored as 5-minute cache-write tokens), `info.model_context_window` and `rate_limits`, which the same decoder reads for the fallback below and the scanner ignores. Counts come from `token_usage_record` deduplicated by `response_id` (by file name and byte offset when a record has none), else from positive deltas of the cumulative `token_count` totals. |
| same rollouts, fallback only | If the codex CLI is missing or the app-server fails for any reason other than being signed out or having no plan limits: the last `rate_limits` of a `token_count` event in the most recently modified rollouts under `sessions/` (up to 8 files are read, newest first), dated when codex logged it, with windows that have since reset dropped. |
| opencode's `auth.json` in its data folder (the account's `profileDir`, else `$XDG_DATA_HOME/opencode` when that variable holds an absolute path, else `~/.local/share/opencode`), or the file named in the account's `credential` | On each OpenCode Go check. The file is read and parsed whole, but only the `opencode-go` entry, then `opencode` (or the entry named in the account's `credential`), is decoded, and only its `type`, `key` and `token` fields. Tokenjar uses the `key` of an `api` entry or the `token` of a `wellknown` entry. That value is sent only to `opencode.ai`. Other entries, OAuth ones included, are never decoded, stored or logged. |
| opencode's `opencode.db`, in the same data folder | Opened read-only. If that open fails and no `-wal` file exists, it is opened as an immutable file instead. From the `message` table (opencode 1.x) and the `session_message` table (opencode 2.x), assistant rows of the account's provider (`opencode-go` for Go, `opencode` for Zen): row id, cost, token counts, model id, created and updated timestamps, and the last path component of the working directory (`path.cwd` in the message data, or `session.directory` for `session_message` rows; `~` for the home folder itself, the repo folder for a Claude Code worktree or a hidden tool folder inside a repo). Only those JSON fields, plus the role, provider id and session id used to filter, are extracted; message text and the `part` table are never queried. The OpenCode Zen account sums this month's cost from the same rows on each check. |
| Account discovery: `~/.claude`, `~/.claude.json`, `~/.codex/auth.json`, opencode's `auth.json`, the CLI search folders | Only at first run (nothing at the config path) and when you click Import from CodexBar: whether `~/.claude` is a folder, `oauthAccount.organizationType` from `~/.claude.json` (to label the account Work or Personal), whether `~/.codex/auth.json` exists (it is never opened), the top-level entry names of opencode's `auth.json` (values never decoded) and whether `agy` is found (its `cliPaths` entry, or the search folders). |
| Each Claude or Codex account's profile folder, and each OpenCode account's credential file (else the default `auth.json`) | Existence only, whenever the account list is built, to hide accounts that are not on this Mac. |
| CodexBar's `config.json` (`$XDG_CONFIG_HOME/codexbar`, else `~/.config/codexbar`, then `~/.codexbar`) and its preferences domain `com.steipete.codexbar` | Only when you click Import from CodexBar in Settings > General, which lists the changes and asks before applying them: `providers[].id` and `providers[].enabled` from the config, and only the preference keys `refreshFrequency`, `quotaWarningThresholds` and `quotaWarningNotificationsEnabled`. The config file is read whole, but its API key and cookie fields are never decoded; the preferences domain is never enumerated. |
| The `claude` and `agy` binaries | Only for the probe latch: the resolved path, size and modification date, hashed into a fingerprint when a probe latches and on every refresh pass (every 30-second tick included) while any account is latched. |
| Tokenjar's own Keychain item, service `com.pedromosquera.tokenjar.apikeys` | The key stored under an account's id, on each check of an OpenCode Go account whose credential is a pasted key. Nothing else. |
| Tokenjar's own files in `~/Library/Application Support/Tokenjar/` | `tokenjar.sqlite`, `alert-state.json` and `probe-latch.json`, at launch and as the app runs. |

Antigravity has no history source; only the `agy` commands above.

## What it writes

| Path | Mode | Contents and when |
|---|---|---|
| `~/Library/Application Support/Tokenjar/` | 0700 | The support folder. Created, or tightened to 0700 if something else created it first, before the database, a state file or the probe folder is written. |
| `.../tokenjar.sqlite`, with its `-wal` and `-shm` files | 0600 | `snapshots`: the latest snapshot per account (plan label, each limit window's id, label, used %, length and reset time, money lines, source label and plain-language notes), shown at launch until the first refresh lands. `window_samples`: one row per fetch per window (account id, window id, time, used %, reset time) for the charts; a repeat within 5 minutes is skipped and samples older than 180 days are deleted. `usage_events`: one row per response (time, account id, harness, model id, project folder name or `~`, input, output, cache read, cache write 5-minute and 1-hour and reasoning tokens, cost the harness reported) and a dedupe key that is the SHA-256 hex digest of a key built from the message, request, response or session id, rollout file name or opencode message id. Rows outlive the logs they came from, because Claude Code deletes transcripts after 30 days. `scan_state`: one row per log file or opencode table read (scanner name `claude-transcripts`, `codex-rollouts` or `opencode-db:<provider id>`, account id, the SHA-256 hex digest of the file path or of `<opencode.db path>#<table>`, and a progress marker: inode and byte offset for Claude, a JSON object with inode, offset, last cumulative token totals, model id and project folder name for Codex, the largest `time_updated` for opencode). `schema_version`: which migrations have run. Written after every successful fetch (snapshot and samples) and every history scan (events and checkpoints). |
| `.../alert-state.json` | 0600 | Alert bookkeeping, rewritten after every applied fetch result: `firedKeys` (`<account id>\|<window id>\|<cycle>\|<threshold>`, or `...\|projected` or `...\|reset`), `failingAccounts` (account ids with an open source problem), and per `<account id>\|<window id>` the last reset time (`lastResetsAt`), last used % (`lastUsedPercent`) and cycle id (`cycles`). No provider account ids, emails or error text. |
| `.../probe-latch.json` | 0600 | `{"entries": {"<account id>": {"binary": "<SHA-256 hex>", "cli": "claude"}}}`, with `cli` either `claude` or `agy`: the accounts whose `/usage` probe ran as a model turn. `binary` is a digest of that CLI binary's resolved path, size and modification date, never the path itself, and is absent when the CLI could not be found. Written when a probe latches and when a latch is released. |
| `.../probe/` | 0700 | An empty folder inside the 0700 support folder, used as the working directory for CLI probes. Created before each `claude`, `codex` or `agy` run. |
| `~/.config/tokenjar/config.json` | Not set by Tokenjar (the default for new files, usually 0644; it holds no secrets) | Your settings as pretty-printed JSON: account ids, labels, profile folder paths, credential references (a file path and entry name, or a Keychain account name, never a key), thresholds, intervals, `cliPaths`. Written on each change in Settings, on a confirmed Import from CodexBar, and once at first launch when nothing is at the path (default settings plus discovered accounts). A stow symlink is written through to its target; a dangling one is left alone and nothing is written. `config.local.json` and `pricing.json` are never written. |
| `$TMPDIR/tokenjar-sign-in-<account id>.command` | 0700 | Written only when you click Sign In in Terminal: the script above, including the expanded profile folder path when the account sets one. It deletes itself when Terminal runs it. |
| Tokenjar's own Keychain item, service `com.pedromosquera.tokenjar.apikeys` | Keychain | A key you paste, stored under the account's id with the label "Tokenjar API key" when you click Save Key. Deleted when you switch that account back to opencode's `auth.json` (after confirming) or remove the account. |
| Tokenjar's preferences (domain `com.pedromosquera.tokenjar` for the installed app) | macOS default | The Dashboard and Settings window frames, saved by AppKit when those windows move or resize. |

Other changes on this Mac:

- **Login item.** Tokenjar registers or unregisters itself as a login item (`SMAppService`) only when you flip Launch at login in Settings > General, and only when it runs as an app bundle.
- **Notifications.** With alerts on, Tokenjar asks macOS for quiet provisional delivery at launch and when you turn alerts on; this shows no prompt. The system prompt for banners appears only when you click Allow Banners in Settings > Alerts. Alerts are local notifications titled with the account's name (for example "Claude · Personal"), with no emails, ids or raw errors in the text, and Tokenjar withdraws its own notifications when a window resets or a source recovers.

Developer flags write nothing of yours: `--render-snapshots <dir>` writes PNG renders of built-in preview data into `<dir>`, and `--probe` and `--scan` print to the terminal (a probe may create the support and probe folders). Neither touches `tokenjar.sqlite` or `config.json`.

Never stored, logged or displayed: prompts, outputs, message or file contents, emails, names or organization names from your provider accounts, provider account ids, OAuth tokens, API keys (outside the Keychain item), raw error bodies, log file paths and the raw message, request, response or session ids.

## Renamed from Headroom

Builds before the rename were called Headroom: bundle id `com.pedromosquera.headroom`, Keychain service `com.pedromosquera.headroom.apikeys`. Tokenjar never reads, writes or deletes that Keychain service, so a key pasted under it stays there until you delete it in Keychain Access, and has to be pasted again in Settings. macOS treats the new bundle id as a new app, so notification permission (Allow Banners) and Launch at login are granted and set again, and Tokenjar does not remove the old app's entries in System Settings.

## What it never does

- **Read, store, print or refresh an OAuth token**, or call any OAuth token or refresh endpoint. Refreshing a CLI-owned token from another process rotates a single-use refresh token and signs the CLI out, so Claude, Codex and Antigravity credentials stay entirely with their CLIs.
- **Read another app's Keychain items.** Every Keychain query carries Tokenjar's own service name, and that is the only service the app uses.
- **Send anything that changes account state**: no POST, nothing that spends a reset credit or other credits, sends an email, starts a model turn on purpose or onboards a project.
- **Run a CLI through a shell** or source your shell files.
- **Telemetry, analytics, crash reporting, update checks or auto-update feeds.** There are none.
- **Cookies**: no browser cookie import, and its own HTTP session neither stores nor sends cookies.
- **Status-page polling or embedded web views.**

## Known gaps

- **A CLI update can turn `/usage` into a model turn once.** Tokenjar cannot know in advance whether `claude -p /usage` or `agy -p /usage` will answer locally. If a CLI build sends it to the model, that one run spends tokens or quota before Tokenjar sees the reply. The account is then latched and not probed again until that CLI's binary changes, which allows one run on the new build, or until you click Try once more. For agy, the version check is the only guard before that first run; for claude there is none.

## Checking it yourself

- The allowlist is `HTTPClient.allowedEndpoints` in `Sources/TokenjarCore/Core/HTTPClient.swift`; `make test` fails if it changes.
- While Tokenjar runs, `nettop -p Tokenjar` or `lsof -i -a -c Tokenjar` lists its own connections. Expect `opencode.ai` only, and only if you have an OpenCode Go account.
- `sqlite3 ~/Library/Application\ Support/Tokenjar/tokenjar.sqlite "SELECT path FROM scan_state LIMIT 3"` prints 64-character hex digests, not paths.
- `ls -la ~/Library/Application\ Support/Tokenjar` shows the modes listed above.
- Settings > About shows a short summary of what is read, run, contacted and written. This page is the complete list.
