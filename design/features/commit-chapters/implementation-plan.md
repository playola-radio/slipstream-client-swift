# Commit Chapters Implementation Plan

> **For agentic workers:** this feature spans two repos and two PRs. Drive it with
> `orchestrate-feature`; each PR runs in its own fresh session with
> superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox
> (`- [ ]`) syntax for tracking. Swift sessions must invoke the `pfw-*` skills listed in the client
> repo's `CLAUDE.md` (`pfw-observable-models`, `pfw-dependencies`, `pfw-testing`,
> `pfw-custom-dump`, `pfw-identified-collections`, `pfw-modern-swiftui`).

**Goal:** Split the change stream into one chapter per git commit, titled by the commit subject,
with the uncommitted tail under "Not committed yet".

**Architecture:** The daemon watches the worktree's HEAD reflog. It places each HEAD move in the
event log (`seq` order) behind a barrier in its observation queue, and announces per activation
whether chapters are running. The app folds those events into chapter sections without moving
any card.

**Tech Stack:** Daemon: TypeScript on Node 24, `node:test`, `@parcel/watcher`. Client: Swift 6,
SwiftUI, Observation, swift-dependencies, Swift Testing, CustomDump.

**Spec:** [spec.md](./spec.md). Contracts: [models.md](./models.md) (event shapes, kind table,
reader state, Swift types), [endpoints.md](./endpoints.md) (route, ordering guarantee,
compatibility), [screens.md](./screens.md) (states and every string). Read all four before
starting. This plan points at them; it does not copy them.

## PR graph

| PR | Repo | Base | Depends on |
|---|---|---|---|
| A — daemon | `playola-radio/slipstream` | `develop` @ `56e171a` | — |
| B — client | `playola-radio/slipstream-client-swift` | `develop` @ `84d31da` | A merged; Task B5 needs A's npm release tag |

PR B's Tasks B1–B5 code only against the frozen contract in models.md, so they may start once A
is merged. A client on an older daemon shows no chapters (endpoints.md compatibility).

## Global Constraints

- Event types: `slipstream.git.chapters.v1`, `slipstream.git.head_observed.v1`. Register in
  `src/public-events.ts` only, never `EVENT_TYPES` in `src/event.ts`.
- Schemas: optional fields absent, never `null`. `kind`/`state` are plain strings with no
  `enum`. SHA pattern `^([0-9a-f]{40}|[0-9a-f]{64})$`.
- `observed_at_ms` (on `head_observed` only) is display only; `seq` is the only ordering key.
- Short SHA = first 7 characters. Chapter and divider times are `HH:mm` in the viewer's injected
  time zone; cards keep `HH:mm:ss`.
- Chapter number: `String(format: "%02d", sections.count)` when a section closes; commit and
  amend both count.
- Every user-visible string is the exact copy in screens.md § Copy.
- Full error detail is shown verbatim (never truncated or replaced with generic text).
- Never point anything at the real `~/.slipstream`; daemon tests use temp stores.
- Client: zero logic in views; every new side effect via an existing dependency.
- No `Co-Authored-By` trailers. PRs target `develop`.

## Review Focus

1. **Continuous file activity during a commit.** An agent that keeps writing while committing
   must not starve the barrier or reorder cards. Covered by A4's `barrierOrdersObservations`
   (B and C arrive while each stage is held; the worker stops at the barrier, not `splice(0)`).
2. **Very long "chapters unavailable" detail** (a multi-line git error). It must be fully
   readable, not cut to one line. Covered by B4's wrapping marker layout and B2's
   `unavailableDrawsOneDividerWithTheFullDetail` (3-line detail).
3. **Commit with a multi-line or non-ASCII subject.** Only the subject reaches the title; UTF-8
   must survive. Covered by A2's `commitSubjectComesFromTheReflogAndKeepsUnicode`.
4. **Session switch mid-fold.** The chapters-on flag and numbering must reset. Covered by B2's
   `switchingSessionResetsChapters`.
5. **Commit while capture is not yet live** (during baseline or a scope outage). Barriers must
   queue behind held observations instead of jumping ahead. Covered by A4's
   `barrierWaitsBehindObservationsHeldWhileNotLive`.

---

## PR A — daemon (`playola-radio/slipstream`)

Read the daemon's `CLAUDE.md`, `AGENTS.md` and `TESTING.md` first. Inspect code at
`origin/develop`. Verification for every task: `npm run typecheck && npm test`.

### Task A1: Event types and schemas

**Files:**
- Create: `schemas/slipstream.git.chapters.v1.json`, `schemas/slipstream.git.head_observed.v1.json`
- Modify: `src/public-events.ts` (`PUBLIC_EVENT_TYPES`, `LIFECYCLE_TYPES`, `LifecycleInput`)
- Test: `src/schema.test.ts`, `src/recovery.test.ts` (recovery needs no code change: it validates
  every `PUBLIC_EVENT_TYPES` entry against `loadAllSchemas()`)

**Interfaces:**
- Produces:
  ```ts
  export type GitChaptersData = { session_id: string; state: 'active' | 'unavailable'; detail?: string };
  export type HeadMoveKind = 'commit' | 'amend' | 'checkout' | 'reset' | 'fast_forward' | 'rebase' | 'rebase_abort' | 'other';
  export type HeadObservedData = { session_id: string; kind: HeadMoveKind; sha: string; subject?: string; target?: string; observed_at_ms: number };
  export type GitChaptersInput = { type: 'slipstream.git.chapters.v1'; occurred_at_ms: number; data: WithoutSessionId<GitChaptersData> };
  export type HeadObservedInput = { type: 'slipstream.git.head_observed.v1'; occurred_at_ms: number; data: WithoutSessionId<HeadObservedData> };
  ```
  Both inputs join `LifecycleInput`; for `head_observed` the producer sets
  `occurred_at_ms === data.observed_at_ms`.

- [ ] **Step 1: Write failing tests**
  - `schema.test.ts` › `gitChaptersAcceptsModelExamples`: both examples from models.md (one
    `active` without detail, one `unavailable`) validate with zero errors; a future
    `state: "paused"` also validates.
  - `headObservedAcceptsModelExample`, plus a 64-hex SHA, an unknown `kind: "stash"`, and a
    checkout with `target`.
  - `headObservedRejects`: a 7-char SHA, uppercase hex, `subject: 42`, `subject: ""` and a
    missing `kind` each produce at least one error.
  - `recovery.test.ts` › `recoversALogContainingGitEvents`: a seeded log with both types
    recovers without `CorruptLogError`.
- [ ] **Step 2:** `npm test` — the new tests FAIL (no schemas).
- [ ] **Step 3:** Write both schemas in the style of `slipstream.capture.scope.v1.json`, with
  the field rules from models.md. Register both types in the files above.
- [ ] **Step 4:** `npm run typecheck && npm test` — PASS.
- [ ] **Step 5:** Commit: `feat: add git chapters and head observed event types`

### Task A2: Reflog record classification

**Files:**
- Create: `src/reflog.ts`, `src/reflog.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface ReflogRecord { oldSha: string; newSha: string; message: string }
  export function parseReflogRecord(line: string): ReflogRecord | undefined; // `<old> <new> <ident> <tz>\t<message>`
  export interface HeadMove { kind: HeadMoveKind; sha: string; subject?: string; target?: string }
  export function classifyReflogRecord(r: ReflogRecord): HeadMove | undefined; // undefined = skipped
  ```

- [ ] **Step 1: Write failing tests.** Fixtures come from **real Git**: a helper
  `recordReflog(setup: (git) => void): string[]` makes a temp repo (`git init -q`, local
  `user.name`/`user.email`), runs the commands, and returns the new lines of
  `git rev-parse --git-path logs/HEAD`. One test per row (expected `kind`):
  `commit`, `commit (initial)`, `commit (merge)` (conflicted merge then commit), cherry-pick,
  revert → `commit`; `commit --amend` → `amend`; `checkout -b x`, `switch y`,
  `checkout --detach` → `checkout` with `target` equal to the text after `to `; `reset --hard
  HEAD~1` → `reset`; `reset --hard HEAD` → nothing; `merge --ff-only` and `pull` from a local
  remote fast-forward → `fast_forward`; non-ff `merge --no-ff feat` → `commit` with subject
  `"Merge feat"`; `rebase main`, `rebase -i` (with `GIT_SEQUENCE_EDITOR=true`), and a
  conflict + `rebase --continue` → exactly one `rebase` across all lines; `rebase --abort` →
  exactly one `rebase_abort`; a hand-written `update-ref -m "custom: x"` → `other`.
  `commitSubjectComesFromTheReflogAndKeepsUnicode`: message `"Fix café\n\nbody"` → subject
  `"Fix café"`; amend, cherry-pick and revert carry their subjects too.
  `parseReflogRecord` returns `undefined` for a line without a tab or with short SHAs, and parses
  a hand-written 64-hex (SHA-256) record.
- [ ] **Step 2:** `npm test` — FAIL.
- [ ] **Step 3:** Implement the kind table and the `subject` rule in models.md, first match
  wins. `sha` = `newSha`. `target` only for `checkout`; `subject` only for `commit`/`amend`.
- [ ] **Step 4:** PASS. If a real Git message differs from the table, fix the table in
  models.md in this PR and say so in the PR body.
- [ ] **Step 5:** Commit: `feat: classify HEAD reflog records`

### Task A3: Reflog reader and git probe

**Files:**
- Create: `src/reflog-reader.ts`, `src/reflog-reader.test.ts`, `src/git-chapters.ts`,
  `src/git-chapters.test.ts`
- Modify: `src/capture-scope.ts` (export `runGit` and `GitError` unchanged)

**Interfaces:**
- Consumes: `parseReflogRecord` (A2), `runGit` (capture-scope.ts).
- Produces:
  ```ts
  // reflog-reader.ts — state per models.md "Reflog reader state"
  export interface ReflogReader {
    baseline(): Promise<void>;
    read(extent: number | undefined): Promise<{ records: ReflogRecord[] } | { lost: string }>; // undefined = to EOF; extent <= offset reads nothing
  }
  export function createReflogReader(logPath: string): ReflogReader;

  // git-chapters.ts
  export type ChaptersProbe =
    | { state: 'active'; logPath: string; gitDir: string }
    | { state: 'unavailable'; detail: string }; // the models.md sentence
  export function probeChapters(root: string): Promise<ChaptersProbe>;
  ```

- [ ] **Step 1: Write failing tests.**
  - Reader: `baselineSkipsExistingHistory`; `readStopsAtExtent` (bytes past `extent` are left for
    the next read); `readUpToTheOffsetReadsNothing`; `recordSplitMidUtf8DecodesIntact` (split a
    `é` subject across two reads); `malformedCompleteRecordIsSkipped`;
    `rewriteKeepingLastRecordContinues` (replace the file with a copy whose tail is the last
    record plus one new one → that one new record); `rewriteDroppingLastRecordIsLost` (→
    `{ lost }` equal to the models.md rewritten sentence); `missingLogReadsNothingUntilCreated`.
  - Probe (real temp repos): `freshRepoWithoutLogsIsActive`;
    `linkedWorktreeUsesItsOwnLog` (`logPath` ends `worktrees/<name>/logs/HEAD`);
    `missingLogAndReflogOffIsDisabled` (detail is the models.md reflog-off sentence with this
    repo's `logPath`); `existingLogAndReflogOffIsActive`; `reftableIsUnsupported` (skip with a
    note if `git --version` < 2.45).
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implement. The probe runs `rev-parse --path-format=absolute --git-path
  logs/HEAD`, `rev-parse --absolute-git-dir`, `rev-parse --show-ref-format` (failure ⇒ `files`)
  and `config --bool core.logAllRefUpdates` through `runGit`. The reader keeps `tail` and
  `lastRecord` as `Buffer`s, and reads `[offset, extent)` from one descriptor after `fstat`.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit: `feat: read the HEAD reflog incrementally`

### Task A4: Barriers in the capture session's classifier loop

**Files:**
- Modify: `src/session.ts` (`onObservation`, `buffer`, `pumpClassifier`, `classifyLoop`
  ~615–725; activation where `deps.platform.watch` is called, ~973; `stop` ~1390)
- Modify: `src/test/fake-platform.ts` (support several subscriptions)
- Create: `src/session-git-chapters.test.ts`

**Interfaces:**
- Consumes: A1 inputs, A2 `classifyReflogRecord`, A3 `createReflogReader`, `probeChapters`.
- Produces: `FakePlatform` gains `observeAbsolute(absPath: string, observedAtMs?: number): void`,
  delivered to whichever subscription's `root` contains it; `observe` and `failWith` keep
  targeting the first (worktree) subscription. `failWith(err, root?)` targets a given
  subscription. `CaptureDependencies` is unchanged.

- [ ] **Step 1: Write failing tests** with `withGitRepo`-style real repos, the fake platform,
  and deferred promises (wrapping the engine, `scope.ignored` and the reader) to hold each
  stage:
  - `commitInMainCheckoutAppendsHeadObserved` and `commitInLinkedWorktreeAppendsHeadObserved`
    (AC 1): run `git commit`, `observeAbsolute(logPath)` → one `head_observed` `commit`, full
    SHA, subject.
  - `barrierOrdersObservations` (AC 2): `observe(A)`, barrier 1, `observe(B)`, barrier 2,
    `observe(C)`, with B and C delivered while classification, drain and the reflog read are
    each held → log order `A, head1, B, head2, C`. Assert relative `seq` order of the events
    that exist; never assert that every observation produced a card.
  - `barrierWaitsBehindObservationsHeldWhileNotLive` (AC 2): barrier during baseline → appended
    after the held observations once live.
  - `duplicateNotificationAddsNothing`, `oneNotificationTwoCommitsInReflogOrder` (AC 3).
  - `activationEmitsActiveAndNoHistory`, `resumeIgnoresCommitsMadeWhileStopped` (AC 5);
    `firstCommitInEmptyRepoIsDetected` (AC 6).
  - `reflogDisabledReportsUnavailableAndKeepsCapturing`,
    `watchFailureReportsUnavailableWithErrorText` (AC 7): a `git.chapters` `unavailable` with
    the models.md sentence, and a later `observe` still yields `file.changed`.
  - `barrierReadDuringStorageRecoveryIsAppendedAfterReopen` (AC 9): hold the read, force a
    storage failure (existing `createLog` wrapper pattern), release → the `head_observed` is
    appended exactly once, after the storage gap event.
  - `stopWithBarrierInFlightAppendsItBeforeTheStopRecord` (AC 9): hold the read, call `stop()`,
    release → `head_observed` before the stop record, nothing after, metadata subscription
    closed.
  - `filesystemPolicyEmitsNoChaptersEvents`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implement spec D1/D2 exactly:
  - `buffer` holds `[rel, observedAtMs]` observations and `{ barrier: true, extent,
    observedAtMs, moves? }` entries in callback order. `classifyLoop` stays the one worker.
  - The metadata subscription watches `probe.gitDir`. Its callback ignores everything except
    `logPath`, then synchronously takes `Date.now()` and `statSync(logPath).size` (`undefined`
    on error), pushes a barrier and calls `pumpClassifier()`.
  - `classifyLoop` takes the observations up to the next barrier (not `splice(0)`) and handles
    them exactly as today. At a barrier: `await engine.drain()`, `reader.read(extent)`, classify.
    If capture stopped being live during any of those awaits, put the barrier back at the head
    of `buffer` with the moves already read in `moves` and return, as the loop does with a
    batch. Otherwise append one `head_observed` per move in reflog order. On `{ lost }`, append
    `git.chapters` `unavailable` with that sentence and stop detection (close the metadata
    subscription; later barriers are dropped).
  - Activation order: probe → subscribe the metadata watch → `reader.baseline()` → append
    `git.chapters` → mark live. Append `git.chapters` after `session.resumed` on resume.
    Filesystem policy keeps today's direct `engine.notify` path untouched.
  - Stop closes the metadata subscription next to `subscription.close()`, before
    `while (classifierRunning) await classifierDone`. Storage recovery needs no new code.
- [ ] **Step 4:** PASS, plus the full existing suite (this edits shared capture code):
  `npm test` and `npm run test:os`.
- [ ] **Step 5:** Commit: `feat: place commit boundaries in the event log`

### Task A5: Docs

**Files:**
- Modify: `docs/autocapture/contracts.md` (new section per event, like
  `capture.ready.v1` § 1), `README.md` event list, and any event list `TESTING.md` names.

- [ ] **Step 1:** Document both events, the kind table, the `subject` rule, the unavailable
  sentences and the ordering guarantee wording from endpoints.md.
- [ ] **Step 2:** `npm run typecheck && npm test` — PASS.
- [ ] **Step 3:** Commit: `docs: describe commit boundary events`

---

## PR B — client (`playola-radio/slipstream-client-swift`)

Verification: `swift test`, then `xcodegen generate` and
`xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS' -skipPackagePluginValidation`.
Warnings are errors. B1–B4 are one migration: B1 deletes `.taskStarted` and B2 deletes
`FeedSection.heading`, which the view uses until B4, so the app compiles again only after B4.
Work through them in order and make **one commit at the end of B4**; B5 is its own commit.

### Task B1: Decode the new events

**Files:**
- Modify: `Sources/SlipstreamCore/Events.swift` (`EventPayload` ~164, `rowlessTypes` ~201,
  decode switch ~227–314)
- Create: `Tests/SlipstreamCoreTests/Fixtures/git-chapters-active.json`,
  `git-chapters-unavailable.json`, `head-observed-commit.json`, `head-observed-checkout.json`
  (the models.md / endpoints.md examples)
- Modify: `Tests/SlipstreamCoreTests/DecodingTests.swift` (replace `taskStarted()`)

**Interfaces:**
- Produces: `HeadObserved`, `HeadObserved.Kind`, `GitChapters` exactly as in models.md, with
  public memberwise inits. `EventPayload.headObserved(HeadObserved)`,
  `.gitChapters(GitChapters)`. `.taskStarted` and `TaskStarted` are deleted.

- [ ] **Step 1: Write failing tests** (`expectNoDifference`): each fixture decodes to the
  expected payload; `kind: "stash"` → `.other`; `state: "paused"` without detail →
  `.unavailable(detail: "")`; `fast_forward`/`rebase_abort` map to
  `.fastForward`/`.rebaseAbort`; `head_observed` without `sha` throws; `task-started.json` →
  rowless (same assertion style as other rowless types).
- [ ] **Step 2:** `swift test` — FAIL.
- [ ] **Step 3:** Implement. Absent `subject`/`target` decode as `nil`.
- [ ] **Step 4:** `swift test` — PASS. (The app target compiles again after B4; no commit yet.)

### Task B2: Chapters in the feed model

**Files:**
- Modify: `SlipstreamViewer/Models/FeedContent.swift` (`TaskHeading` → `Chapter`, `FeedSection`)
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`
  (`apply` ~1478–1540, `append` ~1691, `time` ~1708, fold reset ~1780, `taskCount`)
- Modify: `SlipstreamViewerTests/Support/DaemonFake.swift` (fixtures)
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes: B1 types.
- Produces:
  - `Chapter`, `FeedSection` exactly as in models.md.
  - Fixtures: `Fixture.headObserved(_ seq: Int, kind: String, sha: String, subject: String? = nil, target: String? = nil, atMs: Int64)`,
    `Fixture.gitChapters(_ seq: Int, state: String, detail: String? = nil)`.
  - Model: `private var chaptersActive = false`,
    `private func chapterTime(_ ms: Int64) -> String` (`HH:mm`). No chapter counter: the number
    is `sections.count` when a section closes. `taskCount` is deleted.

- [ ] **Step 1: Write failing tests** (one behaviour each, `expectNoDifference` on
  `model.sections`). Use a fixed `UTC` time zone, so `atMs: 1794501723118` → `16:42`.
  - `changesThenACommitCloseTheFirstChapter` (AC 11): `gitChapters active`, file, commit, file
    → `[FeedSection(id: .zero, chapter: .commit(number: "01", title: <subject>, detail: "a1b2c3d · 16:42"), items: [file1]), FeedSection(id: <commit seq>, chapter: .open, items: [file2])]`.
  - `aCommitFirstMakesACommitChapter` and `twoCommitsInARowGiveTwoEmptyChapters` (AC 12),
    including `emptyStateText == nil` after the first commit (it is `"Waiting for changes…"`
    while `sections` is empty).
  - `anAmendOpensANewChapterMarkedAmended`, `aCommitWithoutSubjectIsTitledByItsSha` →
    `"Commit a1b2c3d"` (AC 13).
  - `eachHeadMoveDrawsItsDivider` (AC 14): checkout with target → `"Switched to feat/x · 16:42"`;
    checkout without target → `"Switched to a1b2c3d · 16:42"`; reset, fast-forward, rebase,
    rebase abort, and an unknown kind → the screens.md strings. Each is a `.marker` in the last
    section.
  - `unavailableDrawsOneDividerWithTheFullDetail`: a 3-line detail → one marker
    `No commit chapters — <detail>`, byte for byte; an empty detail → `No commit chapters`.
  - `aResumeAfterChaptersRanSaysCommitsWereMissed`, `aResumeWithoutChaptersSaysOnlyRestarting`,
    `aResumeDoesNotStartASection` (AC 16). Rewrite the existing
    `aResumeSaysTheCaptureIsRestarting…` and `changesAfterAResumeAreNotFiledUnderThePreviousTask`
    to match.
  - `taskStartedDrawsNothing` (AC 17). Rewrite `eventsBuildSectionsAndAdvanceTheCursor` to use
    commits instead of tasks.
  - `switchingSessionResetsChapters`: commit in session 1, switch, file in session 2 → section
    `.open`, next commit numbered `"01"`, open heading hidden until session 2's `active`.
- [ ] **Step 2:** These fail to compile until Step 3; that is the red step.
- [ ] **Step 3:** Implement spec D7: commit/amend retitle the last section in place (creating
  `.zero` if none) and append `.open` with id = event `seq`. Dividers go through `append`.
  `.sessionResumed` no longer appends a section. Only copy from screens.md.
- [ ] **Step 4:** Continue to B3; the test run happens in B4.

### Task B3: Heading visibility, pinning and file-header geometry

**Files:**
- Modify: `ChangeStreamPageModel.swift` (`isHeadingPinned` ~693, `headingMoved` ~965,
  `taskHeadingMeasured` ~974, `cardFrames` ~158/988/1056, `updateFileHeaderOffset` ~1061)
- Test: `ChangeStreamPageTests.swift` (pinning tests ~1683–1740)

**Interfaces:**
- Produces (view-facing, read by B4):
  - `func isHeadingVisible(_ section: FeedSection) -> Bool`: `.commit` → true; `.open` →
    `chaptersActive && !section.items.isEmpty`.
  - `func chapterBadgeText(_ section: FeedSection) -> String?` (`number` for commit, `nil` for
    open), `chapterTitle(_:) -> String` ("Not committed yet" for open),
    `chapterDetail(_:) -> String?` (`nil` for open).
  - `chapterHeadingMeasured(height:)` replaces `taskHeadingMeasured(height:)`.
  - `cardFrames: [Seq: (row: FileChangeRow, sectionID: Seq, frame: CGRect)]`.
  - `cardMoved(_ row: FileChangeRow, in section: FeedSection, frame: CGRect)` keeps its
    signature.

- [ ] **Step 1: Write failing tests** (AC 15, 18):
  - `theOpenHeadingHidesWhileEmpty`, `…BeforeAnyChaptersEvent`, `…AfterUnavailable`,
    `…ShowsForAMarkerOnlyOpenChapter`, and `aLaterActiveReshowsTheOpenHeading`.
  - Rename `aTaskHeadingIsPinnedOnlyWhileItSitsAtTheTop` → `aChapterHeading…`;
    `aFileNameSticksBelowThePinnedChapterHeading…` for both `.open` and `.commit`, with the same
    offset for the same measured height.
  - `aFileNameOutsideAnyVisibleHeadingSticksToTheTop`: the sticky top is 0 when the section's
    heading is hidden.
- [ ] **Step 2:** Sticky top = `isHeadingVisible(section) ? chapterHeadingHeight : 0`, looked
  up by `sectionID` in `sections`. Pin cleanup is unchanged (`headingMoved`).

### Task B4: Chapter heading and divider views

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift`
  (section header ~375, `TaskHeadingView` ~645 → `ChapterHeadingView`, marker ~438)
- Modify: `SlipstreamViewer/DesignTokens.swift` (`TaskHeading` → `ChapterHeading`, new
  `StreamMarker`, fonts/colours)
- Create: `SlipstreamViewer/Assets.xcassets/PencilLine.imageset/` (lucide `pencil-line` SVG,
  same form as `FileText.imageset`)

**Interfaces:**
- Consumes: B3's view helpers only. The view never inspects `section.chapter`.

- [ ] **Step 1:** Tokens, copied from the pen components (`gPla3`, `VSPW0`, `HG5yk`;
  per-screen JSON in `exports/` after Phase 8):

  | Token | Value |
  |---|---|
  | `ChapterHeading.fill` (commit) / `openFill` | `0x24313B` / `0x1E2730` |
  | `ChapterHeading.stroke` (bottom 1pt, both) | `0x526B7B` |
  | padding vertical / horizontal, gap | 12 / 20, 12 (unchanged) |
  | Commit badge | existing `Badge` + `Fonts.taskBadge`/`Colors.taskBadge` |
  | Open badge fill / stroke 1pt / padding | `0x2A3540` / `0x4A6070` / 7 × 8; icon `PencilLine` 12pt `0x8FA8BA` |
  | Commit title | Geist 15 weight 550, `0xE0EBF1`, one line, truncates |
  | Open title | Geist 15 weight 400, `0x9DB3C3` |
  | Detail | Geist Mono 11, `0x68879E` (`Colors.eventTime`), trailing in the same row |
  | `StreamMarker` | padding 12 × 20, gap 10, lines 1pt `0x34414E` (`Colors.divider`) filling both sides, text Geist 10 `0x7D98AD` |

  Both heading kinds must render at the same height: badge content heights match (12pt text
  at padding 6 vs 12pt icon at padding 7 plus 1pt stroke). Verify with one
  `onGeometryChange` reading in a preview, or by eye against the PNGs.
- [ ] **Step 2:** The section header shows `ChapterHeadingView` when `model.isHeadingVisible`.
  Every marker uses the `StreamMarker` divider layout. The marker text has **no line limit**
  and wraps (Review Focus 2), with the lines centred vertically on the text.
- [ ] **Step 3:** Run `swift test` and the xcodebuild test command — every B1–B3 test PASSES
  along with the whole existing suite. Run the app against a disposable daemon
  (`npm run qa:daemon` in the daemon repo, `SLIPSTREAM_STORE` set) and compare with
  `exports/change-stream--*.png`: commit, amend, checkout, and a reflog-off repo.
- [ ] **Step 4:** Commit B1–B4 together: `feat: split the change stream into commit chapters`

### Task B5: Bundle the daemon release and the changelog note

**Files:**
- Modify: `packaging/runtime.env` (`DAEMON_COMMIT`)
- Create: `changelog.d/commit-chapters.md` (format in `changelog.d/README.md`)

- [ ] **Step 1:** Set `DAEMON_COMMIT` to the full SHA of PR A's npm release tag (`vX.Y.Z`;
  never a branch tip, per `packaging/README.md`). If PR A isn't released yet, stop and report
  BLOCKED to the orchestrator.
- [ ] **Step 2:** Changelog `### Changes`: "The change stream is now split into chapters, one
  per git commit, titled with the commit message; changes since the last commit sit under 'Not
  committed yet'. Task headings are gone."
- [ ] **Step 3:** Run both test commands — PASS. Commit: `chore: bundle the recorder with commit chapters`

## Unresolved questions

None. Real Git reflog messages that disagree with the models.md kind table are fixed in PR A
(Task A2 Step 4) and noted in that PR.
