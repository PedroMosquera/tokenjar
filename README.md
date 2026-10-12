<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/banner-dark.svg">
  <img alt="Tokenjar: how much room is left on your AI plans" src="docs/images/banner-light.svg">
</picture>

Tokenjar is a macOS menu bar app that shows how much of each AI plan's usage limit you have left, and whether you will hit it before it resets. It covers Claude, Codex, OpenCode Go and Zen, Antigravity and GitHub Copilot. Devin gets a card that opens its usage page.

I built it because I did not want a third-party app handling my AI logins. Tokenjar asks each provider's own CLI for the numbers, except for OpenCode, where it reads opencode's key and local database. History stays on your Mac. There is no prebuilt download: you build it from source with the Command Line Tools.

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

## Using it

The menu bar item shows the used percent of the account with the least room left. By default it turns red at 95% and amber at 80%, or sooner when a window that is at least half used is on pace to run out before it resets. When a window is full it counts down to the reset instead. A slash across the icon means Tokenjar can't refresh right now, because the Mac is offline or no provider answered. Faded numbers are out of date, and a dot means something needs you: a failed check you can fix, or settings that can't be read. Devin and OpenCode Zen never show up there. Settings > General changes both levels and can switch the item to one thin bar per account, or to the icon alone.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/menubar-dark.png">
    <img src="docs/images/menubar-light.png" width="424" alt="Menu bar items at 30, 88 and 97 percent used, a full window showing 47m until its reset, then the Bars and Icon only modes">
  </picture>
</p>

Clicking it opens the popover shown at the top. Each limit window gets a bar with a tick where an even pace would be, and the time until it resets. The line under the bars says how you are tracking, such as "Under pace -6%" or "Runs out ~1d 17h before reset". A failed check says what went wrong and offers the fix. When the Mac is offline or no provider answers, the header says so once and the cards keep their last numbers with their age. Command-R refreshes.

Right-click the menu bar item, or Control-click it, for Refresh Now, Open Dashboard, Settings and Quit Tokenjar. Quitting from that menu, the popover or Command-Q asks first. Hold Option in the menu to quit without being asked.

The dashboard (Command-D) charts each limit over time with its resets and estimates what your usage would have cost at API prices, split by model, harness, project or account. Antigravity and Copilot keep no local logs, so they show limits only.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/dashboard-dark.png">
    <img src="docs/images/dashboard-light.png" width="860" alt="The dashboard with an account sidebar, cost tiles for today, 7 days and this month, a chart of each account's tightest limit over a week, and daily spend by model">
  </picture>
</p>

Each account gets its own page in Settings with its status, the fix when a check fails, and buttons to check it now or sign in from Terminal.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-account-dark.png">
    <img src="docs/images/settings-account-light.png" width="680" alt="An account page in Settings: status, enabled and menu bar switches, the profile folder for a second Claude login, and the command Sign In in Terminal runs">
  </picture>
</p>

Alerts are local notifications. By default you get one when a window crosses 80% or 95%, when the pace says you will run out before the reset, and when a source stops working. Settings > Alerts changes the levels and has a reset alert, which is off by default. Until you click Allow Banners there, alerts go to Notification Center without a banner.

## Privacy

Tokenjar never reads or refreshes an OAuth token; each CLI keeps and renews its own login. The one request the app sends itself is `GET https://opencode.ai/zen/go/v1/usage`, and a test fails if another endpoint is added. The Copilot request is gh's own, with gh's telemetry turned off. Tokenjar itself has no telemetry and no update check, and it never imports browser cookies.

On disk it keeps token counts, model ids, timestamps and project folder names, plus each account's plan name, limit percentages and reset times. Log paths and response ids are stored only as SHA-256 digests. Prompts, outputs, emails and provider account ids are never stored. Settings > About lists what the app runs, reads, contacts and writes, and [docs/privacy.md](docs/privacy.md) has the full list.

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

To update, pull and run `make install` again. It quits the Tokenjar running from the install folder, replaces it and opens the new build. A copy started anywhere else, such as by `make run` or a `.build` binary, keeps running. If you pasted an API key in Settings, macOS asks once more for Keychain access after each update, because every build gets a new ad-hoc signature.

To remove it, turn off Launch at login, quit Tokenjar and delete `~/Applications/Tokenjar.app`. To clear its data as well, delete `~/Library/Application Support/Tokenjar` (history) and `~/.config/tokenjar` (settings), run `defaults delete com.pedromosquera.tokenjar` (window sizes and positions), and remove any "Tokenjar API key" item in Keychain Access. [docs/privacy.md](docs/privacy.md#what-it-writes) lists everything it writes. These steps have not been tested on a clean Mac.

## First run

If there is no config file yet, Tokenjar writes one with default settings and the accounts it finds: Claude Code in `~/.claude`, a Codex login, opencode's API keys (Zen stays off the menu bar), `agy` and `gh` if they are installed, and a Devin or Windsurf install. It looks for `gh` but does not run it. If you used CodexBar, Settings > General > Import from CodexBar shows what would change before it changes anything.

## Configuration

Settings writes everything to `~/.config/tokenjar/config.json`, and you can edit it by hand too: the app picks up changes within 30 seconds. Two Claude logins look like this:

```json
{
  "accounts": [
    { "id": "claude", "provider": "claude", "label": "Personal" },
    { "id": "claude-work", "provider": "claude", "label": "Work", "profileDir": "~/.claude-work" }
  ]
}
```

Pick an `id` once and keep it. History and alerts are stored under it.

The file holds no secrets, only where keys live, so it can sit in a dotfiles repo and be symlinked into place on each Mac (`stow --no-folding` works). Anything that should differ on one Mac, such as a label, goes in `config.local.json` next to it. History, alert state and pasted keys stay on each Mac. [docs/configuration.md](docs/configuration.md) has every field and the details of the shared setup.

## Troubleshooting

"Can't find the claude command on this Mac" (or codex, agy, gh): Tokenjar does not read your shell's `PATH`. It searches a fixed list of folders, and the account's page in Settings shows which ones. If the CLI lives somewhere else, put its full path under `cliPaths` in the config.

No notifications: alerts only come from the installed app, not from `swift run` or a `.build` binary.

[docs/troubleshooting.md](docs/troubleshooting.md) covers sign-in, Copilot access, proxies, paused checks, a broken config file, the Keychain prompt and Macs that only run approved software.

## Development

```sh
make build   # debug build
make test    # Swift Testing; run it with XDG_CONFIG_HOME unset
make app     # release build, bundled and signed as build/Tokenjar.app
```

`.build/debug/Tokenjar --render-snapshots <dir>` and `--render-windows <dir>` draw the app to PNG from built-in preview data, without putting a window on screen. The screenshots in this README come from those two flags, so the accounts, numbers and dates in them are made up. [docs/development.md](docs/development.md) has the other targets and flags, and [docs/design.md](docs/design.md) is the full design.

## License

Tokenjar is under the [MIT License](LICENSE). The provider logos in the app and in these screenshots belong to their owners; [docs/logos.md](docs/logos.md) says where each came from. The logos and a few test fixtures keep their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Tokenjar is not affiliated with or endorsed by Anthropic, OpenAI, Google, GitHub, OpenCode, Cognition, Windsurf or CodexBar.
