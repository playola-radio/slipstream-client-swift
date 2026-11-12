# PR Status Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. One PR, so the consumer is `superpowers:executing-plans` / `subagent-driven-development`, not `orchestrate-feature`.

**Goal:** A row at the top of the right column that shows the selected workspace's pull request status and the one next-step button (Create PR, Commit and push, Resolve conflicts, Fix errors, Merge, Continue/Archive), plus file chips in the chat.

**Architecture:** Pure parsing and status derivation live in `SlipstreamCore` (tested with `swift test`). A `PRStatusBarModel` (`@Observable`, owned by `ChangeStreamPageModel`) reads git/gh through a new `RepoCommandClient` in one restartable poll, runs the actions, and hands agent work to `ChatTabModel.enqueueUserMessage(_:)`. Views only bind.

**Tech Stack:** Swift 6 (strict concurrency, warnings as errors), SwiftUI, Observation, swift-dependencies, Swift Testing, CustomDump, XcodeGen.

**Spec:** [`spec.md`](spec.md). Contracts: [`screens.md`](screens.md) (states and mockups), [`models.md`](models.md) (types). Endpoints: none. Read all three before starting, including the spec's "Simplicity gate" table; this plan points at them rather than copying them.

## Global Constraints

- Base: `develop` at `a8fb46b`. Branch `briankeane/pr-status-bar`. PR targets `develop`.
- Invoke the `pfw-*` skills before writing each kind of code (`pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`, `pfw-modern-swiftui`, `pfw-issue-reporting`, `pfw-identified-collections`). Subagents too.
- MV: `@MainActor @Observable final class …: ViewModel`, `// MARK:` order from `CLAUDE.md`; **zero logic in views**.
- Dependency clients follow `OpenInClient`: a plain `Sendable` struct of closures, `DependencyKey` with `liveValue` and a `testValue` built from `unimplemented(…)`.
- Tests: Swift Testing, `expectNoDifference`, `TestClock`, `.mainSerialExecutor`. Never `Task.sleep` in tests. Model tests never run real git/gh. Table-shaped cases use parameterized `@Test(arguments:)`.
- Visual values come from `exports/pr-status-bar.json` into `DesignTokens.swift`; views use only `DesignTokens`.
- Never point anything at the real `~/.slipstream`. Never print or persist the daemon token.
- Deployment target is macOS 15: no `Observations` sequence.
- Timeouts are three named constants: 10 s `git`, 20 s `gh` reads, 60 s `gh run view` / `gh pr merge` / `git fetch`.
- Changelog: add `changelog.d/pr-status-bar.md` (format in `changelog.d/README.md`); never edit `CHANGELOG.md`.
- Gates per task: `swift test` (Core tasks), and `xcodegen generate && xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS' -skipPackagePluginValidation` (app tasks). Commit messages have no co-sign trailer.

## Review Focus

1. **Large command output.** `gh run view --log-failed` can print megabytes. The runner must drain stdout and stderr while the process runs, or the child blocks on a full pipe and every Fix errors click times out. Test in Task 4.
2. **Paths and branches with spaces, `#`, `(`, `)` and non-ASCII.** The marker must round-trip, and git arguments are passed as an argument array, never through a shell. Tests in Task 2 and Task 7.
3. **gh missing or signed out.** It must show "Couldn't check the pull request" with gh's stderr in Details, not an empty row or a hang. Test in Task 6.
4. **A workspace archived or deselected mid-check.** The result is dropped without publishing or crashing. Test in Task 6.
5. **Sleep/wake and app switching.** No reads while the app is inactive; activation reads once (no burst of missed ticks). Test in Task 6.

---

### Task 1: Decode pull requests and checks (Core)

**Files:**
- Create: `Sources/SlipstreamCore/PullRequests.swift`
- Create: `Tests/SlipstreamCoreTests/PullRequestsTests.swift`
- Create: `Tests/SlipstreamCoreTests/Fixtures/gh-pr-list.json`

**Interfaces:**
- Produces: `public struct GitHubPullRequest: Decodable, Equatable, Sendable` and `public struct PullRequestCheck: Decodable, Equatable, Sendable` with the fields in models.md; `PullRequestCheck.Outcome` (`failed`, `running`, `done`); `GitHubPullRequest.State` (`open`, `merged`, `closed`, raw values `OPEN`/`MERGED`/`CLOSED`).
- Produces: `public struct GitHubRepository: Decodable, Equatable, Sendable { isFork: Bool; defaultBranch: String; mergeMethod: String }` decoding `gh repo view --json isFork,defaultBranchRef,viewerDefaultMergeMethod` (`defaultBranchRef.name` → `defaultBranch`).
- Produces: `public struct ActionsRun: Hashable, Sendable { repository: String; id: String; init?(link: URL) }`.

- [ ] **Step 1: Write the failing tests.** The fixture is the real `gh pr list` output for #80 recorded in the spec session (three CheckRuns: two `SUCCESS`, one CodeRabbit `CANCELLED`), plus one added `StatusContext` with `"state":"PENDING"`.
  - `decodesPullRequestList`: `expectNoDifference` on number 80, state `.merged`, `headRefOid` `007da331c3b6f973700e4a35cb7eeb131dd20620`, `reviewDecision` `"CHANGES_REQUESTED"`; outcomes `[.done, .done, .done, .running]` (CANCELLED is `.done`, D13); the StatusContext's name and link come from `context` and `targetUrl`.
  - `classifiesCheck` (parameterized over `(json, expected outcome)`): CheckRun `FAILURE`, `TIMED_OUT`, `ACTION_REQUIRED`, `STARTUP_FAILURE` and StatusContext `FAILURE`, `ERROR` → `.failed`; CheckRun `status: IN_PROGRESS` and StatusContext `EXPECTED` → `.running`; `COMPLETED` with `conclusion: null` → `.done`; an unknown `__typename` → `.done` named by its `name` or `"Unknown check"`.
  - `parsesActionsRun` (parameterized): `…/actions/runs/43083706363/job/130742532911` and `…/actions/runs/43083706363` → `ActionsRun(repository: "playola-radio/slipstream-client-swift", id: "43083706363")`; a coderabbit.ai link → nil.
  - `decodesRepository`: `{"defaultBranchRef":{"name":"develop"},"isFork":false,"viewerDefaultMergeMethod":"MERGE"}`.
- [ ] **Step 2:** `swift test --filter PullRequestsTests`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement.** Decode the rollup with a custom `init(from:)` that switches on `__typename`. Keep `mergeable`, `mergeStateStatus` and `reviewDecision` as raw strings (models.md).
- [ ] **Step 4:** `swift test --filter PullRequestsTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: decode pull requests and checks from gh`.

### Task 2: Attachment marker, instruction text, branch names (Core)

**Files:**
- Create: `Sources/SlipstreamCore/AttachmentMarker.swift`, `Sources/SlipstreamCore/PRInstructions.swift`
- Modify: `Sources/SlipstreamCore/RuntimeInstall.swift:164` (make `shellQuoted` public for Task 4)
- Create: `Tests/SlipstreamCoreTests/AttachmentMarkerTests.swift`, `Tests/SlipstreamCoreTests/PRInstructionsTests.swift`

**Interfaces:**
- Produces: `public enum AttachmentMarker { static func format(name: String, path: String) -> String; static func parse(_ text: String) -> Parsed? }` where `public struct Parsed: Equatable, Sendable { body: String; name: String; path: String }`.
- Produces: `public enum PRInstructions` with:
  - `static func createPR(uncommitted: Int, branch: String, target: String, upstream: Upstream) -> String`, where `public enum Upstream: Equatable, Sendable { case none, inSync(String), unpushed(Int) }`;
  - `static func fixErrors(pullRequest: GitHubPullRequest, branch: String, logs: [ActionsRun: String]) -> String`. Failed checks come from `pullRequest`; each run's text is either the log or the failed command and its output. The 300-line tail is a private detail of this function;
  - `static func resolveConflictsMessage(target: String) -> String`;
  - message constants `createPRMessage = "Create a PR"`, `commitAndPushMessage = "Commit and push all changes"`, `fixErrorsMessage = "Fix the failing CI actions. I've attached the failure logs."`;
  - `static func nextBranchName(after branch: String, taken: Set<String>) -> String` (spec Continue step 2).

- [ ] **Step 1: Write the failing tests.**
  - `formatsAndParsesRoundTrip`: path `/Users/b/Library/Application Support/Slipstream/attachments/U/PR instructions.md` and name `PR instructions.md`. `format` gives `@⟦PR instructions.md⟧(/Users/b/Library/Application%20Support/…/PR%20instructions.md)`. `parse("Create a PR " + marker)` gives body `Create a PR`, the same name, and the decoded path.
  - `roundTripsAwkwardPaths` (parameterized, Review Focus 2): paths containing `(`, `)`, `#`, `%`, `é` and spaces round-trip.
  - `rejectsMalformedMarker` (parameterized) → nil:
    - a marker mid-text;
    - two markers;
    - a relative path;
    - bad percent-encoding (`%zz`);
    - a missing `)`;
    - a name containing `⟧`.
  - `createPRMatchesTemplate` (parameterized over the three `Upstream` cases): equals the spec's template verbatim, with "There is no upstream branch yet.", "The upstream branch is origin/b/x." and "There are 3 unpushed commits.".
  - `fixErrorsListsChecksAndLogs`:
    - the output contains the PR number, URL and branch;
    - it lists each failed check's name and link;
    - each run gets one section, holding only the last 300 of a 1,000-line log;
    - non-Actions checks appear by name and link only.
  - `resolveConflictsMessage(target: "main")` equals the Conductor sentence with `(main)`.
  - `nextBranchName` (parameterized):
    - `b` with `b-2` free → `b-2`;
    - `b` with `b-2` taken → `b-3`;
    - `b-2` → `b-3`;
    - `feature/x` → `feature/x-2`.
- [ ] **Step 2:** `swift test --filter 'AttachmentMarkerTests|PRInstructionsTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Percent-encode with a local `CharacterSet` of ALPHA, DIGIT, `-._~` and `/`. Parse with one anchored regex, `^(.*\S)\s@⟦([^⟦⟧\n]+)⟧\(([^()\s]+)\)$` (dot matches newlines), then `removingPercentEncoding` and require a leading `/`. Copy the template text verbatim from spec "Instruction files".
- [ ] **Step 4:** run again. Expected: PASS.
- [ ] **Step 5: Commit** `feat: format attachment markers, PR instructions and next branch names`.

### Task 3: Derive the PR status (Core)

**Files:**
- Create: `Sources/SlipstreamCore/PRStatus.swift`
- Create: `Tests/SlipstreamCoreTests/PRStatusTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `public struct RepoSnapshot: Equatable, Sendable` (fields in models.md) and `public enum PushState { inSync, localAhead, outOfSync }`;
  - `public enum PRStatus: Equatable, Sendable` (cases in models.md; no PR payloads) with `public init(snapshot: RepoSnapshot)`;
  - `public enum WaitingReason` (models.md);
  - `public static func selectPullRequest(_ prs: [GitHubPullRequest], head: String, uncommitted: Int) -> GitHubPullRequest?` (spec step 4).

- [ ] **Step 1: Write the failing tests.** They build snapshots with a helper `snapshot(pr:uncommitted:push:ahead:)`.
  - `selection` (parameterized):
    - cross-repo PRs are ignored;
    - the highest open number wins;
    - a merged PR counts only when its head matches and the tree is clean;
    - a merged PR with a moved head or a dirty tree → nil.
  - `noPullRequest` (parameterized): `noPRUncommitted(count: 2)`, `noPRCommitted(ahead: 3, target: "develop")` (target is `defaultBranch`), `nothingToSubmit`.
  - `openPullRequest` (parameterized, spec step 9 precedence):
    - dirty or local ahead → `commitAndPush`;
    - out of sync → `waiting(.outOfSync)`;
    - CONFLICTING → `conflicts(target:)` using `baseRefName`;
    - failed checks → `checksFailed(failed: 2, total: 9)`;
    - running → `checksRunning(done: 6, total: 9)`;
    - draft → `draft`;
    - draft with failed checks → `checksFailed`;
    - MERGEABLE with CLEAN, HAS_HOOKS or UNSTABLE → `ready`;
    - zero checks + CLEAN → `ready`.
  - `waitingReason` (parameterized):
    - UNKNOWN mergeable or merge state → `.gitHubChecking`, which also proves UNKNOWN is never `ready`;
    - CHANGES_REQUESTED → `.changesRequested`;
    - REVIEW_REQUIRED → `.reviewRequired`;
    - BEHIND → `.behind(target:)` using `baseRefName`;
    - BLOCKED → `.blocked`;
    - `"DIRTY_WEIRD"` → `.notMergeable`.
  - `mergedAndClosed`: `merged`, `closed`.
- [ ] **Step 2:** `swift test --filter PRStatusTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The precedence lives only in `init(snapshot:)`.
- [ ] **Step 4:** run again. Expected: PASS.
- [ ] **Step 5: Commit** `feat: derive pull request status from repository facts`.

### Task 4: RepoCommandClient and AttachmentClient (app dependencies)

**Files:**
- Modify: `SlipstreamViewer/Dependencies/AgentEnvironmentClient.swift`:
  - generalize `AgentEnvironmentCache` (`:84`) over its value;
  - extract the poll-and-drain loop of `captureOutputBlocking` (`:167`) so it can take a working directory and drain two pipes. `captureOutput` keeps its behaviour.
- Create: `SlipstreamViewer/Dependencies/RepoCommandClient.swift`, `SlipstreamViewer/Dependencies/AttachmentClient.swift`
- Test: `SlipstreamViewerTests/Dependencies/RepoCommandClientTests.swift`, `SlipstreamViewerTests/Dependencies/AttachmentClientTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct CommandResult: Equatable, Sendable {
    enum Ending: Equatable, Sendable { case exit(Int32), timedOut(Duration), launchFailed(String) }
    var command: [String]; var folder: URL; var ending: Ending; var stdout: String; var stderr: String
    var succeeded: Bool { ending == .exit(0) }
    var commandLine: String   // RuntimeInstall.shellQuoted per argument
  }
  struct RepoCommandClient: Sendable {
    var run: @Sendable (_ arguments: [String], _ folder: URL, _ timeout: Duration) async -> CommandResult
  }
  struct AttachmentClient: Sendable {
    var write: @Sendable (_ name: String, _ contents: String) throws -> URL
    var open: @Sendable (_ file: URL) throws -> Void
  }
  ```
- `arguments[0]` is the tool (`git`/`gh`), resolved through `/usr/bin/env` with the cached login environment's `PATH` (fall back to the process environment if `loginEnvironment()` throws). The environment never appears in `commandLine` or in errors.

- [ ] **Step 1: Write the failing tests.** They exercise the live value with real processes under `/bin` only, never git or gh against a real repo.
  - `capturesStdoutStderrAndExit`: `["sh", "-c", "echo out; echo err >&2; exit 3"]` → `.exit(3)`, `"out\n"`, `"err\n"`.
  - `runsInFolder`: `["pwd"]` in a temp dir → that path.
  - `drainsLargeOutputOnBothPipes` (Review Focus 1): `["sh", "-c", "yes x | head -c 5000000; yes y | head -c 5000000 >&2"]` → exit 0, and both streams hold 5,000,000 bytes, within a 10 s timeout.
  - `timesOut`: `["sleep", "30"]` with `.milliseconds(200)` → `.timedOut(.milliseconds(200))`.
  - `missingToolFails`: `["definitely-not-a-tool"]` → not `succeeded`, with non-empty stderr.
  - `commandLineQuotes`: `["git", "switch", "-c", "a b"]` → `git switch -c 'a b'`.
  - Attachments, using an internal `AttachmentClient.live(base:)` pointed at a temp dir:
    - `write` creates `<base>/<uuid>/PR instructions.md` with the contents;
    - `open` of a missing file throws an error naming the path.
- [ ] **Step 2:** run the xcodebuild gate with `-only-testing:SlipstreamViewerTests/RepoCommandClientTests -only-testing:SlipstreamViewerTests/AttachmentClientTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The extracted loop `poll()`s both descriptors, kills with SIGKILL at the deadline, and is called off the main thread the way `captureOutput` already does.
  - `AttachmentClient.liveValue` uses `applicationSupportDirectory/Slipstream/attachments` and writes atomically.
  - `open` checks `fileExists`, then `NSWorkspace.shared.open(url)`, and throws a descriptive error when either fails.
- [ ] **Step 4:** run again, and also the existing `AgentEnvironmentClient` tests (touched-area rule). Expected: PASS.
- [ ] **Step 5: Commit** `feat: run git and gh in a folder with timeouts, and write attachments`.

### Task 5: Queue a message without the draft, and the file chip (chat)

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift` (`send()`:230)
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift` (`userBubble`:306)
- Modify: `SlipstreamViewer/DesignTokens.swift` (chip tokens from `pr-status-bar.json`, screen B)
- Test: `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift`

**Interfaces:**
- Produces on `ChatTabModel`:
  - `func enqueueUserMessage(_ text: String) async throws`. The contract is in spec "Actions". It throws when the tab `isClosed` or the write fails;
  - `func attachment(for item: TranscriptItem) -> AttachmentMarker.Parsed?`;
  - `func attachmentTapped(_ item: TranscriptItem)`;
  - `var attachmentAlert: String?` (the path and the reason) and `func attachmentAlertDismissed()`.
- Consumes: `AttachmentMarker` (Task 2), `AttachmentClient` (Task 4).

- [ ] **Step 1: Write the failing tests.** Use `AgentFake`, like the existing send tests.
  - `enqueueWhenIdleStartsTurnAndKeepsDraft`: with the draft `"half typed"`, enqueue `"Commit and push all changes"`. Expect:
    - one launch;
    - the write is a user message with that text;
    - a userMessage row is projected;
    - the turn is active;
    - the draft is still `"half typed"`.
  - `enqueueMidTurnWritesImmediately`: after `send()` starts a turn, enqueue → a second write happens before the turn ends, and the draft is untouched.
  - `enqueueWriteFailureRemovesRowAndThrows`: the fake write throws → the row is removed, the error is thrown, and a turn it started is ended.
  - `enqueueOnClosedTabThrows`.
  - `markerRendersAsAttachment`: a userMessage row `"Create a PR @⟦PR instructions.md⟧(/tmp/x/PR%20instructions.md)"` → `attachment(for:)` has body `Create a PR`. History round-trips of the text are already covered by `ClaudeLinesTests`.
  - `attachmentTapOpensFile` and `attachmentTapMissingFileShowsAlert` (the alert text contains the path).
  - The existing `send()` tests stay green unchanged.
- [ ] **Step 2:** run the xcodebuild gate filtered to `ChatPageTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Extract `send()`'s write/project/rollback into one private method used by both `send()` and `enqueueUserMessage`.
  - `send()` keeps its idle-only admission and its draft clearing.
  - Enqueue also admits mid-turn, starting the process the way `relay(_:)` does, without relay marks or delivery state.
  - `userBubble` shows `Text(body)`, then a chip button (paperclip + name, tokens from screen B frames `f00glz`/`X6l6V`) when `attachment(for:)` is non-nil, plus an `.alert` bound to `attachmentAlert`.
- [ ] **Step 4:** run the full `ChatPageTests` (touched-area rule). Expected: PASS.
- [ ] **Step 5: Commit** `feat: queue agent messages without touching the draft, and show file chips`.

### Task 6: PRStatusBarModel — reading the status in one restartable poll

**Files:**
- Create: `SlipstreamViewer/Views/Pages/ChangeStreamPage/PRStatusBarModel.swift`
- Create: `SlipstreamViewerTests/Support/RepoCommandFake.swift`
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/PRStatusBarTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3 and 4; `ChatPageModel.folder`, `isAppActive`, `hasWorkingTab(in:)`.
- Produces on `PRStatusBarModel` (models.md):
  - `init(chat: ChatPageModel)`;
  - `var pollKey: PollKey` (`Hashable`; spec Ownership) and `func pollTask() async`;
  - `func reloadRequested()`;
  - computed `snapshot: RepoSnapshot?`, `status: PRStatus?` (nil while not applicable or not yet read), `checkFailure: PRBarFailure?` and `isCheckingShown`.
- Private `readSnapshot(folder:) async -> Result<RepoSnapshot?, PRBarFailure>` runs spec steps 1–7 and returns `.success(nil)` when the feature doesn't apply:
  - not a repo: `git rev-parse` exits 128;
  - detached HEAD: the branch is `HEAD`;
  - no origin;
  - `isFork`.
- `RepoCommandFake`: a `LockIsolated` script of `[[String]: CommandResult]`, a recorded `calls` list, and an optional hold gate for one argument list.

- [ ] **Step 1: Write the failing tests** (`.mainSerialExecutor`, `TestClock`):
  - `readsSnapshot` (parameterized):
    - each not-applicable input → no status, no failure;
    - a happy path → the expected `RepoSnapshot`, with push state from `merge-base --is-ancestor` exit 0 or 1;
    - gh exit 1 with "gh auth login" on stderr → `checkFailure` titled "Couldn't check the pull request", with that stderr in `details` (Review Focus 3);
    - `.timedOut(.seconds(20))` → `details` contains "timed out after 20 s".
  - `cancelledPollNeverPublishes` (Review Focus 4). Hold the first read for folder A, then each of these must leave A's held result unpublished:
    - switch to B, then back to A;
    - set the folder to nil (archived);
    - set an operation in flight.

    Cancel the first `pollTask` (as `.task(id:)` would on a key change) and release the hold.
  - `pollKeyChanges` (parameterized): the folder, `isAppActive`, `reloadRequested()`, an operation starting or finishing, and a tab in the folder starting or ending a turn each change `pollKey`.
  - `pollWaitsThirtySecondsAfterCompletion`: read count goes 1 → (advance 29 s) 1 → (advance 1 s) 2.
  - `inactiveDoesNotRead` (Review Focus 5): with the app inactive, `pollTask` returns without reading. A new `pollTask` once active reads exactly once before sleeping.
  - `checkingShowsUntilFirstResult`: before the first read finishes `isCheckingShown` is true. During a later re-read of the same folder it is false, and the last status stays.
  - `failureReplacedBySuccess`.
- [ ] **Step 2:** run the xcodebuild gate filtered to `PRStatusBarTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `pollTask` returns at once when there's no folder, the app is inactive, or an operation is in flight.
  - Otherwise it loops: read; `guard !Task.isCancelled`; set `checked = Checked(folder:result:)`; `try await clock.sleep(for: .seconds(30))`.
- [ ] **Step 4:** run again. Expected: PASS.
- [ ] **Step 5: Commit** `feat: read pull request status in a restartable poll`.

### Task 7: PRStatusBarModel — display and actions

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/PRStatusBarModel.swift`
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/PRStatusBarTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 5 and 6.
- Produces display properties:
  - `isRowContentShown`, `prNumberText: String?`, `pullRequestURL: URL?`, `statusIconName: String?`, `statusLabel: String`, `statusDetail: String?`;
  - `tone: PRStatusTone` (`muted`, `success`, `warning`, `danger`, `merged`);
  - `primaryButton: PRBarButton?` and `isPrimaryButtonEnabled`;
  - `isContinueShown`, `isArchiveShown`, `isDetailsShown`;
  - `failure: PRBarFailure?` (the action failure, else the check failure).
- `PRBarButton` is an enum: `createPR`, `commitAndPush`, `resolveConflicts`, `fixErrors`, `merge`. Each has a `title` and a `shortcut: KeyboardShortcut?` (`⌘⇧P` for createPR, `⌘⇧X` for fixErrors, `⌘⇧M` for merge).
- The text is exactly the screens.md copy:
  - "Uncommitted changes";
  - "Ready for a pull request · 3 commits ahead of develop";
  - "Merge conflicts with develop";
  - "Checks failed · 2 of 9 failed";
  - "Checks running · 6 of 9 done";
  - "Ready to merge";
  - "Draft · all checks passed";
  - "Waiting on GitHub · review required";
  - "Merging…";
  - "Merged";
  - "Closed";
  - "Checking for a pull request…";
  - failure titles from the spec's Errors table.
- Produces actions:
  - `primaryButtonTapped() async` and `continueTapped() async`;
  - `archiveTapped()`, which calls `onArchive: @MainActor () -> Void`, set by the owner;
  - `detailsTapped()`, `detailsDismissed()`, and `copyTapped()` (uses `PasteboardClient`).

- [ ] **Step 1: Write the failing tests.**
  - `displaysState` (parameterized over every screens.md row): asserts label, detail, tone and button. Also:
    - `isArchiveShown` only when archivable;
    - a failure keeps `isDetailsShown`;
    - agent buttons are disabled while `hasWorkingTab(in:)` or an operation is in flight (D15).
  - Create PR:
    - it writes `PR instructions.md` with click-time facts: the fake `git status` and `rev-parse @{upstream}` results differ from the last snapshot, and the file uses the click-time ones;
    - it enqueues `"Create a PR " + marker` on the tab captured at click.
  - Agent errors:
    - attachment write throws → nothing is enqueued, and the failure is titled "Couldn't send Create PR";
    - the captured tab is closed before sending → nothing is sent, and `details` says the chat tab was closed.
  - Fix errors:
    - two failed checks on one run plus one on another → two `gh run view <id> --repo playola-radio/slipstream-client-swift --log-failed` calls;
    - a failing log fetch is embedded, and the message is still sent.
  - Commit and push / Resolve conflicts: they enqueue the exact messages, with no attachment. Resolve uses the target.
  - Merge:
    - runs `gh pr merge <url> --merge --match-head-commit <oid>` (SQUASH → `--squash`);
    - "Merging…" shows while it runs;
    - a failure shows "Merge failed" with the output.
  - Continue:
    - `git fetch origin develop`, then one `for-each-ref` and one `ls-remote --heads origin`;
    - `git switch -c b-3 origin/develop` when `b-2` is taken;
    - a fetch or switch failure → "Couldn't start a new branch".
  - `branchWithAwkwardCharacters` (Review Focus 2): branch `feature/a b#(1)` reaches git as one unquoted argument in every command.
- [ ] **Step 2:** run the xcodebuild gate filtered to `PRStatusBarTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The send pipeline is spec "Actions → Agent buttons" steps 1–4. `operation` is set for the whole action and cleared in a `defer`; the poll restarts through `pollKey`. An action failure is cleared on retry or on a folder change.
- [ ] **Step 4:** run again. Expected: PASS.
- [ ] **Step 5: Commit** `feat: pull request bar actions — create, push, resolve, fix, merge, continue`.

### Task 8: Wire it into the window

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`:
  - construct `prStatusBar` in `init` (`:34`) with `chat`;
  - set `onArchive` to `archiveTapped(selectedSession)` (`:827`);
  - have `reloadShortcutPressed()` (`:734`) also call `prStatusBar.reloadRequested()`.
- Create: `SlipstreamViewer/Views/Pages/ChangeStreamPage/PRStatusBarView.swift`. It is a 40pt row per screens.md and `pr-status-bar.json`:
  - the PR chip is a `Link(destination:)`;
  - then the status, a spacer, and the button(s), each with `.keyboardShortcut(button.shortcut)` when non-nil;
  - a Details popover with Copy;
  - `.task(id: model.pollKey) { await model.pollTask() }`.
- Modify: `ChangeStreamPageView.rightPane` (`:180`): insert `PRStatusBarView(model: model.prStatusBar)` above `rightPaneStrip`.
- Modify: `SlipstreamViewer/DesignTokens.swift`: add a `PRStatusBar` namespace with values copied from `exports/pr-status-bar.json` (listed there by frame).
- Create: `changelog.d/pr-status-bar.md` with a `### Changes` bullet: "A bar above the right column shows the workspace's pull request status, with one button for the next step (create, push, fix, merge, continue)."
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`.

- [ ] **Step 1: Write the failing tests:**
  - `reloadShortcutAlsoRefreshesPRStatus` (`prStatusBar.pollKey` changes);
  - `archiveFromBarUsesArchiveConfirmation` (the existing alert state is set).
- [ ] **Step 2:** run the gate filtered to `ChangeStreamPageTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the wiring and views. The views read model properties only.
- [ ] **Step 4:** run the **full** xcodebuild gate and `swift test`. Expected: PASS (touched-area rule: run `ChangeStreamPageTests` and `ChatPageTests` in full).
- [ ] **Step 5: Manual check** with a disposable daemon (`SLIPSTREAM_STORE`, `npm run qa:daemon` in the daemon repo), on a scratch GitHub repo:
  - Create PR → chip → the PR opens;
  - checks running → passed → Merge → Merged → Continue;
  - ⌘⇧P / ⌘⇧X / ⌘⇧M fire only while their button is shown and enabled;
  - the row lines up at three window widths and in full screen;
  - VoiceOver reads the status and the button.
- [ ] **Step 6: Commit** `feat: show the pull request bar above the right column`.

## Unresolved questions

None. Merge queues, forks and attachment cleanup are spec non-goals.
