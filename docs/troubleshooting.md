# Troubleshooting

## "Can't find the claude command on this Mac" (or codex, agy, gh)

Tokenjar does not use your shell `PATH`; it searches a fixed list of folders, and the account's Settings page says where it looked. [configuration.md](configuration.md#where-tokenjar-looks-for-clis) lists the folders and shows how to point `cliPaths` at a CLI that lives elsewhere. When a saved copy exists, the card shows it with a note instead: Claude Code's own cache for Claude, or the last limits in a session log for Codex.

## Signed out

The card's Sign In... button opens the account's Settings page. Sign In in Terminal there runs the provider's own login (`claude auth login`, `codex login`, `opencode auth login`, `gh auth login`) in Terminal, and Copy Command copies it instead. Tokenjar never sees your credentials. With an older claude that has no `auth` command, run `claude` and type `/login`.

### Claude says Signed out, but Claude Code works in your terminal

Your Claude Code probably uses an API key, a gateway such as LiteLLM, or a cloud provider such as Bedrock, set up with variables exported in your shell (`.zshrc` and the like). Tokenjar never reads your shell, so the `claude` it runs sees no login. Move those variables into the `env` block of Claude Code's own settings, `~/.claude/settings.json` (or `settings.json` in the account's profile folder). Claude Code then uses them everywhere, and Tokenjar sees that the login has no plan limits. For a LiteLLM gateway:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm.example.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-your-litellm-key"
  }
}
```

To keep the key out of that file, leave `ANTHROPIC_AUTH_TOKEN` out and set `"apiKeyHelper"` to a script that prints the key, such as one that reads it from Keychain. Tokenjar only checks which of these are set, never their values. The card then says "No plan limits for this login" and shows this month's spend, estimated at list price from Claude Code's local logs; a gateway that routes to other models or bills at other rates will differ. To make the card's Open Usage Page go to your gateway's own dashboard, set Usage page URL on the account's page in Settings. Settings an administrator deploys in `/Library/Application Support/ClaudeCode/managed-settings.json` count too.

## "No Copilot access for this GitHub account"

GitHub answered 403 or 404, so the gh login Tokenjar uses has no Copilot seat. The card stays gray and raises no warning. To track another GitHub login, give the account its own GitHub CLI folder in Settings and sign in to it with the command shown there.

## A CLI behind a proxy

Tokenjar passes `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` and their lowercase forms to the CLIs it runs when they are set in its own environment. Opened from Login Items or the Finder, it gets launchd's environment rather than your shell's, so a proxy exported only in `.zshrc` does not reach gh, claude, codex or agy.

## No notifications

Alerts need the app bundle, so they never come from `swift run` or a `.build` binary; use the installed copy in `~/Applications` (from `make install` or `tokenjar-install-app`). If they arrive only in Notification Center, click Allow Banners in Settings > Alerts. If macOS has them turned off, the same pane offers Open Notification Settings.

## "Checks for this account are paused"

The last `/usage` check ran as a model turn and spent tokens (claude) or quota (agy), so Tokenjar stopped checking that account. It checks again once by itself when that CLI updates. Click Try Once More on the card or in Settings to run one check now. If it happens again, checks stop again. Disable turns the account off.

## "Could not read config.json" (or config.local.json)

The file is not valid JSON, often because of a leftover merge conflict. Tokenjar keeps the last good settings (none, if the file was already broken at launch) and saves nothing until the file loads again. Fix it and save; the app reloads within 30 seconds, or click Reload in Settings > General. "config.json is missing or its link is broken" means the same for a missing file or a dangling stow link.

## Keychain prompt after an update

The ad-hoc signature changes on every build, so macOS asks again before Tokenjar can read its own Keychain item. Only API keys you pasted in Settings live there, and each is read once per launch. If you click Deny, the account says "Keychain access was denied" and nothing asks again until you click Try Again on its card or in Settings. `brew upgrade` and `brew reinstall` rebuild the app too, so the prompt comes back once `tokenjar-install-app` puts the new build in place.

## `brew install` fails with "is using Swift tools version 6.2.0"

Homebrew builds Tokenjar with your developer tools, and the build needs Swift 6.2 or later (`swift --version` shows yours). With older tools, Homebrew may first warn that a newer Command Line Tools release is available, or that your Xcode is outdated, and then the build fails and Homebrew shows the last 15 lines of the build log, which say the package is using Swift tools version 6.2.0 but the installed version is older. Update the Command Line Tools from Software Update in System Settings (macOS 15.6 or later is needed). If `xcode-select -p` prints a path inside an Xcode app instead of `/Library/Developer/CommandLineTools`, that Xcode's Swift is used: update it to Xcode 26 or later, or switch to the Command Line Tools with `sudo xcode-select --switch /Library/Developer/CommandLineTools`. Then run the install again. Report any other build failure in this repository's issues, even if Homebrew's message points to the tap's.

## A new build will not launch

If your Mac only runs approved software, through a binary allowlist for example, each `make install`, `brew install`, `brew upgrade` or `brew reinstall` produces a new ad-hoc signed build that needs approval before it can launch.
