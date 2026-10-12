# Tokenjar

A personal macOS menu bar app that shows how much room is left on each AI subscription (Claude, Codex, OpenCode Go/Zen, Antigravity, GitHub Copilot) before the next limit, whether the current pace runs out before the window resets, and what usage costs over time. Devin, which now includes Windsurf, is a link to its usage page until it shares usage with local apps.

It never reads or refreshes an OAuth token. Claude, Codex, Antigravity and GitHub Copilot usage comes from their own CLIs (`gh` for Copilot), and the only network request the app makes itself is one GET to `https://opencode.ai/zen/go/v1/usage`. [docs/privacy.md](docs/privacy.md) lists exactly what it reads, runs, sends and stores; [docs/design.md](docs/design.md) is the design of record.

## What it shows

- **Menu bar.** Three modes, picked in Settings > General: an icon with the used % of the account with the least room left (the default), one thin bar per account, or the icon only. The default icon is Tokenjar's own mark, a cooldown slot that fills clockwise to that account's used share, so the item never looks like the Claude or ChatGPT app. Settings > General > Icon can switch to one of five other marks, a provider logo or an SF Symbol; those stay static but still change color and fade. It turns amber at 80 % used, or when a window at least half used is on pace to run out 15 minutes or more before it resets, and red at 95 % (both levels adjustable). A full window shows its reset countdown instead of the percent. Faded means the data is out of date; a dot means a check failed in a way that needs you. A Devin or OpenCode Zen account never shows there, and neither does one whose only answer so far is that it has no subscription.
- **Popover.** Click the menu bar item. One card per account, in config order: each limit window as a bar with an even-pace tick, used % and time to reset, a verdict line ("On pace", "Ahead of pace +12%", "Runs out ~40m before reset"), a small burn-up chart, and money where it exists (Claude extra usage, OpenCode Zen spend). A failed check says what went wrong and offers the fix (Sign In..., Retry, Try Again); a missing subscription or a passing network blip stays gray and quiet. A Devin card has an Open Usage Page button. Command-R refreshes.
- **Dashboard.** A sidebar of accounts with each one's tightest used %; API-equivalent cost today, over 7 days and this month; used % over time per window with reset markers; daily spend by model, harness, project or account; top projects. Ranges: 24h, 7d, 30d. Antigravity and GitHub Copilot keep no local logs, so they have limits but no cost history.
- **Settings.** General (launch at login, refresh interval, menu bar mode, icon and colors, config file, Import from CodexBar), Accounts (a list with each account's state, and one page per account with its status and fix, Check Now, Sign In in Terminal and per-account overrides), Alerts, and About (a summary of what the app runs, reads, contacts and writes).
- **Alerts.** Local notifications when a window crosses a threshold (80 % and 95 % by default), when it is on pace to run out, when a source stops working, and optionally when a window resets after Tokenjar last saw it at 80 % or more. Until an account's first successful check after launch nothing fires for it, except a check that spent tokens or quota. Alerts arrive quietly in Notification Center until you click Allow Banners in Settings > Alerts.

## Requirements

- macOS 14 or later.
- Command Line Tools with Swift 6.2 or later (`xcode-select --install`, then `swift --version`). Xcode is not needed.
- The CLIs for the accounts you track: `claude`, `codex`, `agy` (1.1.11 or later), and `gh` signed in with `gh auth login` for GitHub Copilot. OpenCode needs no CLI to be tracked; `opencode` is only used to sign in. Devin needs nothing.

## Install

```
git clone <repo-url> tokenjar
cd tokenjar
make install
```

This builds a release binary, bundles `Tokenjar.app`, signs it ad-hoc, copies it to `~/Applications` and launches it. An older `Headroom.app` there, with bundle id `com.pedromosquera.headroom`, is quit and deleted first, and Tokenjar moves its settings and history to its own folders on first launch ([docs/privacy.md](docs/privacy.md#renamed-from-headroom) has the details). If Headroom is still running then (it is not quit by `make run`, or when it is installed somewhere else), Tokenjar loads nothing and its banner asks you to quit Headroom and reopen Tokenjar. No admin rights, no quarantine flag, no Gatekeeper prompt. Run `make install` again to update. `make install INSTALL_DIR=<folder>` installs somewhere else.

On the first launch, when nothing is at the config path (not even a stow link), Tokenjar writes a `config.json` with default settings and the accounts it finds on this Mac: `~/.claude`, `~/.codex/auth.json`, the `opencode-go` and `opencode` entries of opencode's `auth.json`, `agy`, `gh` (found, never run), and a Devin or Windsurf app or data folder (a Devin account, off the menu bar). To bring over CodexBar's providers and thresholds, use Settings > General > Import from CodexBar, which lists the changes before applying them.

### Managed Macs

- On a Mac that only runs approved software, an allowlisting tool blocks each new ad-hoc build, and every `make install` produces a new binary, so the app will not launch until that build is allowlisted.
- Command Line Tools are required to build (`xcode-select --install`). Xcode is not.
- No admin rights are needed: the app installs to `~/Applications` in your home folder.

## Config

Tokenjar reads `~/.config/tokenjar/config.json` (`$XDG_CONFIG_HOME/tokenjar/config.json` when that variable is set in the app's own environment). It holds no secrets, only references to where API keys live. Settings saves every change to it. You can also edit it by hand; the app picks the change up within 30 seconds.

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

`provider` is one of `claude`, `codex`, `opencode-go`, `opencode-zen`, `antigravity`, `copilot`, `devin`. `profileDir` is `CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex, `GH_CONFIG_DIR` for GitHub Copilot (a second GitHub login needs its own gh folder), and opencode's data folder for OpenCode. Other account fields: `enabled`, `showInMenuBar`, `refreshMinutes`, `alertThresholds`, `dashboardURL`. Top-level fields: `refreshMinutes`, `menuBar` (`mode`, `icon`, `warnAt`, `criticalAt`, `showResetCountdownWhenFull`), `alerts`, `cliPaths`, `launchAtLogin`, `paceDays`, `hotkey`. `alerts.shortThresholds` (for windows of a day or less), `paceDays` and `hotkey` are kept in the file but have no effect in this build yet: every window alerts at the account's `alertThresholds`, else `alerts.thresholds`. Every field but `id` and `provider` has a default; [docs/design.md](docs/design.md#config-and-sync) has the full list.

Never rename an account `id` once it has data: it is the key for history and alerts.

## Several Macs

`config.json` holds no secrets, so it can live in your dotfiles repo and be shared by every Mac.

1. In the dotfiles repo, add a `tokenjar` stow package holding `.config/tokenjar/config.json`.
2. Stow it with `--no-folding`, so `~/.config/tokenjar` stays a real folder and only `config.json` is a link. Without it, stow can link the whole folder, and `config.local.json` would end up in the repo.

```
stow --dir=<dotfiles repo> --target="$HOME" --restow --no-folding tokenjar
```

Stow before Tokenjar's first launch on a new Mac. If Tokenjar already wrote a `config.json`, move it into the repo (or out of the way) first, because stow will not replace a real file. Settings saves through the link, so the link survives every save. If the link dangles for a moment (a branch switch in the repo), Tokenjar keeps its current settings and saves nothing until the file is back.

Machine-only values go in `~/.config/tokenjar/config.local.json`, next to the link. It is not stowed, Tokenjar never writes it, and it wins on merge: objects merge key by key, and `accounts` merge by `id`, field by field.

The default `~/.claude` (or `~/.codex`) can be a different login on each Mac: a personal plan on one Mac and a company seat on another. Keep one account for it in the shared file and relabel it on the other Mac with this `config.local.json`:

```json
{
  "accounts": [
    { "id": "claude", "label": "Work" }
  ]
}
```

The plan pill comes from the login itself, so it reads Max on one Mac and Enterprise on the other. A local entry whose `id` is not in `config.json` adds an account, and then needs `provider` too. Such an account stays on this Mac: it is listed after the accounts in `config.json`, Settings never writes it to `config.json`, and a Settings edit to it lasts only until the next reload, so change it in `config.local.json`.

Claude, Codex and GitHub Copilot accounts whose profile folder is missing on a Mac (for Copilot, gh's config folder, `~/.config/gh` by default), OpenCode Go accounts whose credential file (else opencode's default `auth.json`) is missing, and OpenCode Zen accounts without an `opencode.db` are hidden there (Settings lists them as "Not on this Mac"), so one shared file can list `~/.claude-work` and still work on another Mac. Antigravity, Devin and accounts with a pasted API key have no file to check; turn one off on a single Mac with `"enabled": false` in that Mac's `config.local.json`.

Settings keeps keys it does not know when it saves, so a setting a newer build added survives an edit on a Mac that has not updated yet. Builds from before that rule drop such keys, so update every Mac that shares the file together.

Settings writes only `config.json`. Editing a field that `config.local.json` overrides changes the shared value for your other Macs, while this Mac keeps its local one, so change such a field in `config.local.json` by hand.

History and alert state stay on each Mac and are never synced. `tokenjar.sqlite` (usage history and limit samples), `alert-state.json` and `probe-latch.json` live in `~/Library/Application Support/Tokenjar/`. The same account `id` on two Macs keeps two separate histories, which is what lets one id stand for a different login on each. A pasted API key lives only in that Mac's Keychain, so paste it again on each Mac. Launch at login is registered per Mac.

## Make targets

| Target | What it does |
|---|---|
| `make build` | Debug build |
| `make test` | Swift Testing under Command Line Tools (run it with `XDG_CONFIG_HOME` unset) |
| `make release` | Release build |
| `make app` | Release build bundled and signed as `build/Tokenjar.app` |
| `make install` | `make app`, then copy to `~/Applications` and launch |
| `make run` | `make app`, then open `build/Tokenjar.app` |
| `make clean` | Remove `.build` and `build` |

`Scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns` from `Resources/AppIcon.svg`; run it after editing the SVG and commit both.

## Developer flags

The binary takes five flags that do one job and exit:

```
.build/debug/Tokenjar --probe <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]
.build/debug/Tokenjar --capture <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]
.build/debug/Tokenjar --scan <provider> [--profile-dir DIR] [--days N]
.build/debug/Tokenjar --render-snapshots <dir>
.build/debug/Tokenjar --render-windows <dir> [--real-data] [--only <name-prefix>]
```

- `--probe` runs one live check and prints the snapshot as JSON. It runs the real CLI and does not read `config.json` (so `cliPaths` does not apply), and it can spend tokens if `/usage` turns into a model turn. It refuses claude or agy while the app has latched that CLI's binary; use Try Once More in the app first. A Devin probe runs nothing and prints a snapshot with no windows, only its source and notes.
- `--capture` runs the request a check sends, once, and prints its raw answer as one JSON document in which every string outside a pinned allowlist, every numeric id and anything that looks like an email, UUID or key is replaced by `<redacted>`. It is how a plan's answer becomes a test fixture; read the output before sharing it. It refuses a latched CLI like `--probe`. If its own claude or agy run turns into a model turn, it prints no document, only a stop message on stderr, and exits 1.
- `--scan` reads the provider's local history from the start and prints totals and an API-equivalent cost for the last N days (default 30). Antigravity, GitHub Copilot and Devin have no history to scan.
- `--render-snapshots` renders the popover, the menu bar item (every slot state and every icon choice), the dashboard and the General and account Settings pages to PNG, light and dark, from built-in preview data.
- `--render-windows` captures the app's real windows (Settings panes and account pages, the dashboard at three sizes, the popover, menu bar strips) to `<screen>-<light|dark>.png` at 2x, built by the same code the app uses. Each window is parked off every display and the app never activates, so nothing shows on screen and the frontmost app keeps focus; `StrayWindowSweeper` hides any window that lands on a display anyway and prints "stray window hidden" on stderr. Preview data by default; `--real-data` shows this Mac's config and a read-only copy of its history, and `--only` (repeatable) limits the screens by name prefix.

`<provider>` is one of `claude`, `codex`, `opencode-go`, `opencode-zen`, `antigravity`, `copilot`, `devin`. None of the five writes `tokenjar.sqlite` or `config.json`, and none moves Headroom's folders. [docs/privacy.md](docs/privacy.md#what-it-writes) lists what each reads and writes.

## Troubleshooting

- **"Can't find the claude command on this Mac."** (or codex, agy, gh). Tokenjar does not use your shell `PATH`. It looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` and `/usr/bin`, and the account's Settings page says where it looked. Anywhere else, set the full path in config: `"cliPaths": { "claude": "/path/to/claude" }`. A `cliPaths` entry replaces the search, so a wrong path there also reads as not found. When a saved copy exists the card shows it with a note instead (Claude Code's own cache for Claude, the last limits in a session log for Codex).
- **Signed out.** The card's Sign In... button opens the account's Settings page. Sign In in Terminal there runs the provider's own login (`claude auth login`, `codex login`, `opencode auth login`, `gh auth login`) in Terminal, and Copy Command copies it instead. Tokenjar never sees your credentials. With an older claude that has no `auth` command, run `claude` and type `/login`.
- **"No Copilot access for this GitHub account".** GitHub answered 403 or 404, so the gh login Tokenjar uses has no Copilot seat; the card stays gray rather than warning. To track another GitHub login, give the account its own GitHub CLI folder in Settings and sign in to it with the command shown there.
- **A CLI behind a proxy.** Tokenjar passes `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` and their lowercase forms to the CLIs it runs when they are set in its own environment. Opened from Login Items or the Finder, it gets launchd's environment rather than your shell's, so a proxy exported only in `.zshrc` does not reach gh, claude, codex or agy.
- **No notifications.** Alerts need the app bundle, so they never come from `swift run` or a `.build` binary; use the installed copy (`make install`). If they arrive only in Notification Center, click Allow Banners in Settings > Alerts. If macOS has them turned off, the same pane offers Open Notification Settings.
- **"Checks for this account are paused".** The last `/usage` check ran as a model turn and spent tokens (claude) or quota (agy), so Tokenjar stopped checking that account. It checks again once by itself when that CLI updates. Click Try Once More on the card or in Settings to run one check now; if it repeats, checks stop again. Disable turns the account off.
- **"Could not read config.json"** (or `config.local.json`). The file is not valid JSON, often a leftover merge conflict. Tokenjar keeps the last good settings (none, if the file was already broken at launch) and saves nothing until the file loads again. Fix it and save; the app reloads within 30 seconds, or click Reload in Settings > General. "config.json is missing or its link is broken" means the same for a missing file or a dangling stow link.
- **Keychain prompt after an update.** The ad-hoc signature changes on every build, so macOS asks again before Tokenjar can read its own Keychain item. Only API keys you pasted in Settings live there, and each is read once per launch. If you click Deny, the account says "Keychain access was denied" and nothing asks again until you click Try Again on its card or in Settings.
