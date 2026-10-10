# Headroom

A personal macOS menu bar app that shows how much room is left on each AI subscription (Claude, Codex, OpenCode Go/Zen, Antigravity) before the next limit, whether the current pace runs out before the window resets, and what usage costs over time.

It never reads or refreshes an OAuth token. Claude and Codex usage comes from their own CLIs, and the only network request the app makes itself goes to `opencode.ai`. [docs/privacy.md](docs/privacy.md) lists exactly what it reads, runs, sends and stores; [docs/design.md](docs/design.md) has the design.

## Requirements

- macOS 14 or later.
- Command Line Tools with Swift 6.2 or later (`xcode-select --install`, then `swift --version`). Xcode is not needed.
- The CLIs for the accounts you track: `claude`, `codex`, `agy`. OpenCode needs no CLI.

## Install

```
git clone <repo-url> headroom
cd headroom
make install
```

This builds a release binary, bundles `Headroom.app`, signs it ad-hoc, copies it to `~/Applications` and launches it. No admin rights, no quarantine flag, no Gatekeeper prompt. Run `make install` again to update.

### Managed Macs

On a Mac that only runs approved software, an allowlisting tool blocks new ad-hoc signed binaries, and every build is a new binary, so the app will not launch until it is allowlisted.

## Config and sync

Headroom reads `~/.config/headroom/config.json`. It holds no secrets (only references to where API keys live), so it can be stowed from the dotfiles repo and shared between Macs. Settings saves through the symlink, so the link survives.

```json
{
  "refreshMinutes": 10,
  "accounts": [
    { "id": "claude-personal", "provider": "claude", "label": "Personal" },
    { "id": "claude-work", "provider": "claude", "label": "Work", "profileDir": "~/.claude-work" },
    { "id": "codex", "provider": "codex", "label": "Plus" },
    { "id": "opencode-go", "provider": "opencode-go", "label": "Go",
      "credential": { "file": { "path": "~/.local/share/opencode/auth.json", "key": "opencode-go" } } }
  ]
}
```

`config.local.json` in the same folder holds machine overrides. It wins on merge (accounts merge by `id`) and the app never writes it, so keep it out of the dotfiles repo. Accounts whose profile dir or credential file is missing on a machine are hidden there, so one shared file works on every Mac.

Never rename an account `id` once it has data: it is the key for history and alerts.

## Make targets

| Target | What it does |
|---|---|
| `make build` | Debug build |
| `make test` | Swift Testing under Command Line Tools |
| `make release` | Release build |
| `make app` | Release build bundled and signed as `build/Headroom.app` |
| `make install` | `make app`, then copy to `~/Applications` and launch |
| `make run` | `make app`, then open `build/Headroom.app` |
| `make clean` | Remove `.build` and `build` |

`Scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns` from `Resources/AppIcon.svg`; run it after editing the SVG and commit both.

For development, the debug binary has three flags that do one job and exit: `--probe <provider>` prints one fetch as JSON, `--scan <provider> [--days N]` prints history totals, and `--render-snapshots <dir>` renders every surface to PNG from preview data.

## Troubleshooting

- **"claude CLI not found"** (or codex, agy): Headroom does not use your shell `PATH`. It looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.volta/bin` and `/usr/bin`. Anywhere else, set the path in config: `"cliPaths": { "claude": "/path/to/claude" }`.
- **No notifications**: they only work from the installed copy in `~/Applications`, not from `build/` or `swift run`. Run `make install`.
- **Keychain prompt after an update**: the ad-hoc signature changes on every build, so macOS asks again before Headroom can read its own Keychain item. Only API keys you pasted in Settings live there.
