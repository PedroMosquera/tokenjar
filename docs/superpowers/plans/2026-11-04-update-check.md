# Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in update check (Manual by default, Automatic once a day) in Settings > About, with one notification per new version that opens About on click.

**Architecture:** Pure pieces in `TokenjarCore/Updates` (version parsing, the GitHub fetch, the schedule and the once-per-version rule), one `@Observable` `UpdateChecker` in the app target that persists to this Mac's preferences and is driven from `AppModel.tick()` and `popoverWillOpen()`, a new notification kind in `NotificationManager`, and an Updates section at the top of `AboutSettingsPane`.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, UserNotifications. Command Line Tools only (`make test`, `make app`); no `@State` macro in views (use `SettingsState`).

**Spec:** `docs/superpowers/specs/2026-11-04-update-check-design.md`

## Global Constraints

- One new allowlisted endpoint, exactly: host `api.github.com`, path `/repos/PedroMosquera/tokenjar/releases/latest`. GET, HTTPS, no query, no auth header.
- Manual is the default. A missing preference reads as Manual. On Manual nothing is fetched unless the user clicks Check Now.
- Automatic checks at most once every 24 hours, held while `networkWatch.holdsChecks`; Check Now always runs.
- Notification title `Tokenjar <latest> is available`, body `You have <installed>. Open Settings > About to see what changed and how to update.`
- Check Now never notifies; a version it finds counts as notified.
- Switching to Automatic calls `requestNotificationPermission(prominent: true)`.
- The setting and its state live in `UserDefaults` (this Mac only), never `config.json`.
- Installed version is `CFBundleShortVersionString`; outside an app bundle there is none and Check Now is disabled.
- Update commands, verbatim: `brew upgrade tokenjar && tokenjar-install-app`; `curl -fsSL https://raw.githubusercontent.com/PedroMosquera/tokenjar/main/Scripts/get.sh | bash`; `git pull && make install`.
- Writing rules for every string and doc line: no em or en dashes; comments only for why (repo standard).
- Every task ends with `make test` green (1280+ tests).

## Review Focus

1. Installed version equal to or newer than the latest release (a `make install` build from `main` after a `VERSION` bump): About says up to date, nothing is notified. Pinned in Task 2.
2. The Mac's clock moved backwards so the stored last check is in the future: the check must become due, not stall for days. Pinned in Task 2.
3. GitHub answers 403 (rate limit), 404, or a redirect: a failed check, silent on Automatic, shown in About. Pinned in Task 1 and Task 3.
4. A relaunch on the same day: no second fetch and no repeated notification. Pinned in Task 3.
5. Tags `v0.10.0` vs `0.9.0`, `0.4` vs `0.4.0`, and an unparseable tag like `v1.0.0-beta`: numeric comparison, padding with zeros, and a parse failure for the last. Pinned in Task 1.

---

### Task 1: Version parsing, the GitHub fetch, and the allowlist entry

**Files:**
- Create: `Sources/TokenjarCore/Updates/UpdateFetcher.swift`
- Modify: `Sources/TokenjarCore/Core/HTTPClient.swift` (`allowedEndpoints`)
- Modify: `Sources/Tokenjar/Settings/AboutSettingsPane.swift` (`contacts` only)
- Modify: `docs/privacy.md` (Requests Tokenjar makes itself; The summary in Settings > About)
- Test: `Tests/TokenjarCoreTests/Updates/UpdateFetcherTests.swift`, `Tests/TokenjarCoreTests/Core/HTTPClientTests.swift:8-9`, `Tests/TokenjarCoreTests/Health/ProviderHealthFetcherTests.swift:45`

**Interfaces:**
- Produces: `public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible` with `public init?(_ text: String)`; `description` is the dotted numbers without `v`.
- Produces: `public struct ReleaseInfo: Equatable, Sendable { public var version: AppVersion; public var pageURL: URL }`.
- Produces: `public struct UpdateFetcher: Sendable` with `static let url`, `static let timeout: TimeInterval = 10`, `init(http: HTTPClient = HTTPClient())`, `func fetch() async throws -> ReleaseInfo` throwing `FetchError` exactly as `ExchangeRateFetcher.fetch()` does.

- [ ] **Step 1: Write the failing tests** in `UpdateFetcherTests.swift`, reusing `HealthFakeTransport`:

```swift
@Test func parsesVersions() {
    #expect(AppVersion("v0.4.0")?.description == "0.4.0")
    #expect(AppVersion("0.10.0")! > AppVersion("v0.9.0")!)
    #expect(AppVersion("0.4") == AppVersion("0.4.0"))
    #expect(AppVersion("v1.0.0-beta") == nil)
    #expect(AppVersion("") == nil)
}
@Test func sendsOneGETWithNoKeyOrCookie() async throws {
    // body: {"tag_name":"v0.4.0","html_url":"https://example.com/elsewhere"}
    let release = try await fetch(transport)
    #expect(release.version == AppVersion("0.4.0"))
    #expect(release.pageURL == URL(string: "https://github.com/PedroMosquera/tokenjar/releases/tag/v0.4.0"))
    #expect(request.url == URL(string: "https://api.github.com/repos/PedroMosquera/tokenjar/releases/latest"))
    #expect(request.allHTTPHeaderFields == ["User-Agent": "Tokenjar", "Accept": "application/vnd.github+json"])
    #expect(request.timeoutInterval == 10)
}
@Test func a403IsANetworkError()     // FetchError.network("HTTP 403")
@Test func a302IsANetworkError()     // FetchError.network("HTTP 302")
@Test func anUnparseableTagIsAParseError()  // tag_name "v1.0.0-beta" throws FetchError.parse(_)
```

`pageURL` is always built from the tag, never taken from `html_url`, so the response cannot point the About link anywhere else.

- [ ] **Step 2: Run to see them fail.** `make test 2>&1 | grep -E 'UpdateFetcher|error:'` shows a compile failure for `AppVersion`/`UpdateFetcher`. Then add the endpoint assertions to `HTTPClientTests.swift:8-9` and `ProviderHealthFetcherTests.swift:45` (`"api.github.com": ["/repos/PedroMosquera/tokenjar/releases/latest"]`) and watch those fail on their assertion once the rest compiles.

- [ ] **Step 3: Implement** `AppVersion` (strip one leading `v`, split on `.`, every part a non-negative `Int`, compare with missing parts as 0, `==` follows the same rule) and `UpdateFetcher` (decode `tag_name` with `JSONDecoder`; missing or unparseable is `FetchError.parse`). Add the endpoint to `HTTPClient.allowedEndpoints`. Add the About contact `GET https://api.github.com/repos/PedroMosquera/tokenjar/releases/latest` with why `The latest Tokenjar release. Only when you click Check Now, or once a day with Check for updates set to Automatic.` and the same `what` under Contacts in privacy.md's summary section, plus a request entry under "Requests Tokenjar makes itself" that says it sends no key and no identifier.

- [ ] **Step 4: Run `make test`.** Expected: all pass, including `AboutSummaryTests.contactsMatchPrivacyDoc`.

- [ ] **Step 5: Commit** `feat(updates): parse versions and fetch the latest release from GitHub`.

### Task 2: Schedule and once-per-version rule

**Files:**
- Create: `Sources/TokenjarCore/Updates/UpdateSchedule.swift`
- Test: `Tests/TokenjarCoreTests/Updates/UpdateScheduleTests.swift`

**Interfaces:**
- Consumes: `AppVersion`, `ReleaseInfo` (Task 1).
- Produces: `public enum UpdateCheckMode: String, Sendable, CaseIterable { case manual, automatic }`.
- Produces: `public enum UpdateSchedule` with `public static let automaticInterval: TimeInterval = 24 * 3600` and `public static func isDue(mode: UpdateCheckMode, lastCheckAt: Date?, now: Date) -> Bool`.
- Produces: `public struct UpdateDecision: Equatable, Sendable { public var notify: Bool; public var notifiedVersion: AppVersion? }` and `public static func decide(latest: AppVersion, installed: AppVersion, notified: AppVersion?, userInitiated: Bool) -> UpdateDecision` on `UpdateSchedule`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func manualIsNeverDue() { #expect(!UpdateSchedule.isDue(mode: .manual, lastCheckAt: nil, now: now)) }
@Test func automaticIsDueWithoutAPreviousCheck()        // lastCheckAt nil -> true
@Test func automaticWaitsADay()                          // now - 23h -> false; now - 24h -> true
@Test func aLastCheckInTheFutureIsDue()                  // lastCheckAt = now + 3600 -> true (clock moved back)
@Test func notifiesANewVersionOnce() {
    let first = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: nil, userInitiated: false)
    #expect(first == UpdateDecision(notify: true, notifiedVersion: v("0.4.0")))
    let again = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: v("0.4.0"), userInitiated: false)
    #expect(again == UpdateDecision(notify: false, notifiedVersion: v("0.4.0")))
}
@Test func checkNowNeverNotifiesButCountsAsNotified()   // userInitiated: true -> notify false, notifiedVersion 0.4.0
@Test func anInstalledVersionAtOrPastLatestIsNotNews()  // installed 0.4.0 or 0.5.0, latest 0.4.0 -> notify false, notifiedVersion unchanged
@Test func aNewerVersionAfterANotifiedOneNotifiesAgain() // notified 0.4.0, latest 0.5.0 -> notify true, 0.5.0
```

- [ ] **Step 2: Run** `make test 2>&1 | grep -E 'UpdateSchedule|error:'`. Expected: compile failure, then assertion failures against a stub returning `false`/`nil`.

- [ ] **Step 3: Implement** both functions. `decide` returns `notifiedVersion` raised to `latest` whenever `latest > installed`, and `notify` only when also `!userInitiated` and `latest > (notified ?? installed)`.

- [ ] **Step 4: Run `make test`.** Expected: all pass.

- [ ] **Step 5: Commit** `feat(updates): decide when to check and when a version is news`.

### Task 3: UpdateChecker in the app

**Files:**
- Create: `Sources/Tokenjar/App/UpdateChecker.swift`
- Modify: `Sources/Tokenjar/App/AppModel.swift` (`var updates: UpdateChecker?` beside `notifications`, and `@discardableResult func checkForUpdatesIfDue() -> Task<Void, Never>?`, called from `tick()` and `popoverWillOpen()`)
- Test: `Tests/TokenjarTests/App/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: Task 1 and Task 2 types; `DefaultsStoring`, `MemoryDefaults` (`AppModel.swift:1122`).
- Produces: `@MainActor @Observable final class UpdateChecker` with
  - `init(defaults: any DefaultsStoring, installed: AppVersion?, clock: @escaping () -> Date = { Date() }, fetch: @escaping @Sendable () async throws -> ReleaseInfo = { try await UpdateFetcher().fetch() })`
  - `var onNewVersion: (_ installed: AppVersion, _ latest: AppVersion) -> Void = { _, _ in }`
  - `var mode: UpdateCheckMode` (get/set, persisted)
  - `private(set) var status: UpdateStatus`
  - `var canCheck: Bool` (false when `installed == nil`)
  - `@discardableResult func checkIfDue(holdsChecks: Bool) -> Task<Void, Never>?`
  - `@discardableResult func checkNow() -> Task<Void, Never>?`
- Produces: `enum UpdateStatus: Equatable { case unknown, checking, upToDate(checkedAt: Date), available(ReleaseInfo), failed(at: Date) }`.
- Preference keys: `updateCheck` (`"manual"`/`"automatic"`), `updateLastCheck` (Date), `updateLatestVersion` (String), `updateNotifiedVersion` (String).

- [ ] **Step 1: Write the failing tests** with `MemoryDefaults`, a fixed clock and a counting fake fetch:

```swift
@Test func defaultsToManualAndNeverFetchesOnItsOwn()   // mode == .manual; checkIfDue returns nil; fetch count 0
@Test func automaticFetchesOnceADay()                  // second checkIfDue at +1h: nil; at +24h: fetches
@Test func automaticHoldsWhileOffline()                // checkIfDue(holdsChecks: true) -> nil
@Test func notifiesANewVersionOnceAcrossRelaunch() {
    // automatic, installed 0.3.0, fetch returns 0.4.0 -> onNewVersion called once
    // new UpdateChecker on the same defaults at +25h, same answer -> fetches, onNewVersion not called
}
@Test func checkNowRunsOnManualAndNeverNotifies()      // status == .available(release); onNewVersion not called
@Test func aFailedCheckIsSilent()                      // fetch throws FetchError.network("HTTP 403") -> status .failed(at:), no callback
@Test func noInstalledVersionMeansNoCheck()            // installed nil: canCheck false, checkNow and checkIfDue nil
@Test func aKnownNewerVersionShowsAfterRelaunch()      // updateLatestVersion "0.4.0" stored, installed 0.3.0 -> status .available on init, no fetch
@Test func switchingModesPersists()                    // mode = .automatic; new instance on same defaults reads .automatic
```

- [ ] **Step 2: Run** `make test 2>&1 | grep -E 'UpdateChecker|error:'`. Expected: compile failure, then assertion failures.

- [ ] **Step 3: Implement.** Model it on `AppModel.checkExchangeRates`: one in-flight task at a time, `lastCheckAt` written when an attempt starts so a failure also waits a day, `UpdateSchedule.decide` on success, then persist `updateLatestVersion` and `updateNotifiedVersion` and call `onNewVersion` only when `decision.notify`. A stored latest version that is not newer than `installed` (the user upgraded) reads as `.unknown` until the next check. `AppModel.checkForUpdatesIfDue()` returns nil when `isInert`, else `updates?.checkIfDue(holdsChecks: networkWatch.holdsChecks)`; call it in `tick()` after the sleep guard and in `popoverWillOpen()`.

- [ ] **Step 4: Run `make test`.** Expected: all pass.

- [ ] **Step 5: Commit** `feat(updates): check for a new version once a day on Automatic`.

### Task 4: The notification and its route to About

**Files:**
- Modify: `Sources/Tokenjar/App/NotificationManager.swift`
- Modify: `Sources/Tokenjar/App/AppDelegate.swift` (create `UpdateChecker` with `AppVersion(Bundle.main CFBundleShortVersionString)` and `UserDefaults.standard`, assign `model.updates`, wire `onNewVersion` and the click route)
- Modify: `Sources/Tokenjar/App/AppModel.swift` (`var settingsPaneRequest: SettingsPane?`)
- Modify: `Sources/Tokenjar/Settings/SettingsView.swift` (honour `settingsPaneRequest`)
- Test: `Tests/TokenjarTests/App/NotificationPermissionTests.swift` or a new `UpdateNotificationTests.swift`

**Interfaces:**
- Consumes: `UpdateChecker.onNewVersion` (Task 3).
- Produces: `static func updateContent(installed: AppVersion, latest: AppVersion) -> UNMutableNotificationContent` on `NotificationManager`; `func postUpdate(installed: AppVersion, latest: AppVersion)`; `var onOpenAbout: () -> Void`. Request id `tokenjar|update|<latest>`, `threadIdentifier` `tokenjar-update`, `userInfo["route"] = "about"`, no category (no Open Dashboard button), default sound.

- [ ] **Step 1: Write the failing test** `updateNotificationText`: `updateContent(installed: v("0.3.0"), latest: v("0.4.0"))` has title `Tokenjar 0.4.0 is available`, body `You have 0.3.0. Open Settings > About to see what changed and how to update.`, `userInfo["route"] as? String == "about"` and an empty `categoryIdentifier`.

- [ ] **Step 2: Run** and see it fail to compile, then fail on the assertion against an empty stub.

- [ ] **Step 3: Implement.** In `didReceive`, a response whose `userInfo["route"]` is `"about"` calls `onOpenAbout` on the main actor; everything else keeps today's dashboard route. `AppDelegate` sets `onOpenAbout` to set `model.settingsPaneRequest = .about` and open Settings. `SettingsView.pane` reads `chosenPane ?? model.settingsPaneRequest ?? (today's default)`, and an `.onChange(of: model.settingsPaneRequest)` moves a non-nil request into `chosenPane` and clears it, so an already open Settings window switches too.

- [ ] **Step 4: Run `make test`.** Expected: all pass. Then `make app` and post a sample with a temporary local call to check the click opens About (do not commit the temporary call).

- [ ] **Step 5: Commit** `feat(updates): notify once per new version and open About on click`.

### Task 5: The Updates section in About, and the docs

**Files:**
- Modify: `Sources/Tokenjar/Settings/AboutSettingsPane.swift`
- Modify: `README.md`, `docs/privacy.md`, `docs/design.md`, `docs/usage.md`, `docs/development.md`

**Interfaces:**
- Consumes: `model.updates` (Task 3), `AlertDelivery` and `requestNotificationPermission(prominent:)` (`AlertsSettingsPane.swift:9-27`), the update commands in Global Constraints.

- [ ] **Step 1: Header text.** Replace `Built from source; no telemetry, no updates feed.` with `Built from source. No telemetry, and it checks for updates only when you ask.`

- [ ] **Step 2: Updates section** right under the header:
  - Picker `Check for updates` with `Manual` and `Automatic`; caption for Manual `Tokenjar asks GitHub only when you click Check Now.`, for Automatic `Tokenjar asks GitHub once a day and notifies you once per new version.` Choosing Automatic calls `model.requestNotificationPermission(prominent: true)` and `model.checkForUpdatesIfDue()`.
  - Under Automatic, when `AlertDelivery(model.notificationPermission).action` is non-nil, the same Allow Banners / Open Notification Settings button the Alerts pane shows.
  - Button `Check Now`, disabled while checking or when `!canCheck` (then the caption `Update checks need the installed app.`), with the status line: `Up to date · checked <relative time>`, `Checking...`, `Tokenjar <latest> is available`, `Couldn't check for updates · <relative time>`.
  - When `.available(release)`: a `What's new in <latest>` link to `release.pageURL`, then three rows (`Homebrew`, `curl`, `make`) each with its command in monospace and a `Copy` button using `NSPasteboard.general`.
  - The Preferences row in `writes` gains `the update check setting, its last check and the newest version seen` in its why.

- [ ] **Step 3: Docs.** README: replace `It has no telemetry and no update check` with the opt-in wording, and add a short "Updates" note under Install linking Settings > About. privacy.md: the "Never" bullet on update checks now reads that there are no telemetry, analytics, crash reports or update feeds, and that the update check runs only as described above; add the four preference keys under What it writes. design.md: add `api.github.com/repos/PedroMosquera/tokenjar/releases/latest` to hard rule 3's list, keep "auto-update feeds" in Non-goals, and add an `## Updates` section summarizing the spec's behavior. usage.md: a short Updates section. development.md step 6: apps on Automatic hear about the version within a day of the GitHub release.

- [ ] **Step 4: Verify.** `make test` all pass; `make app` then `make install`, open Settings > About, switch to Automatic, and confirm the macOS prompt only on a Mac that has not answered it; click Check Now and see `Up to date` against v0.3.0. Run the em dash check on staged lines.

- [ ] **Step 5: Commit** `feat(updates): add the update check to Settings > About`.
