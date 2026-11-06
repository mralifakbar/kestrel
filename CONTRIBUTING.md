# Contributing to Kestrel

Thanks for helping out. This guide covers the setup, the layout of the code, and
what a good pull request looks like.

## Setup

You need macOS 15 or later and Xcode 16 or later.

```sh
git clone https://github.com/mralifakbar/kestrel.git
cd kestrel
swift test                          # run the tests
./build.sh && open build/Kestrel.app
```

You can open `Package.swift` in Xcode, but run the app from the bundle `build.sh`
makes: macOS needs the `Info.plist` for the audio-capture prompt, the menu-bar-only
mode and the helper binaries.

## Layout

```
Sources/
  CKestrel/      C shims: IOReport declarations, SMC access, responsibility lookup
  KestrelCore/   samplers, process grouping, inspector, dev servers, agents,
                 AI usage, Docker, history (no SwiftUI here, so it's easy to test)
  KestrelApp/    SwiftUI + AppKit app: window, menu bar, alerts, audio, settings
  kestrel/       the CLI and the MCP server
  KestrelHelper/ optional root helper for fan control
Tests/KestrelCoreTests/  unit tests for KestrelCore
scripts/make-icon.swift  draws the app icon
build.sh                 builds, signs and packages the .app
```

## Development switches

| Switch | Effect |
|---|---|
| `KESTREL_OPEN=<section>` | Open the window on that section (`overview`, `apps`, `cpu`, `thermals`, `agents`, …). |
| `-NSRequiresAquaSystemAppearance YES` | Force light mode, for screenshots. |
| `KESTREL_SIGN_IDENTITY="…"` (build.sh) | Sign with a real certificate instead of ad hoc. |
| `kestrel debug-ioreport` | List the IOReport channels your Mac exposes. |
| `kestrel sensors` | List every SMC temperature sensor and fan. |

The README screenshots are made like this:

```sh
A=build/Kestrel.app/Contents/MacOS/Kestrel
KESTREL_OPEN=overview $A
KESTREL_OPEN=overview $A -NSRequiresAquaSystemAppearance YES
KESTREL_OPEN=thermals $A
```

Please don't commit screenshots of Projects or Agents from your own Mac: folder
names and command lines say a lot about a person.

## Adding a coding agent

Agents are matched in `AgentTracker.signatures`
([`DevTools.swift`](Sources/KestrelCore/DevTools.swift)) by the executable name or the
first arguments (for Node and Python launchers). Add a line, add the lowercase name
to the cheap pre-filter in `scan`, and pick an SF Symbol in `AgentCard.icon`.

## Adding a usage-limit provider

Add a function to `UsageLimits` that returns a `ProviderLimits`, call it from
`fetchAll`, and add a toggle in `IntegrationSettings`. Read credentials the tool
already stores; never ask the user to paste a token.

## Pull requests

- Keep each PR focused on one thing, and describe what changed and how you tested it.
- `./scripts/ci.sh` must pass: unit tests, a universal build and a smoke test. There's
  no hosted CI, so run it on your Mac before opening the PR.
- Watch the cost: Kestrel runs all day. Check `ps -o %cpu -p $(pgrep -x Kestrel)`
  with the window open and closed before and after your change.
- Follow the style of the code around you: 4-space indent, small types, comments that
  explain *why*.
- Update `CHANGELOG.md` under **Unreleased**.

## Releasing (maintainers)

1. Move the **Unreleased** notes in `CHANGELOG.md` under a new version heading.
2. Commit, then run `./scripts/release.sh 0.2.0` on your Mac. There is no hosted CI:
   the script checks everything first, then runs the tests, builds the universal app
   signed with the Developer ID, notarizes and staples it, pushes `main` and the
   `v0.2.0` tag, and publishes the GitHub release with the zip, its SHA-256 and the
   changelog section as notes.
3. Once per Mac: the Developer ID Application certificate in the keychain, notarization
   credentials saved with `xcrun notarytool store-credentials notary …` (see the top of
   `scripts/notarize.sh`), and `gh auth login`.
