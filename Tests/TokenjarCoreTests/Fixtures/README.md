Redacted fixtures. Every string that could identify a person or account (emails, uuids, org names, tokens,
prompts) is replaced with a placeholder before it lands here. Numbers and field names are real, except where no live
answer could be captured, so the fixture is written by hand:

- `Antigravity/`: agy is not installed on the build machine, so all five files are written by hand. `usage-camel.json`
  and `usage-snake.json` follow the field names of CodexBar's agy test fixture. `enterprise-no-quota.stdout.json`,
  `renamed-groups-envelope.stdout.json` and `model-turn.stdout.json` are copies of the plan matrix's synthetic
  envelopes in `Plans/antigravity/`.
- `Copilot/`: the fixtures follow the shape of gh's filtered answer. Most Copilot plans have
  not been probed, so their fixtures follow the shapes VS Code's Copilot extension and CodexBar read.
- `Plans/`: fixtures for the plan matrix, all mocked. A `recorded` case reads its live captures from the folders above.
  Each provider folder has a `manifest.json` with one case per matrix row. A case's `confidence` is `recorded` when
  every input it names is a live capture, `documented` when its shape comes from the provider's docs or source or from
  CodexBar, and `inferred` when nothing published shows it. Input paths are relative to `Plans/`; a `fixtures:` prefix
  points into this folder instead. `blocked` names the capture a case waits for, and `preview: false` marks a case with
  no account to show. Copilot's `raw/` files are `copilot_internal/user` bodies, and each `filtered/` twin is that body
  after the fetcher's pinned jq filter.
