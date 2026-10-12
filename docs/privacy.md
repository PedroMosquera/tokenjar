# What Tokenjar reads, runs, sends and stores

Tokenjar shows subscription usage limits without ever handling an OAuth token. Claude, Codex, Antigravity and GitHub Copilot numbers come from their own CLIs (`gh` for Copilot), which keep their own credentials. A Devin account is a link to Devin's usage page: nothing is run, read or sent for it. The app's only network request of its own is one GET to one path on `opencode.ai`. History comes from local log files. Tokenjar keeps counts, model ids, timestamps and project folder names; the log paths and response ids it needs to count each response once are stored only as SHA-256 digests.

This page is the contract, and every statement on it describes the code on `main`. A change that alters what Tokenjar reads, runs, sends or stores updates this page in the same commit.

In the tables below, "account id" is the slug you chose in config (for example `claude-work`), never a provider account id.

## Network

### The one request Tokenjar makes itself

| | |
|---|---|
| Request | `GET https://opencode.ai/zen/go/v1/usage` |
| When | Each check of an OpenCode Go account: at launch; on the first 30-second tick from 15 seconds before its interval ends, the interval counted from when its last check started (`refreshMinutes` of the account, else the global one, default 10, at least 30 in Low Power Mode); 8 seconds after wake; when the popover opens 2 minutes or more after the last refresh; from the popover's refresh button; from the account's own check (Retry or Try Again on its card, Check Now or Try Again in Settings); after Save Key; when the account changes in Settings or in the config file; and again at once if the account was edited while its request ran. After a 429, only the account's own check sends it again before the longer of `Retry-After` and twice the interval has passed since that answer, unless the account was edited while a request for it ran: that result is dropped, the backoff with it, and the request is sent again at once. |
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
- For a GitHub Copilot account, `gh` sends `GET https://api.github.com/copilot_internal/user` with the token of its own login on each check of that account, at the times listed for the OpenCode Go request above except Save Key. `api.github.com` is gh's default host; see [Known gaps](#known-gaps) for an Enterprise-only login. The endpoint is undocumented; it is the one VS Code's Copilot extension reads. Tokenjar sets `GH_TELEMETRY=false` and `DO_NOT_TRACK=1` so that gh does not send its own telemetry event for the run, and `GH_NO_UPDATE_NOTIFIER=1` so that it skips its update check.
- "Open Usage Page" (card title, card menu, the button on a Devin card and on its dashboard page, dashboard header, an account's Settings page), "Open Status Page" (card menu, Claude, Codex and GitHub Copilot only), the usage page links in Settings > About and "Install agy" open a URL in your default browser. Tokenjar does not fetch it. The usage page defaults are `https://claude.ai/settings/usage`, `https://chatgpt.com/settings/usage`, `https://opencode.ai/auth`, `https://antigravity.google/docs/plans`, `https://github.com/settings/copilot` and `https://app.devin.ai/settings/usage`; the status pages are `https://status.claude.com`, `https://status.openai.com` and `https://www.githubstatus.com`; "Install agy" is `https://antigravity.google`. An account's `dashboardURL` replaces its usage page, and is used only when it is an http or https URL. Use Windsurf Page, on a Devin account's Settings page, sets that account's `dashboardURL` to `https://windsurf.com/subscription/manage-plan` and opens nothing.
- "Open Notification Settings" in Settings > Alerts opens System Settings at Tokenjar's notification page, and "Open Login Items Settings" in Settings > General, shown while macOS waits for approval, opens its Login Items page.

## Commands it runs

Every CLI runs:

- from a fixed, empty working directory, `~/Library/Application Support/Tokenjar/probe` (mode 0700), so probes never show up as projects in a CLI's history;
- directly, never through a shell, so your shell rc files are never executed. The binary is the path set in `cliPaths` for that CLI when that path is an executable on this Mac, else the first executable found in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` or `/usr/bin`, so a `cliPaths` entry that names a path missing here (one set on another Mac that shares `config.json`) can run a binary found in those folders;
- with a minimal environment, `CLILocator.baseEnvironment`: `HOME` (your home folder), `USER`, `LOGNAME`, `LANG`, `TMPDIR` and `SHELL` when they are set in Tokenjar's own environment, a fixed `PATH` (the folders above plus `/bin`, `/usr/sbin`, `/sbin`) and `NO_COLOR=1`. The proxy variables `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `https_proxy`, `http_proxy` and `no_proxy` pass unchanged, each only when it is set in Tokenjar's own environment, so a CLI behind a proxy connects as it would from your terminal; their values can hold proxy credentials and are never logged or stored. Opened from Login Items or the Finder, Tokenjar gets launchd's environment, not your shell's, so a proxy exported only in a shell profile such as `.zshrc` does not reach the CLIs. Each CLI adds only its own variables on top: `claude` gets `CLAUDE_CONFIG_DIR` and `codex` gets `CODEX_HOME`, each only when the account sets a profile folder; `gh` always gets `GH_TELEMETRY=false`, `DO_NOT_TRACK=1`, `GH_NO_UPDATE_NOTIFIER=1` and `GH_PROMPT_DISABLED=1`, plus `GH_CONFIG_DIR` only when the account sets a profile folder; `agy` gets nothing more. Nothing else passes through, so API keys, config folders and other network settings (`ALL_PROXY`, certificate stores such as `SSL_CERT_FILE`) in Tokenjar's own environment never reach a CLI. `CLILocatorTests.baseEnvironmentPassesOnlyTheListedVariables` pins the base list, `proxyVariablesPassOnlyWhenSet` and `otherNetworkVariablesStillStayOut` pin the proxy rule, and `CopilotUsageFetcherTests.environmentIsTheMinimalOneWithGhTelemetryAndPromptsOff` and `profileFolderBecomesGhConfigDir` pin gh's;
- with a timeout, after which it gets SIGTERM and, 2 seconds later, SIGKILL.

The probe folder is created, or tightened to 0700, before each `claude`, `codex`, `agy` or `gh` run.

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

The read stops at the first assistant line with `usage_report` (the answer) or the first result line that shows a turn or a cost (the model). If neither appears, an assistant line that carried neither `usage_report` nor `local_command_run` means the run went to the model. The account then reports "Claude Code ran /usage as a prompt, which spends tokens. Checks for this account are paused until claude updates or you click Try Once More.", the cached fallback is not used, and the account is latched (see `probe-latch.json` below). The exact argument list lives in `ClaudeUsageFetcher.arguments`; this section must match it.

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

From the JSON Tokenjar reads `groups` (at any depth): each group's name, and each bucket's window name, remaining fraction, reset time and `disabled` flag. Only when there are no groups does it look at an `error` field and `data.message` (both at any depth) and at a top-level `response`, `stats`, `num_turns`, `command` (only whether it is an object) and `usage` (only whether any count in it is above 0), in this order. A non-empty `error` means signed out when it uses sign-in wording, else a broken source. Any non-empty `data.message` then reads as no limits for the account. Otherwise, if a run that exited 0 prints a model reply (`response`, `stats` or `num_turns`), Tokenjar reports "Antigravity ran /usage as a prompt, which spends quota. Checks for this account are paused until agy updates or you click Try Once More." and latches the account. agy's envelope for a local command (`num_turns` 0 beside a `command` object, with no `stats` and no `usage` count above 0) is not a model reply. Other output is a broken source. An `error` field, and the output of a failed run, are matched only for sign-in wording; they are never shown or stored. The JSON shape of `/usage` is not yet verified against a live install.

### GitHub Copilot

```
gh api --method GET -H 'X-GitHub-Api-Version: 2025-04-01' copilot_internal/user --jq '<filter>'
```

The arguments are passed as a list, not through a shell, so the quotes above are only for reading. `<filter>` is exactly:

```
{copilot_plan, access_type_sku, token_based_billing, quota_reset_date, quota_reset_date_utc, quota_snapshots: ((.quota_snapshots // {}) | map_values({entitlement, remaining, quota_remaining, percent_remaining, unlimited, has_quota, overage_count, overage_permitted, credits_used, token_based_billing})), monthly_quotas: (.monthly_quotas | if type == "object" then {chat, completions} else null end), limited_user_quotas: (.limited_user_quotas | if type == "object" then {chat, completions} else null end)}
```

| Part | Why |
|---|---|
| `api --method GET` | One read-only GET. Never `-f`, `-F`, `--field`, `--raw-field` or `--input`, any of which makes gh send a POST; never `--cache`, which writes the answer to disk; never `--paginate` or `--hostname`. |
| `-H 'X-GitHub-Api-Version: 2025-04-01'` | Pins the API version, as VS Code's Copilot extension does, so a new default on this undocumented endpoint cannot change the answer's shape. |
| `copilot_internal/user` | The endpoint VS Code's Copilot extension reads. gh sends it to `api.github.com`, its default host, with the token of its own login. |
| `--jq <filter>` | Runs inside gh, so only what the filter names reaches Tokenjar. Every object in it is an allowlist: the login, user and organization ids, the organization and enterprise lists, the endpoints, `assigned_date`, `analytics_tracking_id` and each quota's `quota_id` and `timestamp_utc` stay inside gh. |

Stdin is closed at once, the timeout is 20 seconds, and at most 256 KiB each of stdout and stderr is kept. From stdout Tokenjar decodes `copilot_plan` (the plan pill), `access_type_sku` (only compared with `free_limited_copilot`), `token_based_billing`, `quota_reset_date_utc` and `quota_reset_date`, and for each key of `quota_snapshots` its name and `entitlement`, `quota_remaining`, `percent_remaining`, `unlimited`, `overage_count`, `credits_used` and `token_based_billing`. On Copilot Free it also reads the `chat` and `completions` numbers of `monthly_quotas` and `limited_user_quotas`. `remaining`, `has_quota` and `overage_permitted` pass the filter but are not read. Stderr is only matched against gh's exit status and a few error words (HTTP 401, 403, 404, 429 and 5xx, "rate limit", and connection failures) to classify the failure; it can name the account, so it is never shown, logged or stored.

gh keeps its token in its own Keychain item or config folder. Tokenjar never reads `~/.config/gh` or any other gh file, never passes or asks for a token, and never runs `gh auth token`, `gh auth status`, `gh auth refresh` or `gh auth logout`. Discovery only checks whether a `gh` executable exists; it never runs it. A GET cannot start a model turn, so a Copilot account is never latched. The exact argument list lives in `CopilotUsageFetcher.arguments` (the filter in `CopilotUsageFetcher.filter`) and is pinned by `CopilotUsageFetcherTests.runsAPinnedReadOnlyGETThroughGh`; `filterKeepsNoLoginIdOrOrganization` runs the filter through `/usr/bin/jq` over a full answer and checks that no identifying field passes.

### Devin

Nothing is run, sent or read. `DevinUsageFetcher` builds a snapshot with no windows and a note that Devin does not share your quota with local apps yet, plus, while the account has no `dashboardURL`, a hint to point it at the Windsurf page for a grandfathered Windsurf plan. The account is a link to its usage page. `DevinUsageFetcherTests.reportsAUsagePageLinkWithoutRunningAnything` checks that no process runs.

### OpenCode

No CLI is run. See the network request above and the files below.

### Sign in

"Sign In in Terminal..." on an account's Settings page writes that account's login command to a script, `$TMPDIR/tokenjar-sign-in-<account id>.command` (mode 0700, the file name keeps only letters, digits, `-` and `_` of the id), and opens it in Terminal. Nothing is written or run until you click it. The script deletes itself first, prints "Tokenjar: sign in to <provider> (<label>)", then runs the command. The commands are `claude auth login`, `codex login`, `opencode auth login` and `gh auth login`, using the CLI's full path when Tokenjar finds it, and prefixed with `CLAUDE_CONFIG_DIR=<dir>`, `CODEX_HOME=<dir>` or `GH_CONFIG_DIR=<dir>` (the expanded path) when the account sets a profile folder. "Copy Command" copies the same line to the clipboard instead. The Settings page shows paths under your home folder as `~/...`; the script and the clipboard get the full paths. `gh auth login` is gh's own login; gh keeps the token it gets, and Tokenjar never sees it. Antigravity has no login command Tokenjar can hand off to; its Settings page links to `https://antigravity.google` to install agy. Devin has none either; its Settings page explains that the account opens its usage page. Tokenjar does not see what you type in Terminal.

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
| Account discovery: `~/.claude`, `~/.claude.json`, `~/.codex/auth.json`, opencode's `auth.json`, the CLI search folders, and Devin's or Windsurf's app and data folders | Only at first run (nothing at the config path) and when you click Import from CodexBar: whether `~/.claude` is a folder, `oauthAccount.organizationType` from `~/.claude.json` (to label the account Work or Personal), whether `~/.codex/auth.json` exists (it is never opened), the top-level entry names of opencode's `auth.json` (values never decoded), whether `agy` and `gh` are found (their `cliPaths` entries, or the search folders; neither is run), and whether any of `/Applications/Devin.app`, `~/Applications/Devin.app`, `/Applications/Windsurf.app`, `~/Applications/Windsurf.app`, `~/Library/Application Support/Devin` or `~/Library/Application Support/Windsurf` exists (none is opened). |
| Each Claude, Codex or GitHub Copilot account's profile folder (for Copilot, gh's config folder: the account's `profileDir`, else `~/.config/gh`), each OpenCode Go account's credential file (else the default `auth.json`), and each OpenCode Zen account's `opencode.db` | Existence only, whenever the account list is built and on every 30-second tick, to hide accounts that are not on this Mac. Settings checks the same to say which path is missing. |
| CodexBar's `config.json` (`$XDG_CONFIG_HOME/codexbar`, else `~/.config/codexbar`, then `~/.codexbar`) and its preferences domain `com.steipete.codexbar` | Only when you click Import from CodexBar in Settings > General, which lists the changes and asks before applying them: `providers[].id` and `providers[].enabled` from the config, and only the preference keys `refreshFrequency`, `quotaWarningThresholds` and `quotaWarningNotificationsEnabled`. The config file is read whole, but its API key and cookie fields are never decoded; the preferences domain is never enumerated. |
| The `claude` and `agy` binaries | Only for the probe latch: the resolved path, size and modification date, hashed into a fingerprint when a probe latches and on every refresh pass (every 30-second tick included) while any account is latched. |
| Tokenjar's own Keychain item, service `com.pedromosquera.tokenjar.apikeys` | The key stored under the account name in an OpenCode Go account's credential (the account's id when you pasted it in Settings), and nothing else. It is read at that account's first check after launch and then held in memory until Tokenjar quits, never written anywhere else and never logged. Later checks (the 30-second tick, wake, popover open, the refresh button) use the held key and do not read the item. What the first read finds is held whatever it is, no key or a refused read included. After you click Deny on the macOS prompt (or cancel it), the account says "Keychain access was denied. Tokenjar won't ask again on its own.", and nothing in the background asks again. The item is read again only by that account's own check (Retry or Try Again on its card, Check Now or Try Again in Settings) and only while no key is held. Save Key replaces the held key without reading the item, and deleting the key empties it. |
| Tokenjar's own files in `~/Library/Application Support/Tokenjar/` | `tokenjar.sqlite`, `alert-state.json` and `probe-latch.json`, at launch and as the app runs. |

Antigravity and GitHub Copilot have no history source; only the `agy` and `gh` commands above. Devin has nothing at all.

## What it writes

| Path | Mode | Contents and when |
|---|---|---|
| `~/Library/Application Support/Tokenjar/` | 0700 | The support folder. Created, or tightened to 0700 if something else created it first, before the database, a state file or the probe folder is written. |
| `.../tokenjar.sqlite`, with its `-wal` and `-shm` files | 0600 | `snapshots`: the latest snapshot per account (plan label, how the account is billed (free, subscription, pooled, usage-based or pay as you go) when the fetcher can tell, each limit window's id, label, used %, length, reset time and limit style (overage, or a share of an org's pool; absent for a hard limit), money lines, source label and plain-language notes; for a Devin account, only its source label and notes), shown at launch until the first refresh lands. `window_samples`: one row per fetch per window (account id, window id, time, used %, reset time) for the charts; a sample identical to the last one stored for that window and less than an hour newer is not written at once but held in memory and written just before the window's next change, and samples older than 180 days are deleted. `usage_events`: one row per response (time, account id, harness, model id, project folder name or `~`, input, output, cache read, cache write 5-minute and 1-hour and reasoning tokens, cost the harness reported) and a dedupe key that is the SHA-256 hex digest of a key built from the message, request, response or session id, rollout file name or opencode message id. Rows outlive the logs they came from, because Claude Code deletes transcripts after 30 days. `scan_state`: one row per log file or opencode table read (scanner name `claude-transcripts`, `codex-rollouts` or `opencode-db:<provider id>`, account id, the SHA-256 hex digest of the file path or of `<opencode.db path>#<table>`, and a progress marker: inode and byte offset for Claude, a JSON object with inode, offset, last cumulative token totals, model id and project folder name for Codex, the largest `time_updated` for opencode). `schema_version`: which migrations have run. Written after every successful fetch (snapshot and samples) and every history scan (events and checkpoints). |
| `.../alert-state.json` | 0600 | Alert bookkeeping, rewritten after a fetch result changes it: `firedKeys` (`<account id>\|<window id>\|<cycle>\|<threshold>`, or `...\|projected` or `...\|reset`), `failingAccounts` (account ids with an open source problem), and per `<account id>\|<window id>` the last reset time (`lastResetsAt`), last used % (`lastUsedPercent`) and cycle id (`cycles`). No provider account ids, emails or error text. |
| `.../probe-latch.json` | 0600 | `{"entries": {"<account id>": {"binary": "<SHA-256 hex>", "cli": "claude"}}}`, with `cli` either `claude` or `agy`: the accounts whose `/usage` probe ran as a model turn. `binary` is a digest of that CLI binary's resolved path, size and modification date, never the path itself, and is absent when the CLI could not be found. Written when a probe latches and when a latch is released. |
| `.../probe/` | 0700 | An empty folder inside the 0700 support folder, used as the working directory for CLI runs. Created before each `claude`, `codex`, `agy` or `gh` run. |
| `~/.config/tokenjar/config.json` | Not set by Tokenjar (the default for new files, usually 0644; it holds no secrets) | Your settings as pretty-printed JSON: account ids, labels, profile folder paths, credential references (a file path and entry name, or a Keychain account name, never a key), thresholds, intervals, the menu bar mode, icon and colors, `cliPaths`, whether pace counts working days only, the global shortcut. Written on each change in Settings, on a confirmed Import from CodexBar, and once at first launch when nothing is at the path (default settings plus discovered accounts). A stow symlink is written through to its target; a dangling one is left alone and nothing is written. An account that only `config.local.json` lists is never copied into it, and keys this build does not read are kept as they were. `config.local.json` and `pricing.json` are never written. |
| `$TMPDIR/tokenjar-sign-in-<account id>.command` | 0700 | Written only when you click Sign In in Terminal: the script above, including the expanded profile folder path when the account sets one. It deletes itself when Terminal runs it. |
| Tokenjar's own Keychain item, service `com.pedromosquera.tokenjar.apikeys` | Keychain | A key you paste, stored under the account's id with the label "Tokenjar API key" when you click Save Key. Deleted when you switch that account back to opencode's `auth.json` (after confirming) or remove the account. |
| Tokenjar's preferences (domain `com.pedromosquera.tokenjar` for the installed app) | macOS default | The Dashboard and Settings window frames, saved by AppKit when those windows move or resize. |
| The macOS unified log, subsystem `com.pedromosquera.tokenjar` | macOS default | Category `legacy-move`: each step of the move from Headroom's folders (below). Category `keychain`: the Keychain status code when saving or deleting a pasted key fails, never the key. Category `popover`: the popover window's frame, its status item's frame and that screen's visible frame, in whole screen points, when the popover opens and each time it moves or resizes while open, as a warning when it reaches above its status item. Nothing else. |
| `~/Library/Application Support/Headroom/` and `~/.config/headroom/`, when Headroom left them | Unchanged | Renamed once at launch to Tokenjar's folders, with the database files inside; see [Renamed from Headroom](#renamed-from-headroom). |

Other changes on this Mac:

- **Login item.** Tokenjar registers or unregisters itself as a login item (`SMAppService`) only when you flip Launch at login in Settings > General, and only when it runs as an app bundle.
- **Notifications.** With alerts on, Tokenjar asks macOS for quiet provisional delivery at launch and when you turn alerts on; this shows no prompt. The system prompt for banners appears only when you click Allow Banners in Settings > Alerts. Alerts are local notifications titled with the account's name (for example "Claude · Personal"), with no emails, ids or raw errors in the text, and Tokenjar withdraws its own notifications when a window resets or a source recovers.

Developer flags write nothing of yours, and none of them runs the move from Headroom's folders described below.

- `--render-snapshots <dir>` writes PNG renders of built-in preview data into `<dir>`.
- `--render-windows <dir>` writes PNG captures of the app's own windows into `<dir>`, from built-in preview data. With `--real-data` it shows this Mac's settings and history instead: it reads `config.json`, `config.local.json`, `pricing.json` and `probe-latch.json` (never writing them), checks which accounts exist on this Mac as the app does, and copies `tokenjar.sqlite` with SQLite's online backup, opening the original read-only, into a `.tokenjar-render-<random id>` folder (mode 0700) next to `<dir>`. That folder is deleted when the run ends. A render runs no CLI, sends no request, scans no log, and never reads the Keychain, asks for notifications or touches the login item.
- `--probe` and `--scan` print to the terminal. A probe runs the real CLI and may create the support and probe folders; an empty pair left that way does not keep Headroom's folder from moving. Neither touches `tokenjar.sqlite` or `config.json`.
- `--capture <provider>` prints one JSON document: the raw answer to the request a check of that provider sends, redacted, so an answer's shape can become a test fixture. For `claude` it runs the `claude -p /usage` command above and adds, from `.claude.json`, only `organizationType`, `seatTier`, `billingType`, `organizationRateLimitTier`, `userRateLimitTier` and `hasExtraUsageEnabled` of `oauthAccount` and the top-level `hasExtraUsageEnabled`, plus the names, never the values, of the `CLAUDE_CODE_*` and `ANTHROPIC_*` keys under `env` in `<claude profile>/settings.json` and in `/Library/Application Support/ClaudeCode/managed-settings.json`, when those files exist. For `codex` it holds the app-server conversation above with `"excludeResetCreditDetails":false`, so the answer also lists the limit-reset credit inventory; the app's own checks still send `true`. For `copilot` it sends the same `gh api` GET with the same environment, with a capture `--jq` program in place of the filter. On a successful answer the program applies the redaction below inside gh, so the login and ids never reach Tokenjar. gh skips `--jq` when an HTTP error answer carries a `message` or `errors` field and prints that body as it came, so an error body does reach Tokenjar, which applies the same redaction to it before printing anything. For `antigravity` it runs `agy --version` and, only for 1.1.11 or later, `agy -p /usage --output-format json`, and reduces stderr to which of `sign in`, `eligible`, `terms of service`, `region`, `dial tcp`, `no such host` and `eof` it contains, plus its line count. For `opencode-go` it sends the one allowed GET and prints the status code and body. `devin` and `opencode-zen` print that there is nothing to capture.
- Capture redaction (`CaptureRedactor`): every key, bool and null is kept, so the shape survives. A number is kept unless its key ends in `id` or `ids` in any case: `user_id`, `orgId`, `accountid` and `uuid`, and also words such as `valid` or `paid`. A string becomes `<redacted>` unless its provider and JSON path are on `CaptureRedactor.allowlist`, and even there when it looks like an email, a UUID or a key (a known prefix such as `sk-`, `ghp_` or `oc_sk_`, or a long run of letters and digits); a key that looks like one becomes `<redacted-key-N>`. The allowlist: for claude, each output line's `type`, `subtype`, `apiKeySource`, `claude_code_version`, `local_command` and `local_command_run.command`, each limit's `kind`, `group`, `severity` and scope `model.display_name` and `surface.display_name`, `extra_usage.currency`, the five `oauthAccount` strings above and the env key names; for codex, `planType`, `limitId`, `limitName` and `rateLimitReachedType` of `rateLimits` and of each `rateLimitsByLimitId` entry, `status`, `state`, `type` and `kind` anywhere under `rateLimitResetCredits`, and `service_tier` or `serviceTier` anywhere in the result; for copilot, `copilot_plan`, `access_type_sku`, `sku` and each `quota_snapshots` entry's `quota_id`; for antigravity, each group's `name`, `displayName`, `display_name`, `label` and `title` and each bucket's `window`; for opencode-go, `_tag`, `error.type`, any `currency`, and the `status` of `rolling`, `weekly` and `monthly`; and the capture's own labels (the provider, an error kind, the stderr phrases). Dates, amounts and messages sent as strings are redacted with the rest. `CaptureRedactorTests.onlyAllowlistedPathsSurvive` pins the list.
- `--capture` prints the document to stdout and its messages to stderr, and stores no snapshot, latch or other file; like a probe it may create the support and probe folders. A capture whose own run turns into a model turn prints a stop message instead of the document and exits 1. It writes nothing, so the app does not latch on it, and the app's next check of that binary still runs once before it latches.
- `--probe` and `--capture` read `probe-latch.json` (never writing it) before they run `claude` or `agy`, and refuse, running nothing and exiting 1, in two cases. When it holds an entry for that CLI whose binary fingerprint matches the binary they would run, or that has no fingerprint, the message says to use Try Once More in the app. When the file exists but cannot be read, the message says it could not be read and may hold a latch on that CLI.

Never stored, logged or displayed: prompts, outputs, message or file contents, emails, names or organization names from your provider accounts, provider account ids, OAuth tokens, API keys (outside the Keychain item and the copy held in memory while Tokenjar runs), raw error bodies, log file paths and the raw message, request, response or session ids.

## Renamed from Headroom

Builds before the rename were called Headroom: bundle id `com.pedromosquera.headroom`, Keychain service `com.pedromosquera.headroom.apikeys`, `~/.config/headroom/` and `~/Library/Application Support/Headroom/`.

`make install` (`Scripts/install.sh`) first retires the old app, and only when `Headroom.app` in the install folder carries exactly that bundle id in its `Info.plist`: it quits any process named exactly `Headroom` (`pkill -x Headroom`), waits up to 5 seconds for it to exit, stops without installing if it is still running, and then deletes `Headroom.app`. It never touches a Headroom installed anywhere else.

At launch, before the config or the database is opened, Tokenjar moves what Headroom left, once:

- `~/Library/Application Support/Headroom/` is renamed to `~/Library/Application Support/Tokenjar/` when that does not exist yet, or holds nothing but an empty `probe/` folder (what `--probe` leaves when run before Tokenjar's first launch), which is removed first. Inside it, `headroom.sqlite`, `headroom.sqlite-wal` and `headroom.sqlite-shm` are renamed to `tokenjar.sqlite`, `tokenjar.sqlite-wal` and `tokenjar.sqlite-shm` together (missing ones are skipped), and put back under their old names if one of them cannot be renamed. `alert-state.json`, `probe-latch.json` and `probe/` keep their names.
- `~/.config/headroom` (`$XDG_CONFIG_HOME/headroom` when that variable is set in Tokenjar's own environment) is renamed to `~/.config/tokenjar` (or `$XDG_CONFIG_HOME/tokenjar`) when that does not exist yet. A rename keeps the folder's depth, so a relative stow link inside it, or a folder that is itself a relative stow link, still resolves; a folder that is a link moves as the link.
- Where both names exist, even as a dangling link, nothing changes. While an app with bundle id `com.pedromosquera.headroom`, or any process named exactly `Headroom` (an old build started from `.build` has no bundle id), is running, nothing moves, so its open database is never pulled away.
- While something is still left to move, because Headroom is running or a step failed, Tokenjar loads no settings or history and writes nothing under its own names for the rest of that launch, so the names stay free; a banner in the popover and in Settings says to quit Headroom, or that the move failed, and the next launch tries again.
- Folders and files are only renamed: nothing is copied, nothing is deleted but that empty `probe/` folder and the empty folder around it, and no file contents are read. Each step and each failure goes to the macOS unified log (subsystem `com.pedromosquera.tokenjar`, category `legacy-move`) with folder names and an error code, never a path. A failure never stops the launch.

Tokenjar never reads, writes or deletes Headroom's Keychain service, so a key pasted under it stays there until you delete it in Keychain Access, and has to be pasted again in Settings. macOS treats the new bundle id as a new app, so notification permission (Allow Banners) and Launch at login are granted and set again, and Tokenjar does not remove the old app's entries in System Settings.

## What it never does

- **Read, store, print or refresh an OAuth token**, or call any OAuth token or refresh endpoint. Refreshing a CLI-owned token from another process rotates a single-use refresh token and signs the CLI out, so Claude, Codex, Antigravity and GitHub credentials stay entirely with their CLIs.
- **Read another app's Keychain items.** Every Keychain query carries Tokenjar's own service name, and that is the only service the app uses.
- **Send anything that changes account state**: no POST, nothing that spends a reset credit or other credits, sends an email, starts a model turn on purpose or onboards a project.
- **Run a CLI through a shell** or source your shell files.
- **Telemetry, analytics, crash reporting, update checks or auto-update feeds.** There are none, and gh's own telemetry and update check are turned off for the runs Tokenjar starts.
- **Cookies**: no browser cookie import, and its own HTTP session neither stores nor sends cookies.
- **Status-page polling or embedded web views.**

## Known gaps

- **A CLI update can turn `/usage` into a model turn once.** Tokenjar cannot know in advance whether `claude -p /usage` or `agy -p /usage` will answer locally. If a CLI build sends it to the model, that one run spends tokens or quota before Tokenjar sees the reply. The account is then latched and not probed again until that CLI's binary changes, which allows one run on the new build, or until you click Try Once More. For agy, the version check is the only guard before that first run; for claude there is none.
- **Copilot's endpoint is undocumented.** `copilot_internal/user` can change without notice, and an answer in a new shape shows as unreadable or as no per-user limits. Most plans have not been checked against a real account; their shapes and plan names come from what VS Code's Copilot extension and CodexBar read.
- **A proxy set only in your shell does not reach the CLIs.** Tokenjar passes on the proxy variables it was started with. Opened from Login Items or the Finder, that is launchd's environment, so a CLI that can reach its provider only through a proxy exported in a shell profile cannot connect when Tokenjar runs it. `ALL_PROXY` (SOCKS) and custom certificate stores never pass.
- **GitHub Enterprise hosts are not supported.** gh runs without `--hostname` and without `GH_HOST`, so the request is meant for github.com. What gh does when its only login is a GitHub Enterprise Server or GHE.com host is not verified.

## Checking it yourself

- The allowlist is `HTTPClient.allowedEndpoints` in `Sources/TokenjarCore/Core/HTTPClient.swift`; `make test` fails if it changes.
- `DocsPinTests.privacyNamesEveryCLICall` records the command lines and environment variables the fetchers and `CLILocator.baseEnvironment` build, and fails when [Commands it runs](#commands-it-runs) does not name one.
- While Tokenjar runs, `nettop -p Tokenjar` or `lsof -i -a -c Tokenjar` lists its own connections. Expect `opencode.ai` only, and only if you have an OpenCode Go account. The CLIs it starts show up as their own processes: a Copilot check is a short-lived `gh` connecting to `api.github.com`.
- `sqlite3 ~/Library/Application\ Support/Tokenjar/tokenjar.sqlite "SELECT path FROM scan_state LIMIT 3"` prints 64-character hex digests, not paths.
- `ls -la ~/Library/Application\ Support/Tokenjar` shows the modes listed above.
- Settings > About shows a short summary of what is run, read, contacted and written; the section below lists it. This page is the complete list.

## The summary in Settings > About

Settings > About names, under Runs, Reads and Contacts, exactly the items below, in this order. `AboutSummaryTests` fails when either list changes without the other, so a new command, file or endpoint lands on both. Its Writes and Never lists are summaries of [What it writes](#what-it-writes) and [What it never does](#what-it-never-does) and are not checked.

### Runs

Details in [Commands it runs](#commands-it-runs).

- `claude -p /usage --output-format stream-json`
- `codex -s read-only -a never app-server`
- `agy --version`
- `agy -p /usage --output-format json`
- `gh api --method GET copilot_internal/user --jq <filter>`

### Reads

Details in [Files it reads](#files-it-reads).

- `~/.claude/projects/**/*.jsonl`
- `~/.claude.json`
- `~/.claude/settings.json`
- `~/.codex/sessions/**/rollout-*.jsonl`
- `~/.codex/auth.json`
- `Devin.app, Windsurf.app and their Application Support folders`
- `~/.local/share/opencode/auth.json`
- `~/.local/share/opencode/opencode.db`
- `~/.config/tokenjar/`
- `CodexBar's settings`

### Contacts

Details in [Network](#network).

- `GET https://opencode.ai/zen/go/v1/usage`
