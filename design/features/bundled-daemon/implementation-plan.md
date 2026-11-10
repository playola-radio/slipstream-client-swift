# Bundled daemon Implementation Plan

> **Consumer:** `orchestrate-feature`. Three PRs across two repos, each in its own fresh session.
> Inside a PR, use superpowers:subagent-driven-development or superpowers:executing-plans
> task by task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** The macOS app ships, starts, updates and migrates its own daemon, so one Sparkle
update moves the app, the daemon, `slipstream` and `slipstream-mcp` together.

**Architecture:** The client's release build embeds Node and the daemon payload, both signed with
the app. At launch an app-level `RecorderModel`:
- copies the payload to a versioned folder and checks the copy byte for byte against the bundle;
- flips `current` and writes two stable shims;
- runs the daemon through the daemon's existing managed LaunchAgent (`radio.playola.slipstream`),
  installed by a new `slipstream service install` that the app runs through the shim, so the
  agent's plist points at concrete versioned paths;
- publishes one recorder state that the change-stream page shows.

The daemon gains an "app runtime" mode, switched on by one env var the shims set. In that mode
generated hooks and connector configs point at the shims, and a build mismatch defers to the
app. `adopt-app` moves existing hooks and connector configs over, and the MCP forwarder replaces
itself after an update.

**Tech Stack:** TypeScript on Node 24 (`node --test`) for the daemon. Swift 6 with complete
strict concurrency for the client: SwiftPM `SlipstreamCore` and the XcodeGen app,
swift-dependencies, Swift Testing, Sparkle 2. Shell for packaging.

**Spec:** [spec.md](./spec.md). Contracts: [screens.md](./screens.md). Models: none.
Endpoints: none (spec.md › Design deliverables). Design folder:
`playola-radio/slipstream-client-swift` › `design/features/bundled-daemon/`. The daemon session
reads the spec from there.

## Base commits

- Daemon `playola-radio/slipstream`: develop `4117951236b2939b41197d56c13f17e36ecf6091`. Read it
  with `git show 4117951:<path>` or a fresh worktree. `~/playola/slipstream` is a stale checkout.
- Client `playola-radio/slipstream-client-swift`: develop `3f49250908a1b05c668618d8f72420d44e2b68c7`.
- Every PR targets `develop`.

## PR graph

| PR | Repo | Depends on | Delivers |
|---|---|---|---|
| A | daemon | — | App-runtime mode, `service install`, `adopt-app`, MCP self-replace, payload builder |
| B | client | A merged (pins its commit) | Embedded, signed runtime; copy, compare, flip and shims (library and tests, not yet wired) |
| C | client | B | Recorder lifecycle, change-stream recorder states, full errors, app commands through the shim, install-on-quit relaunch, Debug external mode |

## Global Constraints

- Apple Silicon only. The embedded Node is `darwin-arm64`, and the client already builds arm64.
- Node `24.11.0`, pinned by version and sha256 in `packaging/runtime.env`.
- Daemon pinned by commit in `packaging/runtime.env`. App and daemon versions are independent.
- Bundle id `com.playola.SlipstreamViewer`. App bundle `Slipstream.app`.
- Runtime root: `~/Library/Application Support/com.playola.SlipstreamViewer/runtime/`.
  - Versioned dirs: `<daemon_version>-<first 8 chars of daemon_build>/`, each holding
    `bin/node` and `app/`.
  - `current` is a symlink to one versioned dir.
  - `bin/slipstream` and `bin/slipstream-mcp` are the stable shims.
  - `.lock` is the install lock.
- Bundled identity comes from the payload itself: `daemon_version` from `app/package.json`
  `version` and `daemon_build` from `app/dist/build-id`, trimmed. There is no manifest.
- Service: the daemon's existing LaunchAgent, label `radio.playola.slipstream`, plist
  `~/Library/LaunchAgents/radio.playola.slipstream.plist`, log
  `~/Library/Logs/slipstream/daemon.log`. `src/launch-agent.ts` writes all three; the app never
  writes the plist itself.
- App-runtime env var: `SLIPSTREAM_APP_RUNTIME=<runtime root>`, set only by the shims.
- Identity: the `status` control verb's `daemon_build` must equal the bundled `daemon_build`.
  Ownership: the pid in `launchctl print gui/<uid>/radio.playola.slipstream` must equal the
  `pid` in `<store>/owner.lock`.
- Stopping a daemon is SIGTERM only. Never SIGKILL, never `kickstart -k`, never `bootout` of a
  running job. Nothing escalates on a timeout.
- Never exec through `current`. Resolve it to the concrete dir first.
- Never move `current` to a lower `daemon_version` than it points at now.
- Conductor is out of scope; it is being removed separately. Nothing here reads or writes
  Conductor scripts. `service install` keeps `install.json`'s existing `repos` untouched.
- Errors are shown in full (spec item 11). The bearer token never appears in any error, log line,
  evidence block or clipboard text.
- Tests never touch `~/.slipstream`, real launchd or the real runtime root. Use temp dirs and
  `SLIPSTREAM_STORE`.
- Client conventions are in the repo's `CLAUDE.md`, and the pfw-* skills are required. Daemon
  conventions are in the daemon repo's `CLAUDE.md`/`AGENTS.md`.
- Changelog: PR C adds `changelog.d/bundled-recorder.md`. PR A follows the daemon repo's
  changelog rule. PR B is a chore (no user-visible change) and says so.

## Review Focus

1. **Two different app copies launched one after the other** (an old one in `/Applications`, a
   new one in `~/Downloads`). Expected: the newer daemon version stays current, and the older app
   neither copies over it nor stops the newer daemon (its recorder state is "another
   recorder"). Test: Task B2 `activateNeverMovesBackwards`, Task C2 `olderAppDoesNotStopNewerDaemon`.
2. **Disk full or permission denied partway through the copy.** Expected: "Update didn't
   finish" with the errno and path, the staging dir removed, `current` and the running daemon
   untouched. Test: Task B2 `copyFailureLeavesCurrent`.
3. **A daemon outside the LaunchAgent owns the store** (a detached npm daemon, or `slipstream
   start` from a clone). Expected: "another recorder" with its pid and command line, never
   stopped without **Replace it**. Test: Task C2 `unmanagedDaemonIsNeverStopped`.
4. **A bearer token in captured text.** For example, the daemon logs a descriptor path, or stderr
   contains `token`. Expected: the token value is redacted before display or copy. Test: Task C2
   `evidenceRedactsToken`.
5. **An agent session started on the old build calls an MCP tool after the switch.** Expected:
   the call succeeds on the new build without the agent restarting. Test: Task A5
   `forwarderReplacesItselfOnNewerBuild`.

---

## PR A — daemon (`playola-radio/slipstream`)

### Task A1: App-runtime mode and shim-based entries

**Files:**
- Create: `src/app-runtime.ts`, `src/app-runtime.test.ts`
- Modify:
  - `src/attach-workflow.ts` (`AttachDeps`, `planAgentConfig` ~line 317, the
    `server.command === deps.nodePath` ownership check ~line 489)
  - `src/daemon-version.ts` (`remedyFor`, line 128)
  - `src/cli.ts` (`runThisChatAttach`, `daemonStarter` ~line 659)

**Interfaces:**
- Produces:
  - `appRuntime(env: NodeJS.ProcessEnv): { cli: string; mcp: string } | null`. It returns null
    when `SLIPSTREAM_APP_RUNTIME` is unset; otherwise `cli` is `<root>/bin/slipstream` and `mcp`
    is `<root>/bin/slipstream-mcp`. It is a plain read, with no validation: only the shims set
    the variable.
  - `type Entry = { command: string; args: string[] }`.
    - npm: `{ command: node, args: [cli] }`, with the forwarder `{ command: node, args: [forwarder] }`;
    - app: `{ command: runtime.cli, args: [] }` and `{ command: runtime.mcp, args: [] }`.
  - `AttachDeps` replaces `nodePath`/`cliPath` with `entry: Entry` and `mcpEntry: Entry`.
  - In app mode, `remedyFor` returns
    `{ text: 'The Slipstream app is switching this recorder to <own.version>; open Slipstream if it doesn't finish.' }`
    with no `restart`, so the CLI never kickstarts with `-k` under the app.

- [ ] **Step 1: Write failing tests:**
  - `appRuntime` returns null without the var and derives both shim paths with it.
  - In `attach-workflow.test.ts`, with app entries:
    - the Claude hook command is `/rt/bin/slipstream hook claude-code post-tool-use --store <store>`;
    - `claudeTool` is `['/rt/bin/slipstream-mcp', '--store', store]`;
    - the Codex tool's command is `/rt/bin/slipstream-mcp` with args `['--store', store]`;
    - a second attach recognises those entries as Slipstream's (no duplicate, no refusal).
  - In `daemon-version.test.ts`: in app mode, a mismatch has no `restart`, and its text is the
    string above.
- [ ] **Step 2: Run `npm test -- src/app-runtime.test.ts src/attach-workflow.test.ts src/daemon-version.test.ts`.**
  Expected: the new tests fail.
- [ ] **Step 3: Implement.**
  - `cli.ts` builds both entries from `appRuntime(process.env)`, falling back to
    `process.execPath` + the real CLI path and forwarder.
  - The forwarder-missing refusal stays for the npm entry only.
  - The ownership check compares `server.command` with `mcpEntry.command`.
- [ ] **Step 4: Run `npm test`, `npm run typecheck`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat: point hooks and connectors at the app's stable commands in app-runtime mode`.

### Task A2: `slipstream service install`

The LaunchAgent install, without the Conductor half of `conductor install`.

**Files:**
- Modify: `src/cli.ts` (parse `service install --store <dir>`), `src/launch-agent.ts`
- Test: `src/launch-agent.test.ts`

**Interfaces:**
- Consumes: `entryPaths`, `installLaunchAgent`, `readManagedInstall`, `writeManagedInstall`,
  `kickstartLaunchAgent` (all existing).
- Produces:
  - `installService(deps: { execPath; nodeVersion; cliPath; home; store; uid; packageVersion; run }): Promise<LaunchAgentResult>`
    in `src/launch-agent.ts`. It:
    1. calls `entryPaths`;
    2. calls `installLaunchAgent({ ...paths, home, store, uid })` (no `restart`);
    3. writes `install.json` v1 with `{ package_version, node, cli, log, repos: prior?.repos ?? [] }`;
    4. runs `launchctl kickstart gui/<uid>/radio.playola.slipstream` (no `-k`), so a loaded but
       stopped job starts.
  - `slipstream service install --store <dir>`:
    - exits 0 and prints the plist, log, Node and CLI paths, like `conductor install`'s output;
    - on failure, exits 1 with the `InstallError` message on stderr (for example
      `launchctl could not load … (exit 5): Bootstrap failed: 5: Input/output error`).

- [ ] **Step 1: Write failing tests**, using a temp home, a temp store and a fake `run`:
  - `writesPlistWithConcretePaths` (the plist's `ProgramArguments` are the `execPath` and
    `cliPath` given);
  - `keepsPriorRepos`;
  - `kickstartsWithoutKill` (`run` never receives `-k`);
  - `reportsLaunchctlFailureVerbatim`.
- [ ] **Step 2: Run `npm test -- src/launch-agent.test.ts`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `npm test`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: install the background daemon without Conductor`.

### Task A3: `slipstream adopt-app`

Moves Slipstream-written hook and connector entries from nvm paths to the shims. Idempotent.
The app runs it after a switch or a first install.

**Files:**
- Create: `src/adopt-app.ts`, `src/adopt-app.test.ts`
- Modify:
  - `src/cli.ts` (parse `adopt-app --store <dir>`)
  - `src/attach-workflow.ts` (export the hook and tool planners with a "replace a
    Slipstream-written entry" mode)

**Interfaces:**
- Consumes: `appRuntime`, `Entry` (A1).
- Produces: `slipstream adopt-app --store <dir>`:
  - prints one line per file, either `rewrote <path> (backup <backup>)` or
    `unchanged <path>`, and one `failed <path>: <message>` line per error, to stdout;
  - exits 1 if any file failed, otherwise 0;
  - refuses with exit 2 and a stderr message when `SLIPSTREAM_APP_RUNTIME` is unset.

- [ ] **Step 1: Write failing tests** in `src/adopt-app.test.ts`, using a temp home, a temp
  store and a fake `run`:
  - `rewritesWorktreeHooks`:
    - for each root the store's capture intents list, Slipstream-written hook commands in
      `.claude/settings.local.json` and `.codex/hooks.json` become the shim form;
    - Slipstream-written commands are the ones matching
      `<node> <…/dist/cli.js> hook <harness> post-tool-use --store <store>`;
    - unrelated hooks stay byte-identical;
    - a `.slipstream-backup-<epoch-ms>` copy exists.
  - `rewritesCodexTool`: a project or user `config.toml` server whose args start with
    `…/dist/mcp-forwarder.js` becomes `command = "<rt>/bin/slipstream-mcp"`,
    `args = ["--store", "<store>"]`.
  - `reregistersClaudeTool`: a `claude mcp` registration pointing at the forwarder is
    re-registered with the shim, in the scope `claudeToolMissing` checks.
  - `idempotent`: a second run prints only `unchanged` lines and writes no backups.
  - `reportsPerFileErrors`: an unreadable hook file prints a `failed` line, the other files are
    still rewritten, and the exit code is 1.
- [ ] **Step 2: Run `npm test -- src/adopt-app.test.ts`.** Expected: FAIL.
- [ ] **Step 3: Implement `runAdoptApp(deps)` in `src/adopt-app.ts`.**
  - Reuse the hook and tool planners. `planAgentConfig`'s refusal stays for `attach`.
  - Writes are atomic, like `writeAtomic`.
- [ ] **Step 4: Run `npm test`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: add adopt-app to move hooks and connectors onto the app's runtime`.

### Task A4: Runtime payload builder

**Files:**
- Create: `scripts/build-payload.mjs` plus a test in the repo's script-test location
- Modify: `package.json` (`"build:payload": "node scripts/build-payload.mjs"`)

**Interfaces:**
- Produces: `npm run build:payload -- --out <dir>`. It runs `npm pack`, whose `prepack` is the
  only build, so there is one `dist/build-id`. It then extracts the tarball to `<dir>/app/` and
  runs `npm ci --omit=dev` there with the repo's lockfile. `<dir>/app/` then contains:
  - `package.json`;
  - every path in `package.json` `files` (including `dist/build-id`);
  - production `node_modules` for the host's arch.
  - No `bin/node` and no shims: the client adds those.
- It fails, naming the path, if:
  - `dist/build-id` is absent;
  - `node_modules/@parcel/watcher-darwin-arm64` is absent;
  - any symlink exists under `<dir>/app/`.

- [ ] **Step 1: Write a failing test** that runs the builder into a temp dir (marked as the
  repo's slow or OS test kind) and asserts:
  - `app/dist/cli.js`, `app/dist/build-id` and `app/node_modules/@parcel/watcher/package.json`
    exist;
  - `app/node_modules/typescript` does not;
  - no symlinks exist;
  - `node <out>/app/dist/cli.js --version` prints `package.json` `version`.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: build a self-contained runtime payload for the macOS app`.

### Task A5: MCP forwarder replaces itself after an update

**Files:**
- Modify: `src/mcp-forwarder.ts` (`createForwarderHandlers`; the stdin loop and `main`)
- Test: `src/mcp-forwarder.test.ts`

**Interfaces:**
- Consumes: `appRuntime` (A1), `checkDaemonBuild`, `thisBuild`, `versionGate` (`src/daemon-version.ts`).
- Produces: in app mode, when a tool call's gate answers `DAEMON_VERSION_MISMATCH`, the
  forwarder:
  1. reads `<root>/current/app/dist/build-id` (through `realpath`);
  2. if that build differs from its own, calls
     `process.execve(runtime.mcp, [runtime.mcp, ...process.argv.slice(2)], { ...process.env, SLIPSTREAM_MCP_REPLAY: <base64 JSON of the initialize request and the pending tool call> })`;
  3. if they are the same, returns the mismatch as today (the daemon is the stale side and the
     app is switching it).
- On start, the new forwarder, when `SLIPSTREAM_MCP_REPLAY` is set:
  - feeds the saved `initialize` to its handlers without writing that response;
  - deletes the variable from `process.env`;
  - processes the saved tool call normally, so its response goes to the agent under the
    original JSON-RPC id.
- Npm mode is unchanged.

- [ ] **Step 1: Write failing tests:**
  - `forwarderReplacesItselfOnNewerBuild`: with an injected `execve` spy and a fake runtime
    whose `current` build differs, a mismatch calls the spy with the shim path and a replay
    holding the original id.
  - `forwarderDoesNotReplaceOnSameBuild`: same build → no `execve`, and the mismatch response is
    returned.
  - `replayAnswersPendingCallOnce`: a forwarder started with a replay writes exactly one
    response (the tool call's), with the original id, and no `initialize` response.
- [ ] **Step 2: Run `npm test -- src/mcp-forwarder.test.ts`.** Expected: FAIL.
- [ ] **Step 3: Implement.** Inject `execve` and `readCurrentBuild` through
  `ForwarderHandlerOpts` so the tests need no real exec.
- [ ] **Step 4: Run `npm test` and `npm run test:os`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: keep agent MCP sessions working across an app update`.

**PR A done when:**
- `npm test`, `npm run typecheck` and `npm run test:os` pass;
- `npm run build:payload -- --out /tmp/payload`, with `SLIPSTREAM_APP_RUNTIME` pointing at a fake
  root, runs `adopt-app --store <tmp>` and prints its lines.

---

## PR B — client: embedded runtime and installation (`slipstream-client-swift`)

### Task B1: Pin, build and sign the payload

**Files:**
- Create:
  - `packaging/runtime.env`: `DAEMON_REPO=playola-radio/slipstream`,
    `DAEMON_COMMIT=<PR A merge commit on develop>`, `NODE_VERSION=24.11.0`,
    `NODE_SHA256=<sha256 of node-v24.11.0-darwin-arm64.tar.xz from nodejs.org SHASUMS256.txt>`
  - `packaging/build-runtime.sh <out-dir>`:
    - clones the daemon at `DAEMON_COMMIT`;
    - runs `npm ci && npm run build:payload -- --out <out>`;
    - downloads and verifies Node, and copies only `bin/node` to `<out>/bin/node`.
  - `packaging/node.entitlements`: `com.apple.security.cs.allow-jit`. Add
    `allow-unsigned-executable-memory` only if the offline gate (Task C8) fails without it.
- Modify:
  - `packaging/build-app.sh`: after `ditto`, run
    `build-runtime.sh "$DEST_APP/Contents/Resources/SlipstreamRuntime"`.
  - `packaging/sign-app.sh`: before "Signing the app", sign every Mach-O under
    `Contents/Resources/SlipstreamRuntime` (Node with `node.entitlements`, `*.node` without),
    then sign the app.
  - `.github/workflows/release.yml`: needs Node 24 for the daemon build (`actions/setup-node`,
    pinned by SHA like the other actions).
  - `packaging/README.md`.

- [ ] **Step 1: Run `packaging/build-app.sh` locally.** Expected:
  `Slipstream.app/Contents/Resources/SlipstreamRuntime/{bin/node,app/dist/cli.js}` exist and
  `bin/node --version` prints `v24.11.0`.
- [ ] **Step 2: Run `packaging/sign-app.sh` with a local identity.** Expected: the existing "every
  Mach-O signed by team" guard passes, including `bin/node` and `watcher.node`.
- [ ] **Step 3: Commit** `chore: embed the pinned daemon and Node in the app bundle`.

### Task B2: Copy, compare and activate (`SlipstreamCore`)

**Files:**
- Create: `Sources/SlipstreamCore/RuntimeInstall.swift`, `Tests/SlipstreamCoreTests/RuntimeInstallTests.swift`

**Interfaces:**
- Produces:
  - `struct RuntimeIdentity: Equatable, Sendable { version: String; build: String }`, read from
    `app/package.json` and `app/dist/build-id`.
  - `struct RuntimeInstall: Sendable { init(root: URL, bundled: URL) }`, where `bundled` is
    `Contents/Resources/SlipstreamRuntime`.
  - `func bundledIdentity() throws(RuntimeInstallError) -> RuntimeIdentity`
  - `func prepare() throws(RuntimeInstallError) -> PreparedRuntime`. It takes the lock, then:
    - if the versioned dir exists, returns it. The dir only ever appears through a rename after
      the copy has been compared.
    - Otherwise it copies to `root/.staging-<uuid>`, strips `com.apple.quarantine`, and
      compares the copy with `bundled`: the same relative paths, the same bytes, the same
      permission bits, regular files and dirs only. Then it renames the copy to the versioned dir.
    - Any failure removes the staging dir.
  - `struct PreparedRuntime: Equatable, Sendable { identity: RuntimeIdentity; directory: URL }`
  - `func activate(_ runtime: PreparedRuntime) throws(RuntimeInstallError) -> Activation`. Under
    the lock it:
    - returns `.newerActive(RuntimeIdentity)` if `current` points at a higher version (semver);
    - otherwise writes `current.tmp-<uuid>` → `rename` over `current`, writes both shims, and
      returns `.activated`.
  - `func linkCommands() -> [LinkProblem]` creates `~/.local/bin/slipstream{,-mcp}` → the shims.
    - An existing symlink to them is left alone.
    - An existing non-symlink file, or any other failure, is returned as
      `LinkProblem { path: String; message: String }`, never thrown, so it never fails an update.
  - `enum RuntimeInstallError: Error, Equatable`. Each case carries everything the evidence
    block shows:
    - `case io(step: String, path: String, errno: Int32, message: String)`
    - `case differs(path: String, expected: String, actual: String)`, where `expected`/`actual`
      are a sha256, a mode, `absent` or `present`
  - The lock is `flock(LOCK_EX)` on `root/.lock`, held for the duration of `prepare` and
    `activate`.
  - Shim text (both shims; `slipstream-mcp` execs `dist/mcp-forwarder.js`):

    ```sh
    #!/bin/sh
    root="$HOME/Library/Application Support/com.playola.SlipstreamViewer/runtime"
    dir="$(cd "$root/current" 2>/dev/null && pwd -P)" || { echo "slipstream: no runtime at $root/current; open Slipstream once." >&2; exit 127; }
    SLIPSTREAM_APP_RUNTIME="$root" exec "$dir/bin/node" "$dir/app/dist/cli.js" "$@"
    ```

- [ ] **Step 1: Write failing tests**, using temp `root` and `bundled` trees built by a helper:
  - `prepareCopiesAndCompares`;
  - `prepareRejectsChangedByte` (expects `.differs(path, expected, actual)`);
  - `prepareRejectsExtraFile` (expects `.differs(path, "absent", "present")`);
  - `prepareRejectsModeChange`;
  - `prepareRejectsSymlink`;
  - `copyFailureLeavesCurrent` (make `root` read-only after one activation, then prepare a new
    bundled version: expect `.io`, `current` unchanged, no `.staging-*` left);
  - `prepareReusesExistingDir`;
  - `activateFlipsCurrent`;
  - `activateNeverMovesBackwards` (activate 0.3.2, then 0.3.1: expect `.newerActive` with
    0.3.2, `current` unchanged);
  - `activateWritesShims` (expect the exact shim text above);
  - `linkCommandsReportsForeignFile`;
  - `concurrentPrepareIsSerialized` (two tasks preparing the same bundle: one copy, both
    succeed).
- [ ] **Step 2: Run `swift test --filter RuntimeInstallTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: PASS.
- [ ] **Step 5: Commit** `chore: copy and verify the bundled runtime`.

**PR B done when:**
- `swift test` and `xcodebuild test` pass;
- a locally built and signed app contains the runtime;
- `RuntimeInstall` is used by nothing yet.

---

## PR C — client: recorder lifecycle and screens

### Task C1: Recorder service client

**Files:**
- Create: `SlipstreamViewer/Dependencies/RecorderServiceClient.swift`,
  `Sources/SlipstreamCore/LaunchctlPrint.swift`, and tests for the Core file

**Interfaces:**
- Produces:
  - `struct RecorderServiceClient: Sendable`, a pfw-dependencies struct of closures, with
    `liveValue` and `testValue` (all `unimplemented`):
    - `job: @Sendable () async throws -> LaunchdJob?`. It runs
      `launchctl print gui/<uid>/radio.playola.slipstream` and returns nil when the job isn't
      loaded.
    - `terminate: @Sendable (Int32) throws -> Void` (`kill(pid, SIGTERM)`)
    - `ownerLockPID: @Sendable (URL) -> Int32?` (`<store>/owner.lock`, parsed like the daemon's
      `parseLock`: a JSON `pid` or a bare integer)
    - `daemonBuild: @Sendable (URL) async throws -> DaemonBuild?`, the `status` verb over
      `ControlTransport`. nil means no daemon answers.
      `DaemonBuild { version: String; build: String? }`; a nil build is a daemon too old to
      report one.
    - `processDescription: @Sendable (Int32) -> String?` (`ps -o lstart=,command= -p <pid>`, verbatim)
    - `logSize: @Sendable () -> UInt64` and `logSince: @Sendable (UInt64) throws -> String`, on
      `~/Library/Logs/slipstream/daemon.log`
    - `runShim: @Sendable ([String]) async throws -> ShimRun`. It runs `<runtime root>/bin/slipstream`
      with the arguments. `ShimRun { command: String; exitCode: Int32; output: String }`, where
      `output` is stdout and stderr interleaved, verbatim.
  - `LaunchctlPrint.job(in output: String) -> LaunchdJob`, where
    `LaunchdJob { pid: Int32?; lastExit: String?; raw: String }` (`raw` is the full output).

- [ ] **Step 1: Write failing Core tests**, using a captured real `launchctl print` output saved
  as a fixture string:
  - `parsesRunningJob`;
  - `parsesStoppedJobWithLastExit`.
- [ ] **Step 2: Run `swift test --filter LaunchctlPrint`.** Expected: FAIL.
- [ ] **Step 3: Implement the parser and the live client.** The live client shells out with
  `Process`.
- [ ] **Step 4: Run `swift test`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: add the recorder service client`.

### Task C2: `RecorderModel`

The app-level lifecycle owner: one instance, created in `SlipstreamViewerApp`, passed to pages.

**Files:**
- Create:
  - `SlipstreamViewer/Models/RecorderModel.swift`
  - `SlipstreamViewerTests/Models/RecorderModelTests.swift`
  - `SlipstreamViewer/Dependencies/RuntimeInstallClient.swift`, a dependency wrapper over B2
    (`bundledIdentity`, `prepare`, `activate`, `linkCommands`) with `testValue` unimplemented,
    plus `static let runtimeRoot`
- Modify: `SlipstreamViewer/App/SlipstreamViewerApp.swift` (`@State private var recorder = RecorderModel()`;
  `.task { await recorder.appLaunched() }`)

**Interfaces:**
- Consumes: `RuntimeInstallClient` (B2), `RecorderServiceClient` (C1), `\.continuousClock`,
  `\.pasteboard` (existing `PasteboardClient`). The store is
  `URL(fileURLWithPath: daemon.storeID)`; `DaemonClient.storeID` is the standardized path.
- Produces:
  - `RecorderModel: ViewModel`, `@MainActor @Observable`, with:
    - `private(set) var state: RecorderState`
    - `func appLaunched() async`
    - `func tryAgainTapped() async`
    - `func replaceItTapped() async`
    - `func openLogTapped()`
    - `func copyTapped()`
  - `RecorderState` (Equatable):
    - `.starting(RuntimeIdentity)`
    - `.running`
    - `.restarting(from: String, to: RuntimeIdentity)`
    - `.updateDidntFinish(running: DaemonBuild, bundled: RuntimeIdentity, Evidence)`
    - `.anotherRecorder(pid: Int32, Evidence)`
    - `.wontStart(RuntimeIdentity, Evidence)`
    - `.migrationIncomplete(Evidence)`, the migration-failure panel
    - `.external` (Debug only, C4)
  - `Evidence { source: String; text: String }`. The text is already redacted.
  - `appLaunched()` runs this sequence. Every failure maps to exactly one state:
    1. `prepare()`. An error → `.updateDidntFinish` if a daemon answers, else `.wontStart`. The
       evidence lists the step, path, expected/actual or errno, and the running build.
    2. Ask `daemonBuild(store)`, `ownerLockPID` and `job()`.
       - **The build equals the bundled one** → `activate()` (idempotent) → `.running`.
       - **It answers, but the lock pid ≠ `job.pid`** → `.anotherRecorder` (the evidence holds
         `status`, the lock pid and `processDescription`). Nothing is stopped.
       - **It answers, the pids match, and it is on another build** → `activate()` first. A
         flip failure is still a preparation failure: `.updateDidntFinish`, nothing stopped.
         The running daemon uses its concrete dir, so flipping early doesn't disturb it.
         - `.newerActive` → `.anotherRecorder` (an older app never stops a newer daemon).
         - `.activated` → `.restarting`, `terminate(pid)`, then poll with the clock every
           250 ms until `daemonBuild` is nil and `ownerLockPID` is nil or no longer that pid.
           There is no deadline. Then continue as "nothing answers".
         - This branch also moves a pre-app npm install over, because the npm
           `conductor install` used the same label (spec item 7).
       - **Nothing answers** → `activate()`, record `logSize()`, run
         `runShim(["service", "install", "--store", store])`. A non-zero exit → `.wontStart`,
         with the command and its full output as the evidence. Otherwise → `.starting`.
    3. While starting or restarting, poll `daemonBuild` every 250 ms:
       - **It equals the bundled build** → `.running`. If this launch switched or installed, run
         `linkCommands()` and `runShim(["adopt-app", "--store", store])`. Any link problem or a
         non-zero exit → `.migrationIncomplete`, whose evidence is the link problems followed by the
         command's full output.
       - **`job.pid` is nil and `job.lastExit` is non-nil** → `.wontStart`. The evidence is
         `logSince(<recorded size>)`, headed by `job.lastExit`.
  - `replaceItTapped()`:
    1. re-reads `ownerLockPID` and `processDescription`; if either changed since the evidence
       was taken, it re-evaluates instead of stopping;
    2. `terminate(pid)`;
    3. waits as in step 2, then continues as "nothing answers".
  - `tryAgainTapped()` reruns `appLaunched()`. From `.migrationIncomplete`, it reruns only links and
    `adopt-app`.
  - `copyTapped()` copies `source + "\n\n" + text` of the current evidence.
  - Redaction replaces any value of a JSON `"token"` field, and any 32+ character hex or
    base64url run following `token` or `Bearer `, with `<redacted>`. It applies to every
    `Evidence.text` before it is stored.

- [ ] **Step 1: Write failing tests** with `withDependencies`, a `TestClock` and
  `.mainSerialExecutor`, one per transition:
  - `updateDidntFinishKeepsOldRunning` (`prepare` throws `.differs`; assert the state and that
    `terminate` is never called);
  - `freshStartInstallsService`;
  - `serviceInstallFailureIsWontStart` (the evidence is the command plus its full output);
  - `sameBuildIsRunningWithoutAdopting`;
  - `ownedOtherBuildRestarts` (assert the order: `prepare` → `activate` → `terminate(pid)` →
    lock released after clock advances → `service install` → `.running` → `adopt-app`);
  - `flipFailureStopsNothing` (`activate` throws `.io` → `.updateDidntFinish`, no `terminate`);
  - `unmanagedDaemonIsNeverStopped` (lock pid 30117, job nil, status `0.3.0`/nil build →
    `.anotherRecorder`, `terminate` never called);
  - `olderAppDoesNotStopNewerDaemon` (`activate` → `.newerActive` → `.anotherRecorder`, no
    `terminate`);
  - `exitDuringStartIsWontStart` (evidence equals `"last exit code = 1\n\n"` + the log text
    after the recorded size);
  - `adoptFailureIsMigrationIncomplete`;
  - `tryAgainFromMigrationIncompleteRerunsOnlyAdopt`;
  - `replaceItRevalidatesPid` (the pid changed → no `terminate`);
  - `evidenceRedactsToken`;
  - `copyCopiesSourceAndText`.
- [ ] **Step 2: Run `xcodebuild test -only-testing:SlipstreamViewerTests/RecorderModelTests`.**
  Expected: FAIL.
- [ ] **Step 3: Implement `RecorderModel`.** Use the MARK order from `CLAUDE.md`. Async work has
  one owner (a stored `Task` with a generation number); `tryAgainTapped` cancels and restarts it.
- [ ] **Step 4: Run `swift test` and `xcodebuild test`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: start and switch the bundled recorder from the app`.

### Task C3: Install on quit relaunches

**Files:**
- Modify:
  - `SlipstreamViewer/Dependencies/UpdaterClient.swift` (`LiveUpdater` gets an
    `SPUUpdaterDelegate`)
  - `SlipstreamViewer/App/UpdaterModel.swift`
  - `SlipstreamViewer/App/AppDelegate.swift`

**Interfaces:**
- Produces:
  - The delegate implements `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`,
    storing the block, and returns `true`.
  - `UpdaterClient` gains `installPendingUpdateAndRelaunch: @MainActor @Sendable () -> Bool`.
    It returns `false` when no block is stored.
  - `AppDelegate.applicationShouldTerminate` calls it and returns `.terminateCancel` when it
    returned `true`. Sparkle then quits, installs and relaunches.

- [ ] **Step 1: Write failing tests** in `UpdaterModelTests`: `quitWithPendingUpdateRelaunches`
  and `quitWithoutPendingUpdateQuits`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: relaunch after installing an update on quit`.

### Task C4: Debug external mode

**Files:**
- Modify: `RecorderModel.swift`, `project.yml` (the Debug scheme sets env
  `SLIPSTREAM_EXTERNAL_DAEMON=1`, disabled by default)

**Interfaces:**
- Produces: under `#if DEBUG`, when `SLIPSTREAM_EXTERNAL_DAEMON=1`, `appLaunched()` sets
  `.external` and calls no `RuntimeInstallClient` or `RecorderServiceClient` method. Release
  builds compile the check out.
  - Read the env var through an init parameter so tests can set it.

- [ ] **Step 1: Write the failing test** `externalModeTouchesNothing` (both clients are
  `unimplemented`; the state is `.external`).
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: let Debug builds use a daemon run from a clone`.

### Task C5: Discovery and HTTP errors keep their detail

Today `DescriptorDiscovery.discover` collapses every failure into `noDaemonRunning(store:)`,
and `DaemonTransport.check` keeps only the status code (spec item 11).

**Files:**
- Modify: `Sources/SlipstreamCore/DaemonDescriptor.swift`, `Sources/SlipstreamCore/DaemonTransport.swift`,
  and their tests in `Tests/SlipstreamCoreTests/`

**Interfaces:**
- Produces:
  - `DescriptorError`:
    - `case noRuntimeDirectory(path: String, errno: Int32, message: String)`
    - `case noUsableDescriptor(directory: String, rejected: [DescriptorRejection])`
  - `struct DescriptorRejection: Equatable, Sendable { file: String; reason: String }`. Example
    reasons:
    - `mode 0644 (group/other bits set)`
    - `owner uid 0, expected 501`
    - `not a regular file`
    - `invalid JSON: <parser message>`
    - `url is not loopback: http://10.0.0.2:4100`

    A reason never contains the token.
  - `DaemonHTTPError.status(Int, durableSeq: Seq?, body: String)`: the response body, decoded
    as UTF-8 with replacement, up to 64 KiB.

- [ ] **Step 1: Write failing tests:**
  - `missingRuntimeDirReportsErrno`;
  - `rejectedDescriptorsListEachReason` (one group-readable file, one wrong-owner file, one
    non-loopback URL);
  - `rejectionNeverContainsToken`;
  - `statusErrorKeepsBody`.
- [ ] **Step 2: Run `swift test`.** Expected: FAIL.
- [ ] **Step 3: Implement.** `validCandidate` returns a `Result` carrying the rejection instead
  of nil. Update the existing call sites that match `.noDaemonRunning` and `.status`.
- [ ] **Step 4: Run `swift test` and `xcodebuild test`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: keep the real reason when the app can't reach the recorder`.

### Task C6: Recorder message on the change-stream page

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`
  - remove the strings at lines 278 and 1165–1166;
  - `footerText` / `statusText`;
  - add a `recorder: RecorderModel` init parameter.
- Modify: `ChangeStreamPageView.swift`
- Create:
  - `SlipstreamViewer/Views/Reusable Components/RecorderMessageView.swift` (the headline,
    evidence block with Copy, and buttons; full and docked variants)
  - `SlipstreamViewer/Models/RecorderMessage.swift`
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes: `RecorderModel.state` and its actions (C2).
- Consumes: `DescriptorError` and `DaemonHTTPError` (C5). Where lines 278 and 1165–1166 showed
  generic text while the recorder is `.running`, the page shows the error's own text as
  `Evidence`, redacted like C2. The source is `discovery` or `GET <path> → <status>`.
- Produces:
  - `struct RecorderMessage: Equatable { icon: Icon; tone: Tone; headline: String; evidence: Evidence?; actions: [Action] }`
    - `Tone`: `.neutral`, `.warning`, `.error` (mapped to `DesignTokens`)
    - `Action`: `.tryAgain`, `.replaceIt`, `.openLogFile`
  - `ChangeStreamPageModel` gains:
    - `var recorderMessage: RecorderMessage?`, nil for `.running` and `.external`;
    - `var recorderMessageIsDocked: Bool`, true when a session is selected (the cached stream
      stays visible) and always true for `.migrationIncomplete`;
    - `var recorderFooterText: String?`.
  - Headline and footer copy is exactly the text in the pen frames (screens.md table, node ids
    there). For example:
    - `.anotherRecorder` headline: `A recorder this app didn't start (pid <pid>, <describe>) is using <store, ~-abbreviated>. It's still recording; the app won't stop it unless you replace it.`
    - its footer: `Recorder pid <pid> is <describe>, not started by this app`.
  - When a session is selected but the recorder is not running, the footer shows
    `recorderFooterText` in place of `statusText`'s `"Disconnected"`.

- [ ] **Step 1: Write failing tests:**
  - one test per state (`starting`, `restarting`, `updateDidntFinish`, `anotherRecorder`,
    `wontStart`, `migrationIncomplete`), each asserting the exact headline, footer, evidence source and
    actions;
  - one parameterised test over those states × stream open/closed, asserting
    `recorderMessageIsDocked`;
  - `connectionErrorShowsDetail` (a `.noUsableDescriptor` with two rejections → the evidence
    lists both);
  - `noGenericDaemonText`: with the daemon missing, no model string contains "daemon isn't
    running", "Couldn't reach" or "npm i -g".
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement the model properties, then the views.** Views only bind (zero logic),
  use only `DesignTokens`, and the evidence text is `.textSelection(.enabled)` in Geist Mono. Add
  a SwiftUI preview per state.
- [ ] **Step 4: Run `swift test` and `xcodebuild test`.** Expected: PASS, no warnings.
- [ ] **Step 5: Commit** `feat: show the recorder's real state and full errors in the change stream`.

### Task C7: App commands through the shim

**Files:**
- Modify:
  - `SlipstreamViewer/Dependencies/WorkspaceClient.swift` (lines 77–89: drop the `PATH` search
    and `slipstreamNotFoundText`)
  - `SlipstreamViewer/Dependencies/TerminalRuntimeClient.swift` (`TerminalEnvironment.slipstream`
    becomes the shim path, non-optional)
- Test: the existing `WorkspaceClient` and `TerminalRuntimeClient` tests

**Interfaces:**
- Produces:
  - `WorkspaceClient` runs `RuntimeInstallClient.runtimeRoot/bin/slipstream`.
  - When the shim is missing, the error is the shim's own stderr and exit code, verbatim.

- [ ] **Step 1: Write failing tests:**
  - `archiveRunsShim` (the command path is the shim);
  - `missingShimReportsShimError`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test` and `xcodebuild test`.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: run slipstream commands from the app's own runtime`.

### Task C8: Release gate checklist

**Files:**
- Modify: `packaging/README.md` (a "Bundled recorder release gate" section)

The checklist runs on a clean, offline Apple Silicon Mac or VM with no Node, no nvm and no
`~/.slipstream`. Record the result of each line in the PR body:

1. First launch → `.running`. `slipstream status` works from a new terminal through
   `~/.local/bin`.
2. Quit the app → the recorder keeps running (`launchctl print` shows the pid).
3. Reboot → the recorder runs before the app is opened.
4. Move or delete `Slipstream.app` → recording continues (the agent runs from Application
   Support). Supported outcome.
5. Turn Slipstream off in Login Items, then quit and relaunch → "Won't start", with
   `service install`'s full launchctl output as the evidence.
6. Install on quit: install vN, publish vN+1 to a test appcast, quit → the app relaunches on
   vN+1 and the recorder switches (`.restarting` → `.running`). An MCP call from a running agent
   still succeeds.
7. Migration on a copy of a real setup (an npm daemon under `radio.playola.slipstream`):
   - the agent's plist now points into Application Support;
   - hooks and connector configs point at the shims, with backups present.
8. Native module: a capture records a file change (proves `watcher.node` loads from the
   copied runtime).
9. Each state in screens.md, checked against its SwiftUI preview.

- [ ] **Step 1: Write the section.**
- [ ] **Step 2: Commit** `chore: document the bundled recorder release gate`.

**PR C done when:**
- `swift test` and `xcodebuild test` (warnings are errors) pass;
- the gate is recorded for a locally signed build. Lines 6 and 7 may use a Debug-signed build
  against a disposable store.

## Accepted trades

- If Slipstream is turned off in Login Items, launchd's own error ("Bootstrap failed: 5:
  Input/output error") is the evidence; there is no dedicated approval panel.
- Login Items lists the agent under the signer's name, not as "Slipstream" with the app icon.
- An npm CLI run outside the app can still restart the app's daemon with `kickstart -k` on a
  build mismatch (existing behaviour in `remedyFor`), or repoint the agent with its own
  `conductor install`. The next app launch switches it back. Conductor's removal deletes the
  second path.
