Redacted fixtures. Every string that could identify a person or account (emails, uuids, org names, tokens,
prompts) is replaced with a placeholder before it lands here. Field names and shapes come from real answers, and the
numbers in them are made up. Where no real answer could be captured, the fixture is written by hand:

- `Antigravity/`: no answer from a real agy account has been captured, so all five files are written by hand. `usage-camel.json` and `usage-snake.json` follow the field names of CodexBar's agy test fixture.
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
- `Claude/`: the `.settings.json`, `.managed-settings.json` and `.claude.json` files follow Claude Code's documented settings, one per way a login can be billed outside the plan (a gateway, a cloud provider, a key in the settings). `enterprise-usage-based-spend-cap.stream.jsonl` is inferred, since nothing published shows that answer.
- `Codex/`: `rate-limits-workspace-hidden.json` is inferred, since no answer from a workspace that hides its limits has been captured.
