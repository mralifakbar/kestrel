# Working on Kestrel

Kestrel is a native macOS menu-bar system monitor: CPU, memory, GPU, Neural Engine,
power, thermals and fans, plus the dev servers, coding agents and containers eating
the machine. Swift 6 toolchain, SwiftUI and AppKit, zero external dependencies, no
account, no telemetry. It runs all day on someone's laptop, which is the constraint
behind most of the rules below.

Read this before you touch anything. `CONTRIBUTING.md` covers the same ground for
humans and goes deeper on setup and releases.

## The five rules that are not negotiable

1. **No dependencies.** `Package.swift` has no `dependencies:` array and it stays
   that way. Everything talks to IOKit, IOReport, SMC, libproc and sqlite3 directly
   through `Sources/CKestrel`. If you want a package to do something, write the 80
   lines instead. A monitor that pulls in a dependency tree costs more than the thing
   it measures.
2. **No telemetry, no accounts, no network calls you did not justify.** Kestrel reads
   the machine it runs on. The only outbound requests are the AI usage-limit providers,
   which are off until the user turns them on, and which read credentials the tool
   already stored on disk. Never add a check-in, a crash reporter, or an update ping.
   Never write code that asks the user to paste a token.
3. **Killing something always asks first.** Any path that quits a process, stops a dev
   server or stops a container goes through a confirmation. For the CLI and the MCP
   server that means `StopBroker.requestApproval`, which posts to the running app and
   blocks until the user answers there. An agent must never be able to quit the user's
   work by calling a tool. If you add a destructive action, wire it through the broker
   and say so in the PR.
4. **The cost budget is real.** Measure before and after, window open and closed:
   ```sh
   ps -o %cpu,rss -p $(pgrep -x Kestrel)
   ```
   A change that adds a sampler, a timer or a view that redraws per tick needs a number
   in the PR. If your change costs more than it tells the user, it does not land.
5. **Nothing personal in the repo.** Screenshots of Projects or Agents leak folder names,
   client names and full command lines. `docs/` screenshots are taken on a clean account
   with the recipes in `CONTRIBUTING.md`. Same for test fixtures and issue reports.

## Layout, and the one layering rule

```
Sources/
  CKestrel/      C shims: IOReport declarations, SMC access, responsibility lookup
  KestrelCore/   samplers, process grouping, inspector, dev servers, agents,
                 AI usage, Docker, history
  KestrelApp/    SwiftUI + AppKit: window, menu bar, alerts, audio, settings
  kestrel/       the CLI and the MCP server
  KestrelHelper/ optional root helper for fan control, nothing else
Tests/KestrelCoreTests/
```

**KestrelCore imports no SwiftUI.** That is what makes it testable, and it is what lets
the CLI and the MCP server exist at all: they link Core without the app. If you find
yourself wanting `@Published` or `Color` in Core, the type belongs in `KestrelApp`, or
the value belongs in `Models.swift` as plain data and the app decides how to draw it.

`KestrelHelper` runs as root for fan control. Keep it tiny (it is under 100 lines) and
keep it dumb. Code that runs as root is code you have to be certain about.

## Verifying a change

There is no hosted CI. The checks run on a Mac:

```sh
./scripts/ci.sh      # unit tests, universal build, signature and lipo smoke test
```

That must pass before a PR. For quicker loops:

```sh
swift test
./build.sh && open build/Kestrel.app
```

**Run the app from `build/Kestrel.app`, not from Xcode's run button.** macOS needs the
bundle's `Info.plist` for the audio-capture prompt, the menu-bar-only mode and the helper
binaries. A bare `swift run KestrelApp` will behave differently and you will chase a
ghost.

Useful switches while you work:

| Switch | Effect |
|---|---|
| `KESTREL_OPEN=<section>` | Open straight to `overview`, `apps`, `cpu`, `thermals`, `agents`, … |
| `-NSRequiresAquaSystemAppearance YES` | Force light mode, for screenshots |
| `kestrel debug-ioreport` | List the IOReport channels this Mac exposes |
| `kestrel sensors` | List every SMC temperature sensor and fan |

## Traps that have already cost someone an afternoon

- **One sample tells you nothing.** CPU, disk and network are deltas between two reads.
  `SystemMonitor.warmSample` exists for one-shot consumers (CLI, MCP) and deliberately
  sleeps a second between samples. Never report the first sample as a rate.
- **`SystemMonitor` is not thread-safe.** The doc comment says so. Sample from one queue.
  If you need a reading somewhere else, pass the `SystemSnapshot`, not the monitor.
- **Not every Mac has every counter.** IOReport channels and SMC keys differ by chip and
  by generation; Intel Macs are missing most of the Apple silicon power counters. Check
  `PowerStats.available` and degrade quietly. Never render `0 W` for "we could not read it",
  and never crash on a missing key. Test on a different Mac than the one you wrote it on,
  or at least read `kestrel debug-ioreport` output from one.
- **Thermals and battery are cached on purpose** (3s and 4s in `Monitor.sample`). SMC reads
  are not free. If you shorten those intervals, rule 4 applies.
- **APFS is case-insensitive.** The CLI binary `kestrel` cannot sit next to the app binary
  `Kestrel`, which is why `build.sh` puts it in `Contents/Helpers/`. Do not "tidy" that.
- **`swiftLanguageModes: [.v5]`** on a Swift 6 toolchain is deliberate. Do not flip the
  package to Swift 6 language mode as a drive-by; it is a real piece of work with real
  concurrency consequences, and it gets its own PR and its own discussion.
- **The universal build is what ships.** `./build.sh --universal` builds arm64 and x86_64.
  Code that only compiles on one of them fails late, in `ci.sh`, after you thought you
  were done.

## Common changes

**Adding a coding agent.** Agents are matched in `AgentTracker.signatures`
(`Sources/KestrelCore/DevTools.swift`) by executable name, or by the first arguments for
Node and Python launchers. Add the signature, add the lowercase name to the cheap
pre-filter in `scan`, and pick an SF Symbol in `AgentCard.icon`. Add a test to
`DevToolsTests.swift` with a realistic command line.

**Adding a usage-limit provider.** Write a function in `AIUsage.swift` returning a
`ProviderLimits`, call it from `fetchAll`, add a toggle in `IntegrationSettings`. Read
credentials the tool already stores on disk. Rule 2: never prompt for a token.

**Adding a reading to the menu bar.** The value goes in `Models.swift` and
`SystemMonitor.historyMetrics`, the drawing in `MenuBar.swift`. Check both the value and
graph presentations, light and dark, and that the strain threshold turns it red at a
sensible point.

## Style and hygiene

- Follow the code around you: 4-space indent, small types, comments that explain *why*
  rather than restating the line. The existing comments are the standard, so match them.
- One PR, one thing. Say what changed and how you tested it.
- Update `CHANGELOG.md` under **Unreleased**, in the voice of the existing entries:
  what the user now sees, not what you refactored.
- Do not reformat files you did not otherwise change. Do not bump the version; releases
  go through `scripts/release.sh`.

## If you are an AI agent

- Read `CONTRIBUTING.md` and the file you are about to change, in full, before editing.
  This codebase talks to undocumented Apple interfaces; the surrounding lines usually
  explain why something looks wrong.
- Do not invent IOReport channel names, SMC keys or `sysctl` names. If you are not sure a
  key exists, run `kestrel debug-ioreport` or `kestrel sensors` and read the output.
  A plausible-looking four-character SMC key that does not exist returns garbage, not an
  error, and that garbage will ship as a temperature.
- Do not add a dependency, a network call, or a destructive action without asking first.
  Those three are where a confident wrong answer does real damage.
- Run `./scripts/ci.sh` and paste the result. "Should work" is not a test result, and on
  this project the build is the only thing that knows whether both architectures compile.
- When a measurement looks wrong, suspect your sampling before you suspect the Mac.
