# Releasing Slipstream

A release builds a Developer ID–signed, notarized app, wraps it in a signed,
notarized, stapled DMG, adds a signed item to the Sparkle appcast, and uploads both
to S3. Installed copies update themselves through Sparkle
(**Check for Updates…** in the app menu, plus a daily background check). It is the same
pipeline as Playola Interview Editor (`~/playola/logic-utils/packaging`), minus the
bundled Python engine.

Merges to `develop` release from GitHub Actions (`.github/workflows/release.yml`). The
same fastlane lane can still run locally.

## Bundled runtime

The app embeds the Slipstream daemon and an arm64 Node at
`Contents/Resources/SlipstreamRuntime/` (`bin/node`, `app/`), so one Sparkle update moves
the app and the recorder together. `build-app.sh` runs `build-runtime.sh`, which:

- fetches the daemon at `DAEMON_COMMIT` from `runtime.env` and runs
  `npm ci && npm run build:payload` there (so the build needs Node 24 and npm on PATH);
- downloads Node `NODE_VERSION`, refuses it unless its sha256 is `NODE_SHA256`, and copies
  only `bin/node`.

`sign-app.sh` signs `bin/node` with `node.entitlements` (JIT only) and every other Mach-O in
the payload (native addons such as `watcher.node`) with no entitlements, before the app.

To ship a new daemon, set `DAEMON_COMMIT` to the commit its npm release was cut from (the
daemon's `vX.Y.Z` tag; never a branch tip). The release lane runs `daemon_freshness.rb`
after building and refuses to ship a bundled daemon older than the newest
`@playola-radio/slipstream` on npm: the app never takes over a newer recorder, so an npm
install ahead of the bundle would leave the app without its `slipstream` command.

To move Node, set `NODE_VERSION` and copy the `node-v<version>-darwin-arm64.tar.xz` line's
hash from `https://nodejs.org/dist/v<version>/SHASUMS256.txt` into `NODE_SHA256`. App and
daemon versions are independent.

## Download links

- Website / first install:
  `https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/SlipstreamViewer-latest.dmg`
  (re-pointed every release, `no-cache`).
- Sparkle feed: `https://playola-static.s3.amazonaws.com/downloads/SlipstreamViewer/appcast.xml`
  (baked into the app as `SUFeedURL`; its items point at the versioned DMGs).

## Release

While Slipstream's only user is its developer, every merge to `develop` that brings
user-facing notes releases a new patch version. Pull requests add their notes as files
under `changelog.d/` (format in `changelog.d/README.md`), not to `CHANGELOG.md`; a pure
chore adds none and ships with the next release that has notes.

On each merge, `packaging/prepare-release.sh` decides what to publish. If `develop` has
already moved past that merge before its tip check, it does nothing and leaves the release to
the newer merge's run. A merge that lands after preparation does not go out with the older run.
Otherwise:

- **The version in `project.yml` is already tagged** (`v<version>-b<build>`) and notes
  with a `### Changes` bullet are waiting: it runs `fastlane mac bump` for the next patch
  version and pushes that commit to `develop`. The bump moves the notes under
  `## [<version>] - <today>` in `CHANGELOG.md`, deletes the `changelog.d/` files it moved,
  and raises the integer `CURRENT_PROJECT_VERSION` (the `sparkle:version`, which must
  only ever go up). `### Ops`-only notes wait for a release with changes.
- **The version is not tagged yet:** it releases the merge as it is, without bumping
  again. That covers a version prepared by hand and a release that failed. Notes merged
  after that bump stay in `changelog.d/` and wait for a later release that promotes them.
- **Otherwise** it publishes nothing.

The workflow then runs both test jobs on the commit it chose, builds, signs, notarizes,
uploads, and pushes the tag at that commit. A malformed note fails the run, naming the
file and line. Notes left waiting (after a failed release, say) go out with the next
merge, or run the workflow by hand from the Actions tab.

To release a minor version instead of the next patch, on a branch off `develop` with a
clean tree, run

```bash
make prep-release VERSION=0.5.0
```

and merge it. That does the same bump with the version you name, and refuses a version
already in the changelog. The `/prep-release` skill (`.claude/skills/prep-release`) walks
through it, including checking the notes against the PRs merged since the last release.
`release` refuses a dirty tree, aborts before building if the version has no changelog
section, and refuses a build that is not newer than every published one.

### If a release fails

Re-run the failed jobs, or run the workflow by hand from the Actions tab if `develop` has
moved on since (re-running a whole old run publishes nothing). That is safe until the
upload starts. If it got further:

- **Appcast uploaded, tag push failed:** the release is live. Push the tag by hand at
  the commit the run released: `git tag v0.2.0-b5 <sha> && git push origin v0.2.0-b5`.
- **DMG uploaded, appcast not:** nobody is offered the build, and a re-run stops at
  "release artifact already exists". Run `bundle exec fastlane mac bump` on a branch
  off `develop` and merge it; the orphaned DMG is harmless.

## CI credentials

The `release` GitHub environment (deployments from `develop` only) holds:

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

## Bundled recorder release gate

Before merging a change to how the app runs its recorder, run this on a clean, offline Apple
Silicon Mac, VM or test user with no Node, no nvm and no `~/.slipstream`. Never on a Mac whose
recorder you rely on. Record each line's result in the pull request.

1. First launch → the recorder is running. `slipstream status` works from a new terminal
   through `~/.local/bin`.
2. Quit the app → the recorder keeps running (`launchctl print gui/$(id -u)/radio.playola.slipstream`
   shows the pid).
3. Reboot → the recorder runs before the app is opened.
4. Move or delete `Slipstream.app` → recording continues (the recorder runs from Application
   Support). This is supported.
5. Turn Slipstream off in Login Items, then quit and relaunch → "won't start", with
   `service install`'s full launchctl output as the evidence.
6. Install on quit: install vN, publish vN+1 to a test appcast, quit → the app relaunches on
   vN+1 and the recorder switches (restarting → running). An MCP call from a running agent
   still succeeds.
7. Migration on a copy of a real setup (an npm recorder under `radio.playola.slipstream`):
   the LaunchAgent plist now points into Application Support, and hooks and connector configs
   point at the shims, with backups present.
8. Native module: a capture records a file change (proves `watcher.node` loads from the
   copied runtime).
9. Each recorder state in `design/features/bundled-daemon/screens.md`, checked against its
   SwiftUI preview in `RecorderMessageView.swift`.
10. Two app builds that bundle the same recorder version, launched alternately → when their
    daemon build ids differ, the newer app build keeps the recorder and the older one shows
    "another recorder"; when the daemon build is identical, both show running. Nothing restarts
    in either case.

Lines 6 and 7 may use a Debug-signed build against a disposable store (`SLIPSTREAM_STORE`).

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
