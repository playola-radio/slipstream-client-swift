# Releasing Slipstream

A release builds a Developer ID–signed, notarized app, wraps it in a signed,
notarized, stapled DMG, adds a signed item to the Sparkle appcast, and uploads both
to S3. Installed copies update themselves through Sparkle
(**Check for Updates…** in the app menu, plus a daily background check). It is the same
pipeline as Playola Interview Editor (`~/playola/logic-utils/packaging`), minus the
bundled Python engine.

Releases run locally from one fastlane lane; CI never signs or uploads.

## Download links

- Website / first install:
  `https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/SlipstreamViewer-latest.dmg`
  (re-pointed every release, `no-cache`).
- Sparkle feed: `https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/appcast.xml`
  (baked into the app as `SUFeedURL`; its items point at the versioned DMGs).

## Prerequisites (one-time, shared with Playola Interview Editor)

- The **Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)**
  identity in the login Keychain.
- The notarytool profile **`qie-notary`** (see `notarize-app.sh`). It is per team,
  not per app.
- The **Sparkle EdDSA private key** in the login Keychain (account `ed25519`). The
  public key in `project.yml` (`SUPublicEDKey`) is the same one Playola Interview
  Editor ships; backup and recovery are documented in
  `~/playola/logic-utils/packaging/README.md`.
- **AWS**: the `default` profile (override with `AWS_PROFILE`) can write
  `s3://playola-static/downloads/SlipstreamViewer/`.
- `bundle install` once at the repo root (fastlane).

## Release

1. Move the finished entries under `## [Unreleased]` in `CHANGELOG.md` into a dated
   heading for the new version, e.g. `## [0.2.0] - 2026-11-20`, and commit it.
2. From the repo root:

   ```bash
   export NOTARY_PROFILE=qie-notary
   bundle exec fastlane mac bump version:0.2.0   # or plain `bump` for a build-only bump
   bundle exec fastlane mac release
   ```

`bump` edits `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION` (the
`sparkle:version`, which must only ever go up) in `project.yml` and commits.
`release` refuses a dirty tree, and aborts before building if the version has no
changelog section. Env overrides (defaults shown): `RELEASE_S3_BUCKET=playola-static`,
`RELEASE_S3_PREFIX=downloads/SlipstreamViewer`,
`RELEASE_DOWNLOAD_HOST=https://playola-static.s3.amazonaws.com`, `AWS_PROFILE=default`.
To rehearse, set `RELEASE_S3_PREFIX=downloads/SlipstreamViewer-staging`; it still
uploads, but under a separate prefix.

## Verify every release

```bash
curl -fLo /tmp/Slipstream.dmg https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/SlipstreamViewer-latest.dmg
spctl --assess --type open --context context:primary-signature -v /tmp/Slipstream.dmg
xcrun stapler validate /tmp/Slipstream.dmg
```

Then install from the DMG on a Mac without the dev tools, launch it, and confirm an
earlier release offers the update through **Check for Updates…**.

## Invariants

Sparkle only installs an update signed by the same EdDSA key and the same Developer
ID team. Never change the bundle id `com.playola.SlipstreamViewer`, the team
`FSRSPV9N9Q`, `SUFeedURL` or `SUPublicEDKey` without shipping a bridging release
first.

## Rollback

Old DMGs and appcast items are never deleted. To pull a bad release, remove its
`<item>` (matching `sparkle:version`) from `appcast.xml`, re-upload it with
`--content-type application/xml --cache-control no-cache`, and copy the previous
good DMG over `SlipstreamViewer-latest.dmg`. Sparkle does not downgrade, so users
already on the bad build need a fixed, higher version.
