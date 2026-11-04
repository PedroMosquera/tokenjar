# Update check and update notification

Date: 2026-11-04. Status: approved in conversation; sample notifications reviewed on a real Mac.

## Why

Tokenjar has no way to tell anyone a new version exists. Today the only signal is watching the repository's GitHub releases, which most people who install it never do, so they keep running an old build until something breaks. Someone asked for this; the owner had not needed it personally.

The app's privacy promise is that it contacts nothing it does not have to ("no telemetry, no update check"). The update check has to fit that promise rather than break it: by default it makes no request at all unless the user clicks.

## Goals

1. Settings > About shows the installed version, a **Check for updates** setting with two values, **Manual** (the default) and **Automatic**, a **Check Now** button, and the result of the last check.
2. On Manual, Tokenjar makes no update request unless the user clicks Check Now.
3. On Automatic, Tokenjar checks at most once a day and posts one notification per new version: title `Tokenjar <new> is available`, body `You have <installed>. Open Settings > About to see what changed and how to update.` (the text reviewed in the sample).
4. Clicking that notification opens Settings on the About pane.
5. When a newer version is known, About says so, links to that release's GitHub page for what changed, and shows how to update for each install way, each with a Copy button:
   - Homebrew: `brew upgrade tokenjar && tokenjar-install-app`
   - curl: the README's one-liner
   - make: `git pull && make install` (run in the clone)

## Non-goals

- Downloading, installing or running anything. Tokenjar never updates itself; the user runs the command.
- Showing release notes inside the app. The release page on GitHub has them.
- Percentage alerts. They already exist (Settings > Alerts, and per account under Overrides). Making them easier to find is a separate change.
- Prerelease or beta channels.
- Telling which way Tokenjar was installed. Homebrew and curl builds look the same from inside the app, so About shows all three commands.

## Anti-goals

- Any update request on Manual without a click, including at launch, at first run, or after an upgrade.
- An upgrade turning Automatic on by itself. A missing setting reads as Manual.
- The same version notified twice, on this launch or the next.
- A failed check notifying or nagging. A check that fails on Automatic shows only in About.
- Turning this on for one Mac turning it on for another Mac that shares the config file.

## Constraints

- **Hard rule 3, allowlisted endpoints.** Add exactly one endpoint to `HTTPClient.allowedEndpoints`: host `api.github.com`, path `/repos/PedroMosquera/tokenjar/releases/latest`. GET, HTTPS, no query, no auth header, no redirect followed (the client follows none). GitHub's latest-release endpoint already skips drafts and prereleases. Unauthenticated calls are limited to 60 an hour per IP, far above one a day plus clicks.
- **Docs that state the promise today and must change in the same commit:** `README.md` ("no telemetry and no update check"), `docs/privacy.md` (allowlisted requests, and the "Never" line on update checks), the About pane's own text ("no updates feed") and its Contacts list, `docs/design.md` (hard rule 3's list, and the non-goals line, which keeps "auto-update feeds" as a non-goal because this is a check, not a feed), `docs/usage.md`, and `HTTPClient`'s comment. The tests that pin the endpoint set, the privacy doc and the About summary change with them.
- **Where the setting lives.** In Tokenjar's preferences (`UserDefaults`), this Mac only, never in `config.json`, following `ProviderHealthSetting`. The last check time, the newest version seen and the last version notified are stored there too, so a relaunch neither checks again within the day nor repeats a notification.
- **Versions.** The installed version is `CFBundleShortVersionString`. The latest is the response's `tag_name` without its leading `v`. Compare them as dotted numbers. A tag that does not parse counts as a failed check. Only a strictly greater version counts as new. Running outside an app bundle there is no installed version, so Check Now is disabled with a line saying why.
- **Notifications.** Posted through `NotificationManager` with a kind of its own, so a click routes to Settings > About instead of the dashboard. On Automatic it posts even when usage alerts are turned off in Settings > Alerts, because choosing Automatic is itself the opt-in. It needs the same notification permission as alerts. Switching the setting to Automatic asks macOS for banners right away (`requestAuthorization(prominent: true)`), since that is the moment the user asked to be told; macOS shows its prompt only once, so a Mac that already allows or denies banners sees nothing. When banners are not allowed, About shows the state under the setting, as the Alerts pane does: Allow Banners while the grant is quiet, Open Notification Settings when macOS has notifications off for Tokenjar.
- **Check Now never notifies.** A version found with Check Now shows in About only, and counts as notified: a later automatic check does not post a notification for that same version.
- **Network.** On Automatic, a check is held while the Mac is offline and runs when it is back, as the ECB rate check does (`NetworkWatch.holdsChecks`). Check Now always runs.
- **Releases.** Apps on Automatic learn about a version once its GitHub release exists. That release is already the last step in `docs/development.md`, after the Homebrew formula is updated, so nobody is told about a version they cannot install. Note this in that step.

## Decided in conversation

- A setting with Manual as the default and Automatic as the option.
- The check and its result live in Settings > About.
- One notification per new version; clicking it opens Settings > About.
- The app never installs anything; About shows the commands.
- The notification text above.
- Switching to Automatic asks macOS for banners right away.

## Calls made by the author, open to correction

- The GitHub API endpoint rather than following the `releases/latest` web redirect: `HTTPClient` follows no redirects, and the API answers directly with JSON that includes the release page URL.
- The update notification ignores the usage alerts switch.
- About shows all three update commands, since the app cannot tell how it was installed.
- A failed Automatic check stays silent and shows in About only.
- Check Now never notifies, and a version it finds counts as notified.

## Left to the builder

- The exact layout and wording of the About section, within the goals above.
- How the daily check is scheduled. `ExchangeRateSchedule` and `checkExchangeRates` are the model to follow.
- Test structure, including how the version comparison and the "once per version" rule are pinned.
