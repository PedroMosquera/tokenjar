# In-app update, Update in Terminal, and failure reports

Date: 2026-11-04. Status: approved in conversation. Extends `2026-11-04-update-check-design.md` and replaces its non-goal "Tokenjar never updates itself".

## Why

The update check tells people a version exists, but updating still means opening a terminal and typing a command. Most people who install a menu bar app expect a button. When an update fails, the person has no easy way to tell the maintainer what went wrong, and the maintainer has no way to find out at all, because Tokenjar has no telemetry and must keep it that way.

The model is Sparkle, the update framework most Mac apps outside the App Store use: check automatically, ask before installing, and offer fully silent installs only as an opt-in.

## Goals

1. When a newer version is known, Settings > About shows **Update Now** as the main button and **Update in Terminal** as the second. The copy-only command rows stay below them.
2. **Update Now** builds the new version in the background, shows progress in About, then quits Tokenjar and opens the new version, as `make install` does today.
3. **Update in Terminal** opens Terminal running the same update, so the person can watch it.
4. On Automatic, the "new version" notification gains an **Update Now** action button that starts the same update without opening Settings.
5. Under Automatic, a checkbox **Install updates automatically**, off by default. When it is on, a new version found by the daily check is built in the background and installed with no click, and the swap waits until no Tokenjar window is open.
6. When an update fails, About shows **Report This Problem**, which opens a prefilled GitHub issue in the browser, and **Reveal Log**, which shows the full build log in Finder.
7. After an update succeeds, the new version posts one notification, `Tokenjar updated to <version>`, which opens About on click. An automatic install that fails posts one notification, `Tokenjar couldn't update to <version>`, which also opens About.

## Non-goals

- Cancelling a build in progress.
- Retrying a failed automatic install in the background. Each version is tried automatically once; Update Now stays available.
- Creating the GitHub issue from the app (through the API or the user's `gh` login). The person submits it in the browser.
- Crash reporting, analytics, or sending the log anywhere.
- Updating a `make install` copy in its clone. Update Now always uses Homebrew or the release archive (see Constraints).
- Downgrades, prerelease channels, choosing a version.

## Anti-goals

- Anything installing without a click unless **Install updates automatically** is on.
- The app quitting while a Tokenjar window is open because of a silent install.
- A failed update leaving the person without a working Tokenjar.
- The person's home folder path or username in a prefilled issue.
- Running a script freshly downloaded from the network at update time.
- An upgrade turning on silent installs by itself. A missing preference reads as off.

## Hazards

Blast radius: with silent installs on, a release tag runs a build on every such Mac, and nothing can switch that off remotely. Contract: the privacy docs and the About lists change. Durability: the swap replaces the installed app.

## Constraints

- **Install method.** If Homebrew's copy exists (`/opt/homebrew/opt/tokenjar/Tokenjar.app` or `/usr/local/opt/tokenjar/Tokenjar.app`), the update uses Homebrew: build with `brew upgrade tokenjar`, swap with that prefix's `bin/tokenjar-install-app`. Otherwise it uses the release archive through the `get.sh` copy bundled inside the app (`Contents/Resources/get.sh`, added by `Scripts/bundle.sh`), with `TOKENJAR_VERSION` pinned to the version found. A `make install` user who clicks Update Now therefore moves to release builds; the docs say so and repeat the existing advice to run `make clean` in the clone.
- **Two phases, so the swap can wait.** Phase 1 builds without touching the installed app. Phase 2 swaps. For the archive path, `get.sh` gains a stage mode: with `TOKENJAR_STAGE_DIR=<dir>` set, it builds and copies `Tokenjar.app` and `Scripts/install.sh` into `<dir>` instead of installing, so phase 2 runs `<dir>/install.sh` with `TOKENJAR_APP=<dir>/Tokenjar.app`. The stage folder is `~/Library/Application Support/Tokenjar/update/`, replaced on each attempt and deleted after a successful swap. For Homebrew, `brew upgrade tokenjar` is phase 1 and `tokenjar-install-app` is phase 2.
- **Where it installs.** Phase 2 installs into the folder that holds the running app (`Bundle.main.bundleURL`'s parent), passed as the folder argument to `install.sh` or `tokenjar-install-app`, so the copy being replaced is the one that is running and `install.sh`'s `pkill` matches it. When that folder is not writable, Update Now is disabled with a line saying why, and Update in Terminal stays available.
- **Building without installing.** The archive path's stage mode runs `make app` (which already builds `build/Tokenjar.app` without installing) and copies `build/Tokenjar.app` and `Scripts/install.sh` into the stage folder before the temporary folder is deleted. `install.sh` with `TOKENJAR_APP` set never looks for files beside itself, so the copied script works alone. For Homebrew, after `brew upgrade tokenjar` the app reads the keg's `Tokenjar.app` version; if it is older than the version being installed (the tap is not updated yet), phase 1 fails with a message saying Homebrew does not have that version yet. A `brew upgrade` that does nothing because the keg is already current is not a failure.
- **The swap never leaves the folder empty.** `install.sh` changes to copy the new app next to the old one first (`.Tokenjar.app.new` in the install folder), verify its signature there, then quit the running copy and swap by renaming, removing the old copy last. If the copy or the check fails, the old app is untouched. This also protects `make install`, `tokenjar-install-app` and the curl installer, which all run the same script.
- **When the swap runs.** From Update Now (in About or the notification action), right after phase 1 succeeds. From a silent install, at the first tick after phase 1 when no Tokenjar window (popover, dashboard, Settings) is open.
- **The swap outlives the app.** `install.sh` quits the running Tokenjar with `pkill`, so phase 2 runs as a process that is not a child the app waits on and survives the app's exit. Before it starts, the app stores `updateSwappingTo = <version>`. On the next launch, if the installed version equals it, the app posts the "updated" notification and clears the key. If the installed version is older, the swap failed: the app shows the failure in About and clears the key. The installed version is the running bundle's `CFBundleShortVersionString`.
- **Environment for the build.** A GUI app has no shell `PATH`, so the update processes get `PATH` with the Homebrew prefix's `bin`, `/usr/bin`, `/bin`, `/usr/sbin` and `/sbin`, plus `HOME`. They run at utility priority, below the app's own work without confining a build of several minutes to the efficiency cores (changed from background priority during the build). Output from both phases goes to `~/Library/Application Support/Tokenjar/update.log`, replaced on each attempt. The Command Line Tools are required; when `xcode-select -p` fails, Update Now is disabled with the same message `get.sh` prints. An older Swift is not pre-checked: `get.sh` stops at once with its own message, which then shows as an ordinary failure. Only the two standard Homebrew prefixes are looked at.
- **Interrupted attempts.** A build cut short by quitting Tokenjar, a restart or sleep is abandoned, not resumed. `updateAutoInstallTried` is set when a silent install starts, so an interrupted silent install counts as tried. Update Now stays available.
- **Failure.** A nonzero exit in phase 1 or 2 keeps the current app running, sets a failed state in About naming the version, keeps the log, and on a silent install posts the failure notification once per version.
- **Update in Terminal.** Follows `TerminalLauncher` (formerly `SignInLauncher`): a `.command` file in `$TMPDIR` that deletes itself and runs, for Homebrew, `brew upgrade tokenjar && tokenjar-install-app`, otherwise `TOKENJAR_VERSION=<version> bash <app>/Contents/Resources/get.sh`. One step, no staging, since the person is watching.
- **Report This Problem.** Opens `https://github.com/PedroMosquera/tokenjar/issues/new` with `template=update-failure.yml` and these fields prefilled: from version, to version, install method (Homebrew or release archive), macOS version, `swift --version` first line, and the last 40 lines of the log. Before it goes into the URL, every occurrence of the home folder path becomes `~`, and the whole URL stays under 8000 characters by dropping log lines from the top. A new issue form `.github/ISSUE_TEMPLATE/update-failure.yml` declares those fields with matching ids and the label `update-failure`. Adding the first issue form turns on GitHub's template chooser, so `.github/ISSUE_TEMPLATE/config.yml` sets `blank_issues_enabled: true` to keep plain issues working. The `update-failure` label is created on the repository when this ships, since GitHub drops a label that does not exist.
- **Notification action.** The "available" notification gets a new category of its own (the usage-alert category stays as it is) with one action, **Update Now**, which starts the update and opens About to show progress. Clicking the notification body still only opens About.
- **Permissions and promises.** The silent-install checkbox's caption says Tokenjar downloads and builds new versions by itself. `docs/privacy.md`, About's Runs list and README describe the commands the update runs and the hosts `get.sh` and Homebrew contact (`github.com`, `codeload.github.com`, and Homebrew's own traffic). The app's own HTTP allowlist does not change: these requests come from `curl` and `brew`, which the app runs, like the CLIs it already runs.
- **Preferences** (this Mac only): `updateAutoInstall` (Bool, absent means off), `updateSwappingTo`, and `updateAutoInstallTried` (the last version a silent install attempted, for the once-per-version rule).

## Decided in conversation

- Update Now in the app is the main path; Update in Terminal is the second option.
- Automatic checks and notifies; installing with no click is an opt-in checkbox, off by default (the Sparkle model).
- A failed update offers a prefilled GitHub issue that the person reviews and submits in the browser, plus the log.

## Calls made by the author, open to correction

- Update Now starts at once, with no confirmation dialog; the caption under the button says Tokenjar quits and reopens when the build is done.
- The install method is detected from Homebrew's copy, and everyone else gets the release archive, including `make install` users.
- The bundled `get.sh` runs instead of the one on GitHub, so nothing fetched at update time is executed except the build of the tagged source.
- No cancel button; a build takes minutes, and quitting Tokenjar ends it.
- One automatic attempt per version; failures are not retried in the background.
- The update installs into the running app's own folder, and is disabled when that folder is not writable.
- `install.sh` becomes copy-then-rename for every install path, so a failed copy never removes the old app.
- An interrupted build is abandoned, and counts as the version's one automatic attempt.
- Older Swift versions are not pre-checked; `get.sh`'s own message shows as a failure.
- The issue form ships with `config.yml` keeping blank issues, and the label is created at ship time.
- A silent attempt that stops because Homebrew does not have the release yet does not spend the version's try; the next daily check (not the 30-second tick) tries again, since the tap is updated by hand after the release.
- Update Now on a silent install's finished build swaps it at once, and Update Now during a silent build swaps as soon as it ends instead of waiting for the windows to close.
- The couldn't-update notice after a relaunch is posted when the failed swap's version is the one in `updateAutoInstallTried`.

## Left to the builder

- How phase 2 is detached from the app (for example `/usr/bin/nohup` through `Process`, or `posix_spawn` with a new session), as long as it survives the app's exit and its output reaches the log.
- The progress wording in About while building.
- Test structure, including how the URL builder and the redaction are pinned, and how the two-phase state machine is tested without running a real build.
