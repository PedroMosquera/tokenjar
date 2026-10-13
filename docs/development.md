# Development

Tokenjar builds with the Command Line Tools: Swift 6.2 or later, no Xcode and no package dependencies. It links the system SQLite.

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

`Scripts/make-icon.sh` rebuilds `Resources/AppIcon.icns` from `Resources/AppIcon.svg`. Run it after editing the SVG and commit both.

## Tests

There are two Swift Testing targets. `TokenjarCoreTests` runs the fetchers against recorded or hand-written fixtures, plus the scanners, the store, alerts, pricing, config and discovery. `TokenjarTests` covers the app module: the model with fake fetchers in a temporary home, the popover, the dashboard math, the menu bar and the Settings logic. [design.md](design.md#tests) names the tests that pin the privacy rules.

`make test` passes the plugin and framework paths that Swift Testing needs under the Command Line Tools. Run it with `XDG_CONFIG_HOME` unset: `AppPaths` honors that variable, so some config tests would write into your real config folder. Tests never touch the real Keychain, notifications or login items.

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

`<provider>` is one of `claude`, `codex`, `opencode-go`, `opencode-zen`, `antigravity`, `copilot`, `devin`. None of the five writes `tokenjar.sqlite` or `config.json`, and none moves the folders left by Headroom, Tokenjar's old name. [privacy.md](privacy.md#what-it-writes) lists what each reads and writes.

`renders/` and `captures/` at the repository root are for real-data renders and captures: they hold your own data, and `.gitignore` keeps them out of git. A real-data render also copies your history into a `.tokenjar-render-<id>` folder next to `<dir>` while it runs. A killed run leaves that copy behind, so delete it; `.gitignore` covers it at the repository root.

```sh
.build/debug/Tokenjar --render-windows renders --real-data
mkdir -p captures && .build/debug/Tokenjar --capture codex > captures/codex.json
```

## Preview renders and the README images

Preview renders read no path, region or time zone from your Mac. The accounts, numbers and the fixed date in the preview data are made up. The preview models use a stand-in home folder, `/Users/you`, and the process switches to US English and UTC before it draws, so a render shows the same data on any Mac. The window backgrounds still follow the macOS version that draws them, so re-render the window images together rather than one alone. A render with `--real-data` shows your own config and history, so keep those images to yourself.

The images in `docs/images/` came from these two commands, then a pass that resizes them and rounds their corners:

```sh
make build
.build/debug/Tokenjar --render-windows <dir> --only popover --only dashboard-all --only settings-account-claude-work
.build/debug/Tokenjar --render-snapshots <dir>
```

- `popover-*.png` is `popover-<theme>.png` from `--render-windows`, kept at 720 px wide.
- `popover-spend-limit-*.png` is `popover-spend-limit-<theme>.png`, also 720 px wide. `--only popover` renders it too.
- `dashboard-*.png` is `dashboard-all-default-<theme>.png`, resized to 1720 px wide.
- `settings-account-*.png` is `settings-account-claude-work-<theme>.png`, resized to 1360 px wide.
- `menubar-*.png` joins six items from `--render-snapshots` into one strip: `menubar-slot-030`, `menubar-worst`, `menubar-slot-critical` and `menubar-slot-100`, then `menubar-bars` and `menubar-icon`. Those files are Display P3, so they are converted to sRGB first.

The window captures get rounded corners (24 px on the popovers, 22 px on the windows) and a 2 px edge, white at 16% on dark and black at 16% on light; the menu bar strip gets rounded corners only. Each image is saved with no metadata, at about twice the width the README shows it at. The banner, `banner-<theme>.svg`, is a plain SVG built from `Resources/AppIcon.svg` and the shape of the menu bar slot. Its numbers are made up, and it has no provider logos.

## Releasing

A release is a tag on `main` with a GitHub release for it, plus the Homebrew formula `tokenjar.rb` in [PedroMosquera/homebrew-tap](https://github.com/PedroMosquera/homebrew-tap) pointing at that tag. There is no prebuilt app. The formula downloads the tag's source archive, runs `make app SWIFT_FLAGS="--disable-sandbox --manifest-cache local"` with network access denied, and installs `Scripts/install.sh` as the `tokenjar-install-app` command. So a change to the `release` or `app` targets, to `Scripts/bundle.sh` or to `Scripts/install.sh` reaches Homebrew users at the next release.

1. Check that `VERSION` holds the version being released. The app's version comes from it, and step 5 checks that the built app reports it.
2. Tag the commit on `main` and push the tag: `git tag v<version>`, then `git push origin v<version>`.
3. Get the checksum of the archive Homebrew will download: `curl -fsSLo tokenjar.tar.gz https://github.com/PedroMosquera/tokenjar/archive/refs/tags/v<version>.tar.gz && shasum -a 256 tokenjar.tar.gz`. It prints no checksum if the download fails, for example before the tag is pushed.
4. In the tap, set `url` and `sha256` in `tokenjar.rb` to the new tag and checksum, commit as `tokenjar <version>` and push.
5. Check it with a real install: `brew update`, then `brew upgrade tokenjar`, or `brew install PedroMosquera/tap/tokenjar` on a Mac that does not have it yet. Then `codesign --verify --strict "$(brew --prefix)/opt/tokenjar/Tokenjar.app"` must pass, `plutil -extract CFBundleShortVersionString raw "$(brew --prefix)/opt/tokenjar/Tokenjar.app/Contents/Info.plist"` must print the new version, and `cat "$(brew --prefix)/bin/tokenjar-install-app"` must name the new version's `libexec/install.sh`.
6. Once those checks pass, create a GitHub release for the tag, with short notes and no uploaded files. Tokenjar has no update check, so this is how people who watch the repository's releases hear about a new version, and by then Homebrew can install it.

A release does not run `brew test` or `brew audit`. They are Homebrew developer commands, and running one turns on Homebrew's developer mode, which moves `brew update` to Homebrew's `main` branch and installs gems that `brew developer off` leaves behind.
