# Headroom

A personal macOS menu bar app that shows how much room is left on each AI subscription (Claude, Codex, OpenCode Go/Zen, Antigravity) before the next limit, whether the current pace runs out before the window resets, and what usage costs over time.

Built from source with Command Line Tools only. It never reads or refreshes an OAuth token: Claude and Codex usage comes from their own CLIs, and the only network request the app makes itself goes to `opencode.ai`.

```
make test      # Swift Testing under Command Line Tools
make install   # build, bundle, ad-hoc sign, copy to ~/Applications, launch
```

See [docs/design.md](docs/design.md) for the design and [docs/privacy.md](docs/privacy.md) for exactly what it reads and contacts.
