# New providers: Z.ai GLM Coding Plan, MiniMax, and Cursor as a link

Date: 2026-11-02. Status: design, not built.

## Why

A November 2026 review of adoption surveys, competitor trackers and their issue queues found that the 5-hour plus weekly limit has become the standard plan shape, and that two plans with that shape are both popular and readable within Tokenjar's hard rules: Z.ai's GLM Coding Plan and MiniMax's Token Plan. Each answers one read-only GET authenticated by an API key the user pastes, the same pattern as OpenCode Go.

Cursor is the most used tool Tokenjar does not cover, but every way to read its usage needs Cursor's own login token or a browser cookie. The owner treats Cursor like Devin: a tool whose usage page is one click away, with no card.

## Goals

- A GLM account shows its 5-hour and weekly token windows, and the monthly tools (MCP) quota when the plan reports one, with used %, reset countdown, pace, alerts, menu bar and history charts, like any other limit.
- A MiniMax account shows its 5-hour and weekly windows the same way.
- A Cursor account exists only as a link to Cursor's usage page, exactly as Devin does today.
- Every parser is tested against responses recorded from the owner's own GLM and MiniMax accounts, opened for this purpose.

## Non-goals

- China-region plans (`open.bigmodel.cn`, `api.minimaxi.com`). International hosts only. A region choice comes later, if someone needs it.
- Cost history or token charts for GLM or MiniMax. Neither writes local logs Tokenjar reads, so their dashboard pages chart limits only, like Antigravity and Copilot.
- Reading keys from environment variables, other apps' config files or the provider CLIs. The only key source is the one pasted in Settings.
- Endpoint fallbacks. One allowlisted path per provider.
- New menu bar icon choices for the new logos.
- JetBrains AI (evaluated below, deferred).

## Anti-goals

- Anything that reads Cursor's `state.vscdb` auth rows, a cookie, or a token. Cursor gets a link and nothing else.
- Any request to a Z.ai or MiniMax host when no account of that provider with a pasted key exists. Some users will not want a Chinese company's host contacted at all, so the default must be silence.
- A parser built only from CodexBar's reading of these endpoints. Both are undocumented on public docs sites and both changed shape in 2026.

## Constraints

The hard rules in [design.md](../../design.md#hard-rules) apply unchanged. The relevant ones here:

- Rule 2: the key lives in Tokenjar's own Keychain item (`com.pedromosquera.tokenjar.apikeys`), keyed by account id, as OpenCode Go's does.
- Rule 3: `HTTPClient.allowedEndpoints` gains exactly two entries, `https://api.z.ai/api/monitor/usage/quota/limit` and the MiniMax path chosen below. `HTTPClientTests.allowlistIsPinned` and the request table in privacy.md change in the same commit.
- Rule 5: both endpoints are reads. Nothing calls a chat or completion endpoint.

## Cursor: link only

Mirror Devin.

- New `ProviderID.cursor` (raw value `cursor`), `isLinkOnly == true`, `reportsWindows == false`, `checkUsesNetwork == false`, no status feed, no harness, no sign-in command.
- `CursorUsageFetcher` returns a snapshot with no windows, source "usage page", and the note "Cursor doesn't share your usage with local apps. Open the usage page to see it."
- Default usage page: `https://cursor.com/dashboard?tab=usage`. The builder confirms the current URL in a browser before pinning it in `ModelsTests.defaultUsagePagesArePinned`.
- Discovery: suggest an account when `/Applications/Cursor.app` or `~/Library/Application Support/Cursor` exists, with `showInMenuBar: false`, as Devin does. Nothing inside those folders is read.
- CodexBar import maps `cursor` to `.cursor`.
- Capture: "Cursor has nothing to capture: Tokenjar runs, reads and sends nothing for it."

## Z.ai GLM Coding Plan

- New `ProviderID.glm` (raw value `glm`, display name "GLM Coding Plan"). Usage page: `https://z.ai/manage-apikey/coding-plan/personal/my-plan` (CodexBar's), to be confirmed by the builder against the owner's account.
- Request: `GET https://api.z.ai/api/monitor/usage/quota/limit`, header `authorization: <key>` with no `Bearer` prefix, 20 s timeout. That header form is what Z.ai's own client documents in [zai-org/ZCode docs/coding-plan-quota-remaining-api.md](https://github.com/zai-org/ZCode/blob/main/docs/coding-plan-quota-remaining-api.md). CodexBar sends `Bearer`; if the owner's account rejects the bare key and accepts `Bearer`, use what works and note it.
- Expected answer, per that document and CodexBar's `docs/zai.md`: `data.limits[]`, each entry with `type`, `unit`, `number`, `percentage` (used %) and `nextResetTime` (epoch milliseconds), plus a plan name in `data.planName` (or `plan`, `plan_type`, `packageName`, `level`). Plan V3, sold since 2026-07-30 and so the likely shape of a plan opened now, reports its windows as `CREDIT_LIMIT` (points) instead of `TOKENS_LIMIT`. Both are read the same way.
- Window mapping:

| Entry | Window id | Label | Length |
|---|---|---|---|
| `type` is `TOKENS_LIMIT` or `CREDIT_LIMIT`, `unit == 3`, `number == 5` | `session` | 5-hour | 300 min |
| `type` is `TOKENS_LIMIT` or `CREDIT_LIMIT`, `unit == 6` | `weekly` | Weekly | 10,080 min |
| `type == "TIME_LIMIT"`, `unit == 5`, `number == 1` | `mcp:monthly` | Tools (MCP) | calendar month ending at the reset (`UsageWindow.monthMinutes`) |

- An entry matching none of these is skipped. If the answer has no recognized entry at all, the check fails as a parse error, so a shape change shows up as a failed check rather than an empty card.
- A window at 0 % with a reset in the future is "not started", as OpenCode Go's is.
- Plan name: the first of `data.planName`, `plan`, `plan_type`, `packageName`, `level` that is a non-empty string; otherwise "GLM Coding Plan".
- A successful answer with an empty `limits` array is the calm "No active GLM Coding Plan for this key", never 0 % used: Tokenjar sends only personal-scope requests, so an empty list means the key has no plan. A non-empty list with no recognized entry is a parse failure.
- Errors: classify from recorded answers. Z.ai is known to answer some errors with HTTP 200 and a body with `success: false` and a `code`; the builder records a bad-key answer from the real account and maps it to "Key rejected". 401 is a rejected key, 429 backs off with `Retry-After`, 5xx and transport failures are network errors.

## MiniMax Token Plan

- New `ProviderID.minimax` (raw value `minimax`, display name "MiniMax"). Usage page: `https://platform.minimax.io/user-center/payment/coding-plan`, to be confirmed.
- Request: `GET https://api.minimax.io/v1/token_plan/remains` with `Authorization: Bearer <key>`, 20 s timeout. The key is the Token Plan key (`sk-cp-…`), not a pay-as-you-go `sk-api-` key; the paste field says so.
- One path only. If the owner's account answers only on the legacy path `/v1/api/openplatform/coding_plan/remains`, allowlist that one instead, not both.
- Expected answer, per CodexBar's `MiniMaxModelRemains.swift`: `base_resp.status_code` (non-zero is an error even on HTTP 200), and a `model_remains` array with per-model `current_interval_*` (5-hour) and `current_weekly_*` fields, `end_time` / `weekly_end_time` in epoch milliseconds, optional `*_used_percent` / `*_remaining_percent`, and `*_boost_permill` that can lift the total above 100 %.
- Traps CodexBar documents and the recorded answer must confirm or refute: `current_interval_usage_count` and `current_weekly_usage_count` count what remains, not what was used; prefer an explicit used or remaining percent when present; status 3 with an empty quota marks a model excluded from the plan and is skipped.
- Which entries become windows: only text models with a token quota. Speech, image or video entries, and entries with no 5-hour or weekly total, are skipped. The recorded answer shows which entries those are.
- Window ids: `<model>:session` and `<model>:weekly`, the model name lowercased and reduced to letters and digits, as Antigravity names its pools. If only one text model remains, plain `session` and `weekly` instead. This is decided from the recorded answer and is permanent, because ids key history and alert state.
- Boost: used % is measured against the boosted total, the quota the user can actually spend, so a boost never pushes a window past 100 %. If the recorded answer has no boost, this stays on a hand-written fixture and is listed under Not verified.
- Errors: a non-zero `base_resp.status_code` whose message names auth or the key is "Key rejected"; others are classified from recorded answers like GLM's.

## Shared changes for pasted-key providers

- The key field in Settings is shown by `provider == .opencodeGo` (`AccountDetailView.swift:39`). Replace that check with a `ProviderID.usesPastedKey` property, true for `opencodeGo`, `glm` and `minimax`. `usesAPIKey` (`:607`, today Go and Zen) also becomes true for `glm` and `minimax`; Zen keeps its current behaviour. OpenCode Go keeps its fallback to opencode's `auth.json`.
- Key resolution for the new two: `.keychain(name)` reads the pasted key; `nil` is "not signed in" with no fallback. `.file(path, key)` is also accepted, reusing OpenCode's auth-file reader, only so `--capture` can take a key through the existing `--credential-file FILE --credential-key KEY` flags. Settings never writes a `.file` credential for these providers. For a capture, the owner puts the key in a file under the gitignored `captures/` folder in opencode's `auth.json` shape and deletes it afterwards. No new dev flag and no Keychain read from the unsigned debug binary.
- `--capture glm` and `--capture minimax` work from the first commit that adds each provider, with `CaptureRedactor` allowlists for their fields, because that is how the fixtures are recorded.
- Each provider's fixtures are hand-written from the documented shapes first, labelled as hand-written in the test support file, then replaced by redacted captures from the owner's accounts. `FixtureShapeTests` already scans every fixture for secrets.
- **A valid key with no plan** (a Z.ai pay-as-you-go key with no Coding Plan, a MiniMax `sk-api-` key) is a calm `noSubscription` state ("No active GLM Coding Plan for this key", "No active MiniMax Token Plan for this key"), as OpenCode Go does, never "Key rejected". The owner records that answer by capturing once with a non-plan key if one is at hand; otherwise the mapping stays on a hand-written fixture and is listed under Not verified. No local check of key prefixes.
- **If a live answer needs something the hard rules forbid** (a query parameter such as MiniMax's `GroupId`, another host, cookie auth): stop work on that provider and bring it back to the owner. The other provider carries on.

- For both providers, an HTTP 200 whose body is not JSON (a captive portal or a corporate block page, which is what the owner's work laptop serves for these hosts) is a network error, not a parse failure, so it reads as "Can't reach the server" rather than asking the user to act.

## Shipping

The repo pushes straight to main and the owner installs every push, so anything on main is live. Cursor ships on its own as soon as it is done.

GLM and MiniMax are built against hand-written fixtures now, but their live answers can only be captured from the owner's personal Mac: the work laptop where this is built blocks both hosts, and the plans are not open yet. So GLM and MiniMax go to a pushed `wip/glm-minimax` branch, not main. On the personal Mac the owner opens the plans, checks out that branch, and runs the captures. The fixtures and parsers are then corrected, and the branch is rebased onto main and pushed to main. The branch is deleted after that. This is the one exception to the repo's no-branches habit, and it exists only because the code has to travel between Macs before it is ready.

## Config compatibility

`AccountConfig` decoding fails on an unknown provider. A config synced through dotfiles that gains a `cursor`, `glm` or `minimax` account will not load on a Mac still running an older build. Builder's call (my default): do not add tolerance code; say in the README's update notes to update every Mac before adding one of these accounts to a synced config.

## Logos

- Cursor and MiniMax: `cursor.svg` and `minimax.svg` from simple-icons 16.32.0 (both exist at that version), normalized as described in [logos.md](../../logos.md) with hashes recorded.
- Z.ai: simple-icons 16.32.0 has no `zai` or `zhipuai` icon. Use a stand-in drawn for Tokenjar (a plain "Z" lettermark in the 24 x 24 template style) and document it as a stand-in, like `antigravity.svg`.
- All three follow the text color, like the OpenAI and Copilot marks.

## Docs changed in the same commits

README provider table and requirements, privacy.md (request table, Keychain use, a line saying the Z.ai and MiniMax hosts are contacted only for accounts with a pasted key), design.md (Non-goals provider list, Data sources table, window ids, hard rule 3 list), configuration.md provider list, logos.md, THIRD_PARTY_NOTICES.md, development.md capture list, Settings > About.

## JetBrains AI: evaluated, deferred

- **Use case.** 12.8% of Stack Overflow 2026 respondents used JetBrains AI, and JetBrains' monthly credits draw forum complaints about burning fast. But no request for it was found in nine competing trackers' issue queues, and the owner uses IntelliJ without JetBrains AI, so nobody can check a live answer.
- **Mechanism.** Fits the rules as a local read: `~/Library/Application Support/JetBrains/<IDE><version>/options/AIAssistantQuotaManager2.xml` holds monthly and top-up credits and the next refill; `~/Library/Logs/JetBrains/<IDE><version>/idea.log` has fresher `QuotaManager2Impl` lines. On this Mac only `IdeaIC2024.1` exists and it has no quota file.
- **Complexity: M.** Discovery across every IDE and version folder, choosing the freshest, an internal XML format with no published schema, a log parser, and a file that can lag weeks behind the IDE, all without a real account to record fixtures from.
- **Verdict.** Not now. Revisit if someone asks for it or the owner starts using JetBrains AI.

## Build order

1. Cursor (link only).
2. Shared `usesPastedKey` property, then GLM with hand-written fixtures and capture.
3. MiniMax, reusing step 2.
4. The owner captures both live answers (a good answer, and a bad-key answer by pasting a deliberately wrong key); fixtures and parsers are corrected against them, usage-page URLs are confirmed, then GLM and MiniMax are pushed.

## Left to the builder

Exact Swift type names, file layout under `Sources/TokenjarCore/Providers/`, label wording beyond what is fixed above, test names, and whether GLM and MiniMax share a small helper for "GET with a pasted key and classify the status". Prefer extending OpenCode Go's patterns over a new abstraction.
