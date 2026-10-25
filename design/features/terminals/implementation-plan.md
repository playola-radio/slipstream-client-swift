# Terminals Pane Implementation Plan

> **For agentic workers:** this feature spans two repos and four PRs. Drive it with the
> `orchestrate-feature` skill: one fresh context per PR, in the order below. Inside a PR, use
> superpowers:subagent-driven-development or superpowers:executing-plans task by task. Steps
> use checkbox (`- [ ]`) syntax for tracking. Before writing Swift, invoke every `pfw-*` skill
> the repo's `CLAUDE.md` lists for the files you touch (`pfw-observable-models`,
> `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`, `pfw-identified-collections`,
> `pfw-modern-swiftui`, `pfw-issue-reporting`, `pfw-sharing`); subagents too.

**Goal:** A right-hand Terminals pane in the Slipstream window with a Setup tab that runs New
Workspace live and any number of login-shell tabs per workspace, each saving its own history.

**Architecture:** SwiftTerm draws the terminals; the app owns each pty itself (SwiftTerm's
`forkpty` helper, read and reaped like `AgentProcess`) behind a `TerminalRuntimeClient`
dependency. An app-lifetime `TerminalPageModel` owns one `TerminalTabModel` per tab, persisted
in one `@Shared(.terminalState)` file plus one log per tab. The daemon CLI prints the workspace
path before running setup so the window can switch early.

**Tech Stack:** Swift 6 (strict concurrency, warnings as errors), SwiftUI + AppKit, SwiftTerm
1.19.0, swift-dependencies, swift-sharing, swift-identified-collections, Swift Testing; daemon
in TypeScript on Node's test runner.

**Spec:** [spec.md](./spec.md). Contracts: [screens.md](./screens.md),
[models.md](./models.md), [endpoints.md](./endpoints.md). Implement those files as written; this
plan points at them and doesn't restate them.

## Base commits

| Repo | Path | Base |
|---|---|---|
| Client `playola-radio/slipstream-client-swift` | this repo | `develop` @ `fad72167eb0e5431489c71187d90fcffe343feae` |
| Daemon `playola-radio/slipstream` | `~/playola/slipstream` | `develop` @ `7374d6d2641c7b005bff692f94911d9f937c02b8` (the spec surveyed `feffc30`; `src/workspace.ts` `runWorkspaceCreate` is unchanged between them) |

Every PR targets `develop`. The design folder is `design/features/terminals/` in the client
repo; the daemon session reads it from there.

## PR graph

| PR | Repo | Title | Depends on |
|---|---|---|---|
| 1 | daemon | `feature: show the new workspace's folder before its setup script runs` | none |
| 2 | client | `chore: add the terminal engine for the coming terminals pane` | none |
| 3 | client | `feature: add a terminals pane with shell tabs for each workspace` | 2 |
| 4 | client | `feature: run New Workspace in a Setup tab you can watch` | 3 (and 1 released for the early switch; with an older CLI it still works and switches when setup ends) |

PR 1 and PR 2 can run in parallel.

## Global Constraints

- SwiftTerm `exactVersion: 1.19.0` in `project.yml`, product `SwiftTerm`, linked to the app
  only. The test target links only what it already links (`DependenciesTestSupport`,
  `CustomDump`).
- `SlipstreamCore` gets only pure code (no SwiftTerm, no AppKit, no Observation).
- Models are `@MainActor @Observable final class …: ViewModel` with MARK sections in the repo
  order. Views hold zero logic; every string, icon choice and show/hide flag is a model
  property.
- Every side effect is a struct-of-closures `Sendable` client with `liveValue` and an
  `unimplemented` `testValue`. Model tests never open a pty, touch the disk or use real time;
  only the integration suites in Tasks 2.4 and 2.5 do, in disposable temp folders.
- Never point anything at the real `~/.slipstream`; never print or persist the daemon token.
- Pane width `440`pt. Window minimum width `1000` (or the demo width) plus `440` while the pane
  shows, never more than the screen's visible width.
- History cap: compact when a log reaches 5,000 lines or 4 MiB (4,194,304 bytes), down to at
  most the last 4,000 lines and 3 MiB (3,145,728 bytes).
- Path reader: a line longer than 4,096 bytes is discarded up to its next line end.
- Strings are exactly those in [screens.md](./screens.md) ("Strings, all from the approved
  frames").
- Commits: no `Co-Authored-By` or other co-sign trailer. Never `--no-verify`.

## Review Focus

1. **A fast-exiting command loses its last line.** A command that prints a lot and its path
   line, then exits, exits before the reader drains; the user expects the path to be seen.
   Pinned by `immediateExitKeepsOutput` (Task 2.5) and `oldCliFinalLineMovesSetupTab` (Task 4.2).
2. **The user switches workspace while setup is still fetching.** They expect to stay where
   they went, with the Setup tab still moving to its new workspace. Pinned by
   `newWorkspaceDoesNotSwitchAfterUserPickedAnother` (Task 4.3).
3. **An interactive shell ignores SIGTERM** (zsh does), so a stop that only sends SIGTERM hangs
   quit and archive. The user expects quit to finish within a few seconds. Pinned by
   `stopEndsAShellThatIgnoresHangup` (Task 2.5).
4. **Quit or archive while Setup is running** must show "Setup was interrupted", never
   "Setup failed — exit 129". Pinned by `archiveMarksRunningSetupInterrupted` and
   `quitMarksRunningSetupInterrupted` (Task 4.2).
5. **A log full of a newline-free flood** (`yes | tr -d '\n'`) must stay under 3 MiB after
   compaction and replay its tail. Pinned by `oversizedLineKeepsItsEnd` (Task 2.2).

## Acceptance matrix

The gates from the Phase 5 review (R-31). Each PR's final task checks its rows.

| Area | Gate | PR |
|---|---|---|
| Workspace transition | Early line moves the Setup tab by id; switch only if the user didn't pick another workspace; orphan Setup shows in every strip; one folderless Setup at a time | 4 |
| Legacy CLI | Only the final line: the tab moves and the window switches when setup ends | 4 |
| Runtime | Real pty: exit 0, exit 1, a signal, immediate exit, launch failure, idle close, foreground close, bounded stop | 2 |
| Archive | Stops terminals before the command; success deletes records, logs and selection; failure restores with fresh shells; running Setup becomes interrupted | 3, 4 |
| Persistence | Record saved before launch or log write; log deleted before the record is removed; a write error stops saving for that tab only | 2, 3 |
| Bounds/replay | Line and byte caps; temp file + replace; replay leaves the alternate screen and resets modes without clearing scrollback | 2, 3 |
| UI | First-ever workspace; New Workspace with the pane hidden; dead shell note; missing folder; close confirmation that survives the Setup move; small-screen width cap | 3, 4 |
| Regression | ChangeStreamPage, ChatPage, WorkspaceClient and AgentEnvironmentClient suites pass; daemon `npm test`, `npm run test:os`, `npm run typecheck` pass | all |

## Commands

- Core: `swift test`
- App: `xcodegen generate && xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS'`
  (one suite: add `-only-testing:SlipstreamViewerTests/<SuiteName>`)
- Daemon: `npm test`, `npm run test:os`, `npm run typecheck`

---

## PR 1 — Daemon: print the path before setup

### Task 1.1: Early `workspace_path:` line

**Files:**
- Modify: `src/workspace.ts` (`runWorkspaceCreate`, the block after `realpath`)
- Test: `src/workspace.test.ts`
- Modify: `README.md` ("Workspaces without Conductor", the sentence "Its last line is
  `workspace_path: <folder>`…")

**Interfaces:** Produces the CLI output in [endpoints.md](./endpoints.md). No code consumer in
this repo.

- [ ] **Step 1: Write the failing tests.** In `fake()`, push `out` lines into `calls` as well
  (`out: (line) => { out.push(line); calls.push(`out ${line}`); }`) so order across output and
  scripts is one log. Tests:

```ts
it('prints the path after recording and before the setup script', async () => {
  const f = fake({ git: createGit() });
  assert.equal(await runWorkspaceCreate(ROOT, f.deps), 0);
  const order = f.calls.filter((c) => c.startsWith('out ') || c.startsWith('record ') || c.startsWith('run '));
  assert.deepEqual(order.slice(-6).map((c) => c.split(' @')[0]), [
    `record ${WS}`, 'out ', `out workspace_path: ${WS}`, 'run make setup', 'out ', `out workspace_path: ${WS}`,
  ]);
});

it('prints both path lines when recording fails', async () => {
  const f = fake({ git: createGit(), record: 1 });
  assert.equal(await runWorkspaceCreate(ROOT, f.deps), 1);
  assert.equal(f.out.filter((l) => l === `workspace_path: ${WS}`).length, 2);
});
```

- [ ] **Step 2:** `npm test` — the new tests FAIL (one path line).
- [ ] **Step 3:** In `runWorkspaceCreate`, after `const recorded = …` and before
  `runRepoScript('setup', …)`, add `deps.out(''); deps.out(`workspace_path: ${path}`);`.
- [ ] **Step 4:** `npm test && npm run test:os && npm run typecheck` — PASS, including the
  existing last-two-lines assertion (`src/workspace.test.ts:83`) and the OS test's last-line
  assertion.
- [ ] **Step 5:** README: change the sentence to say the path is printed once before setup
  runs and again as the last line, whenever the folder was made.
- [ ] **Step 6: Commit** `feat: print the workspace path before running setup`.

---

## PR 2 — Client: terminal engine (no UI)

### Task 2.1: `WorkspacePathStreamParser` and `ManagedWorkspacePath` (Core)

**Files:**
- Create: `Sources/SlipstreamCore/WorkspacePathStreamParser.swift`
- Test: `Tests/SlipstreamCoreTests/WorkspacePathStreamParserTests.swift`
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`
  (`isArchiveWorkspaceShown` calls `ManagedWorkspacePath.contains` instead of its own
  two-level check)

**Interfaces — Produces:**
```swift
public struct WorkspacePathStreamParser: Sendable {
  public static let prefix = "workspace_path: "
  public init()
  public mutating func consume(_ bytes: some Collection<UInt8>) -> [String]  // paths, in order
}
public enum ManagedWorkspacePath {
  /// `<root>/<repo>/<name>`: exactly two levels below the root. Both are already normalized.
  public static func contains(_ folder: String, root: String) -> Bool
}
```
The CLI writes its path lines with `console.log` after an empty line
(`src/workspace.ts` `runWorkspaceCreate`), so they are plain text ending in a newline. The
parser only splits on LF; it doesn't parse escape codes (simplicity gate S-2).

- [ ] **Step 1: Write the failing tests** (`@Test` each, `expectNoDifference` on the result):
  - `plainLine`: `"workspace_path: /a/b\n"` → `["/a/b"]`
  - `splitAcrossReads`: feed `"works"`, `"pace_path: /a"`, `"/b\r\n"` → `[]`, `[]`, `["/a/b"]`
  - `splitUTF8`: a path with `é` split between its two bytes → whole path
  - `notAtLineStart`: `"x workspace_path: /a\n"` → `[]`
  - `overlongLineDiscarded`: 5,000 `x` bytes then `"workspace_path: /a\n"` on the same line → `[]`; the next line `"workspace_path: /b\n"` → `["/b"]`
  - `containsManagedWorkspace`: root `/h/slipstream/workspaces`: `…/repo/workspace-3` true; `…/repo/workspace-3/x` false; `…/workspace-3` (one level) false; `/elsewhere/repo/workspace-3` false.
- [ ] **Step 2:** `swift test --filter WorkspacePathStreamParserTests` — FAIL (no type).
- [ ] **Step 3: Implement.** A byte line buffer split on LF, a trailing CR dropped (the pty
  turns `\n` into `\r\n`), decoded as UTF-8 at line end. A fixed private limit of 4,096 bytes:
  a longer line is discarded up to its next LF. `contains` is the path-component check
  `isArchiveWorkspaceShown` has today, moved here; switch that property to it.
- [ ] **Step 4:** `swift test`, then `ChangeStreamPageTests` (touched-area rule) — PASS.
- [ ] **Step 5: Commit** `chore: read workspace paths out of streamed setup output`.

### Task 2.2: `HistoryCompaction` (Core)

**Files:**
- Create: `Sources/SlipstreamCore/HistoryCompaction.swift`
- Test: `Tests/SlipstreamCoreTests/HistoryCompactionTests.swift`

**Interfaces — Produces:**
```swift
public struct HistoryCompaction: Sendable, Equatable {
  public static let terminal = HistoryCompaction(triggerLines: 5_000, triggerBytes: 4_194_304, keepLines: 4_000, keepBytes: 3_145_728)
  public init(triggerLines: Int, triggerBytes: Int, keepLines: Int, keepBytes: Int)
  public func needsCompaction(lines: Int, bytes: Int) -> Bool
  public func compacted(_ log: [UInt8]) -> [UInt8]
  public static func lineCount(_ bytes: some Collection<UInt8>) -> Int   // counts LF
}
```

- [ ] **Step 1: Write the failing tests** (use a small instance, e.g. trigger 5/50, keep 4/30):
  - `belowTriggerNeedsNothing`, `lineTriggerFires`, `byteTriggerFires`
  - `keepsLastLines`: 6 lines → the last 4, starting at a line boundary
  - `keepsByteBudgetAtLineBoundary`: lines of 10 bytes → ≤ 30 bytes, starts after an LF
  - `oversizedLineKeepsItsEnd`: one 100-byte line with no LF → its last 30 bytes
- [ ] **Step 2:** `swift test --filter HistoryCompactionTests` — FAIL.
- [ ] **Step 3: Implement** scanning back from the end: take the last `keepLines` lines, then
  drop leading lines until within `keepBytes`; if a single line still exceeds it, keep its last
  `keepBytes` bytes.
- [ ] **Step 4:** `swift test` — PASS.
- [ ] **Step 5: Commit** `chore: bound terminal history by lines and bytes`.

### Task 2.3: SwiftTerm package, terminal records, design tokens

**Files:**
- Modify: `project.yml` (package `SwiftTerm`, url `https://github.com/migueldeicaza/SwiftTerm`,
  `exactVersion: 1.19.0`; app dependency `package: SwiftTerm`)
- Create: `SlipstreamViewer/Models/TerminalState.swift` (`TerminalState`, `TerminalTabRecord`,
  `SetupStatus`, the `SharedKey` extension `.terminalState` → `terminals.json`, beside
  `chatTabs.json`, `default: TerminalState()`)
- Modify: `SlipstreamViewer/DesignTokens.swift` (`DesignTokens.TerminalPane`: `width = 440`,
  plus the terminal font, colours and spacing read from the approved frames' tokens in
  `exports/design-tokens.json` and the per-screen JSON)
- Test: `SlipstreamViewerTests/Models/TerminalStateTests.swift`

**Interfaces — Produces:** exactly the types in [models.md](./models.md), plus these helpers
(pure, on `TerminalState`):
```swift
extension TerminalState {
  func tabs(shownIn folder: String?, listed: Set<String>) -> [TerminalTabRecord]
  func nextTerminalNumber(in folder: String) -> Int
  mutating func moveSetup(_ id: TerminalTabRecord.ID, to folder: String)   // sets folder and selects it there
}
```
Selections left pointing at a moved or closed tab aren't pruned; they fall back to the first
tab (simplicity gate S-7).
`tabs(shownIn:listed:)` returns, in order: Setup tabs whose folder is nil or not in `listed`
(orphans), then the folder's own tabs in array order. With `folder == nil` it returns only the
orphans.

- [ ] **Step 1: Write the failing tests:** `codableRoundTrip` (every `Kind` and `SetupStatus`
  case), `orphanSetupShowsFirstInEveryFolder`, `orphanSetupShowsAloneWithNoFolder`,
  `listedSetupShowsOnlyInItsFolder`, `nextNumberIsHighestPlusOne` (tabs 1 and 3 → 4; none →
  1), `moveSetupSetsFolderAndSelectsIt`.
- [ ] **Step 2:** `xcodegen generate`, run `TerminalStateTests` — FAIL.
- [ ] **Step 3: Implement.** Confirm the app builds with `import SwiftTerm` in an empty file
  under warnings-as-errors; if SwiftTerm's sources warn, set the package's warnings off in
  `project.yml` only for that package, not the app.
- [ ] **Step 4:** Run the suite — PASS.
- [ ] **Step 5: Commit** `chore: add SwiftTerm and the saved terminal tabs`.

### Task 2.4: `TerminalHistoryClient`

**Files:**
- Create: `SlipstreamViewer/Dependencies/TerminalHistoryClient.swift`
- Test: `SlipstreamViewerTests/Dependencies/TerminalHistoryClientTests.swift` (live value on a
  temp folder)

**Interfaces — Produces:**
```swift
struct TerminalHistoryClient: Sendable {
  var read: @Sendable (_ tab: UUID) async -> [UInt8]
  var append: @Sendable (_ tab: UUID, _ bytes: [UInt8]) -> Void // enqueues; never blocks the caller
  var flush: @Sendable (_ tab: UUID) async -> Void              // returns once earlier appends are on disk
  var delete: @Sendable (_ tab: UUID) async -> Void             // after pending appends
}
extension TerminalHistoryClient {
  static func live(directory: URL, compaction: HistoryCompaction = .terminal) -> Self
}
```
`liveValue` uses `Application Support/<bundle id>/terminals/`. Live: one serial
`DispatchQueue` and a per-tab state (open `FileHandle`, line and byte counts, `isFailed`), so
`append` order is call order. A tab's first append after launch opens its log and counts the
lines and bytes already in it. Compaction runs only on append, so a log is never more than one
read over the trigger (simplicity gate S-8). Compaction writes `<id>.log.tmp`, replaces with
`FileManager.replaceItemAt`, reopens the handle. A write error marks the tab failed, reports it
once with `reportIssue`, and drops later appends for that tab.

- [ ] **Step 1: Write the failing tests:** `appendThenReadReturnsBytesInOrder` (100 appends),
  `compactsWhenOverTrigger` (small `HistoryCompaction`; after flush the file holds only the
  kept tail and later appends land after it), `compactsAnExistingLogOnFirstAppend` (a fresh
  client over a log already at the trigger compacts on its first append),
  `deleteAfterPendingAppendsLeavesNoFile`, `appendAfterDeleteDoesNotRecreate`,
  `writeErrorStopsSavingForThatTabOnly` (make one tab's log path a directory; the other tab
  still saves), `noTempFileLeftAfterCompaction`.
- [ ] **Step 2:** Run the suite — FAIL.
- [ ] **Step 3: Implement** as above.
- [ ] **Step 4:** Run the suite — PASS.
- [ ] **Step 5: Commit** `chore: save each terminal's output to its own capped log`.

### Task 2.5: `TerminalRuntimeClient` (owned pty)

**Files:**
- Create: `Sources/SlipstreamCore/TerminalExit.swift`; test
  `Tests/SlipstreamCoreTests/TerminalExitTests.swift`
- Create: `SlipstreamViewer/Dependencies/TerminalRuntimeClient.swift` (client, types, the
  pure `terminalEnvironment` builder)
- Create: `SlipstreamViewer/Dependencies/TerminalProcess.swift` (private live process)
- Test: `SlipstreamViewerTests/Dependencies/TerminalRuntimeClientTests.swift` (pure
  environment builder) and `SlipstreamViewerTests/Dependencies/TerminalProcessIntegrationTests.swift`
  (real pty, `.serialized`, temp folders, `/bin/sh` only)

**Interfaces — Produces:**
```swift
public enum TerminalExit: Equatable, Sendable {
  case exited(Int32)
  case signalled(Int32)
  public init(waitStatus: Int32)
  public var noteText: String   // "Process exited (exit 1)" / "Process exited (signal SIGTERM)"
}

struct TerminalSize: Equatable, Sendable { var columns: Int; var rows: Int }
struct TerminalEnvironment: Equatable, Sendable { var variables: [String: String]; var shell: String; var slipstream: String? }
struct TerminalLaunch: Equatable, Sendable { var executable: String; var arguments: [String]; var environment: [String: String]; var directory: String; var size: TerminalSize }
enum TerminalEvent: Equatable, Sendable { case output([UInt8]); case finished(TerminalExit) }
struct TerminalLaunchError: Error, Equatable { var text: String }

struct TerminalProcessHandle: Sendable {
  var events: AsyncStream<TerminalEvent>
  var write: @Sendable ([UInt8]) -> Void
  var resize: @Sendable (TerminalSize) -> Void
  var isBusy: @Sendable () -> Bool
  var stop: @Sendable () async -> Void
}

struct TerminalRuntimeClient: Sendable {
  var environment: @Sendable () async throws -> TerminalEnvironment
  var folderExists: @Sendable (String) -> Bool
  var launch: @Sendable (TerminalLaunch) throws -> TerminalProcessHandle
}
extension TerminalRuntimeClient {
  static func terminalEnvironment(login: [String: String], passwordDatabaseShell: String?) throws -> TerminalEnvironment
}
```
`noteText` names signals from a fixed table (`SIGHUP`, `SIGINT`, `SIGQUIT`, `SIGABRT`,
`SIGKILL`, `SIGSEGV`, `SIGPIPE`, `SIGTERM`); any other number shows as `signal <N>`.

Live behaviour, pinned:
- `environment`: `AgentEnvironmentClient.loginEnvironment()` → `terminalEnvironment(…)`.
  Throws `TerminalLaunchError` when `PATH` is missing (R-23). Sets `TERM=xterm-256color`,
  `COLORTERM=truecolor`, `LANG=en_US.UTF-8` when no `LANG`/`LC_ALL`/`LC_CTYPE` is set; `shell`
  from `AgentEnvironmentClient.loginShell(…)`; `slipstream` from
  `WorkspaceClient.slipstreamExecutable(in:)`. `launch` sets `PWD` to the directory.
- `launch`: `PseudoTerminalHelpers.fork(andExec:args:env:currentDirectory:desiredWindowSize:)`.
  `nil` throws `TerminalLaunchError`. The shell is the session leader, so its pgid is its pid.
  A reader on the master fd yields `.output`; a `waitpid` thread records the exit.
  `.finished(TerminalExit(waitStatus:))` is yielded once, after both the exit and master
  EOF/EIO, or 1s after exit if EOF never comes (R-20); then the stream finishes.
- `isBusy`: `tcgetpgrp(master) != pid` (and false once exited).
- `stop`: idempotent and bounded. `SIGHUP` + `SIGCONT` to the foreground group (if positive and
  not the shell's) and to `-pid`; after 2s, `SIGKILL` to both; close the master; await the
  reap. Late escalations after the process is gone do nothing (R-2, R-6).

- [ ] **Step 1: Write the failing tests.**
  - Core `TerminalExitTests`: `0` → `.exited(0)`; `256` → `.exited(1)`; `9` → `.signalled(9)`;
    `15` → `.signalled(15)`; `noteText` for `.exited(1)` is `"Process exited (exit 1)"`, for
    `.signalled(15)` is `"Process exited (signal SIGTERM)"`.
  - `TerminalRuntimeClientTests`: `environmentNeedsPath` (throws), `environmentSetsTerminalVariables`,
    `environmentKeepsExistingLang`, `environmentFindsSlipstreamOnPath` (temp folder with an
    executable `slipstream`).
  - Integration (each with a 10s timeout guard via `withTimeout`-style task group; real time is
    allowed only here): `exitZero` (`/bin/sh -c 'exit 0'` → `.finished(.exited(0))`),
    `exitOne`, `signalled` (`kill -TERM $$` → `.signalled(15)`), `immediateExitKeepsOutput`
    (`printf 'a%.0s' $(seq 1 20000); printf "\nworkspace_path: /x\n"` → all of it, ending
    with the path line, before `.finished`), `launchFailureThrows` (missing executable or directory),
    `idleShellIsNotBusy` (`/bin/sh -i` at its prompt), `foregroundProgramIsBusy` (write
    `sleep 30\n`; `isBusy` true within 2s), `stopEndsAShellThatIgnoresHangup`
    (`/bin/sh -c "trap '' HUP TERM; sleep 100"`; `stop()` returns within 4s and
    `kill(pid, 0)` fails with `ESRCH`), `stopTwiceIsSafe`, `writeReachesTheChild`
    (`cat` echoes input), `resizeIsSeen` (`stty size` after resize prints `30 100`).
- [ ] **Step 2:** `swift test` and the app suites — FAIL.
- [ ] **Step 3: Implement.** Model the process on `AgentProcess`
  (`AgentProcessClient.swift`): its `terminationGrace`/`outputGrace` shape, a lock-protected
  state, reaping on a background thread. Reuse its `OneShot` by making that class internal
  (Modify `AgentProcessClient.swift`); don't copy it. `testValue` is `unimplemented` for each
  closure.
- [ ] **Step 4:** Run all three suites — PASS. Then the touched-area regression: run
  `AgentEnvironmentClientTests`, `WorkspaceClientTests`, `ProcessIntegrationTests`.
- [ ] **Step 5: Commit** `chore: run terminals in a pty the app owns, with a bounded stop`.

### Task 2.6: `TerminalSurface` and the replay reset

**Files:**
- Create: `SlipstreamViewer/Views/Pages/TerminalPage/TerminalSurface.swift`
- Test: `SlipstreamViewerTests/Views/Pages/TerminalPage/TerminalSurfaceTests.swift`

**Interfaces — Produces:**
```swift
@MainActor final class TerminalSurface {
  static let replayReset: [UInt8]   // see below
  let view: TerminalView            // a private TerminalView subclass reporting focus
  var onInput: @MainActor ([UInt8]) -> Void
  var onResize: @MainActor (TerminalSize) -> Void
  var onFocusChange: @MainActor (Bool) -> Void
  var size: TerminalSize { get }
  init()
  func feed(_ bytes: [UInt8])
  func focus()
}
```
`replayReset` is exactly
`"\u{18}\u{1b}[?1049l\u{1b}[!p\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[0m\r\n"`
as UTF-8 (R-16: CAN aborts a half-sent sequence; then main screen, soft reset, mouse and
bracketed-paste off, cursor on, attributes off). The surface is SwiftTerm's
`TerminalViewDelegate` and only forwards: `send` → `onInput`, `sizeChanged` → `onResize`. It
leaves `requestOpenLink` to SwiftTerm's default (⌘-click opens URLs). Scrollback is 4,000
lines, matching the history cap (SwiftTerm's default is 500). Font and colours come from
`DesignTokens`.

- [ ] **Step 1: Write the failing tests** (headless `Terminal(delegate:options:)` from
  SwiftTerm, fed the same bytes the surface would get):
  `replayResetLeavesAlternateScreen` (`"keep\r\n\u{1b}[?1049hvim"` + `replayReset` →
  `isCurrentBufferAlternate == false` and the normal buffer still contains `keep`),
  `replayResetTurnsOffMouseAndPaste` (`\u{1b}[?1003h\u{1b}[?2004h` first → `mouseMode == .off`,
  `bracketedPasteMode == false`), `replayResetAbortsHalfSequence` (`"\u{1b}[3"` + reset +
  `"x"` → `x` printed), `scrollbackHoldsTheHistoryCap` (feed 4,100 lines → the first
  line still in the buffer is line 101 or earlier).
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run — PASS.
- [ ] **Step 5: Commit** `chore: wrap SwiftTerm's view and reset it after a replay`.

### Task 2.7: PR 2 gate

- [ ] `swift test` and the full app test run pass. Acceptance rows Runtime, Persistence
  (writer parts), Bounds/replay (Core parts) are green.
- [ ] Open the PR per the repo's flow (Codex creates it; base `develop`).

---

## PR 3 — Client: the pane, terminal tabs, archive and quit

### Task 3.1: `TerminalTabModel` for terminal tabs

**Files:**
- Create: `SlipstreamViewer/Views/Pages/TerminalPage/TerminalTabModel.swift`
- Create: `SlipstreamViewerTests/Support/TerminalFake.swift` (a fake runtime: records
  launches, hands back a handle whose events the test sends, a settable `isBusy`, counts
  `stop` calls; and an in-memory history recording calls in order)
- Test: `SlipstreamViewerTests/Views/Pages/TerminalPage/TerminalTabModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2.3–2.6.
- Produces:
```swift
@MainActor @Observable final class TerminalTabModel: ViewModel, Identifiable {
  let id: TerminalTabRecord.ID
  let surface: TerminalSurface
  init(id: TerminalTabRecord.ID)
  var title: String                  // "Setup" / "Terminal N" from the record
  var missingFolderPath: String?
  var isFolderMissing: Bool { get }  // missingFolderPath != nil
  var isCloseConfirmationVisible: Bool
  var closeConfirmationText: String  // "Closing stops what's running in <title>."
  var isBusy: Bool { get }           // asks the handle; a running Setup is busy
  func start() async                 // replay and divider if the log has bytes, then launch
  func stop() async                  // bounded; awaits history flush
  func closeRequested() -> Bool      // true = close now; false = confirmation shown
  func keepTapped()
}
```
`start`: reads the record from `@Shared(.terminalState)`; if `!folderExists(folder)`, sets
`missingFolderPath` and starts nothing. Otherwise: feed `history.read(id)` then
`replayReset`; when there was history, write the divider "Restored — earlier processes ended"
(dim, on its own line). Then `environment()` and `launch(shell, ["-l"], …, directory: folder,
size: surface.size)`. `surface.onInput` sends to `handle?.write`, so typed input and the
terminal's query replies during replay are dropped because there is no handle yet (simplicity
gate S-5). Each `.output`: `history.append` then `surface.feed`. `.finished(exit)`: write
`exit.noteText`. A launch or environment error writes its text. "Write" means append to the
history and feed the surface, so notes replay later (R-21). If the process finishes while
the confirmation is showing, the confirmation hides (R-25).

- [ ] **Step 1: Write the failing tests** (`.dependencies` with the fakes,
  `.mainSerialExecutor`): `startLaunchesLoginShellInFolder` (launch has
  `arguments == ["-l"]`, `directory`, `PWD`), `outputIsSaved` (each `.output` reaches the
  fake history), `replayThenDividerThenShell`
  (history first; divider text in the buffer; launch after; input sent before launch is dropped),
  `noHistoryMeansNoDivider`, `exitWritesNote` (`.finished(.exited(1))` → buffer and history
  end with "Process exited (exit 1)"; no relaunch), `launchErrorWritesItsText`,
  `missingFolderStartsNothing`, `idleCloseClosesAtOnce`, `busyCloseShowsConfirmation`,
  `keepHidesConfirmation`, `processEndingHidesConfirmation`, `stopIsForwarded`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Implement.** The run loop is one `Task` owned by the tab, cancelled in `stop()`.
- [ ] **Step 4:** Run — PASS.
- [ ] **Step 5: Commit** `feature: run a login shell in a terminal tab`.

### Task 3.2: `TerminalPageModel`

**Files:**
- Create: `SlipstreamViewer/Views/Pages/TerminalPage/TerminalPageModel.swift`
- Test: `SlipstreamViewerTests/Views/Pages/TerminalPage/TerminalPageTests.swift`

**Interfaces — Produces:**
```swift
@MainActor @Observable final class TerminalPageModel: ViewModel {
  init()
  // Properties
  var folder: String? { get }
  var shownTabs: [TerminalTabModel] { get }      // strip order, from TerminalState.tabs(shownIn:listed:)
  var selectedTab: TerminalTabModel? { get }
  var hasKeyboardFocus: Bool { get }
  // Display text
  var emptyTitle: String { get }                 // "Choose a workspace"
  var emptyText: String { get }                  // "Its terminals appear here."
  var isEmptyStateVisible: Bool { get }          // no folder and no orphan Setup
  // Actions (called by ChangeStreamPageModel and the view)
  func launched() async                          // launch cleanup, once
  func workspaceChanged(folder: String?) async
  func workspacesListed(_ folders: Set<String>)
  func newTabTapped() async
  func tabSelected(_ id: TerminalTabRecord.ID)
  func closeTabTapped(_ id: TerminalTabRecord.ID) async
  func closeConfirmed(_ id: TerminalTabRecord.ID) async
  func closeShortcutPressed() async
  func terminalFocusChanged(_ id: TerminalTabRecord.ID, isFocused: Bool)
  func stopTabs(in folder: String) async
  func restoreTabs(in folder: String) async
  func forgetTabs(in folder: String) async
  func quitConfirmed() async
}
```
Rules, pinned:
- Tab models are created and started the first time their workspace is shown. Tabs in other
  workspaces keep running.
- `workspaceChanged`: shows the folder; when the folder has no terminal tab and isn't being
  archived or quit, adds **Terminal 1** (scope 4). Selection: the folder's `selectedTabIDs`
  value if it's in `shownTabs`, else the first tab. Clicking a tab focuses its surface.
- `newTabTapped`: record `.terminal(number: nextTerminalNumber)`, selected; `try await
  $state.save()` before `start` (R-7).
- Close: busy → the tab's confirmation; a tab that isn't selected is selected first (scope 8).
  Closing: `tab.stop()`, `await history.delete(id)`, `state.tabs.remove(id:)`, then
  `await $state.save()` (spec S-1: a log never outlives its record, so launch has nothing to
  clean up).
  Closing the last terminal tab of a shown folder adds a fresh Terminal 1.
- `closeShortcutPressed`: closes the selected tab, with the busy check.
- `launched`: marks every `.setup(.running)` as `.interrupted`, then saves.
- Archive: `stopTabs(in:)` stops the folder's tabs and blocks Terminal 1 creation for it;
  `restoreTabs(in:)` starts its terminal tabs again with fresh shells; `forgetTabs(in:)`
  deletes their logs, then removes its records and selection and saves.
- `quitConfirmed`: sets quitting (no new tab starts), stops every live tab concurrently,
  awaits the history flush and the state save.

- [ ] **Step 1: Write the failing tests:** `firstShowAddsTerminalOne`,
  `plusUsesHighestNumberPlusOne`, `selectionIsRememberedPerWorkspace`,
  `danglingSelectionFallsBackToFirstTab`, `recordIsSavedBeforeLaunch` (fake history and launch
  see the record already in `terminals.json`'s in-memory store),
  `closeDeletesLogThenRecord`, `closingLastTerminalOpensTerminalOne`,
  `closingUnselectedBusyTabSelectsItAndAsks`, `closeShortcutClosesSelectedTab`,
  `tabsInOtherWorkspacesKeepRunning` (switching folders calls no `stop`),
  `noWorkspaceShowsEmptyState`, `launchMarksRunningSetupInterrupted`,
  `restoredTabReplaysThenStartsShell`, `stopTabsStopsOnlyThatFolder`,
  `noTerminalOneDuringArchive`, `restoreTabsStartsFreshShells`,
  `forgetTabsDeletesRecordsLogsAndSelection`, `quitStopsAllAndBlocksNewTabs`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Implement** as above.
- [ ] **Step 4:** Run — PASS.
- [ ] **Step 5: Commit** `feature: keep terminal tabs per workspace and remember the last one`.

### Task 3.3: Pane views

**Files:**
- Create: `SlipstreamViewer/Views/Pages/TerminalPage/TerminalPageView.swift` (tab strip, + ,
  Hide terminals, close box, empty and folder-missing states)
- Create: `SlipstreamViewer/Views/Pages/TerminalPage/TerminalHostView.swift`
  (`NSViewRepresentable` that only moves `tab.surface.view` into its container; never creates,
  starts or stops one)
- Modify: `SlipstreamViewer/Views/Pages/TerminalPage/TerminalPageModel.swift` (any display
  property the views need: tab status icon, accessibility labels)

**Interfaces:** Consumes Tasks 3.1–3.2. Visuals match the approved frames `QPmYb`, `M7WFX`,
`Vuydd`, `itKKe`, `D8Kx1`, `mouwC` ([screens.md](./screens.md)); values only from
`DesignTokens`.

- [ ] **Step 1:** Add model tests for each display property that depends on state
  (`tabStatusIcon` per tab kind and status), FAIL, implement, PASS. Fixed strings
  ("Hide terminals", "This folder no longer exists", "No shell was started.") get no test of
  their own; Step 2's comparison with the frames covers them.
- [ ] **Step 2:** Build the views. Check by running the app against a disposable daemon
  (`SLIPSTREAM_STORE`, `npm run qa:daemon`) and comparing with the PNGs.
- [ ] **Step 3: Commit** `feature: draw the terminals pane`.

### Task 3.4: Window integration, archive and ⌘W

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`
  (`init(chat:terminals:isFunctionDemoVisible:)`; `chatWorkspaceMayHaveChanged` also calls
  `terminals.workspaceChanged`; `archiveConfirmed` stops, restores or forgets terminals beside
  chats; `loadSessions` ends with `terminals.workspacesListed(<listed folders>)`; new
  `isTerminalPaneHidden`, `hideTerminalsTapped()`, `showTerminalsTapped()`,
  `showTerminalsText == "Show terminals"`, `func minimumWindowWidth(visibleScreenWidth:) -> CGFloat`,
  `closeShortcutPressed() async`)
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift` (third
  column `TerminalPageView` at `DesignTokens.TerminalPane.width` unless hidden; Show terminals
  in the chat strip; `minWidth` from the model with the screen's visible width; the hidden ⌘W
  button calls `model.closeShortcutPressed()`)
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`

`closeShortcutPressed`: `terminals.hasKeyboardFocus ? terminals.closeShortcutPressed() :
chat.closeShortcutPressed()`. `minimumWindowWidth`: `base + (isTerminalPaneHidden ? 0 : 440)`,
then `min(that, visibleScreenWidth)` but never below `base`'s own value when the screen is
wider (base is 1000, or the demo width).

- [ ] **Step 1: Write the failing tests:** `terminalsFollowTheSelectedWorkspace`,
  `archiveStopsTerminalsBeforeTheCommand` (fake archive records that `stopTabs` already ran),
  `failedArchiveRestoresTerminals`, `successfulArchiveForgetsTerminals`,
  `hideAndShowTerminals`, `minimumWidthWithPane` (1440), `minimumWidthHidden` (1000),
  `minimumWidthCappedBySmallScreen` (screen 1280 → 1280),
  `commandWClosesTerminalWhenFocused`, `commandWClosesChatOtherwise`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Implement.** Existing tests construct `ChangeStreamPageModel(chat:)`; give
  `terminals` a default only if the existing call sites would otherwise all change, and
  prefer updating them.
- [ ] **Step 4:** Run `ChangeStreamPageTests`, `ChatPageTests` in full (touched-area rule) —
  PASS. Check in the app that the window grows when the pane shows.
- [ ] **Step 5: Commit** `feature: add the terminals pane to the workspace window`.

### Task 3.5: App wiring and quit

**Files:**
- Modify: `SlipstreamViewer/App/SlipstreamViewerApp.swift` (`@State private var terminals =
  TerminalPageModel()` beside `chat`; pass it to `ChangeStreamPageModel`; `.task { await
  terminals.launched() }`; `QuitFlowHandoff` hands it to the delegate)
- Modify: `SlipstreamViewer/App/AppDelegate.swift` (`var terminals: TerminalPageModel?`; the
  `Task` awaits `chat.quitConfirmed()` and `terminals.quitConfirmed()` concurrently before
  replying. The quit alert still asks only about chats.)

- [ ] **Step 1:** Run the app against a disposable daemon: open two terminals, run `sleep 100`
  in one, quit. The app quits within about 3s and no `sleep` is left (`pgrep -f "sleep 100"`
  is empty). Relaunch: both tabs replay, show the divider, and get fresh prompts.
- [ ] **Step 2: Commit** `feature: stop terminals when the app quits`.

### Task 3.6: PR 3 gate

- [ ] Full `swift test` and app test run pass. Acceptance rows Archive (terminal parts),
  Persistence, Bounds/replay, UI (dead shell, missing folder, small screen) are checked.
- [ ] Run the Codex review / challenge / Excess Audit per `~/.claude/CLAUDE.md`, then open
  the PR (Codex creates it; base `develop`).

---

## PR 4 — Client: New Workspace in a Setup tab

### Task 4.1: Remove the headless create

**Files:**
- Modify: `SlipstreamViewer/Dependencies/WorkspaceClient.swift` (delete `create` and any
  helper only it uses. Archive output has no `workspace_path:` line, so also delete
  `WorkspaceOutcome` and `pathPrefix`: `archive` returns the failure text as `String?`, and
  `outcome(output:status:)` becomes `failureText(output:status:) -> String?`, keeping the
  12-line tail and the "slipstream exited with status N." fallback without the path-line
  filter. `managedRoot`, `chooseRepository`, `slipstreamExecutable`, `slipstreamNotFoundText`
  stay)
- Modify: `SlipstreamViewerTests/Dependencies/WorkspaceClientTests.swift` (drop create-only
  tests and the path assertions)
- Modify: `ChangeStreamPageModel.swift` and `ChangeStreamPageTests.swift` (archive callers and
  fakes use the `String?` result)

- [ ] **Step 1:** Delete; the build fails only at `newWorkspaceTapped` (fixed in Task 4.3) —
  do this task and Task 4.3 in one commit if the build must stay green.
- [ ] **Step 2:** `WorkspaceClientTests` and the archive tests in `ChangeStreamPageTests` pass.

### Task 4.2: Setup tabs

**Files:**
- Modify: `TerminalTabModel.swift`, `TerminalPageModel.swift`
- Test: `TerminalTabModelTests.swift`, `TerminalPageTests.swift`

**Interfaces — Produces** (on `TerminalPageModel`):
```swift
/// Opens and selects a Setup tab running `slipstream workspace create <repository> --store <store>`.
/// Returns the workspace folder once the first valid `workspace_path:` line is seen, or nil
/// if the command ended (or couldn't start) without one. The tab keeps running after it returns.
func newWorkspaceStarted(repository: URL, store: String, managedRoot: URL) async -> String?
```
and on `TerminalTabModel`: `footerText: String?`, `footerStyle` (`.progress` / `.success` /
`.failure`, from the frames), `statusIcon`.

Rules, pinned:
- A folderless Setup tab already present is closed (record and log) first (scope 3).
- Record `.setup(.running)`, `folder: nil`, saved before launch, selected in the current
  folder.
- Launch: `environment.slipstream` nil → write `WorkspaceClient.slipstreamNotFoundText`,
  `failed(exitStatus: nil)`, return nil. Environment error → write its text, same status.
  Otherwise `launch(slipstream, ["workspace", "create", repository.path, "--store", store],
  directory: repository.path)`.
- Live output only goes through `WorkspacePathStreamParser`. Each path is normalized with
  `ChangeStreamPageModel.normalizedFolder`; the first one that is absolute, where
  `ManagedWorkspacePath.contains(path, root: normalizedFolder(managedRoot.path))` and
  `folderExists(path)` → `state.moveSetup(id, to: path)`, save, return the path. Later paths
  are ignored. Replayed bytes never reach the parser.
- `.finished`: `await history.flush(id)`,
  then the status (R-3): `.exited(0)` → `finished(seconds:)` timed with
  `@Dependency(\.continuousClock)` from launch, whole seconds rounded down; `.exited(n)` →
  `failed(exitStatus: n)`; `.signalled(s)` → `failed(exitStatus: 128 + s)` (Claude's call:
  the shell convention). If no path was returned yet, return nil.
- A tab being stopped by archive or quit is marked `.interrupted` before it's stopped, and its
  `.finished` changes nothing.
- Footer text exactly as [screens.md](./screens.md): "Setting up <last path component>…" or
  "Setting up…", "Setup finished · <N>s", "Setup failed — exit <N>. The workspace was
  created." (folder set), "Setup failed — no workspace was created. Close this tab to
  dismiss." (no folder), "Setup was interrupted".
- A Setup tab is busy while `.running`. Its replay on relaunch runs no command and no parser.

- [ ] **Step 1: Write the failing tests:** `setupLaunchesCreateCommand`,
  `slipstreamMissingWritesInstallHint`, `environmentFailureWritesItsText`,
  `firstValidPathMovesSetupTab`, `invalidPathIsIgnored` (outside the managed root, wrong depth,
  missing folder), `laterPathsAreIgnored`, `oldCliFinalLineMovesSetupTab` (the only path
  arrives just before `.finished`), `finishedAfterFourteenSeconds` (TestClock advance 14s →
  "Setup finished · 14s"), `failureWithFolder`, `failureWithoutFolder`,
  `signalMapsToExitCode`, `statusSavedAfterFlush` (fake history's flush recorded before the
  state change), `secondNewWorkspaceReplacesFolderlessSetup`,
  `movedSetupLeavesOtherWorkspaces` (R-29), `orphanSetupShowsInEveryStrip` (folder not in
  `workspacesListed`), `closeConfirmationSurvivesMove` (R-25),
  `archiveMarksRunningSetupInterrupted`, `quitMarksRunningSetupInterrupted`,
  `replayedSetupRunsNothing`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run — PASS.
- [ ] **Step 5: Commit** `feature: run New Workspace in a Setup tab`.

### Task 4.3: New Workspace flow

**Files:**
- Modify: `ChangeStreamPageModel.swift` (`newWorkspaceTapped`; a `selectionCount` bumped in
  `sessionSelected`; remove the "Couldn't finish creating the workspace" path)
- Test: `ChangeStreamPageTests.swift`

`newWorkspaceTapped`: guard not busy and a repository chosen; `isWorkspaceBusy = true`;
`isTerminalPaneHidden = false` (R-14); remember `selectionCount`; `let folder = await
terminals.newWorkspaceStarted(repository:store: daemon.storeID, managedRoot:)`, passing the
`managedWorkspaceRoot` it already holds, or `await workspace.managedRoot()` once if that hasn't
loaded yet (each call starts a login shell); `isWorkspaceBusy = false`;
if `folder` is non-nil, `await loadSessions(preferring: selectionCount == remembered ? folder :
nil)`. Archive and New Workspace stay exclusive through `isWorkspaceBusy`.

- [ ] **Step 1: Write the failing tests:** `newWorkspaceSwitchesWhenPathArrives`,
  `newWorkspaceDoesNotSwitchAfterUserPickedAnother` (call `sessionSelected` while the fake
  Setup is waiting; afterwards the selected session is the one picked and the Setup record's
  folder is the new path), `newWorkspaceShowsHiddenPane`, `newWorkspaceAvailableAgainAfterMove`
  (busy false while the Setup tab is still `.running`), `failedNewWorkspaceShowsNoAlert`,
  `firstEverWorkspaceShowsSetupInEmptyPane` (no session selected; `terminals.shownTabs` is
  the Setup tab, empty state hidden).
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run `ChangeStreamPageTests`, `ChatPageTests`, `TerminalPageTests`,
  `WorkspaceClientTests` — PASS.
- [ ] **Step 5:** Manual check with a disposable daemon and a throwaway repo whose
  `conductor.json` setup prints ports: the window switches when the folder exists, the setup
  output streams, the footer ends "Setup finished · Ns". Repeat with the setup script exiting 1.
- [ ] **Step 6: Commit** `feature: switch to the new workspace while its setup runs`.

### Task 4.4: PR 4 gate

- [ ] Full test runs pass. Acceptance rows Workspace transition, Legacy CLI, Archive (Setup),
  UI (first workspace, hidden pane, pending close during move) are checked.
- [ ] Codex review / challenge / Excess Audit, then the PR (Codex creates it; base `develop`).

## Open questions

None. Brian adopted D1 (spec S-1) on 2026-10-25. Claude's calls made while planning, for Brian's review: the app owns the pty instead of
`LocalProcessTerminalView` (spec Architecture); tabs start the first time their workspace is
shown after launch; a signalled setup shows as exit `128 + signal`; notes and the divider are
written into the history so they replay.
