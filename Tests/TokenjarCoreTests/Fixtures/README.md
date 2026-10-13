Redacted fixtures. Every string that could identify a person or account (emails, uuids, org names, tokens,
prompts) is replaced with a placeholder before it lands here. Field names and shapes come from real answers, and the
numbers in them are made up. Where no real answer could be captured, the fixture is written by hand:

- `Antigravity/`: no answer from a real agy account has been captured, so all five files are written by hand.
  `usage-camel.json` and `usage-snake.json` follow the field names of CodexBar's agy test fixture.
  `enterprise-no-quota.stdout.json`, `renamed-groups-envelope.stdout.json` and `model-turn.stdout.json` are copies of
  the synthetic envelopes in `Plans/antigravity/`.
- `Copilot/`: the fixtures follow the shape of gh's filtered answer. Most Copilot plans have not been checked against a
  real account, so their fields follow what VS Code's Copilot extension and CodexBar read.
- `ProviderHealth/`: public status page answers, which hold no personal data. `claude-console-only.json` is
  status.claude.com's `summary.json` as fetched on 2026-10-12. Each other Claude and GitHub file is that day's answer with
  one incident from the provider's own history put back as it stood at an earlier update, and the component statuses
  that update recorded. Four are edited further, as their tests say: `claude-many-models-down.json` keeps the components
  down at the second update, `claude-spend-limits.json` is an incident posted already resolved, reopened,
  `claude-mixed.json` gives each of three incidents one component, and the maintenances in it and in
  `claude-maintenance.json` are written by hand, since none has been captured. `openai-proxy.json` is
  status.openai.com's page data with the fields Tokenjar does not read left out; tests fill in its affected components,
  whose shape follows CodexBar's decoder because none were affected when it was saved.
- `Plans/`: fixtures for each plan and account state a provider can report, all mocked. Each provider folder has a
  `manifest.json` that lists its cases, and a `recorded` case reads its captures from the folders above. A case's
  `confidence` is `recorded` when every input it names has the shape of a real answer, `documented` when its shape
  comes from the provider's docs or source or from CodexBar, and `inferred` when nothing published shows it. Input
  paths are relative to `Plans/`; a `fixtures:` prefix points into this folder instead. `blocked` names the capture a
  case waits for, and `preview: false` marks a case with no account to show. Copilot's `raw/` files are
  `copilot_internal/user` bodies, and each `filtered/` twin is that body after the fetcher's pinned jq filter.
