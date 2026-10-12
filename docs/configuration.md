# Configuration

Tokenjar reads `~/.config/tokenjar/config.json` (`$XDG_CONFIG_HOME/tokenjar/config.json` when that variable is set in the app's own environment). It holds no secrets, only references to where API keys live. Settings saves every change to it. You can also edit it by hand; the app picks the change up within 30 seconds, or right away when you click Reload in Settings > General.

[design.md](design.md#config-and-sync) is the full reference, with every default and edge case.

## Example

```json
{
  "refreshMinutes": 10,
  "accounts": [
    { "id": "claude", "provider": "claude", "label": "Personal" },
    { "id": "claude-2", "provider": "claude", "label": "Second login", "profileDir": "~/.claude-2" },
    { "id": "codex", "provider": "codex", "label": "ChatGPT" },
    { "id": "opencode-go", "provider": "opencode-go", "label": "Go",
      "credential": { "file": { "path": "~/.local/share/opencode/auth.json", "key": "opencode-go" } } }
  ]
}
```

## Fields

`provider` is one of `claude`, `codex`, `opencode-go`, `opencode-zen`, `antigravity`, `copilot`, `devin`. `profileDir` is `CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex, `GH_CONFIG_DIR` for GitHub Copilot (a second GitHub login needs its own gh folder), and opencode's data folder for OpenCode. Other account fields: `enabled`, `showInMenuBar`, `refreshMinutes`, `alertThresholds`, `dashboardURL`. Top-level fields: `refreshMinutes`, `menuBar` (`mode`, `icon`, `warnAt`, `criticalAt`, `showResetCountdownWhenFull`), `alerts`, `cliPaths`, `launchAtLogin`, `paceDays`, `hotkey`. `alerts.shortThresholds` (for windows of a day or less), `paceDays` and `hotkey` are kept in the file but have no effect in this build yet: every window alerts at the account's `alertThresholds`, else `alerts.thresholds`. Every field but `id` and `provider` has a default; [design.md](design.md#config-and-sync) has the full list.

Never rename an account `id` once it has data: it is the key for history and alerts.

## Where Tokenjar looks for CLIs

Tokenjar does not use your shell `PATH`. It looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` and `/usr/bin`, and the account's Settings page says where it looked. Anywhere else, set the full path in config: `"cliPaths": { "claude": "/path/to/claude" }`. A `cliPaths` entry replaces the search, so a wrong path there also reads as not found.

## Model prices

Costs are API-equivalent estimates from the prices in `Resources/pricing.json`, which records a source URL and date for each model. To change a price, or to price a model the bundled file does not know, put a `pricing.json` next to `config.json`. Each model there replaces the bundled entry with the same id. [design.md](design.md#pricing) describes the format and how model ids are matched.

## Several Macs

`config.json` holds no secrets, so it can live in a dotfiles repo and be shared by every Mac.

1. In the dotfiles repo, add a `tokenjar` stow package holding `.config/tokenjar/config.json`.
2. Stow it with `--no-folding`, so `~/.config/tokenjar` stays a real folder and only `config.json` is a link. Without it, stow can link the whole folder, and `config.local.json` would end up in the repo.

```sh
stow --dir=<dotfiles repo> --target="$HOME" --restow --no-folding tokenjar
```

Stow before Tokenjar's first launch on a new Mac. If Tokenjar already wrote a `config.json`, move it into the repo (or out of the way) first, because stow will not replace a real file. Settings saves through the link, so the link survives every save. If the link dangles for a moment, during a branch switch in the repo for example, Tokenjar keeps its current settings and saves nothing until the file is back.

### Values for one Mac

Machine-only values go in `~/.config/tokenjar/config.local.json`, next to the link. It is not stowed, Tokenjar never writes it, and it wins on merge: objects merge key by key, and `accounts` merge by `id`, field by field.

The default `~/.claude` (or `~/.codex`) can hold a different login on each Mac, such as a personal Mac and a work Mac. Keep one account for it in the shared file and give it another label on one Mac with a `config.local.json` like this:

```json
{
  "accounts": [
    { "id": "claude", "label": "Work" }
  ]
}
```

The plan pill comes from the login itself, so each Mac shows the plan it is signed in to. A local entry whose `id` is not in `config.json` adds an account, and then needs `provider` too. Such an account stays on that Mac. It is listed after the accounts in `config.json`, and Settings never writes it to `config.json`. A Settings edit to it lasts only until the next reload, so change it in `config.local.json`.

### Accounts missing on a Mac

An account is hidden on a Mac that lacks what it reads, and Settings lists it there as "Not on this Mac". That covers Claude, Codex and GitHub Copilot accounts whose profile folder is missing (for Copilot, gh's config folder, `~/.config/gh` by default), OpenCode Go accounts whose credential file (else opencode's default `auth.json`) is missing, and OpenCode Zen accounts without an `opencode.db`. One shared file can therefore list a second profile folder that exists on only one of your Macs. Antigravity, Devin and accounts with a pasted API key have no file to check. To turn one of those off on a single Mac, set `"enabled": false` in that Mac's `config.local.json`.

### What Settings saves

Settings writes only `config.json`. Editing a field that `config.local.json` overrides changes the shared value for your other Macs, while this Mac keeps its local one, so change such a field in `config.local.json` by hand.

Settings keeps keys it does not know when it saves, so a setting a newer build added survives an edit on a Mac that has not updated yet. Builds from before that rule drop such keys, so update every Mac that shares the file together.

### What stays on each Mac

History and alert state are never synced. `tokenjar.sqlite` (usage history and limit samples), `alert-state.json` and `probe-latch.json` live in `~/Library/Application Support/Tokenjar/`. The same account `id` on two Macs keeps two separate histories, which is what lets one id stand for a different login on each. A pasted API key lives only in that Mac's Keychain, so paste it again on each Mac. Launch at login is set per Mac as well.
