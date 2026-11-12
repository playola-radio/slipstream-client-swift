# AGENTS.md

This repo's agent instructions live in `CLAUDE.md`; read and follow it first.

## Logs

- The app writes `~/Library/Logs/slipstream/app.log` (rotates to `app.log.1` at 10 MB); debug builds
  write `app-debug.log` instead. The daemon's log is `~/Library/Logs/slipstream/daemon.log`. `tail -F`
  or `grep` them to diagnose a problem after the fact.
- Categories: `app`, `daemon`, `follow`, `agent`, `recorder`, `terminal`, `issue`.
- Log through `@Dependency(\.appLog)`. Log full errors (`"\(error)"`, stderr, exit codes), never just
  `localizedDescription`. Never log the daemon token, launch environments or agent argument arrays.

## Changelog

Never edit `CHANGELOG.md` in a pull request. A user-visible change adds one new file,
`changelog.d/<short-kebab-description>.md`, in the format in `changelog.d/README.md`; a pure
chore adds none and says so in the PR description. When the current version is tagged, pending
`### Changes` notes make CI bump the patch version and roll all pending notes into
`CHANGELOG.md`; `### Ops`-only notes wait for Changes notes. An untagged version publishes as
is, and notes merged after that bump wait for a later release (`packaging/README.md`).
