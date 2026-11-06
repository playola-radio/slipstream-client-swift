# Releasing Slipstream

A release builds a Developer ID–signed, notarized app, wraps it in a signed,
notarized, stapled DMG, adds a signed item to the Sparkle appcast, and uploads both
to S3. Installed copies update themselves through Sparkle
(**Check for Updates…** in the app menu, plus a daily background check). It is the same
pipeline as Playola Interview Editor (`~/playola/logic-utils/packaging`), minus the
bundled Python engine.

Every merge to `main` that carries a new version releases from GitHub Actions
(`.github/workflows/release.yml`). The same fastlane lane can still run locally.

## Download links

- Website / first install:
  `https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/SlipstreamViewer-latest.dmg`
  (re-pointed every release, `no-cache`).
- Sparkle feed: `https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/appcast.xml`
  (baked into the app as `SUFeedURL`; its items point at the versioned DMGs).

## Release

1. On `develop`, move the finished entries under `## [Unreleased]` in `CHANGELOG.md`
   into a dated heading for the new version, e.g. `## [0.2.0] - 2026-11-20`, then:

   ```bash
   bundle exec fastlane mac bump version:0.2.0   # or plain `bump` for a build-only bump
   ```

   `bump` edits `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION` (the
   `sparkle:version`, which must only ever go up) in `project.yml` and commits.
2. Open the `develop` → `main` release PR (`/create-release-pr`) and merge it.

The workflow's first job reads the version from `project.yml` and stops if the tag
`v<version>-b<build>` already exists, so a merge without a bump publishes nothing.
Otherwise it builds, signs, notarizes, uploads, and pushes that tag at the released
commit. `release` refuses a dirty tree, aborts before building if the version has no
changelog section, and refuses a build that is not newer than every published one.

### If a release fails

Re-run the workflow. That is safe until the upload starts. If the DMG and appcast
were uploaded but the tag push failed, the re-run stops at "release artifact
already exists"; push the tag by hand at the merge commit instead:
`git tag v0.2.0-b5 <sha> && git push origin v0.2.0-b5`.

## CI credentials

The `release` GitHub environment (deployments from `main` only) holds:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_P12_B64`, `DEVELOPER_ID_P12_PASSWORD` | The **Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)** identity, base64 .p12. Imported into a throwaway keychain per run. |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | App Store Connect API key used by `notarytool`. |
| `SPARKLE_ED_PRIVATE_KEY` | The Slipstream Sparkle EdDSA private key (`generate_keys --account slipstream-viewer -x`). |
| `AWS_ROLE_ARN` | `slipstream-viewer-release`, assumed through GitHub OIDC; may only read and write `s3://playola-static/downloads/SlipstreamViewer/`. |

## Releasing locally

Needs the Developer ID identity in the login Keychain, the notarytool profile
`qie-notary` (see `notarize-app.sh`), the Sparkle key in the login Keychain (account
`slipstream-viewer`), AWS credentials that can write the prefix, and `bundle install`.

```bash
NOTARY_PROFILE=qie-notary bundle exec fastlane mac release
```

The lane pushes the release tag, so CI then skips that version. Env overrides
(defaults shown): `RELEASE_S3_BUCKET=playola-static`,
`RELEASE_S3_PREFIX=downloads/SlipstreamViewer`,
`RELEASE_DOWNLOAD_HOST=https://playola-static.s3.amazonaws.com`. AWS credentials come
from the CLI's normal chain (`AWS_PROFILE`, env vars). To rehearse, set
`RELEASE_S3_PREFIX=downloads/SlipstreamViewer-staging`; it still uploads and tags.

## Verify every release

```bash
curl -fLo /tmp/Slipstream.dmg https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/SlipstreamViewer-latest.dmg
spctl --assess --type open --context context:primary-signature -v /tmp/Slipstream.dmg
xcrun stapler validate /tmp/Slipstream.dmg
```

Then install from the DMG on a Mac without the dev tools, launch it, and confirm an
earlier release offers the update through **Check for Updates…**.

## Invariants

Sparkle installs an update when either its EdDSA signature verifies against the
installed app's `SUPublicEDKey` or its Developer ID signature matches the installed
app's. So the EdDSA key or the Developer ID may change in one release, never both.
0.1.0 shipped Playola Interview Editor's key; later releases use the
Slipstream-only key, which 0.1.0 accepts through the Developer ID rule. The lane refuses an update whose signature doesn't verify against the key
inside the app it is shipping. Never change the bundle id
`com.playola.SlipstreamViewer` or `SUFeedURL`.

Back up the Sparkle private key (`generate_keys --account slipstream-viewer -x`)
somewhere safe. Losing it is recoverable only through the Developer ID rule above.

## Rollback

Old DMGs and appcast items are never deleted. To pull a bad release, remove its
`<item>` (matching `sparkle:version`) from `appcast.xml`, re-upload it with
`--content-type application/xml --cache-control no-cache`, and copy the previous
good DMG over `SlipstreamViewer-latest.dmg`. Sparkle does not downgrade, so users
already on the bad build need a fixed, higher version.
