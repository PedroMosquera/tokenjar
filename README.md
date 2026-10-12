<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/banner-dark.svg">
  <img alt="Tokenjar: how much room is left on your AI plans" src="docs/images/banner-light.svg">
</picture>

Tokenjar is a macOS menu bar app that shows how much of each AI plan's usage limit you have left, and whether you will hit it before it resets. It covers Claude, Codex, OpenCode Go and Zen, Antigravity and GitHub Copilot. Devin gets a card that opens its usage page.

I built it for myself because I did not want a third-party app handling my AI logins, so Tokenjar asks each provider's own CLI for the numbers and keeps its history on your Mac. There is no prebuilt download. You build it from source with the Command Line Tools.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/popover-dark.png">
    <img src="docs/images/popover-light.png" width="360" alt="The Tokenjar popover: a card per account with a bar for each limit window, its used percent and time to reset, and a line saying whether the week runs out before it resets">
  </picture>
</p>

## What it tracks

| Provider | Where the numbers come from | Plans it recognizes |
|---|---|---|
| Claude | `claude -p /usage`, with hooks and MCP servers off | Pro, Max, Max 5x, Max 20x, Team, Team Premium, Enterprise. API key, Bedrock, Vertex and Foundry logins have no plan limits, so they get cost history only. |
| Codex | `codex app-server`, read-only | Free, Go, Plus, Pro, Business, Edu, Enterprise |
| OpenCode Go | One HTTPS GET to opencode.ai with your opencode key | Go |
| OpenCode Zen | This month's spend, added up from the local `opencode.db` | Pay as you go |
| Antigravity | `agy -p /usage` (agy 1.1.11 or later) | No plan name. Each quota pool agy reports becomes a limit. |
| GitHub Copilot | `gh api`, a read-only GET | Free, Pro, Pro+, Max, Business, Enterprise |
| Devin, which now includes Windsurf | Nothing yet. Devin shares no usage with local apps, so its card opens the usage page. | |

The Antigravity reader has never run against a live install. Copilot's endpoint is undocumented, and most Copilot plans have not been checked against a real account.

## A quick look

The menu bar item shows the account with the least room left. It turns amber at 80% used, or earlier when a half-used window is on pace to run out before it resets, and red at 95%. When a window is full it counts down to the reset instead. Settings > General switches it to one thin bar per account, or to the icon alone.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/menubar-dark.png">
    <img src="docs/images/menubar-light.png" width="424" alt="Menu bar items at 30, 88 and 97 percent used, a full window showing 47m until its reset, then the Bars and Icon only modes">
  </picture>
</p>

Clicking it opens the popover above. Each limit window gets a bar, with a tick where an even pace would be, and the time until it resets. Under the bars, a short verdict says whether you are on pace or, say, "Runs out ~40m before reset". A failed check says what went wrong and offers the fix. Command-R refreshes.

The dashboard (Command-D) lists every account with its tightest limit. It shows what your usage would have cost at API prices today, over 7 days and this month, and charts each limit over time with its resets. Below that sit daily spend, split by model, harness, project or account, and your top projects. Ranges are 24 hours, 7 days and 30 days. Cost comes from local logs, so Antigravity and Copilot, which keep none, show limits only.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/dashboard-dark.png">
    <img src="docs/images/dashboard-light.png" width="860" alt="The dashboard with an account sidebar, cost tiles for today, 7 days and this month, a chart of each account's tightest limit over a week, and daily spend by model">
  </picture>
</p>

Settings has four panes. General covers launch at login, how often to check and how the menu bar item looks. Accounts has a page per account with its status, the fix when a check fails, Check Now and Sign In in Terminal. Alerts holds the notification settings, and About lists what the app runs, reads, contacts and writes.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-account-dark.png">
    <img src="docs/images/settings-account-light.png" width="680" alt="An account page in Settings: status, enabled and menu bar switches, the profile folder for a second Claude login, and the command Sign In in Terminal runs">
  </picture>
</p>

Alerts are local notifications. You get one when a window crosses 80% or 95%, when the pace says you will run out before the reset, and when a source stops working. A reset alert is there too, off by default. They land quietly in Notification Center until you click Allow Banners in Settings > Alerts.

## Privacy

Tokenjar never reads or refreshes an OAuth token; each CLI keeps and renews its own login. The one request the app sends itself is `GET https://opencode.ai/zen/go/v1/usage`, and a test fails if another endpoint is added. The Copilot request is gh's own, with gh's telemetry turned off. It sends no telemetry, never checks for updates and never imports browser cookies.

On disk it keeps token counts, model ids, timestamps and project folder names. Log paths and response ids are stored only as SHA-256 digests. Prompts, outputs, emails and account ids are never stored. [docs/privacy.md](docs/privacy.md) has the full list, and Settings > About shows the short version.

## Requirements

- macOS 14 or later.
- Command Line Tools with Swift 6.2 or later (`xcode-select --install`). Xcode is not needed.
- The CLI for each provider you track: `claude`, `codex`, `agy` 1.1.11 or later, and `gh` signed in with `gh auth login`. OpenCode and Devin need none.

## Install

```sh
git clone https://github.com/PedroMosquera/tokenjar.git
cd tokenjar
make install
```

That builds a release binary, wraps it in `Tokenjar.app`, signs it ad-hoc, copies it to `~/Applications` and opens it. It needs no admin rights and shows no Gatekeeper prompt. `make install INSTALL_DIR=<folder>` puts it somewhere else. Tokenjar has no Dock icon, except while the dashboard or Settings is open. Launch at login stays off until you turn it on in Settings > General.

To update, pull and run `make install` again. It replaces the running app and opens the new build. If you pasted an API key in Settings, macOS asks once more for Keychain access after each update, because every build gets a new ad-hoc signature.

To remove it, turn off Launch at login, quit Tokenjar and delete `~/Applications/Tokenjar.app`. If you want its data gone too, delete `~/Library/Application Support/Tokenjar` (history) and `~/.config/tokenjar` (settings), plus any "Tokenjar API key" item in Keychain Access. I put this list together from what the app writes ([docs/privacy.md](docs/privacy.md#what-it-writes)) and have not tried it on a clean Mac.

## First run

If there is no config file yet, Tokenjar writes one with default settings and the accounts it finds: Claude Code in `~/.claude`, a Codex login, opencode's API keys (Zen stays off the menu bar), `agy` and `gh` if they are installed, and a Devin or Windsurf install. It looks for `gh` but does not run it. If you used CodexBar, Settings > General > Import from CodexBar shows what would change before it changes anything.

## Configuration

Settings writes everything to `~/.config/tokenjar/config.json`, and you can edit it by hand too: the app picks up changes within 30 seconds. The file holds no secrets, only where keys live. Two Claude logins look like this:

```json
{
  "accounts": [
    { "id": "claude", "provider": "claude", "label": "Personal" },
    { "id": "claude-2", "provider": "claude", "label": "Second login", "profileDir": "~/.claude-2" }
  ]
}
```

Pick an `id` once and keep it. History and alerts are stored under it.

Because there are no secrets in it, the file can live in a dotfiles repo and be symlinked into place on each Mac (`stow --no-folding` works). Anything that should differ on one Mac, such as a label, goes in `config.local.json` next to it. History, alert state and pasted keys stay on each Mac. [docs/configuration.md](docs/configuration.md) has every field and the details of the shared setup.

## Troubleshooting

"Can't find the claude command on this Mac" (or codex, agy, gh): Tokenjar does not read your shell's `PATH`. It searches a fixed list of folders, and the account's page in Settings shows which ones. If the CLI lives somewhere else, put its full path under `cliPaths` in the config.

No notifications: alerts only come from the installed app, not from `swift run` or a `.build` binary. If they show up only in Notification Center, click Allow Banners in Settings > Alerts.

[docs/troubleshooting.md](docs/troubleshooting.md) covers sign-in, Copilot access, proxies, paused checks, a broken config file and the Keychain prompt.

## Development

```sh
make build   # debug build
make test    # Swift Testing; run it with XDG_CONFIG_HOME unset
make app     # release build, bundled and signed as build/Tokenjar.app
```

`.build/debug/Tokenjar --render-snapshots <dir>` and `--render-windows <dir>` draw the app to PNG from built-in preview data, without putting a window on screen. That is how the images in this README were made. [docs/development.md](docs/development.md) has the other targets and flags, and [docs/design.md](docs/design.md) explains how the pieces fit.

## License

I have not picked a license yet, so there is no license file. The provider logos in the app and in these screenshots belong to their owners; [docs/logos.md](docs/logos.md) says where each came from.
