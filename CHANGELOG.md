# Changelog

All notable changes to CmdTab are listed here. `scripts/publish-release.sh` uses the `## [X.Y.Z]` section of the version being released as the GitHub Release notes.

## [Unreleased]

### Added
- When not all windows fit, the previews shrink so more of them show (Settings > Appearance > Shrink to fit, on by default).
- Settings > General can list minimized windows and the windows of hidden apps (both off by default); they show after the other windows with a badge, and choosing one restores it.

## [0.1.1] - 2026-11-11

### Added
- Window previews are captured in the background when CmdTab starts, so the first Cmd+Tab on any screen already shows them instead of app icons.
- When the menu bar icon is shown and a new version is available, the icon gets a small green download badge and its menu shows "Update to CmdTab <version>…" instead of an alert popping up.

### Changed
- New app logo.
- The selection highlight in the switcher stands out more.

### Fixed
- Cached previews are kept when you switch between screens of different scales (for example a Retina and a non-Retina display).
- Choosing a window now reliably brings its app forward and makes that exact window the key window.

## [0.1.0] - 2026-11-11

- First version.
