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
  compare. Typical: well under 1 ms per query on ~3k items.

## Layout

- `Sources/QuickbarCore` — pure logic, no AppKit, unit tested. Matching, index,
  learning, calculator, URL detection, config, scanning, clipboard model.
- `Sources/Quickbar` — the app. `LauncherController` is the state machine
  (root / browse folder / search text). `QueryEngine` turns (mode, text) into
  rows on the search queue.
- `Resources/Info.plist`, `scripts/` — bundle assembly. There is no Xcode project.
- `PLAN.md` — stages and ideas not yet built.

User data lives in `~/Library/Application Support/Quickbar/`
(`config.json`, `learning.json`, `clipboard.json`).

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

What the harness cannot check: global hotkeys, focus, the retype timer's
select-all, the clipboard panel's modifier-release commit, and the Settings
window. Check those in the running app.

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
  `action:<name>`. Learning and custom abbreviations key on them.
- Comments say why, not what.
- Commit in small stages with the tests passing.
