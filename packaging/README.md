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

The `/prep-release` skill (`.claude/skills/prep-release`) walks through all of this,
including drafting the notes from the PRs merged since the last release.

1. On a branch off `develop`, commit the release notes so the working tree is clean. Make
   sure `## [Unreleased]` in `CHANGELOG.md` lists every user-facing change since the last
   release, then:

   ```bash
   make prep-release VERSION=0.3.0
   ```

   This moves the `[Unreleased]` notes under `## [0.3.0] - <today>` and bumps
   `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION` (the
   `sparkle:version`, which must only ever go up) in `project.yml`, in one commit. It
   refuses an empty `[Unreleased]` or a version already in the changelog. For a
   build-only bump of the same version, run `bundle exec fastlane mac bump`. If the
   preparation commit fails, it restores the clean tree so the command can be rerun.
2. Merge that branch into `develop`, then open the `develop` → `main` release PR and
   merge it.

The workflow's first job reads the version from `project.yml` and stops if the tag
`v<version>-b<build>` already exists, so a merge without a bump publishes nothing.
Otherwise it builds, signs, notarizes, uploads, and pushes that tag at the released
commit. `release` refuses a dirty tree, aborts before building if the version has no
changelog section, and refuses a build that is not newer than every published one.

### If a release fails

Re-run the workflow. That is safe until the upload starts. If it got further:

- **Appcast uploaded, tag push failed:** the release is live. Push the tag by hand at
  the merge commit: `git tag v0.2.0-b5 <sha> && git push origin v0.2.0-b5`.
- **DMG uploaded, appcast not:** nobody is offered the build, and a re-run stops at
  "release artifact already exists". Run `fastlane mac bump` on `develop` and merge
  again; the orphaned DMG is harmless.

## CI credentials

The `release` GitHub environment (deployments from `main` only) holds:

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_P12_B64`, `DEVELOPER_ID_P12_PASSWORD` | The **Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)** identity, base64 .p12. Imported into a throwaway keychain per run. |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | App Store Connect API key used by `notarytool`. |
| `SPARKLE_ED_PRIVATE_KEY` | The Slipstream Sparkle EdDSA private key (`generate_keys --account slipstream-viewer -x`). |
| `AWS_ROLE_ARN` | `slipstream-viewer-release`, assumed through GitHub OIDC; may only read and write `s3://playola-static/downloads/SlipstreamViewer/`. |

## Releasing locally

Only when CI is unavailable, and never while a release workflow is running: the two
do not lock each other out of the appcast. Needs the Developer ID identity in the login Keychain, the notarytool profile
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
`RELEASE_S3_PREFIX=downloads/SlipstreamViewer-staging`; it uploads there but does
not tag.

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
