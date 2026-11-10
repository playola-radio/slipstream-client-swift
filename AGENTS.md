# AGENTS.md

This repo's agent instructions live in `CLAUDE.md`; read and follow it first.

## Changelog

Never edit `CHANGELOG.md` in a pull request. A user-visible change adds one new file,
`changelog.d/<short-kebab-description>.md`, in the format in `changelog.d/README.md`; a pure
chore adds none and says so in the PR description. Merging a note to `develop` releases it:
CI bumps the patch version and rolls the files into `CHANGELOG.md` (`packaging/README.md`).
