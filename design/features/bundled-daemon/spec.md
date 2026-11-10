# Bundled daemon — the app ships, starts and updates its own daemon

**Status:** Phase 8 (export and ship). The design is approved and ready for implementation.

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `3f49250908a1b05c668618d8f72420d44e2b68c7` (develop).
- Daemon (`playola-radio/slipstream`): `4117951236b2939b41197d56c13f17e36ecf6091` (develop,
  package `0.3.1`). Version identity is already in this commit (PR #90): `dist/build-id`, the
  `status` verb's `daemon_version`/`daemon_build`, and `versionGate` on every control sender.
  This feature changes:
  - the daemon's packaging;
  - the paths it writes into hooks and connector configs;
  - how its LaunchAgent is installed;
  - how the MCP forwarder behaves after an update.

  Read the daemon code at this commit, not from a local checkout.

## Target surfaces

- `client`: the macOS app's packaging, its release pipeline, launch-time daemon management, and
  the change-stream window's recorder messages.
- Daemon:
  - a self-contained runtime payload;
  - an "app runtime" mode;
  - `slipstream service install` and `slipstream adopt-app`;
  - the MCP forwarder's behaviour after an update.

## Why

The app and the daemon ship separately:
- The app updates itself through Sparkle.
- The daemon only updates through a manual `npm publish`, `npm i -g` and a restart.

So the two drift: on 2026-11-10, Brian's daemon was still the npm 0.3.0 build from 2026-10-27.
Nothing checks that they match, so the drift shows up as confusing errors.

The LaunchAgent and the generated hooks also pin `~/.nvm/versions/node/v24.11.0/...`, so a Node
upgrade breaks them.

Brian (2026-11-10): eliminate the friction without porting the daemon to Swift.

## Scope

1. **One release ships everything.** Each app release embeds an arm64 Node runtime plus the
   daemon built at a pinned commit, signed and notarized with the app. When Sparkle updates the
   app, it updates the daemon, the `slipstream` CLI and `slipstream-mcp` too.
2. **Versioned copy.** On launch, the app copies the embedded runtime to
   `~/Library/Application Support/com.playola.SlipstreamViewer/runtime/<daemon_version>-<build8>/`.
   - Identity is read from the payload itself: `daemon_version` from `app/package.json` and
     `daemon_build` from `app/dist/build-id`. There is no manifest.
   - The copy is made in a unique staging directory and compared byte for byte with the signed
     bundle: same paths, same bytes, same permission bits, and no symlinks. Then it is atomically
     renamed into place, and `current` is atomically pointed at it.
   - A cross-process file lock covers the copy and the flip. A crash before the flip leaves the
     previous runtime in use.
   - If two installed apps disagree, the newer daemon version wins; an app never moves `current`
     backwards.
   - The running daemon never reads files from the app bundle.
3. **Stable entry points.** `slipstream` and `slipstream-mcp` are small shims in that folder. Each
   resolves `current` to the concrete version directory and execs it, setting
   `SLIPSTREAM_APP_RUNTIME`.
   - Hooks, connector configs and the `~/.local/bin` links all use the shims, and so do the app's
     own commands.
   - No nvm, no PATH search.
   - A failure to link `~/.local/bin` is reported, never fatal.
4. **The daemon runs in the background under its existing LaunchAgent**
   (`radio.playola.slipstream`). The app installs it with a new `slipstream service install`,
   which it runs through the shim:
   - It is the LaunchAgent half of `conductor install`, with no Conductor half.
   - The plist points at the concrete versioned Node and `cli.js`.
   - Recording continues with the app closed and restarts after login or reboot.
   - There is no `SMAppService`, no launcher and no approval screen. If Slipstream is turned off
     in Login Items, launchd's own error is shown as "Won't start".
5. **Exact version match.** Identity is the existing `status` reply's `daemon_build`, compared
   with the bundled `daemon_build`.
   - The daemon is the app's own when the pid launchd reports for `radio.playola.slipstream`
     equals the pid in `owner.lock`.
   - When the app's own daemon is on another build, the app, on launch:
     1. prepares the runtime and flips `current` (the running daemon uses its concrete directory,
        so the flip doesn't disturb it);
     2. stops the daemon with SIGTERM (its existing drain-and-resume path; no timeout escalation,
        no force-kill, no `kickstart -k`);
     3. waits for the store lock to be released;
     4. runs `service install`.
   - Every preparation failure, including the flip, happens before the SIGTERM, so the old daemon
     keeps running. A failure after the SIGTERM shows "Won't start".
   - A daemon the app didn't start is never stopped unless the user asks.
6. **Update on quit relaunches.** Sparkle's install-on-quit installs and relaunches immediately,
   so the CLI never stays on the old build for days.
7. **Existing installs move over by themselves.**
   - The npm `conductor install` used the same label, so an existing npm daemon is the app's
     "own" by the rule in item 5, and the first launch switches it over like any other build.
   - Afterwards the app runs `slipstream adopt-app`, which:
     - rewrites Slipstream-written nvm paths in workspace hooks and connector configs to the
       shims (backups kept, unrelated content untouched);
     - links `~/.local/bin/slipstream{,-mcp}`.
   - `install.json` stays version 1. `service install` keeps its `repos` and points `node`/`cli`
     at the app's runtime, so an old 0.3.1 CLI kickstarts the app's daemon instead of starting a
     rival.
   - The npm package files stay.
   - Failures here show "Migration incomplete" with the full output and **Try again**.
8. **Development.** A Debug-only setting points the app at a daemon run from a clone. It skips
   the build and ownership checks and never touches the LaunchAgent. Release builds have no such
   path.
9. **arm64 only.** The app and the runtime are Apple Silicon only (Brian, 2026-11-10).
10. **npm stays.** The daemon is still published to npm by hand, for use without the app
    (Brian, 2026-11-10).
11. **Errors are shown in full.** Every recorder failure shows the specific failure as its
    headline, plus the raw evidence in a selectable monospace block with Copy:
    - the full stderr or stack trace;
    - exit code, pid, versions, paths, errno.

    No generic error text (Brian, 2026-11-10: "I want to show entire stack-traces or full error
    messages"). The bearer token is never shown.
    - This also replaces the existing generic texts:
      - "The Slipstream daemon isn't running" and "Couldn't reach the Slipstream daemon"
        (`ChangeStreamPageModel`);
      - the `npm i -g` hint (`WorkspaceClient.slipstreamNotFoundText`).
    - Discovery keeps each rejected descriptor's reason, and HTTP errors keep the response body.
    - "Won't start" shows everything `daemon.log` gained since the app started the daemon.
12. **Running agent sessions survive an update.** When `slipstream-mcp` gets
    `DAEMON_VERSION_MISMATCH` and `current` holds a newer build, it replaces itself with that build
    through the stable shim (`process.execve`), replaying the MCP `initialize` handshake. The
    agent's session carries on without a restart.
13. **The lifecycle has one owner.** Copying, the LaunchAgent, switching and migration live in one
    app-level `@Observable` model behind dependencies, not in the change-stream page.

## Non-goals

- Porting the daemon to Swift.
- Intel support.
- Conductor. Its integration is being removed separately, and this feature neither reads nor
  writes Conductor scripts. Until it's removed, a manual npm `conductor install` can repoint the
  LaunchAgent at nvm; the next app launch switches it back (accepted).
- Automatic deletion of old runtime versions (it needs a process lease; later, if disk use matters).
- A new daemon endpoint or control verb, or new descriptor fields. Identity comes from the existing
  `status` verb, and SIGTERM is the graceful stop.
- Merging the two repos (later, as its own change; the daemon keeps its Apache-2.0 license).
- Automated npm publishing.

## Open questions

None open.

## Architecture record

Designed through two rounds of Codex consult on 2026-11-10 (`gpt-5.6-sol`, high effort).
- Round one proposed:
  - a Sparkle pre-install shutdown handshake;
  - a native LaunchServices locator;
  - a `/v1/runtime` endpoint;
  - a shutdown control verb;
  - a universal binary.
- Round two, after pushback:
  - replaced the first two with versioned extraction;
  - dropped the endpoint and the verb;
  - chose arm64-only.

Codex's corrections that this design keeps:
- never exec through `current`;
- `kickstart -k` is not graceful; SIGTERM is;
- no automatic pruning without a lease;
- copy without quarantine xattrs;
- a clean, offline Apple Silicon machine is a release gate, because loose binaries can't be stapled.

Phase 7 later replaced `SMAppService` with the daemon's existing LaunchAgent, and the manifest
with a byte comparison.

## Adversarial review (Phase 5)

Codex `gpt-6-astra`, 2026-11-10 (`.context/codex-bundled-daemon-review.md`). It also found that
the earlier rounds, and the first models.md, were based on a stale daemon checkout (`b736f77`,
missing PR #90). Everything below is checked against `4117951`.

| # | Finding | Disposition |
|---|---|---|
| 1 | Daemon baseline unsettled; `control/install.json` and the old agent can still start a daemon; app commands use PATH | Resolved. Baseline `4117951`. The app now owns that same agent, and `install.json` points at its runtime (items 4, 7). App commands use the shim (item 3) |
| 2 | `distribution_owner` proves where a payload came from, not who started the process | Resolved. The descriptor fields and `release.json` are dropped. Ownership is launchd's pid for the label equal to the `owner.lock` pid (item 5). **Replace it** re-reads the lock, checks the pid and start time, and sends SIGTERM; it never force-kills (screens.md) |
| 3 | Switching isn't a complete transaction; there's no 30s SIGTERM timeout | Resolved. Preparation, comparison and the `current` flip all happen before the SIGTERM. After it, the app waits for the store lock to be released, then installs. A failure after the SIGTERM is "Won't start" (item 5). The 30s claim is removed |
| 4 | The store lock doesn't serialize two app updaters | Resolved: a cross-process file lock, unique staging, crash-safe; the newer version wins and `current` never moves backwards (item 2) |
| 5 | Newest descriptor by mtime may not be the live daemon | Accepted. Identity no longer comes from the descriptor but from `status` and launchd's pid |
| 6 | Running MCP sessions keep old request expectations after a switch | Resolved: `slipstream-mcp` replaces itself through the shim (item 12) |
| 7 | Version authorities unclear | Resolved. App and daemon versions are independent; the daemon's comes from the payload's own `package.json` and `build-id` |
| 8 | Extraction must verify the final signed payload; hashes alone don't reject extra files | Resolved by comparing the copy with the signed bundle: every path, its bytes and mode; extra or missing files are rejected (item 2). The offline native-module load test is a release gate |
| 9 | Moving or deleting the app still affects restart; Sparkle has no updater delegate | Resolved. The release gate covers app move, deletion, reboot, Login Items off and install-on-quit; Sparkle gets an updater delegate for the relaunch |
| 10 | Cached streams survive a lost recorder; diagnostics are dropped upstream; a log tail isn't the full error | Resolved. Every state has a stream-open variant (screens.md); diagnostics stay structured (item 11); "Won't start" shows all of `daemon.log` since the app started the daemon; the lifecycle sits in one app-level model (item 13) |

## Simplicity gate (Phase 7)

Codex `gpt-6-astra` (`.context/simplicity-codex.md`) and an Opus reviewer, 2026-11-10. Brian's
answers then drove the three biggest cuts.

| Finding | Disposition |
|---|---|
| Is `conductor install` needed? (Brian) | Cut. Conductor is being removed. Only its LaunchAgent half is kept, as `slipstream service install`; no Conductor script is read or written |
| Drop the runtime manifest (Brian: "yes absolutely") | Cut. Identity comes from `package.json` and `build-id`, and the copy is byte-compared with the signed bundle. `models.md` is now "none" |
| Keep the Sparkle relaunch on install-on-quit (Brian: "YES") | Kept (item 6) |
| `SMAppService`, the launcher and the needs-approval states | Cut. The daemon's existing LaunchAgent does the job. A Login Items refusal shows as "Won't start" with launchd's output |
| `install.json` v2 | Cut. v1 stays, pointing at the app runtime, so old CLIs drive the app's daemon instead of starting a rival |
| Legacy-agent retirement as its own path (Codex) | Cut. The legacy label is the app's agent, so it's an ordinary build switch |
| Merge the "lifecycle" and "screens" PRs (Codex) | Adopted: three PRs, not four |
| Double daemon build gives two `build-id`s (Codex) | Adopted: `npm pack`'s `prepack` is the only build |
| `adopt-app` JSON report and `AdoptResult` decoding (Codex) | Cut: exit code plus raw output |
| Separate `launchdPID`/`lastExit` closures (Codex) | Adopted: one `launchctl print` parse |
| Public `active()` (Codex) | Cut |
| `.updateDidntFinish` holding a manifest (Codex) | Adopted: it holds versions and evidence only |
| `AppRuntime` label field and validation (Codex) | Adopted: a plain env read with derived shim paths |
| Parameterize the stream-open docking tests (Codex) | Adopted |
| Screenshot launch flag (Opus) | Cut: SwiftUI previews instead |
| A `~/.local/bin` link failure fails the update (Opus) | Fixed: reported in "Migration incomplete", never fatal |
| A one-word shim breaks Conductor's `OURS` regex (Opus) | Moot: Conductor scripts are untouched |
| Signature check of the extracted copy (`SecStaticCodeCheckValidity`) | Cut: the byte comparison with the signed bundle covers it |
| Prepending the shim dir to the terminal PATH | Cut: the terminal env gets the shim path directly |

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: none. Identity comes from the existing `status` control verb
  (`daemon_version`/`daemon_build`); there is no new endpoint, verb or descriptor field, and
  SIGTERM is the graceful stop.
- Models: [models.md](./models.md) (none)

## Approvals log

- 2026-11-10 — Brian approved the bundling direction ("ok love it let's do it"), arm64-only, and
  keeping manual npm publishing.
- 2026-11-10 — Brian rejected generic error text ("I want to show entire stack-traces or full error
  messages"), which became scope item 11.
  - He then approved the Change stream screen revision with full error blocks ("yeah. much better
    continue").
  - The approved states were starting, needs-approval, update-didnt-finish, another-recorder,
    wont-start, stream-open-restarting and stream-open-update-didnt-finish.
  - The stream-open-another-recorder state was added after that approval, to complete the set.
- 2026-11-10 — Brian approved the stream-open-another-recorder state, models.md and "Endpoints:
  none" ("yes... all sound good").
- 2026-11-10 — Brian approved the Phase 5 dispositions ("agreed").
  - He chose MCP self-replace over restarting agent sessions.
  - He approved the screen changes: stream-open variants for every state, and full output since
    the last start.
- 2026-11-10 — Brian approved the implementation plan ("ok looks good!"), including the proposed
  migration-failure panel, pending its mockup.
- 2026-11-10 — Brian, on the simplicity gate:
  - Conductor is being removed, so `conductor install` isn't needed ("We're fully removing
    conductor... do we need to keep conductor install?"). It became `service install`, and the
    approval path was cut.
  - Drop the manifest ("yes absolutely").
  - Keep the install-on-quit relaunch ("YES").

  This removes the needs-approval states and the install.json v2 record that he had approved
  earlier.
- 2026-11-10 — Brian approved the revised screens ("yes looks good continue"): the
  migration-incomplete state (`Y1Pnk`), the removal of both needs-approval states, and the updated
  evidence text (daemon.log, Slipstream.app, byte comparison, an unmanaged npm daemon as
  "another recorder").
