# Troubleshooting

## "Can't find the claude command on this Mac" (or codex, agy, gh)

Tokenjar does not use your shell `PATH`; it searches a fixed list of folders, and the account's Settings page says where it looked. [configuration.md](configuration.md#where-tokenjar-looks-for-clis) lists the folders and shows how to point `cliPaths` at a CLI that lives elsewhere. When a saved copy exists, the card shows it with a note instead: Claude Code's own cache for Claude, or the last limits in a session log for Codex.

## Signed out

The card's Sign In... button opens the account's Settings page. Sign In in Terminal there runs the provider's own login (`claude auth login`, `codex login`, `opencode auth login`, `gh auth login`) in Terminal, and Copy Command copies it instead. Tokenjar never sees your credentials. With an older claude that has no `auth` command, run `claude` and type `/login`.

## "No Copilot access for this GitHub account"

GitHub answered 403 or 404, so the gh login Tokenjar uses has no Copilot seat. The card stays gray and raises no warning. To track another GitHub login, give the account its own GitHub CLI folder in Settings and sign in to it with the command shown there.

## A CLI behind a proxy

Tokenjar passes `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` and their lowercase forms to the CLIs it runs when they are set in its own environment. Opened from Login Items or the Finder, it gets launchd's environment rather than your shell's, so a proxy exported only in `.zshrc` does not reach gh, claude, codex or agy.

## No notifications

Alerts need the app bundle, so they never come from `swift run` or a `.build` binary; use the installed copy (`make install`). If they arrive only in Notification Center, click Allow Banners in Settings > Alerts. If macOS has them turned off, the same pane offers Open Notification Settings.

## "Checks for this account are paused"

The last `/usage` check ran as a model turn and spent tokens (claude) or quota (agy), so Tokenjar stopped checking that account. It checks again once by itself when that CLI updates. Click Try Once More on the card or in Settings to run one check now. If it happens again, checks stop again. Disable turns the account off.

## "Could not read config.json" (or config.local.json)

The file is not valid JSON, often because of a leftover merge conflict. Tokenjar keeps the last good settings (none, if the file was already broken at launch) and saves nothing until the file loads again. Fix it and save; the app reloads within 30 seconds, or click Reload in Settings > General. "config.json is missing or its link is broken" means the same for a missing file or a dangling stow link.

## Keychain prompt after an update

The ad-hoc signature changes on every build, so macOS asks again before Tokenjar can read its own Keychain item. Only API keys you pasted in Settings live there, and each is read once per launch. If you click Deny, the account says "Keychain access was denied" and nothing asks again until you click Try Again on its card or in Settings.

## A new build will not launch

If your Mac only runs approved software, through a binary allowlist for example, each `make install` produces a new ad-hoc signed build that needs approval before it can launch.
