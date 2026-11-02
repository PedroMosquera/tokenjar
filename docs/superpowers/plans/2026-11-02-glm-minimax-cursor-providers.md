# GLM, MiniMax and Cursor providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cursor as a link-only provider, and Z.ai GLM Coding Plan and MiniMax Token Plan as pasted-key providers with real limit windows.

**Architecture:** Cursor copies `DevinUsageFetcher` and every `.devin` branch. GLM and MiniMax copy `OpenCodeGoUsageFetcher`: one allowlisted GET with a key from Tokenjar's own Keychain item, decoded into `UsageWindow`s by a pure `static func snapshot(from:account:now:)` that the tests drive with fixtures. A small shared `PastedKey` resolver and a `PastedKeySection` view serve both.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI, Command Line Tools only.

**Spec:** `docs/superpowers/specs/2026-11-02-glm-minimax-cursor-providers-design.md`. Read it first; this plan does not repeat its reasoning.

## Global Constraints

- Hard rules in `docs/design.md#hard-rules` hold. No OAuth token, cookie or other app's Keychain item is read. Nothing starts a model turn.
- `HTTPClient.allowedEndpoints` gains exactly `"api.z.ai": ["/api/monitor/usage/quota/limit"]` and `"api.minimax.io": ["/v1/token_plan/remains"]`. No query strings, no fallbacks.
- Final `ProviderID` case order (it sets the Add menu): `claude, codex, opencodeGo, opencodeZen, antigravity, copilot, glm, minimax, devin, cursor`. Raw values `glm`, `minimax`, `cursor` are permanent.
- Window ids are permanent once on main: GLM `session`, `weekly`, `mcp:monthly`; MiniMax per Task 4.
- No em or en dashes anywhere, code comments and test names included. Comments only where they carry a why (see the repo's existing density, but do not match it for its own sake).
- Docs change in the same commit as the behaviour they describe (design.md says so for itself).
- Focused test run, used below as `ftest <Filter>`: `CLT=$(xcode-select -p); swift test --scratch-path .build -Xswiftc -plugin-path -Xswiftc $CLT/usr/lib/swift/host/plugins/testing -Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks -Xlinker -F -Xlinker $CLT/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks --filter <Filter>`. Full run: `make test`.
- Before each commit: `git diff --cached | grep -n '^+' | perl -CSD -ne 'print if /[\x{2013}\x{2014}]/'` must print nothing (run it as its own command, not chained with `git commit`).
- Task 1 is pushed to main (`git push origin HEAD:main`), then `make install` from the main checkout after `git pull --ff-only`. Tasks 2 to 5 are pushed only to `wip/glm-minimax`. Task 6 is the owner's, on the personal Mac.

## Review Focus

1. A corporate block page or captive portal answering HTTP 200 with HTML: expect `FetchError.network`, never `.parse`. Tests in Tasks 2 and 4.
2. A pasted key with a trailing newline or spaces: expect it trimmed before it is sent. Test in Task 2.
3. A synced config that names a GLM or MiniMax account on a Mac whose Keychain has no key: expect `.notSignedIn` and the Change Key fix, not Sign In. Test in Task 3.
4. A reset field missing or zero: expect `resetsAt == nil` and no crash; monthly length nil. Tests in Tasks 2 and 4.
5. A key from the wrong product (Z.ai pay-as-you-go, MiniMax `sk-api-`): expect the calm no-plan message, never "Key rejected". Tests in Tasks 2 and 4 (hand-written until Task 6).

---

### Task 1: Cursor as a link-only provider

**Files:**
- Modify: `Sources/TokenjarCore/Core/Models.swift` (`ProviderID`: new case `cursor` after `devin`, every property)
- Create: `Sources/TokenjarCore/Providers/Cursor/CursorUsageFetcher.swift`
- Modify: `Sources/TokenjarCore/Core/Fetching.swift:33-55`, `Sources/TokenjarCore/Core/Capture.swift:25-36`, `Sources/TokenjarCore/Setup/AccountDiscovery.swift:37-80`, `Sources/TokenjarCore/Setup/CodexBarImport.swift:127-138`, `Sources/TokenjarCore/Settings/SignInCommand.swift`, `Sources/TokenjarCore/Core/CostLine.swift:31`, `Sources/TokenjarCore/Health/ProviderHealthFeed.swift:76`, `Sources/Tokenjar/Shared/ProviderLogo.swift:74`, `Sources/Tokenjar/Settings/AccountDetailView.swift:596-610`
- Create: `Resources/Logos/cursor.svg`
- Test: `Tests/TokenjarCoreTests/Core/ModelsTests.swift`, `Tests/TokenjarCoreTests/Cursor/CursorUsageFetcherTests.swift`, `Tests/TokenjarCoreTests/Setup/AccountDiscoveryTests.swift`, `Tests/TokenjarCoreTests/Setup/CodexBarImportTests.swift`, `Tests/TokenjarCoreTests/Core/CaptureCommandTests.swift`
- Docs: `README.md` (provider table, the Devin row's neighbour), `docs/design.md` (Non-goals list, Data sources table), `docs/privacy.md` (where Devin is listed as sending nothing), `docs/configuration.md:22`, `docs/logos.md`, `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Produces: `ProviderID.cursor` with `displayName "Cursor"`, `logoName "cursor"`, `isLinkOnly true`, `reportsWindows false`, `checkUsesNetwork false`, `harness nil`, `statusFeedURL nil`; `CursorUsageFetcher.source == "usage page"`, `CursorUsageFetcher.noUsageNote`.

- [ ] **Step 1: Confirm the two URLs.** Open `https://cursor.com/dashboard?tab=usage` in a browser signed in to Cursor and record the final URL of the usage view. Run `curl -sI https://status.cursor.com | head -1`; use it as `statusPageURL` only if it answers 200 without a redirect, else `nil`.

- [ ] **Step 2: Write the failing tests.**
  - `ModelsTests.defaultUsagePagesArePinned`: add `.cursor: "<URL from step 1>"`.
  - `ModelsTests.statusPagesArePinned`: add `.cursor` per step 1.
  - Replace `onlyDevinIsALinkOnlyProvider` with `linkOnlyProvidersAreDevinAndCursor`: `#expect(ProviderID.allCases.filter(\.isLinkOnly) == [.devin, .cursor])`.
  - `onlyZenAndDevinReportNoWindows` (rename to `zenDevinAndCursorReportNoWindows`) and `providersThatNeedTheNetworkAreTheOnesThatContactOne`: add `.cursor: false`.
  - `newProvidersHaveTheirPermanentIDsAndNames`: `ProviderID(rawValue: "cursor") == .cursor`, `displayName == "Cursor"`, `logoName == "cursor"`, `harness == nil`.
  - `CursorUsageFetcherTests.linkOnlySnapshot`: fetch with a `FetchContext` whose `ProcessRunner` and `HTTPTransport` fakes record calls; expect `windows.isEmpty`, `source == "usage page"`, `notes == ["Cursor doesn't share your usage with local apps. Open the usage page to see it."]`, and zero recorded processes and requests (copy the Devin test's setup).
  - `AccountDiscoveryTests`: a temp home with `Applications/Cursor.app` yields an account `id "cursor"`, `provider .cursor`, `label "Cursor"`, `showInMenuBar false`; `isAvailable` is true and `location` is nil.
  - `CodexBarImportTests`: `providerID("cursor") == .cursor`.
  - `CaptureCommandTests`: `.cursor` gives `.nothingToCapture("Cursor has nothing to capture: Tokenjar runs, reads and sends nothing for it.")`.

- [ ] **Step 3: Run `swift build --scratch-path .build`.** Expected: compile errors at every exhaustive `switch` over `ProviderID` (about a dozen). That list is the work list for step 4.

- [ ] **Step 4: Implement.** Add the case and extend each switch the way `.devin` is handled, except: `logoName "cursor"`, `defaultDashboardURL` and `statusPageURL` from step 1, discovery markers `/Applications/Cursor.app`, `~/Applications/Cursor.app`, `~/Library/Application Support/Cursor` (existence only), `cliName nil`, `hasSignInCommand` false for `.cursor`, `CodexBarImport.isSameLogin` treats two Cursor accounts as one login as it does Devin. `CursorUsageFetcher` mirrors `DevinUsageFetcher` with the one note above and no Windsurf note. The "Use Windsurf Page" button stays Devin-only.

- [ ] **Step 5: Logo.** Fetch `https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/cursor.svg`, normalize as `docs/logos.md` describes (keep the path bytes, `fill="#000000"`, `width="16" height="16"`), add its row with both SHA-256 values and brand hex from that version's `data/simple-icons.json`. `brandColor` is `.primary`.

- [ ] **Step 6: Run `ftest ModelsTests`, `ftest CursorUsageFetcherTests`, `ftest AccountDiscoveryTests`, `ftest CodexBarImportTests`, `ftest CaptureCommandTests`, `ftest LogoAssetTests`, then `make test`.** Expected: all pass. Then temporarily set `isLinkOnly` false for `.cursor` and confirm `linkOnlyProvidersAreDevinAndCursor` fails on its assertion; revert.

- [ ] **Step 7: Docs.** Add Cursor next to Devin everywhere Devin is listed as link only. design.md Non-goals: "and Devin and Cursor (links only...)". README table row: "Cursor | Nothing. Cursor shares usage only through its own login token or a browser session, so it has no card; its page in Settings opens the usage page." Add under the README's update steps: "Update Tokenjar on every Mac before adding a Cursor account to a config.json you sync, since an older build cannot load it." (Task 5 widens this to GLM and MiniMax.)

- [ ] **Step 8: Render check.** `swift build --scratch-path .build && .build/debug/Tokenjar --render-windows renders/ --only settings` and look at the Add menu and a Cursor account page in `renders/`.

- [ ] **Step 9: Commit, push to main, install.**

```bash
git add -A && git commit -m "feat: add Cursor as a link to its usage page"
git fetch origin && git rebase origin/main && git push origin HEAD:main
```
Then in the main checkout: `git pull --ff-only && make install && pgrep -fl 'Applications/Tokenjar.app'`.

---

### Task 2: GLM Coding Plan provider (core)

**Files:**
- Modify: `Sources/TokenjarCore/Core/Models.swift` (case `glm` after `copilot`; new property `usesPastedKey`)
- Create: `Sources/TokenjarCore/Core/PastedKey.swift`
- Modify: `Sources/TokenjarCore/Providers/OpenCode/OpenCodeLocalData.swift` (make `apiKey(inAuthFile:entries:)` internal, no other change)
- Create: `Sources/TokenjarCore/Providers/GLM/GLMUsageFetcher.swift`
- Modify: `Sources/TokenjarCore/Core/HTTPClient.swift:32-37`, `Fetching.swift`, `Capture.swift`, `CaptureRedactor.swift:35-60`, `AccountDiscovery.swift` (`isAvailable`, `location`), and the other exhaustive switches the compiler lists
- Create: `Resources/Logos/zai.svg`
- Test: `Tests/TokenjarCoreTests/GLM/GLMUsageFetcherTests.swift`, `Tests/TokenjarCoreTests/Core/PastedKeyTests.swift`, `Tests/TokenjarCoreTests/Core/HTTPClientTests.swift`, `Tests/TokenjarCoreTests/Core/ModelsTests.swift`, `Tests/TokenjarCoreTests/Core/CaptureCommandTests.swift`
- Fixtures (hand-written, every string a placeholder): `Tests/TokenjarCoreTests/Fixtures/GLM/glm-quota.json`, `glm-quota-v3.json`, `glm-quota-idle.json`, `glm-quota-empty.json`, `glm-error-401.json`, `glm-error-body.json`, `glm-block-page.html`

**Interfaces:**
- Produces: `ProviderID.glm` (`displayName "GLM Coding Plan"`, `logoName "zai"`, `defaultDashboardURL https://z.ai/manage-apikey/coding-plan/personal/my-plan`, `statusPageURL nil`, `statusFeedURL nil`, `isLinkOnly false`, `reportsWindows true`, `checkUsesNetwork true`, `harness nil`).
- Produces: `public var usesPastedKey: Bool` on `ProviderID`, true for `.opencodeGo, .glm` (Task 4 adds `.minimax`).
- Produces: `enum PastedKey { static func apiKey(for account: AccountConfig, secrets: any SecretStore, paths: AppPaths) throws -> String }`. `.keychain(name)` reads `secrets.pastedKey(account:)`; `.file(path, entry)` reads `OpenCodeLocalData.apiKey(inAuthFile:entries:[entry])`; `nil` or a blank key throws `FetchError.notSignedIn`; the result is trimmed of whitespace and newlines.
- Produces: `GLMUsageFetcher.usageURL`, `GLMUsageFetcher.noSubscriptionMessage == "No active GLM Coding Plan for this key"`, `static func snapshot(from: HTTPResponse, account: AccountConfig, now: Date) throws -> UsageSnapshot`.

- [ ] **Step 1: Write the fixtures.** Use `now = 2026-11-02T12:00:00Z` and epoch milliseconds for resets.
  - `glm-quota.json`: `{"code":200,"msg":"<placeholder>","success":true,"data":{"planName":"Lite","limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":42,"nextResetTime":<2026-11-02T14:00:00Z>},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":18,"nextResetTime":<2026-11-06T00:00:00Z>},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":5,"nextResetTime":<2026-12-01T00:00:00Z>}]}}`
  - `glm-quota-v3.json`: same with `CREDIT_LIMIT` for the two token windows, no `planName` but `"level":"pro"`, an extra entry `{"type":"FUTURE_LIMIT","unit":3,"number":1,"percentage":99}`, and the TIME_LIMIT entry without `nextResetTime`.
  - `glm-quota-idle.json`: session at `percentage 0`.
  - `glm-quota-empty.json`: `"limits":[]`.
  - `glm-error-401.json` (served with status 401) and `glm-error-body.json` (status 200, `{"code":1001,"msg":"<placeholder>","success":false}`).
  - `glm-block-page.html`: a few lines of HTML.

- [ ] **Step 2: Write the failing tests** in `GLMUsageFetcherTests` (shape like `OpenCodeGoUsageFetcherTests`):
  - `mapsTheThreeWindowsByTypeUnitAndNumber`: ids `["session","weekly","mcp:monthly"]`, labels `["5-hour","Week","Tools (MCP)"]`, used `[42,18,5]`, minutes `[300, 10_080, 30 * 1_440]` (November ends at the Dec 1 reset), resets as in the fixture, `plan == "Lite"`, `source == "z.ai API"`, `provider == .glm`.
  - `readsCreditLimitsAndSkipsUnknownEntries`: v3 fixture gives ids `["session","weekly","mcp:monthly"]`, `plan == "pro"`, `mcp:monthly` has `resetsAt == nil` and `windowMinutes == nil`.
  - `idleWindowIsNotStarted`: session `notStarted == true`.
  - `emptyLimitsMeanNoPlan`: throws `FetchError.noSubscription("No active GLM Coding Plan for this key")`.
  - `unrecognizedOnlyIsAParseError`: a body whose only entry is `FUTURE_LIMIT` throws `.parse`.
  - `statusAndBodyErrors` (parameterized): 401 fixture to `.unauthorized`; `glm-error-body.json` at 200 to `.unauthorized`; 429 with `Retry-After: 30` to `.rateLimited(retryAfter: 30)`; 503 to `.network`.
  - `nonJSONAnswerIsANetworkError`: block page at 200 throws `.network`, not `.parse`.
  - `sendsTheBareKeyOnlyToTheAllowlistedPath`: through `fetch` with a fake transport and a `.keychain` credential whose stored key is `"  k-123\n"`: one request, URL `https://api.z.ai/api/monitor/usage/quota/limit`, header `authorization == "k-123"`, no `Bearer`.
  - `PastedKeyTests`: `.keychain` returns the trimmed stored key; `nil` throws `.notSignedIn`; a blank stored key throws `.notSignedIn`; `.file` reads the entry from an auth.json-shaped temp file.
  - `HTTPClientTests.allowlistIsPinned`: add the `api.z.ai` entry.
  - `ModelsTests`: add `.glm` to every per-provider table (usage page, status page nil, reports windows true, network true, permanent id `glm`).
  - `CaptureCommandTests`: `.glm` with no key stops with "No GLM key was found in the --credential-file entry."; with a fake transport it returns a document whose `response.data.limits[].type` survives redaction and whose `msg` is redacted.

- [ ] **Step 3: Run `ftest GLMUsageFetcherTests` and `ftest PastedKeyTests`.** Expected: fail to compile (types missing).

- [ ] **Step 4: Implement** `PastedKey`, `ProviderID.glm` and `usesPastedKey`, the allowlist entry, and `GLMUsageFetcher`. Decoding order in `snapshot`: non-JSON body is `.network("z.ai answered with something other than JSON")`; then `success == false` or status 401 is `.unauthorized`; 429 `.rateLimited`; 5xx and other non-200 `.network`; then `data.limits`. Entry to window: `type` in `["TOKENS_LIMIT","CREDIT_LIMIT"]` with `unit 3, number 5` is session; same types with `unit 6` is weekly; `TIME_LIMIT, unit 5, number 1` is `mcp:monthly` with `UsageWindow.monthMinutes(endingAt:)`. `nextResetTime` of 0 or missing is `nil`. Plan is the first non-empty string of `data.planName`, `plan`, `plan_type`, `packageName`, `level`, else `"GLM Coding Plan"`. Capture: `glm(account:context:)` mirrors `opencodeGo` using `PastedKey`; redactor allowlist `.glm: ["capture", "error", "response.data.limits[].type", "response.data.planName", "response.data.level", "response.data.plan", "response.data.plan_type", "response.data.packageName"]`. Discovery: no marker (nothing on disk to find); `location` is the `.file` path or nil. Other switches: `cliName nil`, `hasSignInCommand false`, `SignInCommand` nil, `CostLine.source .history`, health feed nil, `brandColor .primary`.

- [ ] **Step 5: Logo.** simple-icons 16.32.0 has no Z.ai icon. Draw `Resources/Logos/zai.svg`: a single-path "Z" lettermark in a `0 0 24 24` viewBox, `fill="#000000"`, `width="16" height="16"`. Document it in `docs/logos.md` as a stand-in drawn for Tokenjar, like `antigravity.svg`.

- [ ] **Step 6: Run `ftest GLMUsageFetcherTests`, `ftest PastedKeyTests`, `ftest HTTPClientTests`, `ftest ModelsTests`, `ftest CaptureCommandTests`, `ftest FixtureShapeTests`, `ftest LogoAssetTests`, then `make test`.** Expected: all pass. Then swap the `unit 6` check for `unit 5` and confirm `mapsTheThreeWindowsByTypeUnitAndNumber` fails on its assertion; revert.

- [ ] **Step 7: Commit (no push).** `git commit -m "feat: read GLM Coding Plan limits with a pasted z.ai key"`

---

### Task 3: Settings for pasted-key-only providers

**Files:**
- Create: `Sources/Tokenjar/Settings/PastedKeySection.swift`
- Modify: `Sources/Tokenjar/Settings/AccountDetailView.swift:38-46` (which credential section shows), `:607` (`usesAPIKey`), `:650-660` (`AccountFix.primary`)
- Test: `Tests/TokenjarTests/Settings/AccountFixTests.swift`

**Interfaces:**
- Consumes: `ProviderID.usesPastedKey` (Task 2), `AppModel.savePastedKey(_:accountID:)`, `SettingsLogic.removingPastedKey(from:secrets:)`.
- Produces: `struct PastedKeySection: View { var account: AccountConfig }`.

- [ ] **Step 1: Write the failing tests** in `AccountFixTests`:
  - `glmWithoutAKeyOffersChangeKey`: `AccountFix.primary(for: .notSignedIn, provider: .glm, credential: nil) == .changeKey`.
  - `glmWithAKeyMissingOnThisMacOffersChangeKey`: same with `.keychain(account: "g")`, `== .changeKey`.
  - `glmRejectedKeyOffersChangeKey`: `.unauthorized` gives `.changeKey`.
  - `glmWithoutAPlanOffersNothing`: `.noSubscription("x")` gives `nil`.
  - Keep the existing Zen and Go cases passing unchanged.

- [ ] **Step 2: Run `ftest AccountFixTests`.** Expected: the first test fails (`nil` instead of `.changeKey`).

- [ ] **Step 3: Implement.** `usesAPIKey` becomes `self == .opencodeGo || self == .opencodeZen || usesPastedKey`. In `AccountFix.primary`, `.notSignedIn`: `if provider.usesAPIKey, pastedKey || !provider.hasSignInCommand { return .changeKey }`. `AccountDetailView`: show `AccountCredentialSection` for `.opencodeGo` as now, else `PastedKeySection` when `usesPastedKey`, both with `.id(Self.credentialAnchor)` and `.disabled(!model.canEditConfig)`. `PastedKeySection`: a `Section` headed "Credential" with the line "Never saved in config.json. A pasted key stays in this Mac's Keychain, so paste it again on each Mac.", a `SecureField` whose prompt is `"Paste a GLM Coding Plan API key"` for `.glm` (Task 4 adds MiniMax's), Save Key (reuse `AccountCredentialSection.saveKey`'s messages), and, when a key is stored, Remove Key behind a confirmation that calls `SettingsLogic.removingPastedKey`. Lift shared save and remove code out of `AccountCredentialSection` only if both views would otherwise repeat more than a few lines.

- [ ] **Step 4: Run `ftest AccountFixTests`, then `make test`.** Expected: pass.

- [ ] **Step 5: Render check.** Add a GLM account to `PreviewData` (one snapshot from `glm-quota.json`'s numbers), run `.build/debug/Tokenjar --render-windows renders/ --only settings --only popover`, and look at the GLM account page and card in light and dark.

- [ ] **Step 6: Commit (no push).** `git commit -m "feat: paste a key for GLM in Settings"`

---

### Task 4: MiniMax Token Plan provider

**Files:**
- Modify: `Models.swift` (case `minimax` after `glm`; `usesPastedKey` adds it), `HTTPClient.swift`, `Fetching.swift`, `Capture.swift`, `CaptureRedactor.swift`, `AccountDiscovery.swift`, the other exhaustive switches, `PastedKeySection.swift` (prompt)
- Create: `Sources/TokenjarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift`, `Resources/Logos/minimax.svg`
- Test: `Tests/TokenjarCoreTests/MiniMax/MiniMaxUsageFetcherTests.swift`, `HTTPClientTests`, `ModelsTests`, `CaptureCommandTests`, `AccountFixTests`
- Fixtures (hand-written): `Tests/TokenjarCoreTests/Fixtures/MiniMax/minimax-remains.json`, `minimax-remains-two-models.json`, `minimax-remains-boost.json`, `minimax-error-key.json`, `minimax-error-plan.json`

**Interfaces:**
- Consumes: `PastedKey.apiKey(for:secrets:paths:)`, `ProviderID.usesPastedKey`.
- Produces: `ProviderID.minimax` (`displayName "MiniMax"`, `logoName "minimax"`, `defaultDashboardURL https://platform.minimax.io/user-center/payment/coding-plan`, others as `.glm`), `MiniMaxUsageFetcher.usageURL`, `noSubscriptionMessage == "No active MiniMax Token Plan for this key"`, `static func snapshot(from:account:now:) throws -> UsageSnapshot`.

- [ ] **Step 1: Write the fixtures.** `now = 2026-11-02T12:00:00Z`. Every count below is what remains, as CodexBar reads these fields.
  - `minimax-remains.json`: `base_resp {status_code 0}`, `model_remains` with `MiniMax-M2` (`current_interval_total_count 600`, `current_interval_usage_count 450`, `end_time <2026-11-02T15:00:00Z>`, `current_weekly_total_count 6000`, `current_weekly_usage_count 5400`, `weekly_end_time <2026-11-09T00:00:00Z>`) and `speech-2.6-hd` with its own counts (skipped).
  - `minimax-remains-two-models.json`: `MiniMax-M2` as above plus `MiniMax-M2.5` with `current_interval_used_percent 10` and `current_weekly_remaining_percent 70`.
  - `minimax-remains-boost.json`: `MiniMax-M2` with `interval_boost_permill 500` and remaining 150 of base 600.
  - `minimax-error-key.json`: HTTP 200, `base_resp {status_code 1004, status_message "<contains: invalid api key>"}`. `minimax-error-plan.json`: `status_code 2056`, message contains "token plan".

- [ ] **Step 2: Write the failing tests** in `MiniMaxUsageFetcherTests`:
  - `oneTextModelUsesPlainIDs`: ids `["session","weekly"]`, used `[25, 10]`, minutes `[300, 10_080]`, resets as fixture, `plan == "Token Plan"`, `source == "minimax API"`, speech entry absent.
  - `twoTextModelsArePools`: ids `["minimaxm2:session","minimaxm2:weekly","minimaxm25:session","minimaxm25:weekly"]`, `minimaxm25` used `[10, 30]` (explicit percents win over counts), labels `"MiniMax-M2 5-hour"` style.
  - `boostRaisesTheTotal`: used `(900 - 150) / 900 * 100` rounded to one decimal, `83.3`; never above 100.
  - `modelExcludedFromThePlanIsSkipped`: an entry with `current_interval_status 3` and zero totals yields no window.
  - `errorsInTheBody` (parameterized): key fixture to `.unauthorized`, plan fixture to `.noSubscription("No active MiniMax Token Plan for this key")`, HTTP 401 to `.unauthorized`, 429 to `.rateLimited`, 503 to `.network`, HTML at 200 to `.network`.
  - `missingEndTimeLeavesNoReset`: `end_time` absent gives `resetsAt == nil`.
  - `sendsBearerOnlyToTheAllowlistedPath`: one request to `https://api.minimax.io/v1/token_plan/remains` with `Authorization: Bearer k-123`.
  - `HTTPClientTests.allowlistIsPinned`, `ModelsTests` tables, `CaptureCommandTests` (stop message "No MiniMax key was found in the --credential-file entry."), `AccountFixTests` (`minimaxWithoutAKeyOffersChangeKey`).

- [ ] **Step 3: Run `ftest MiniMaxUsageFetcherTests`.** Expected: fail to compile.

- [ ] **Step 4: Implement.** Order in `snapshot`: non-JSON is `.network`; HTTP 401 `.unauthorized`, 429 `.rateLimited`, other non-200 `.network`; `base_resp.status_code != 0`: message lowercased containing `key`, `auth` or `token` but not `plan` is `.unauthorized`, containing `plan` or `subscription` is `.noSubscription`, else `.network`. A model entry is text unless its lowercased name contains `speech`, `image`, `video`, `music`, `voice` or `hailuo`. Used % for each lane: `*_used_percent` if present; else `100 - *_remaining_percent`; else from counts as `(total - remaining) / total * 100`, where `total = base * (1000 + boost_permill) / 1000`. Skip a lane with `total == 0`, and a model with `*_status == 3` and no total. Ids: plain when exactly one text model, else `<name lowercased, letters and digits only>:session|weekly`. Resets from `end_time` / `weekly_end_time` (epoch ms), 0 or missing is nil. Redactor allowlist `.minimax: ["capture", "error", "response.model_remains[].model_name"]`. Logo from simple-icons 16.32.0 `minimax.svg`, normalized and documented as in Task 1. `PastedKeySection` prompt for `.minimax`: `"Paste a MiniMax Token Plan key (sk-cp-...)"`.

- [ ] **Step 5: Run the focused suites, then `make test`.** Expected: pass. Then make the counts read as used instead of remaining and confirm `oneTextModelUsesPlainIDs` fails on its assertion; revert.

- [ ] **Step 6: Commit (no push).** `git commit -m "feat: read MiniMax Token Plan limits with a pasted key"`

---

### Task 5: Docs for GLM and MiniMax, then push the WIP branch

**Files:** `README.md`, `docs/privacy.md`, `docs/design.md`, `docs/configuration.md`, `docs/development.md`, `docs/logos.md`, `THIRD_PARTY_NOTICES.md`, `Sources/Tokenjar/Settings/AboutSettingsPane.swift` (if it lists hosts by hand)

- [ ] **Step 1: Write the docs.** README provider table rows; a README note under updating: "Update Tokenjar on every Mac before adding a GLM, MiniMax or Cursor account to a config.json you sync, since an older build cannot load it." privacy.md request table rows for both endpoints, the Keychain item now holding GLM and MiniMax keys too, and the sentence "Tokenjar contacts api.z.ai or api.minimax.io only for an account of that provider with a pasted key." design.md: Non-goals provider list, Data sources rows (mechanism, error rules, window ids), window id list, hard rule 3 endpoint list. development.md capture list gains `glm` and `minimax` with the `--credential-file` recipe from the spec.

- [ ] **Step 2: Run `make test`** (the docs pin nothing, but About pane tests may). Expected: pass. Run the dash check on staged lines.

- [ ] **Step 3: Commit and push the branch.**

```bash
git commit -m "docs: describe the GLM and MiniMax sources"
git push origin HEAD:refs/heads/wip/glm-minimax
```

---

### Task 6 (owner, personal Mac): record live answers and land on main

- [ ] **Step 1:** Open a small GLM Coding Plan at z.ai and a MiniMax Token Plan at minimax.io. Create a key for each.
- [ ] **Step 2:** `git fetch origin && git switch --detach origin/wip/glm-minimax && swift build --scratch-path .build`.
- [ ] **Step 3:** Put each key in `captures/keys.json` as `{"glm":{"type":"api","key":"..."},"minimax":{"type":"api","key":"..."}}`, then:

```bash
mkdir -p captures
.build/debug/Tokenjar --capture glm --credential-file captures/keys.json --credential-key glm > captures/glm.json
.build/debug/Tokenjar --capture minimax --credential-file captures/keys.json --credential-key minimax > captures/minimax.json
```
Repeat each with a deliberately wrong key for the bad-key answer. If a Z.ai pay-as-you-go key or a MiniMax `sk-api-` key is at hand, capture once with it for the no-plan answer. Delete `captures/keys.json`.

- [ ] **Step 4:** Read every capture before sharing it. Replace the hand-written fixtures with the captures (keep the hand-written ones only for cases no capture shows, and say so in each test support file). Fix the parsers until every test passes against the real shapes. Settle the open points: GLM bare key vs `Bearer`, MiniMax path, which MiniMax models are text, whether counts are remaining, whether `total_count` already includes the boost, and the final MiniMax window ids (permanent from here).
- [ ] **Step 5:** If an answer needs something the hard rules forbid (a query parameter, another host, a cookie), stop that provider and decide with the owner; land the other.
- [ ] **Step 6:** Confirm both usage-page URLs while signed in. Add the accounts through Settings with pasted keys and watch one refresh cycle and the dashboard.
- [ ] **Step 7:** `make test`, then rebase onto main, push to main, delete the branch, reinstall:

```bash
git fetch origin && git rebase origin/main && git push origin HEAD:main
git push origin --delete wip/glm-minimax
git switch main && git pull --ff-only && make install
```

## Not verified until Task 6

GLM and MiniMax response shapes, error codes, the auth header form, MiniMax's path and boost semantics, both usage-page URLs, and how either behaves on the work laptop's network beyond the block page reading as a network error.
