# Quickbar

A personal LaunchBar replacement for macOS. Native Swift, AppKit, no dependencies.
Claude owns and maintains this code; Nino uses it daily.

## The one rule

**The bar must respond immediately, always.** The app exists because LaunchBar
froze. Every change is judged against this first.

- The main thread draws and handles keys. Nothing else. No file I/O, no network,
  no directory listing, no icon loading, no Launch Services calls on it.
- Anything slow goes to a background queue and delivers a finished result to the
  main thread. Stale results are dropped (see `generation` in `LauncherController`).
- Search runs over an immutable in-memory snapshot (`SearchIndex`). Do not add
  locks, lazy loading or per-keystroke allocation of `Item`s to the search path.
- The hotkey handler only shows a panel that already exists.
- After touching the search path, run `.build/release/Quickbar --bench` and
  compare. Typical: around 0.1 ms per query on ~3k items. Never hash item ids
  per match; resolve anything keyed by id to index positions once per query.

## Layout

- `Sources/QuickbarCore` — pure logic, no AppKit, unit tested. Matching, index,
  learning, calculator, URL detection, config, scanning, clipboard model, snippets.
- `Sources/Quickbar` — the app. `LauncherController` is the state machine
  (root / browse folder / search text). `QueryEngine` turns (mode, text) into
  rows on the search queue.
- `Resources/Info.plist`, `scripts/` — bundle assembly. There is no Xcode project.
  The icon is an Icon Composer document, `Resources/AppIcon.icon`, written and
  compiled by `python3 scripts/make-icon.py` into `Assets.car` (Liquid Glass)
  and `AppIcon.icns` (fallback). Needs Xcode's `actool` only for redrawing;
  the compiled files are checked in. Preview renditions with Icon Composer's `ictool`.
- `TextInserter` posts synthetic keys (⌘V, or the text key by key) for
  snippets. It needs the Accessibility permission and runs on its own queue.
- Shared look (`Theme`, `TintedBox`, `KeyHintBar`) lives in `PanelViews.swift`.
  The footer hints must stay true to what the keys do for the selected row.
- `PLAN.md` — stages and ideas not yet built.

User data lives in `~/Library/Application Support/Quickbar/`
(`config.json`, `learning.json`, `clipboard.json`, and `clipboard-data/` for
copied images and rich text; files there are named by entries in the history
and orphans are deleted at launch).

## Commands

```bash
swift test                      # core unit tests
swift build -c release          # compile
scripts/build-app.sh            # build/Quickbar.app, signed
scripts/install.sh              # build, copy to /Applications, restart
```

## Checking changes without a keyboard

The binary has a headless harness (`DebugHarness.swift`). It builds the real
index, drives the launcher, prints rows and can render the panel to a PNG. It
registers no hotkeys, does not watch the clipboard, and writes nothing to disk.

```bash
B=.build/release/Quickbar
$B --bench
$B --script type:saf --dump
$B --script "type:/usr/lo" key:right key:down --dump --snapshot /tmp/out.png
$B --script type:kagi "type:kagi " "type:swift conc" wait:1.5 --dump
```

Steps: `type:<text>` sets the field as if typed; `key:<up|down|left|right|tab|return|backspace>`;
`wait:<seconds>`. The blur behind the panel is not captured in snapshots.
Add `--dark` to render in dark mode, `--clipboard` to snapshot the clipboard
panel with sample entries, and `--settings <0-4>` to snapshot a Settings pane
(it renders grey because the window is never shown or made key).
`--no-files` indexes no folders: use it for anything that will be published
(the README images in `docs/screenshots/`), so no personal file names appear.
`--snippets` replaces the snippets with two samples, for the same reason.
In the harness, ↩ on a snippet prints what it would insert and posts no keys. Look at both appearances after any visual change.

What the harness cannot check: global hotkeys, focus, the retype timer's
select-all, the clipboard panel's modifier-release commit, snippets arriving
in another app (paste and typing), and what the Settings controls do when used. Check those in the running app.

## Logs

`~/Library/Logs/Quickbar.log`. `Log.info` always writes; `Log.debug` only when
launched with `open --env QUICKBAR_DEBUG=1 build/Quickbar.app`. The live app can
be driven with `osascript` + System Events key codes and checked through the
log, the pasteboard and the files in Application Support. Do not use
`screencapture`: it raises a screen-recording prompt on Nino's machine.

## Conventions

- Swift 5 language mode (see `Package.swift`); AppKit for the bar, SwiftUI only
  in the Settings window.
- Sign with the Apple Development identity (the build script finds it). Privacy
  grants are tied to the signature; ad-hoc signing re-prompts on every build.
- Config fields must have defaults and be read with `decodeIfPresent`
  (`Config.init(from:)`), so old config files keep loading.
- Item ids are stable strings: file paths for file-system items, `template:<id>`,
  `action:<name>`, `settings:<bundle id>`, `snippet:<id>`. Learning and custom abbreviations key on them.
- Comments say why, not what.
- Commit in small stages with the tests passing.
