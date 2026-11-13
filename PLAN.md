# Quickbar implementation plan

A LaunchBar replacement that does a small set of things and never makes you wait.

## Principles

1. **The main thread only draws and handles keys.** No file I/O, no network, no
   scanning, no icon loading on it. Everything else runs on background queues
   and hands finished results back.
2. **Search is in-memory.** The index is an immutable snapshot (one contiguous
   byte blob plus a bitmask per item). A keystroke scans it in well under a
   millisecond for a typical index; the target is < 5 ms at 50k items.
3. **The panel is created once at launch** and only shown/hidden afterwards.
   The hotkey handler does nothing but `orderFront`.
4. **No dependencies.** AppKit + Carbon hotkeys + Foundation. SwiftUI only for
   the Settings window, which is not on the hot path.

## Architecture

```
Sources/QuickbarCore   pure logic, unit tested, no AppKit
  FuzzyMatcher         abbreviation scoring (DP over bytes)
  SearchIndex          immutable snapshot + search
  LearningStore        abbreviation -> item learning, usage counts
  Calculator           recursive-descent arithmetic
  URLDetector          "is this a URL?"
  Config               JSON config with defaults
  ClipboardHistory     dedupe + cap model
  FileScanner          apps / folders / directory listings
  Suggestions          OpenSearch suggestion parsing (Kagi)

Sources/Quickbar       the app
  HotKey               Carbon global hotkeys
  LauncherPanel        the bar: text field + results table
  LauncherController   state machine: root / browse folder / search text
  IndexManager         background scans + FSEvents
  IconCache            async icons
  ClipboardMonitor     pasteboard polling on a background queue
  ClipboardPanel       cmd-\ cycling UI
  SettingsWindow       SwiftUI settings
```

## Stages

Status (2026-11-13): all stages are built and Quickbar is installed in
/Applications. Verified live: hotkey, search, launch, retype select-all, math,
clipboard cycling, Settings opens, rescan after a file is added or removed.
Not yet exercised by hand: the individual Settings controls, launch at login.

| # | Stage | Done when |
|---|-------|-----------|
| 1 | Repo, package, build script, docs | `swift build` and `scripts/build-app.sh` work |
| 2 | Core: fuzzy matcher, index, learning, calculator, URL detection, config | `swift test` green, perf test under budget |
| 3 | App shell: hotkey, panel, results list, open apps | hotkey shows bar, typing finds and launches apps |
| 4 | Indexing: configured folders, FSEvents, folder browsing with arrows | arrows walk the hierarchy, enter opens |
| 5 | Calculator, URLs, search templates, Kagi suggestions | `2+2`, pasted URL, `kagi<space>query` all work |
| 6 | Learning + custom abbreviations + retype delay | 3 selections flips the ranking; overrides win |
| 7 | Clipboard history + cmd-\ cycling | copies captured, cycling commits on release |
| 8 | Settings window, launch at login | folders/hotkeys/abbreviations editable |
| 9 | Verify in the running app, install | installed in /Applications and running |

## Later / ideas

- Rich clipboard entries (images, files), paste-on-release
- System Settings panes, contacts, bookmarks in the index
- Main-thread stall watchdog
- Search is ~0.8 ms for one-letter queries on 3k items; nearly all of it is in
  `Fuzzy.score`. If the index grows past ~30k items, profile that loop first.
- LaunchBar also registers ⌘\\ for its clipboard history; while both run, both react.
