# Third-party notices

Tokenjar's own code is under the MIT License in [LICENSE](LICENSE). The files below come from other projects, or are adapted from them, and keep their own terms.

## Primer Octicons

`Resources/Logos/copilot.svg` is the path of the `copilot-24` icon from [Primer Octicons](https://github.com/primer/octicons), taken through simple-icons 16.32.0, which lists it under the MIT License. [docs/logos.md](docs/logos.md) records the source and how the file was changed.

```text
MIT License

Copyright (c) 2026 GitHub Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## CodexBar

These test fixtures are adapted from the tests of [CodexBar](https://github.com/steipete/CodexBar):

- `Tests/TokenjarCoreTests/Fixtures/Plans/copilot-devin/copilot/raw/user-business-credits-with-monthly-completions.json` and its twin under `filtered/` reproduce a `copilot_internal/user` body from CodexBar's `Tests/CodexBarTests/CopilotUsageModelsTests.swift`, with identity fields added as placeholders.
- `Tests/TokenjarCoreTests/Fixtures/Antigravity/usage-camel.json` and `usage-snake.json` follow the field names of CodexBar's agy test fixture. The `.stdout.json` envelopes in `Tests/TokenjarCoreTests/Fixtures/Plans/antigravity/` that list quota groups use the same shape and its group and bucket labels, and `Fixtures/Antigravity/renamed-groups-envelope.stdout.json` is a copy of one of them.
- `Tests/TokenjarCoreTests/Fixtures/Plans/opencode/go-usage-v2-console-meters.json` borrows its meter shape from a CodexBar fixture of `/console/api/go/status`.

```text
MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## simple-icons

`Resources/Logos/claude.svg`, `openai.svg`, `opencode.svg`, `antigravity.svg` and `windsurf.svg` come from [simple-icons](https://github.com/simple-icons/simple-icons) at the versions [docs/logos.md](docs/logos.md) pins. The simple-icons collection is released under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). CC0 covers the drawings, not the trademarks they show.

## Trademarks

Product names and logos belong to their owners. Tokenjar is not affiliated with or endorsed by Anthropic, OpenAI, Google, GitHub, OpenCode, Cognition, Windsurf or CodexBar. The logos are used only to identify each provider.
