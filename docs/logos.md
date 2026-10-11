# Logos

Provider marks in `Resources/Logos/`, loaded by `ProviderLogo` as `<ProviderID.logoName>.svg`. All come from the [simple-icons](https://github.com/simple-icons/simple-icons) npm package at a pinned version, served by jsDelivr. Nothing is fetched at build or run time; the files are committed. `copilot.svg` is GitHub Copilot's mark, and `windsurf.svg` stands in for Devin (see below). Tokenjar's own menu bar marks are in `Resources/Marks/`, described under [Marks](#marks).

| File | Source URL | Package version | SHA-256 of committed file | SHA-256 of upstream file | Brand hex |
|---|---|---|---|---|---|
| `claude.svg` | https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/claude.svg | simple-icons 16.32.0 (published 2026-09-20) | `99e3f2813f4c4572231d10b37e0b622d2f59de97a74b40e55d02689362ca1b17` | `2d6fda79eb18ddccca35b799eeb3cece0dfabc22520ce3b10abd25668df9fa93` | `#D97757` |
| `openai.svg` | https://cdn.jsdelivr.net/npm/simple-icons@15.22.0/icons/openai.svg | simple-icons 15.22.0 (published 2025-11-23) | `3ab5be980dba66365b5868e8919eda293a3068b8ddedd9d64a5ea978cf951ae4` | `2b4a04ddc2395b20d168694d3850ce2050a702c4a0cdeb4d8b31b9a970481a8c` | `#412991` |
| `opencode.svg` | https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/opencode.svg | simple-icons 16.32.0 (published 2026-09-20) | `1e4cf7115b3a697bc4d4695abc826c64b685d1691140f8965623adf2b53de576` | `6f7d203200ba051cdbaa726c4de0a729cee3f1cec47953f189399d951af58c4c` | `#000000` |
| `antigravity.svg` | https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/googlegemini.svg | simple-icons 16.32.0 (published 2026-09-20) | `2879700fcd4cc6e0f6a64ff85453ec494538fc161347a0411cc6a62dd50080bc` | `a6228d8846040401e941a39ed17459785e8324dbb7b870ce84233c9b3e9863a0` | `#8E75B2` |
| `copilot.svg` | https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/githubcopilot.svg | simple-icons 16.32.0 (published 2026-09-20) | `09d6bb1e34f0e0b993dbb131de510daf942397ff6a767782a32f6c8477e345a8` | `c72c1e0018e84b3128c5a1ac43ec2be135ac6ec4eb9c0ea18ed76416d23f2af3` | `#000000` |
| `windsurf.svg` | https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/windsurf.svg | simple-icons 16.32.0 (published 2026-09-20) | `32b8612ce3f45366e8748a39fed19c0370a9c1faf103b2dfe4f6a5d2cd72b6c4` | `6a084cb5c1a82bbf3eeda54e3bf450bf8d4a9368d80b815db22116b6b00a2aae` | `#0B100F` |

Brand hex values come from `data/simple-icons.json` in the same package version. The files themselves are black, so draw them as templates and tint them at runtime. Drawn as-is they nearly vanish on a dark background.

In the app, `ProviderLogoView` draws each file as a template, tinted `#D97757` for Claude and `#8E75B2` for Antigravity. The OpenAI, OpenCode, GitHub Copilot and Windsurf (Devin) marks follow the text color instead, so they read in dark mode and their brand hex is unused. The menu bar shows a provider logo only when the user picks it as the menu bar icon in Settings > General; it is then a monochrome template, drawn at its own 16 pt and tinted only with a severity color, and the picker names `antigravity.svg` "Gemini" and `windsurf.svg` "Windsurf / Devin" after what they show. `make app` copies `Resources/Logos/` into `Contents/Resources/Logos`; a binary run from `.build` falls back to the repo's `Resources/Logos/`. `LogoAssetTests.everyProviderHasALoadableLogoAtMenuBarSize` checks that every provider's file, `copilot.svg` and `windsurf.svg` included, loads with `NSImage(contentsOf:)` at 16 x 16 pt.

## Why these versions

- **16.32.0** is the newest release published at least two weeks before 2026-10-10. Versions are pinned exactly, never `latest`.
- **OpenAI** was removed from simple-icons in 16.0.0. 15.22.0 is the last 15.x release, and `icons/openai.svg` exists at that version.
- **Antigravity** has no simple-icons slug in 16.32.0 (nor in 16.34.0, the newest release on 2026-10-10). `antigravity.svg` is the **Google Gemini mark used as a stand-in**. Replace it when simple-icons adds an Antigravity icon, or with Google's own mark after checking its guidelines.
- **Devin** has no simple-icons slug in 16.32.0. `windsurf.svg` is the **Windsurf mark used as a stand-in** for it. Replace it when simple-icons adds a Devin icon, or with Devin's own mark after checking its guidelines.

## How the files were normalized

Each upstream file is a single `<path>` in a `0 0 24 24` viewBox. The committed file keeps that path data byte for byte and only changes the wrapper:

- dropped `role="img"` and `<title>`;
- set `fill="#000000"` on the path, so the file works as an `NSImage` template (only alpha matters once `isTemplate` is set);
- kept the square `0 0 24 24` viewBox and added `width="16" height="16"`, because `NSImage` reads those as the image size in points and 16 pt is the right height for a menu bar glyph. Views that call `.resizable()` are unaffected.

Each file was checked with `NSImage(contentsOf:)` (non-nil, 16 x 16 pt, `_NSSVGImageRep`), rasterized at 16 and 128 px, and drawn as a tinted template. `copilot.svg` and `windsurf.svg` were checked for size and rasterized when they were added, before any code drew them; the app now draws them as templates for GitHub Copilot and Devin accounts and in the menu bar icon picker.

To check a file against its source, download the upstream URL and compare its hash with the upstream column:

```
curl -sSf https://cdn.jsdelivr.net/npm/simple-icons@16.32.0/icons/claude.svg | shasum -a 256
```

## License and trademarks

- The simple-icons collection is released under **CC0 1.0** (`LICENSE.md` in the package). Its `DISCLAIMER.md` notes that CC0 for the collection does not mean every icon is CC0.
- The marks are **trademarks of their owners**: Claude (Anthropic), OpenAI, OpenCode, Google Gemini (Google), GitHub Copilot (GitHub) and Windsurf. CC0 covers the SVG drawing, not the trademark.
- These logos are here for **personal, non-distributed use only**: a menu bar app built from source for one user.
- **Do not publish this repository, or a build of it, with these logos** without first checking each brand's guidelines. simple-icons lists OpenAI's at https://openai.com/brand and Windsurf's at https://windsurf.com/brand. It lists no guidelines URL for Claude, OpenCode, Google Gemini or GitHub Copilot; GitHub's own logo page is https://github.com/logos. Check each owner's site.

## Marks

`Resources/Marks/` holds five more menu bar marks for the icon picker in Settings > General: `mana.svg`, `taper.svg`, `tally.svg`, `burnrate.svg` and `genio.svg` (`menuBar.icon` values `mark:mana` and so on). They are not provider or brand marks and do not come from simple-icons. The default menu bar icon, the cooldown slot, is not a file: `StatusGlyph` draws it in code, and `Resources/AppIcon.svg` draws the same slot for the app icon.

- Each is a black drawing in an SVG whose `width` and `height` are set, so `NSImage` reads its size in points: 18 pt tall, with the view box trimmed to the ink plus about 0.25 pt of side room (Taper and Burnrate are 12 wide, Mana 13, Genio 16, Tally 18). Genio's view box is also moved up 1.6 so its ink is centered.
- The menu bar draws them as templates, like the logos: black or white with the menu bar, tinted only with a severity color, faded when stale and with the failure dot. Only the slot shows the fill level; a mark is static.
- `make app` copies `Resources/Marks/` into `Contents/Resources/Marks`, and `ProviderLogo.resourceURL("Marks/<name>.svg")` loads them through `Bundle.main`, falling back to the repo's `Resources/Marks/` from `.build`. A mark that fails to load falls back to the slot.
- The picker draws each choice centered on an 18 pt square so its rows line up whatever the glyph's width.
