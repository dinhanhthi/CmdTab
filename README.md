<div align="center">

<img src="assets/logo.png" width="128" alt="CmdTab logo">

# CmdTab

**Cmd+Tab between windows, not apps, on macOS.**

By Anh-Thi DINH. MIT licence. [github.com/dinhanhthi/CmdTab](https://github.com/dinhanhthi/CmdTab)

</div>

CmdTab is a small menu bar app that replaces the system Cmd+Tab with a switcher that lists windows, front to back, instead of one entry per app.

## Features

- Lists windows, not apps: two windows of the same app are two entries, in front-to-back order.
- "Show windows from": the screen under the mouse pointer (default) or all screens.
- Minimized windows and the windows of hidden apps are skipped.
- A quick tap (press and release) switches to the previous window at once, without drawing anything.
- Hold the modifier and the panel shows the windows as thumbnails. Cached thumbnails show at once; they are refreshed only once the panel has stayed open for a short moment (about 0.2 s).
- The app's icon on each preview, and the window title under it.
- Tab moves forward, Shift+Tab back, both wrap around. Left / Right move too, Escape closes without switching. Releasing the modifier switches to the highlighted window. The mouse works too: hover highlights a tile, a click switches to it. Holding Tab repeats like a held key.
- Hotkey: ⌘ Tab (default), ⌥ Tab or ⌃ Tab. With ⌥ or ⌃, the system Cmd+Tab keeps working beside CmdTab.
- Theme: System, Dark (default) or Light.
- Thumbnail size and App icon size: Small, Medium or Large each.
- Hide animation: None (default) or Fade out.
- "Show CmdTab in": Dock, Menu bar (default) or Hidden. When hidden, open CmdTab again to show Settings.
- "Enable CmdTab" in the menu bar menu turns the switcher off and on; off gives Cmd+Tab back to the system.
- Start at login.
- Updates through Sparkle ("Check for Updates…" in the menu and in Settings > About).

All settings live in the Settings window (menu bar icon > Settings…), in four sections: General, Appearance, Permissions and About. Every change applies at once.

## Requirements

- macOS 15 or later, on Apple silicon: release builds are arm64 only. An Intel (universal) build is possible with `ARCHS="arm64 x86_64"` on `scripts/build-and-notarize.sh` or `scripts/ship.sh`, but has never been run on an Intel Mac.
- CmdTab has been built and tested on macOS 27 only. It compiles for macOS 15, but macOS 15 to 26 have not been tested.

## Permissions

- **Accessibility** (required): CmdTab reads each app's windows through Accessibility to tell real windows from sheets and panels, and to bring the chosen window to the front. Without it CmdTab does not take over the hotkey, the system Cmd+Tab keeps working, and Settings opens on Permissions with a "Grant…" button. A new grant takes effect without a relaunch. On macOS 27 the pane is "Device Control and Data Access".
- **Screen Recording** (optional): for window previews and titles. Without it CmdTab shows app icons and names instead. The grant applies after CmdTab restarts. On macOS 27 the pane is "Screen & System Audio Recording". The first capture may show the macOS alert "CmdTab is requesting to bypass the system private window picker and directly access your screen and audio" (buttons Allow / Open System Settings); how often macOS shows it again is not known yet.

## Private API

CmdTab calls two private macOS functions, declared in `App/CmdTab-Bridging-Header.h`. Both resolve through the system frameworks CmdTab already links (CoreGraphics, ApplicationServices); no private framework is linked. A macOS update may change or remove them.

- `CGSSetSymbolicHotKeyEnabled`: turns the system's Cmd+Tab and Cmd+Shift+Tab off while CmdTab uses ⌘ Tab, and back on when it stops. This setting lives in the WindowServer and outlives the process that changed it (see the next section).
- `_AXUIElementGetWindow`: gives the window ID behind an Accessibility window, so CmdTab can match the windows it lists with what Accessibility reports and focus exactly the chosen one.

## If the native Cmd+Tab stops working

CmdTab turns the system Cmd+Tab back on when it quits normally, when it is terminated (`kill`), and on most crashes. A force quit cannot be caught: after a force quit or `kill -9`, the system Cmd+Tab stays off, and pressing it shows no switcher, until CmdTab is opened again and quit normally.

To get it back:

1. Open CmdTab again (from `/Applications`, or `open -a CmdTab`).
2. Quit it normally: menu bar icon > Quit CmdTab, or `osascript -e 'quit app "CmdTab"'` when the icon is hidden.

## Known limitations

- Only the current Space: windows on other Spaces are not listed.
- Minimized windows and hidden apps are not listed, by design.
- Tiles are capped by the screen size: the panel never grows past 90 % of the screen, and windows whose tiles do not fit are not shown (there is no scrolling).
- A Cmd+Tab within about 0.3 s of a sheet appearing (for example a Save sheet), or right after an app was launched, can land on the sheet's own document instead of the next window.
- With the Control modifier, Left / Right are not available in the switcher: Control+Left / Control+Right stay Mission Control's shortcuts. Tab, Shift+Tab and Escape still work. ⌃ Tab also takes over tab switching in browsers.

## Build

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and is not in git.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project CmdTab.xcodeproj -scheme CmdTab -configuration Debug build
xcodebuild -project CmdTab.xcodeproj -scheme CmdTab -configuration Debug test
```

- Debug is signed with Developer ID (team in `project.yml`), so the Accessibility and Screen Recording grants survive rebuilds. A clone without that certificate builds ad hoc with:

  ```sh
  xcodebuild -project CmdTab.xcodeproj -scheme CmdTab -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=
  ```

  Such a build loses the permission grants on every rebuild. The same overrides apply to the `test` command (the scheme builds the app for testing).
- The tests are hostless: they compile the switcher's pure logic directly, so they never launch CmdTab or touch the system hotkeys.

## Performance

Budgets on real hardware:

| Metric | Budget |
| --- | --- |
| `press`: hotkey pressed → session ready | p50 ≤ 6 ms, max ≤ 16 ms |
| `showPanel`: hold timer fired → panel on screen | p50 ≤ 12 ms, max ≤ 25 ms (press → visible ≤ 125 ms) |
| `step`: Tab / arrow → highlight moved | p50 ≤ 2 ms, max ≤ 8 ms |
| `focus`: switch → window focused (off the main thread) | p50 ≤ 50 ms, max ≤ 300 ms |
| `capture`: one window thumbnail (off the main thread) | p50 ≤ 40 ms |
| Idle CPU, 30 s, no session | average ≤ 0.1 % |
| Idle wakeups, 30 s | ≤ 30 in total |
| Memory, Settings never opened | ≤ 40 MB before the first panel; ≤ 65 MB after 20 hold sessions at Medium |

Measured so far only in a macOS 27 virtual machine, where timings are slower than on real hardware (VM runs scale the latency budgets by 3):

- `press` p50 13.37 ms, max 31.94 ms; `showPanel` p50 1.37 ms, max 3.06 ms; `capture` p50 24.47 ms.
- From an earlier run: `step` p50 0.04 ms, max 0.21 ms; `focus` p50 6.38 ms, max 31.18 ms.
- Idle: 0.00 % CPU, 0 idle wakeups in 30 s, 12 MB.

These numbers are not host numbers. `press` (p50 about 13 ms in the VM) has not been checked against its 6 ms host budget yet.

To measure on your Mac, run CmdTab and use `scripts/measure.sh` (the last line says PASS or FAIL):

```sh
scripts/measure.sh idle                          # 30 s, memory budget 40 MB
scripts/measure.sh idle 30 65                    # after 20 hold sessions
scripts/measure.sh latency 10                    # perf lines CmdTab logged in the last 10 minutes
BUDGET_SCALE=3 scripts/measure.sh latency 10     # in a VM
```

`latency` reads CmdTab's log with `log show`. If it fails with "Could not open local log store: Operation not permitted", run it from a Terminal that has Full Disk Access, or as `sudo scripts/measure.sh latency 10`.

## Releasing

Releases are maintainer-only, see [docs/RELEASING.md](docs/RELEASING.md).

## License

MIT, see [LICENSE](LICENSE).
