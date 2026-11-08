---
name: prep-release
description: Get a new Slipstream for macOS version ready to ship — check the changelog.d/ release notes against the PRs merged since the last release, pick the version, run `make prep-release`, and open the PRs that publish it. Use when asked to cut, prep, or ship a release of this app.
---

# Prep a release

Publishing is automatic: merging `develop` → `main` with a new version in `project.yml`
builds, notarizes, uploads, and tags it (`.github/workflows/release.yml`). This skill gets
the changelog and version right before that merge. Background: `packaging/README.md`.

## 1. Find what shipped since the last release

```bash
git fetch origin --tags --quiet
TAG=$(git tag --list 'v*' --sort=-creatordate | head -1)
git log --first-parent --merges --format='%s' "$TAG"..origin/develop | grep -oE '#[0-9]+'
```

For each PR: `gh pr view <num> --json title,body`. Then see what the release will say
(the bullets still under `## [Unreleased]` in `CHANGELOG.md`, then every `changelog.d/`
note):

```bash
ruby packaging/release_notes.rb notes CHANGELOG.md changelog.d
```

## 2. Fill the gaps

Every user-facing PR should already have its `changelog.d/` note. For any that doesn't,
add a note file in the `changelog.d/README.md` format (for example
`changelog.d/release-<version>-missing-notes.md`); fix a weak note by editing its file.
Don't add bullets to `CHANGELOG.md` itself. Describe what changes for the person using
the app, not how it was built. Match the existing bullets' voice and wrapping
(~88 columns). Skip `chore:` work with no visible effect. Mention when a change needs an
up-to-date Slipstream daemon. Point out any `### Ops` notes: someone has to do them
before the release PR merges.

## 3. Pick the version

Read `MARKETING_VERSION` in `project.yml`. While on 0.x: bump the minor version if any PR
is a `feature:`, otherwise the patch version.

**Stop and show the user the drafted notes, the PR list, and the proposed version. Wait
for confirmation before committing anything.**

## 4. Commit and bump

Work on a branch off `origin/develop`. Never commit to `develop` or `main` directly.

```bash
git add changelog.d && git commit -m "chore: release notes for <version>"   # only if step 2 changed notes
make prep-release VERSION=<version>
```

`make prep-release` moves the `[Unreleased]` and `changelog.d/` notes under a dated
`## [<version>]` heading, deletes the note files it moved, and bumps `project.yml`, in one
commit. It changes nothing if a note is malformed (it names the file and line), the
version is already in the changelog, or there are no `### Changes` notes. If it fails, fix
the cause; don't hand-edit the version or the changelog.

## 5. Open the PRs

1. Push and open the bump PR against `develop` using the normal PR workflow, titled
   `chore: get version <version> ready to ship`.
2. After it merges, open the `develop` → `main` release PR titled
   `release: v<version> — <plain-English theme>`. Don't use `/create-release-pr` here: it
   edits `server/package.json` and pushes to `develop`.

Merging the release PR publishes it. Afterwards, confirm with
`gh run list --workflow release --limit 1` and check that the new version appears in
`https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/appcast.xml`.
