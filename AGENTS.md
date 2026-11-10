# AGENTS.md

This repo's agent instructions live in `CLAUDE.md`; read and follow it first.

## Changelog

Never edit `CHANGELOG.md` in a pull request. A user-visible change adds one new file,
`changelog.d/<short-kebab-description>.md`, in the format in `changelog.d/README.md`; a pure
chore adds none and says so in the PR description. When the current version is tagged, pending
`### Changes` notes make CI bump the patch version and roll all pending notes into
`CHANGELOG.md`; `### Ops`-only notes wait for Changes notes. An untagged version publishes as
is, and notes merged after that bump wait for a later release (`packaging/README.md`).
