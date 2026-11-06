# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-06

### Changed

- A new look shared with Panefold: dashboard cards sit on soft surfaces with plain
  section labels, page titles are larger, and numbers use the system font.
- Settings is one window with a searchable sidebar; each page groups its settings
  on cards with a short explanation under each one.
- The menu bar dropdown has a header with the reading's status, a card naming the
  busiest app when a reading is under strain, and Open, Settings and Quit rows with
  their shortcuts.

## [0.1.1] - 2026-11-03

### Changed

- Releases are signed with a Developer ID and notarized by Apple, so macOS opens
  Kestrel without a warning. Coming from 0.1.0, which was signed ad-hoc, macOS asks
  for the audio and notification permissions once more.
- `scripts/notarize.sh` notarizes and staples a signed build.

## [0.1.0] - 2026-11-01

First public release.

### Added

- Window with Overview, Apps, CPU, Memory, Disk, Network, GPU, Neural Engine,
  Power & Battery, Thermals & Fans, Sound, Bluetooth, Projects, Agents, Containers
  and History.
- Menu bar items per reading (value, graph or both) with a dropdown of figures and
  the apps behind them.
- Apps view that folds helper processes into their app, and a Process Inspector with
  code signature, launch agent, command line, open files, ports and children.
- Power and Neural Engine readings from IOReport, temperatures and fans from the SMC,
  and manual fan control through an optional root helper.
- Per-app volume and mute through Core Audio process taps.
- Dev servers grouped by project, coding agent sessions, AI usage limits, token
  counts and Docker containers.
- Alerts for runaway CPU, memory growth, disk and network use, memory pressure and
  temperature.
- Per-metric and per-app history in a local SQLite file with configurable retention.
- `kestrel` CLI and MCP server.
- Share image export, palettes, compact layout, unit options, English and Bahasa Indonesia.
- Press and hover feedback, critically damped springs for panels and sections, a
  translucent live-readings strip, and support for Reduce Motion and Reduce Transparency.

[Unreleased]: https://github.com/mralifakbar/kestrel/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mralifakbar/kestrel/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mralifakbar/kestrel/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mralifakbar/kestrel/releases/tag/v0.1.0
