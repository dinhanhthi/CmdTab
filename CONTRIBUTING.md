# Contributing to CmdTab

## Setup

Needs macOS 15 or later, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and is not in git: run `xcodegen generate` again after you add, remove or move a file, or edit `project.yml`.

```sh
brew install xcodegen
xcodegen generate
open CmdTab.xcodeproj
```

## Build and test

```sh
xcodebuild -project CmdTab.xcodeproj -scheme CmdTab -configuration Debug build
xcodebuild -project CmdTab.xcodeproj -scheme CmdTab -configuration Debug test
```

- **Signing**: Debug is signed with Developer ID (team in `project.yml`), so the Accessibility and Screen Recording grants survive rebuilds. Without that certificate, add these overrides to `build` and `test`:

  ```sh
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=
  ```

  An ad hoc build loses its permission grants on every rebuild: remove CmdTab from the Accessibility list in System Settings and grant it again.
- **Tests** are hostless: `CmdTabTests` compiles `WindowFilter.swift` and `SwitcherSession.swift` directly, so tests never launch CmdTab or touch the system hotkeys. Keep logic you want to test in pure, AppKit-free files like these and add them to the test target's `sources` in `project.yml`.
- **Intel**: release builds are arm64 only. `ARCHS="arm64 x86_64"` on `scripts/build-and-notarize.sh` or `scripts/ship.sh` gives a universal build, never run on an Intel Mac so far.

## Project layout

```
App/                    App, settings, status item, permissions, updater (Sparkle)
App/Switcher/           The switcher: hotkey, session, window list, capture, focus, panel
App/Perf.swift          perf timings and signposts
Tests/CmdTabTests/      Hostless unit tests
scripts/                Release and measurement scripts
docs/RELEASING.md       Release guide (maintainer only)
```

## Things to know

- **Private APIs**, declared in `App/CmdTab-Bridging-Header.h` and resolved through CoreGraphics and ApplicationServices (no private framework is linked):
  - `CGSSetSymbolicHotKeyEnabled` turns the system Cmd+Tab off while CmdTab uses ⌘ Tab. The setting lives in the WindowServer and outlives the process.
  - `_AXUIElementGetWindow` maps an Accessibility window to its window ID.
- **Lost the system Cmd+Tab?** Stopping CmdTab from Xcode or with `kill -9` skips the cleanup, so the system Cmd+Tab stays off. Launch CmdTab again and quit it normally (`osascript -e 'quit app "CmdTab"'`). Or develop with the ⌥ Tab hotkey, which leaves the system Cmd+Tab alone.
- **Screen Recording** grants apply only after CmdTab restarts.
- **Logs**: subsystem `com.math2it.cmdtab`, categories `Perf`, `Input`, `Permissions`, `Updater`.

  ```sh
  log stream --predicate 'subsystem == "com.math2it.cmdtab"'
  ```

## Performance

Changes to the switcher must stay within these budgets on real hardware:

| Metric | Budget |
| --- | --- |
| `press`: hotkey pressed → session ready | p50 ≤ 6 ms, max ≤ 16 ms |
| `showPanel`: hold timer fired → panel on screen | p50 ≤ 12 ms, max ≤ 25 ms |
| `step`: Tab / arrow → highlight moved | p50 ≤ 2 ms, max ≤ 8 ms |
| `focus`: switch → window focused (off the main thread) | p50 ≤ 50 ms, max ≤ 300 ms |
| `capture`: one window thumbnail (off the main thread) | p50 ≤ 40 ms |
| Idle CPU, 30 s, no session | average ≤ 0.1 % |
| Idle wakeups, 30 s | ≤ 30 in total |
| Memory, Settings never opened | ≤ 40 MB before the first panel; ≤ 65 MB after 20 hold sessions |

Run CmdTab, use the switcher, then check (the last line says PASS or FAIL):

```sh
scripts/measure.sh idle                          # 30 s, memory budget 40 MB
scripts/measure.sh idle 30 65                    # after 20 hold sessions
scripts/measure.sh latency 10                    # perf lines from the last 10 minutes
BUDGET_SCALE=3 scripts/measure.sh latency 10     # in a VM
```

If `latency` fails with "Could not open local log store: Operation not permitted", run it from a Terminal with Full Disk Access, or with `sudo`.

## Pull requests

- Keep each change small and focused, and match the style of the code around it.
- Commit messages are one line: `<type>(<scope>): <summary>`, with `feat`, `fix`, `docs`, `style`, `refactor`, `test` or `chore`.
- Add user-facing changes under `## [Unreleased]` in `CHANGELOG.md`.
- Make sure `build` and `test` pass. For switcher changes, include the `measure.sh` output.
- Say which macOS version you tested on.

Releases are maintainer-only, see [docs/RELEASING.md](docs/RELEASING.md).
