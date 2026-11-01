# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/mralifakbar/kestrel/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mralifakbar/kestrel/releases/tag/v0.1.0
