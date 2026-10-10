# Headroom

A personal macOS menu bar app that shows how much room is left on each AI subscription (Claude, Codex, OpenCode Go/Zen, Antigravity) before the next limit, whether the current pace runs out before the window resets, and what usage costs over time.

It never reads or refreshes an OAuth token. Claude, Codex and Antigravity usage comes from their own CLIs, and the only network request the app makes itself is one GET to `https://opencode.ai/zen/go/v1/usage`. [docs/privacy.md](docs/privacy.md) lists exactly what it reads, runs, sends and stores; [docs/design.md](docs/design.md) is the design of record.

## What it shows

- **Menu bar.** Three modes, picked in Settings > General: the logo and used % of the account with the least headroom (the default), one thin bar per account, or the logo only. It turns amber at 80 % used, or when a window at least half used is on pace to run out 15 minutes or more before it resets, and red at 95 % (both thresholds adjustable). A full window shows its reset countdown instead of the percent. Faded means the data is out of date; a dot means the last check failed.
- **Popover.** Click the menu bar item. One card per account, in config order: each limit window as a bar with an even-pace tick, used % and time to reset, a verdict line ("On pace", "Ahead of pace +12%", "Runs out ~40m before reset"), a small burn-up chart, and money where it exists (Claude extra usage, OpenCode Zen spend). Command-R refreshes.
- **Dashboard.** API-equivalent cost today, over 7 days and this month; used % over time per window with reset markers; daily spend by model, harness, project or account; top projects. Ranges: 24h, 7d, 30d.
- **Settings.** General (launch at login, refresh interval, menu bar), Accounts (one page per account, with Test, Sign In in Terminal and per-account overrides), Alerts, and About (a summary of what the app touches).
- **Alerts.** Local notifications when a window crosses a threshold (80 % and 95 % by default), when it is on pace to run out, when a source stops working, and optionally when a window resets after Headroom last saw it at 80 % or more. Until an account's first successful check after launch nothing fires for it, except a check that spent tokens or quota. Alerts arrive quietly in Notification Center until you click Allow Banners in Settings > Alerts.

## Requirements

- macOS 14 or later.
- Command Line Tools with Swift 6.2 or later (`xcode-select --install`, then `swift --version`). Xcode is not needed.
- The CLIs for the accounts you track: `claude`, `codex`, `agy` (1.1.11 or later). OpenCode needs no CLI to be tracked; `opencode` is only used to sign in.

## Install

```
git clone <repo-url> headroom
cd headroom
make install
```

This builds a release binary, bundles `Headroom.app`, signs it ad-hoc, copies it to `~/Applications` and launches it. No admin rights, no quarantine flag, no Gatekeeper prompt. Run `make install` again to update. `make install INSTALL_DIR=<folder>` installs somewhere else.

On the first launch, when nothing is at the config path (not even a stow link), Headroom writes a `config.json` with default settings and the accounts it finds on this Mac: `~/.claude`, `~/.codex/auth.json`, the `opencode-go` and `opencode` entries of opencode's `auth.json`, and `agy`. To bring over CodexBar's providers and thresholds, use Settings > General > Import from CodexBar, which lists the changes before applying them.

### Managed Macs

- On a Mac that only runs approved software, an allowlisting tool blocks each new ad-hoc build, and every `make install` produces a new binary, so the app will not launch until that build is allowlisted.
- Command Line Tools are required to build (`xcode-select --install`). Xcode is not.
- No admin rights are needed: the app installs to `~/Applications` in your home folder.

## Config

Headroom reads `~/.config/headroom/config.json` (`$XDG_CONFIG_HOME/headroom/config.json` when that variable is set in the app's own environment). It holds no secrets, only references to where API keys live. Settings saves every change to it. You can also edit it by hand; the app picks the change up within 30 seconds.

```json
{
  "refreshMinutes": 10,
  "accounts": [
    { "id": "claude", "provider": "claude", "label": "Personal" },
    { "id": "claude-work", "provider": "claude", "label": "Work", "profileDir": "~/.claude-work" },
    { "id": "codex", "provider": "codex", "label": "ChatGPT" },
    { "id": "opencode-go", "provider": "opencode-go", "label": "Go",
      "credential": { "file": { "path": "~/.local/share/opencode/auth.json", "key": "opencode-go" } } }
  ]
}
```

`provider` is one of `claude`, `codex`, `opencode-go`, `opencode-zen`, `antigravity`. `profileDir` is `CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex, and opencode's data folder for OpenCode. Other account fields: `enabled`, `showInMenuBar`, `refreshMinutes`, `alertThresholds`, `dashboardURL`. Top-level fields: `refreshMinutes`, `menuBar`, `alerts`, `cliPaths`, `launchAtLogin`. Every field but `id` and `provider` has a default; [docs/design.md](docs/design.md#config-and-sync) has the full list.

Never rename an account `id` once it has data: it is the key for history and alerts.

## Several Macs

`config.json` holds no secrets, so it can live in your dotfiles repo and be shared by every Mac.

1. In the dotfiles repo, add a `headroom` stow package holding `.config/headroom/config.json`.
2. Stow it with `--no-folding`, so `~/.config/headroom` stays a real folder and only `config.json` is a link. Without it, stow can link the whole folder, and `config.local.json` would end up in the repo.

```
stow --dir=<dotfiles repo> --target="$HOME" --restow --no-folding headroom
```

Stow before Headroom's first launch on a new Mac. If Headroom already wrote a `config.json`, move it into the repo (or out of the way) first, because stow will not replace a real file. Settings saves through the link, so the link survives every save. If the link dangles for a moment (a branch switch in the repo), Headroom keeps its current settings and saves nothing until the file is back.

Machine-only values go in `~/.config/headroom/config.local.json`, next to the link. It is not stowed, Headroom never writes it, and it wins on merge: objects merge key by key, and `accounts` merge by `id`, field by field.

The default `~/.claude` (or `~/.codex`) can be a different login on each Mac: a personal plan on one Mac and a company seat on another. Keep one account for it in the shared file and relabel it on the other Mac with this `config.local.json`:

```json
{
  "accounts": [
    { "id": "claude", "label": "Work" }
  ]
}
```

The plan pill comes from the login itself, so it reads Max on one Mac and Enterprise on the other. A local entry whose `id` is not in `config.json` adds an account, and then needs `provider` too. The next time you add, remove or edit any account in Settings, that account is copied into `config.json`, so put accounts in `config.json` when you can.

Claude and Codex accounts whose profile folder is missing on a Mac, and OpenCode accounts whose credential file (else opencode's default `auth.json`) is missing, are hidden there (Settings lists them as "Not on this Mac"), so one shared file can list `~/.claude-work` and still work on another Mac. Antigravity and accounts with a pasted API key have no file to check; turn one off on a single Mac with `"enabled": false` in that Mac's `config.local.json`.

Settings writes only `config.json`. Editing a field that `config.local.json` overrides changes the shared value for your other Macs, while this Mac keeps its local one, so change such a field in `config.local.json` by hand.

History and alert state stay on each Mac and are never synced. `headroom.sqlite` (usage history and limit samples), `alert-state.json` and `probe-latch.json` live in `~/Library/Application Support/Headroom/`. The same account `id` on two Macs keeps two separate histories, which is what lets one id stand for a different login on each. A pasted API key lives only in that Mac's Keychain, so paste it again on each Mac. Launch at login is registered per Mac.

## Make targets

| Target | What it does |
|---|---|
| `make build` | Debug build |
| `make test` | Swift Testing under Command Line Tools (run it with `XDG_CONFIG_HOME` unset) |
| `make release` | Release build |
| `make app` | Release build bundled and signed as `build/Headroom.app` |
| `make install` | `make app`, then copy to `~/Applications` and launch |
| `make run` | `make app`, then open `build/Headroom.app` |
| `make clean` | Remove `.build` and `build` |

`Scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns` from `Resources/AppIcon.svg`; run it after editing the SVG and commit both.

## Developer flags

The binary takes three flags that do one job and exit:

```
.build/debug/Headroom --probe <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]
.build/debug/Headroom --scan <provider> [--profile-dir DIR] [--days N]
.build/debug/Headroom --render-snapshots <dir>
```

- `--probe` runs one live check and prints the snapshot as JSON. It runs the real CLI, ignores the probe latch and does not read `config.json` (so `cliPaths` does not apply), and it can spend tokens if `/usage` turns into a model turn.
- `--scan` reads the provider's local history from the start and prints totals and an API-equivalent cost for the last N days (default 30). Antigravity has no history to scan.
- `--render-snapshots` renders the popover, the menu bar item, the dashboard and the General and account Settings pages to PNG, light and dark, from built-in preview data.

`<provider>` is one of `claude`, `codex`, `opencode-go`, `opencode-zen`, `antigravity`. None of the three touches `headroom.sqlite` or `config.json`.

## Troubleshooting

- **"claude CLI not found"** (or codex, agy). Headroom does not use your shell `PATH`. It looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` and `/usr/bin`. Anywhere else, set the full path in config: `"cliPaths": { "claude": "/path/to/claude" }`. A `cliPaths` entry replaces the search, so a wrong path there also reads as not found. When a saved copy exists the card shows it with a note instead (Claude Code's own cache for Claude, the last limits in a session log for Codex).
- **Signed out.** The card's Sign in button opens the account's Settings page. Sign In in Terminal there runs the provider's own login (`claude auth login`, `codex login`, `opencode auth login`) in Terminal, and Copy Command copies it instead. Headroom never sees your credentials. With an older claude that has no `auth` command, run `claude` and type `/login`.
- **No notifications.** Alerts need the app bundle, so they never come from `swift run` or a `.build` binary; use the installed copy (`make install`). If they arrive only in Notification Center, click Allow Banners in Settings > Alerts. If macOS has them turned off, the same pane offers Open Notification Settings.
- **"Checks for this account are paused".** The last `/usage` check ran as a model turn and spent tokens (claude) or quota (agy), so Headroom stopped checking that account. It checks again once by itself when that CLI updates. Click Try once more on the card (Try Once More in Settings) to run one check now; if it repeats, checks stop again. Disable turns the account off.
- **"Could not read config.json"** (or `config.local.json`). The file is not valid JSON, often a leftover merge conflict. Headroom keeps the last good settings (none, if the file was already broken at launch) and saves nothing until the file loads again. Fix it and save; the app reloads within 30 seconds, or click Reload in Settings > General. "config.json is missing or its link is broken" means the same for a missing file or a dangling stow link.
- **Keychain prompt after an update.** The ad-hoc signature changes on every build, so macOS asks again before Headroom can read its own Keychain item. Only API keys you pasted in Settings live there.
