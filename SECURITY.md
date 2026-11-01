# Security

Kestrel can quit processes, read other processes' metadata and, if you install it,
run a small helper as root. This page explains what it does with those privileges
and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through
[GitHub's vulnerability reporting](https://github.com/mralifakbar/kestrel/security/advisories/new)
with steps to reproduce. You'll get a reply within a week, and a fix or a plan
soon after that.

Only the latest release gets security fixes.

## The fan helper (optional, root)

Manual fan control writes to the SMC, which needs root. When you click **Install
helper**, Kestrel uses the standard macOS admin prompt to copy
`Kestrel.app/Contents/MacOS/KestrelHelper` to
`/Library/PrivilegedHelperTools/dev.kestrel.helper` and registers it as the launchd
daemon `dev.kestrel.helper`.

The helper:

- **is started on demand** by launchd when something connects to
  `/var/run/dev.kestrel.helper.sock`, and exits after two idle minutes when every fan
  is back on automatic.
- **understands three commands**: `ping`, `fan <n> auto` and `fan <n> <rpm>`. The
  speed is clamped to the fan's own minimum and maximum. It reads and writes nothing
  else, runs no shell commands and makes no network connections.
- **puts fans back on automatic** when it's stopped, and Kestrel asks it to do the
  same when the app quits.

Uninstall it from Settings › History › Fan helper, or with
`sudo launchctl bootout system/dev.kestrel.helper` and deleting the two files above.

## Quitting things

Every quit, force quit, server stop, container stop and agent session quit shows a
confirmation first. The CLI asks on the terminal (skip it with `--yes`). The MCP
server can't quit anything on its own: `request_stop` shows a dialog in the app and
only proceeds when you click **Allow**. If the app isn't running, nothing is quit.

## Network

Kestrel makes no network requests unless you enable **AI usage limits**. Then it
calls `api.anthropic.com`, `api.github.com` and `cursor.com` with the credentials
Claude Code, the `gh` CLI and Cursor already keep on your Mac. Those credentials are
read when needed and never written anywhere.

## Known limits

- **Install to `/Applications`.** The helper installer copies the binary inside the
  app bundle. If the app lives somewhere other users or processes can write to, they
  could swap it before you approve the prompt.
- **The helper socket is world-writable** (mode `0666`), so any local process can ask
  it to change fan speeds within the fan's limits. It can't do anything else.
- **Release builds are ad-hoc signed and not notarized.** Check the SHA-256 on the
  release page, or build from source.
