# What Headroom reads, runs, sends and stores

Headroom shows subscription usage limits without ever handling an OAuth token. Claude and Codex numbers come from their own CLIs, which keep their own credentials. The app's only network request of its own is one GET to `opencode.ai`. History comes from local log files, and only counts, model ids, timestamps and project folder names are kept.

This page is the contract. If the code and this page disagree, the code has a bug.

## Status of each statement

Two labels are used below:

- **In code**: implemented in this repository today.
- **As designed**: specified in [design.md](design.md); the implementation is still a stub on `main`. Whoever implements it updates this page in the same change.

In code today: the HTTP client (allowlist, GET only, HTTPS only, no redirects, no cookies) and the test that pins it; the Keychain wrapper scoped to the app's own service; how CLIs are located and the environment they get; the config file paths and how config is written. Every provider fetcher, history scanner, the SQLite store, first-run discovery and the CodexBar import are as designed.

## Network

### The one request Headroom makes itself

| | |
|---|---|
| Request | `GET https://opencode.ai/zen/go/v1/usage` |
| When | Each refresh, for OpenCode Go accounts only (as designed) |
| Headers | `Authorization: Bearer <key>`, `User-Agent: Headroom`, `Accept: application/json` |
| Key source | The `key` field of the `opencode-go` entry in opencode's `auth.json`, falling back to the `opencode` entry, or a key you pasted in Settings and Headroom stored in its own Keychain item (as designed) |

Enforced by `HTTPClient` (in code):

- The host allowlist is exactly `opencode.ai`. Any other host, including subdomains and look-alikes such as `opencode.ai.evil.example`, is rejected before a request is built.
- HTTPS only, GET only. The transport refuses any other method.
- Redirects are never followed, so the `Authorization` header cannot be carried to another host.
- The URL session is ephemeral: no cookie storage, no cookies sent, no URL cache.
- `HTTPClientTests.allowlistIsExactlyOpenCode` fails if the allowlist changes. Adding a host is a privacy decision that needs this page updated in the same change.

### Traffic that is not Headroom's

- The CLIs Headroom runs (below) talk to their own providers with their own credentials, the same as when you run them in a terminal. Headroom never sees those credentials and does not proxy that traffic.
- Clicking "Open dashboard" or a status link opens the URL in your default browser. Headroom does not fetch it. The defaults are `https://claude.ai/settings/usage`, `https://chatgpt.com/codex/settings/usage`, `https://opencode.ai/auth`, `https://antigravity.google/docs/plans`, `https://status.claude.com` and `https://status.openai.com` (in code; overridable per account with `dashboardURL`).

## Commands it runs

All as designed. Every CLI runs:

- from a fixed, empty working directory, `~/Library/Application Support/Headroom/probe`, so probes never show up as projects in a CLI's history;
- without a login shell, so your shell rc files are never executed. The binary is found in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` or `/usr/bin`, or at the path you set in `cliPaths` (in code);
- with a minimal environment: `HOME`, `USER`, `LOGNAME`, `LANG`, `TMPDIR`, `SHELL`, a fixed `PATH` and `NO_COLOR=1` (in code), plus `CLAUDE_CONFIG_DIR` or `CODEX_HOME` when an account uses a non-default profile directory.

### Claude

```
claude -p /usage --output-format stream-json --verbose --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}'
```

| Part | Why |
|---|---|
| `-p /usage` | Runs the local `/usage` command and exits. It reports plan limits and starts no model turn (0 tokens). |
| `--output-format stream-json --verbose` | Machine-readable output; `stream-json` requires `--verbose` in print mode. Headroom reads only `usage_report.rate_limits` (`limits[]`, `extra_usage`). |
| `--no-session-persistence` | The probe is not saved as a session, so it never appears in `claude --resume` or in the transcripts Headroom scans. |
| `--strict-mcp-config` | With no `--mcp-config` given, no MCP servers start. |
| `--settings '{"disableAllHooks":true}'` | Your hooks do not run for the probe. |

The exact argument list lives in `ClaudeUsageFetcher`; this table must match it.

### Codex

```
codex -s read-only -a never app-server
```

`-s read-only` keeps the sandbox read-only and `-a never` means it never asks for approval. Headroom speaks JSON-RPC over stdin/stdout and sends exactly three messages:

1. `initialize`
2. `initialized` (notification)
3. `account/rateLimits/read` with `{"excludeResetCreditDetails": true}`

It never sends `account/read` with `refreshToken: true`, never uses Codex's consume or nudge methods, and sends nothing else.

### Antigravity

```
agy -p /usage --output-format json
```

Needs agy 1.1.11 or later. Not yet verified against a live install.

### OpenCode

No CLI is run. See the network request above and the files below.

### Sign in

"Sign in" in Settings opens the provider's own CLI login in Terminal, and only when you click it (as designed). Headroom does not see what you type there.

## Files it reads

| Path | What is read | Status |
|---|---|---|
| `~/.config/headroom/config.json`, `~/.config/headroom/config.local.json` | The whole file. Both are secret-free by design. | In code |
| `~/.config/headroom/pricing.json` | Optional per-model price overrides. | As designed |
| `<claude profile>/projects/**/*.jsonl` (default profile `~/.claude`) | Assistant entries only: the token counts in `message.usage`, `message.model`, `timestamp`, the last path component of `cwd`, and `message.id` plus `requestId` to count each response once. Never `message.content`. | As designed |
| `~/.claude.json` (or `.claude.json` inside a custom profile dir) | From `oauthAccount`, only the field that names the plan, for the plan label. No email, name, organization or uuid fields. | As designed |
| `<codex home>/sessions/**/rollout-*.jsonl` (default `~/.codex`) | `token_usage_record` token counts and model id, deduplicated by `response_id`; otherwise positive deltas of `token_count` events; timestamps; the last path component of the session's working directory. If the codex CLI is missing, the last `rate_limits` snapshot in the newest rollout, shown as stale. | As designed |
| `~/.codex/auth.json` | Existence only, for first-run discovery. The file is never opened. | As designed |
| opencode's `auth.json` (`~/.local/share/opencode/auth.json`) | The `key` field of the `opencode-go` entry, then of `opencode`. That key is an API key, not an OAuth token, and it is sent only to `opencode.ai`. The file is parsed to find that entry; no other entry is used, stored or logged. First-run discovery reads only which entry names exist. | As designed |
| opencode's `opencode.db` (`~/.local/share/opencode/`) | Opened read-only. For assistant messages: cost, token counts, provider id, model id, timestamps, and the last path component of the working directory. Never message text or parts. | As designed |
| CodexBar's config and preferences | One-shot import you start at first run: provider ids and enabled flags, plus an explicit allowlist of preference keys (thresholds, refresh interval, notifications). Never its API key or cookie fields; its preferences domain is never enumerated. | As designed |
| Headroom's own Keychain item, service `com.pedromosquera.headroom.apikeys` | API keys you pasted in Settings. Nothing else. | In code |

Antigravity has no history source; only the `agy` command above.

## What it stores

| Where | What | Status |
|---|---|---|
| `~/Library/Application Support/Headroom/headroom.sqlite` | The latest snapshot per account: plan label, each limit window (id, label, used %, length, reset time), money lines, source label and plain-language notes. | As designed |
| same | `window_samples(account_id, window_id, ts, used_percent, resets_at)`: one row per fetch per window, for the charts. | As designed |
| same | Per-response token counts: timestamp, harness, model id, project folder name, input, output, cache read, cache write and reasoning tokens, cost reported by the harness, and a dedupe key built from the response's message or request id. Rolled up into `usage_daily`, because Claude Code deletes transcripts after 30 days. | As designed |
| same | `scan_state(path, inode, size, offset)`: which log files were read and how far, so scans are incremental. | As designed |
| `~/Library/Application Support/Headroom/probe/` | An empty directory, used as the working directory for CLI probes. | As designed |
| `~/.config/headroom/config.json` | Your settings, written when you change them in Settings, through the stow symlink if there is one. `config.local.json` is never written. | In code |
| Headroom's own Keychain item | API keys you paste in Settings. | In code |

`account_id` everywhere is the slug you chose in config (for example `claude-work`), not a provider account id.

Never stored, logged or displayed: prompts, outputs, file contents, emails, names, organization names, provider account ids or uuids, OAuth tokens, API keys (outside the Keychain item), raw error bodies.

Notifications are local macOS notifications. Their text carries no emails, ids or raw errors (as designed).

## What it never does

- **Read, store, print or refresh an OAuth token**, or call any OAuth token or refresh endpoint. Refreshing a CLI-owned token from another process rotates a single-use refresh token and signs the CLI out, so Claude and Codex credentials stay entirely with their CLIs.
- **Read another app's Keychain items.** The app's Keychain wrapper adds Headroom's own service name to every query, and that is the only service the app uses (in code).
- **Send anything that changes account state**: no POST, nothing that spends a reset credit or other credits, sends an email, starts a model turn or onboards a project.
- **Telemetry, analytics, crash reporting, update checks or auto-update feeds.** There are none.
- **Cookies**: no browser cookie import, and its own HTTP session neither stores nor sends cookies (in code).
- **Status-page polling or embedded web views.**

## Checking it yourself

- The allowlist is `HTTPClient.allowedHosts` in `Sources/HeadroomCore/Core/HTTPClient.swift`; `make test` fails if it changes.
- While Headroom runs, `nettop -p Headroom` or `lsof -i -a -c Headroom` lists its own connections. Expect `opencode.ai` only, and only if you have an OpenCode Go account.
- Settings > About shows the same list of what is read and contacted (as designed).
