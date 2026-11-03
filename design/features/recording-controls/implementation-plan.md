# Recording Controls Implementation Plan

> **For agentic workers:** this feature spans two repos and two PRs. **Consumer:
> `orchestrate-feature`**: PR 1 (daemon, `playola-radio/slipstream`) merges first; PR 2 (client,
> `playola-radio/slipstream-client-swift`) starts from that merged daemon. Each PR gets its own
> fresh session, which uses superpowers:subagent-driven-development or superpowers:executing-plans
> task by task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Brian chooses which workspaces record from the app's sidebar (Pause / Record / Record a
folder…). Nothing records on its own, and the daemon refuses instead of queuing when its 32 slots
are full.

**Architecture:** The daemon drops its `waiting` intent and queue, raises `MAX_CAPTURES` to 32,
refuses a full attach before writing anything, and refuses a chat attach that would resume a
paused capture. The app sends watch-only `attach` and `detach`, both keyed by folder path, over
the existing control socket and ignores the reply's fields. One shared `RecordingControlsModel`
holds the in-flight operation and message per folder for the sidebar and Ask. The sidebar derives
every row from each `GET /v1/captures` refresh.

**Tech Stack:** Daemon: TypeScript on Node (`node --test`, `tsc`). Client: Swift 6, SwiftUI,
`@Observable` models, swift-dependencies, Swift Testing, CustomDump.

**Spec:** [spec.md](./spec.md). Contracts: [screens.md](./screens.md),
[endpoints.md](./endpoints.md), [models.md](./models.md). Mockups:
`design/slipstream.pen`, zones `ZcE7b` and `KNAm8`, plus `exports/`. The design folder lives in
the **client** repo at `design/features/recording-controls/`. The daemon session reads it from
there.

## Base commits

- Daemon `~/playola/slipstream`: `b736f77c1c9728354767e708f067a8427f172567` (develop).
- Client: `7749fcce5f33250ac3b8f8e85df8de9eee96dcf7` (develop), rebased on develop after PR 1
  merges.

## Global Constraints

- PRs target `develop`, never `main`. Titles start with `feature:` and are plain English. No
  co-sign trailers.
- `MAX_CAPTURES = 32`. `MAX_BINDINGS` stays `10`.
- Daemon full message, exact: `32/32 capture slots in use. This workspace is NOT recording. Pause one first.`
  (built from `MAX_CAPTURES` as today).
- Daemon paused message, exact: `This workspace is paused. Record it in Slipstream first, then attach again.`
  with the new code `CAPTURE_PAUSED`.
- App strings are copied verbatim from [screens.md](./screens.md) and the error tables in
  [endpoints.md](./endpoints.md). No app string contains the slot count.
- Client: follow `CLAUDE.md`. Use the `pfw-*` skills (observable models, dependencies, testing,
  custom-dump, modern-swiftui, issue-reporting). Views hold zero logic; every visual value comes
  from `DesignTokens`. Swift 6 strict concurrency, warnings are errors. Run `xcodegen generate`
  after adding files.
- Never point anything at the real `~/.slipstream`. Manual checks use `npm run qa:daemon` with
  `SLIPSTREAM_STORE`. Never print the bearer token.
- Daemon verification: `npm run typecheck && npm test`. Client verification: `swift test` and
  `xcodebuild -scheme SlipstreamViewer -destination 'platform=macOS' test`.

## Review Focus

1. **Attach racing Pause.** An auto-link attach in flight while Pause commits must not restart
   recording. Pinned by D3's `CAPTURE_PAUSED` test, which detaches and then chat-attaches the same
   root.
2. **Full while a folder is already recording.** Record on a folder that is already starting or
   recording must succeed at 32/32 (a join, not a new slot). Pinned in D2.
3. **No reply after send.** Never show "not recording" or "paused" as fact. The app shows "not
   confirmed", refreshes, and the row follows the refresh. Pinned in C3.
4. **A recreated folder.** Two captures share one path. The sidebar shows one row, and Pause by
   path withdraws both. Pinned in C4.
5. **A reply after the selection changed.** It updates that folder's row and message and never
   moves the selection. Pinned in C4.

---

# PR 1 — Daemon (`~/playola/slipstream`)

Branch: `briankeane/recording-controls` from `origin/develop`.

### Task D1: Intent model: no `waiting`, 32 slots, legacy entries read as paused

**Files:**
- Modify: `src/capture-intent.ts` (`MAX_CAPTURES`, `CaptureIntent.intent`, `NotRecordingReason`, `admitCapture`, `withdrawCapture`)
- Modify: `src/intent-store.ts` (`loadIntent`)
- Test: `src/capture-intent.test.ts`, `src/intent-store.test.ts`

**Interfaces:**
- Produces:
  - `MAX_CAPTURES = 32`.
  - `admitCapture(record, entry): CaptureIntent` always writes `intent: 'running'`. Callers
    check `runningCount(record) < MAX_CAPTURES` first, in the same synchronous turn.
  - `withdrawCapture(record, sessionId, reason): void`. There is no promotion.
  - `loadIntent(storeDir)` rewrites each parsed `waiting` entry as `intent: 'withdrawn',
    withdrawn_reason: 'detached', last_failure: null` before validating. It writes nothing; the
    next normal `saveIntent` persists the new form.

- [ ] **Step 1: Write failing tests.**
  - `capture-intent.test.ts`: "admits up to 32 running captures": 32 `admitCapture` calls leave
    `runningCount === 32`. Replace the promotion tests with this one.
  - `intent-store.test.ts`: "loads a legacy waiting entry as paused": the fixture has one running
    entry and one waiting entry with a `last_failure`. The waiting entry loads as `withdrawn` /
    `detached` / `last_failure: null`; the running entry is unchanged; the file on disk is
    unchanged.
- [ ] **Step 2:** Run `node --test src/capture-intent.test.ts src/intent-store.test.ts`.
  Expect a FAIL.
- [ ] **Step 3: Implement.** Remove `'waiting'` from `CaptureIntent.intent` and
  `'capture-limit-reached'` from `NotRecordingReason`. The rewrite in `loadIntent` is the only
  place that still knows the word `waiting`. Update the comments that mention waiting.
- [ ] **Step 4:** Run the same command. Expect PASS. `npm run typecheck` fails in `daemon.ts`,
  `conductor.ts` and `attach-workflow.ts`; D2 and D4 fix them.
- [ ] **Step 5:** Commit with "Drop the waiting capture intent and raise the cap to 32".

### Task D2: Full is a refusal; the queue is gone

**Files:**
- Modify: `src/daemon.ts`:
  - `CAPTURE_LIMIT_MESSAGE` (~311);
  - the status projection waiting branch (~570);
  - `admitNew`: the slot check before `registry.freeze`/`reserve` (~908);
  - `admissionReply` (~1240);
  - detach promotion (~1455–1475).
- Modify: `src/test/captures-fold.ts` (drop the waiting branch)
- Test: `src/daemon-intent.test.ts`

**Interfaces:**
- Consumes: D1's `admitCapture`, `withdrawCapture`, `runningCount`.
- Produces: `CAPTURE_LIMIT_REACHED` with the exact message from Global Constraints. Nothing is
  written on refusal.

- [ ] **Step 1: Write failing tests** (`daemon-intent.test.ts`, with the existing daemon harness).
  Replace "records waiting captures in admission order" with:
  - "refuses a new root when 32 slots are held and writes nothing": the fixture includes a paused
    root A. Admit 32 other roots. A 33rd new root and a re-attach of A each return
    `CAPTURE_LIMIT_REACHED` with the exact message; `intent.json` is byte-identical before and
    after, so A stays paused.
  - "two concurrent new roots at 31 slots admit exactly one": `Promise.all` of two attaches
    gives one ok and one `CAPTURE_LIMIT_REACHED`.
  - "joining a recording root succeeds while full": at 32/32, re-attaching an admitted root
    returns ok with `created: false`.
  - "detach frees a slot and starts nothing else": at 32/32, detach one. No other capture
    changes state, and a new attach then succeeds.
- [ ] **Step 2:** Run `node --test src/daemon-intent.test.ts`. Expect a FAIL.
- [ ] **Step 3: Implement.**
  - In `admitNew`, check `runningCount(intent) < MAX_CAPTURES` in the same synchronous turn as
    `admitCapture`: after the deleted-session check, before `registry.freeze`/`reserve`, with no
    `await` between it and `admitCapture`.
  - Delete the waiting branches in `admissionReply` and the status projection.
  - Delete detach's `promotedFor` / `enqueueStart(next)`.
- [ ] **Step 4:** Run `npm run typecheck && npm test`. Expect PASS, except the
  `conductor`/`attach-workflow` failures that D4 fixes. Existing tests of waiting or promotion
  are replaced by the tests above, not kept.
- [ ] **Step 5:** Commit with "Refuse attaches when all 32 capture slots are in use".

### Task D3: A chat attach never resumes a paused workspace

**Files:**
- Modify: `src/daemon.ts` (`admit`, `admitNew`, `attachChat`, `attachWatchOnly`)
- Modify: `src/control-protocol.ts` (error union, docs comment)
- Test: `src/daemon-intent.test.ts`

**Interfaces:**
- Produces:
  - `admit(root: string, opts: { resumePaused: boolean })`. `attachWatchOnly` passes `true`;
    `attachChat` passes `false`.
  - Error code `CAPTURE_PAUSED` with the exact message from Global Constraints.

- [ ] **Step 1: Write failing tests.**
  - "chat attach of a paused root is refused and changes nothing": attach root, detach, then
    chat-attach the same root. The reply is `CAPTURE_PAUSED`; intent and bindings are
    byte-identical; no `session.resumed` event.
  - "chat attach of a recreated root admits a new session": detach, remove the directory and
    recreate it, then chat-attach. It is admitted with a new `session_id`.
  - "paused is reported before full": at 32/32, chat-attach a paused root. The reply is
    `CAPTURE_PAUSED`.
  - "watch-only attach of a paused root resumes it": the same `session_id`, `capture.gap`
    logged, and the status `binding.state === 'unlinked'`.
- [ ] **Step 2:** Run `node --test src/daemon-intent.test.ts`. Expect a FAIL.
- [ ] **Step 3: Implement.** In `admitNew`, once `match` is final (the identity-checked lookup),
  refuse when `!opts.resumePaused && match && findCapture(intent, match.id)?.intent === 'withdrawn'`.
  The refusal comes before the slot check and before any freeze, reserve or write. Thread the
  flag through `admit`; a joined pending admission keeps today's behavior.
- [ ] **Step 4:** Run `npm run typecheck && npm test`. Expect PASS, except D4's files.
- [ ] **Step 5:** Commit with "Never resume a paused workspace from a chat attach".

### Task D4: CLI wording and the contract doc

**Files:**
- Modify: `src/conductor.ts` (`runConductorEnroll`, ~338–363: delete the `CAPTURE_LIMIT_REACHED`
  branch, the waiting counter and the "start automatically" note; the generic `!res.ok` branch
  handles a full refusal)
- Modify: `src/attach-workflow.ts:224` (drop the `capture-limit-reached` clause from
  `refusalExpected`)
- Modify: `docs/autocapture/contracts.md`:
  - §5 attach rows (lines ~193–194);
  - §5 errors (~240–249, adding `CAPTURE_PAUSED`);
  - §6 (~299, ~323);
  - §8 intent field and slot rules (~410–438), plus the read-time upgrade note.
- Test: `src/conductor.test.ts`, `src/attach-workflow.test.ts`

- [ ] **Step 1: Update tests.** `conductor.test.ts`: the existing waiting case now expects the
  generic failure line carrying `CAPTURE_LIMIT_REACHED` and the message, no "waiting" in the
  summary, and exit code 1. `attach-workflow.test.ts`: remove the case that expects a refusal
  because of `capture-limit-reached`.
- [ ] **Step 2:** Run `node --test src/conductor.test.ts src/attach-workflow.test.ts`. Expect a
  FAIL.
- [ ] **Step 3:** Implement. Edit `contracts.md` to match [endpoints.md](./endpoints.md) and
  [models.md](./models.md); it doesn't restate the app's wording.
- [ ] **Step 4:** Run `npm run typecheck && npm test && npm run test:os`. Expect PASS.
  `grep -rn "waiting for a capture slot\|capture-limit-reached\|'waiting'" src docs` returns only
  the `loadIntent` rewrite and its test.
- [ ] **Step 5:** Commit with "Report a full daemon plainly in enroll and attach".

### Task D5: Ship gate — real-use resource check at 32

- [ ] Run `docs/autocapture/real-use-check.md` with 32 captures (today it exercises 16) against a
  disposable store (`npm run qa:daemon`). Record the result in that doc.
- [ ] If it fails, set `MAX_CAPTURES` to the highest passing value, update "32" in this design
  folder, and tell Brian before opening the PR. The app's wording has no number.
- [ ] Open PR 1 via `codex exec`, per the global PR rules. Title:
  `feature: let you pause and resume recording, with room for 32 workspaces`.

---

# PR 2 — Client (this repo)

Branch: `briankeane/recording-controls` from `origin/develop`, after PR 1 is merged.

### Task C1: Control requests for Record and Pause

**Files:**
- Modify: `Sources/SlipstreamCore/ControlTransport.swift` (two public methods)
- Test: `Tests/SlipstreamCoreTests/ControlTransportTests.swift`

**Interfaces:**
- Produces:
  - `ControlTransport.record(folder: String) async throws` sends
    `{v:1, verb:"attach", mode:"watch-only", worktree: folder}`.
  - `ControlTransport.pause(folder: String) async throws` sends
    `{v:1, verb:"detach", target: folder}`.
  - Both ignore every field of an `ok:true` reply. Errors reuse `QuestionError`:
    - `.unavailable` means it couldn't connect;
    - `.outcomeUnknown` means it was sent but no reply came back;
    - `.rejected(code:message:)` carries the daemon's `{ok:false, code, message}`.

- [ ] **Step 1: Write failing tests**, following the file's existing socket fixture:
  - each request line is byte-equal to the JSON in endpoints.md;
  - `{ok:true, …}` returns;
  - `{ok:false, code:"CAPTURE_LIMIT_REACHED", message}` throws `.rejected` with that code and
    message.
- [ ] **Step 2:** Run `swift test --filter ControlTransportTests`. Expect a FAIL.
- [ ] **Step 3:** Implement on the private `send(line:decode:)`, decoding `ok:false` the way
  `QuestionAcknowledgment.decode` does.
- [ ] **Step 4:** Run `swift test`. Expect PASS.
- [ ] **Step 5:** Commit with "Send record and pause requests to the daemon".

### Task C2: Dependencies

**Files:**
- Create: `SlipstreamViewer/Dependencies/RecordingClient.swift`
- Modify: `SlipstreamViewer/Dependencies/WorkspaceClient.swift` and its one caller in
  `ChangeStreamPageModel.newWorkspaceTapped()`

**Interfaces:**
- Produces:
  - `struct RecordingClient: Sendable { var record: @Sendable (_ folder: String) async throws -> Void; var pause: @Sendable (_ folder: String) async throws -> Void }`.
    - `liveValue` builds `ControlTransport(store:)` exactly as `QuestionClient.liveValue` does.
    - `testValue` is `unimplemented`.
    - Exposed as `\.recording`.
  - `WorkspaceClient.chooseRepository` becomes
    `chooseFolder: @MainActor @Sendable (_ message: String, _ prompt: String) async -> URL?`.
    New Workspace passes today's "Choose a git repository for the new workspace" /
    "Create Workspace"; Record a folder… passes "Choose a folder to record" / "Record".
  - Folder existence reuses the existing `\.terminalRuntime.folderExists`.

- [ ] **Step 1:** Add both, run `xcodegen generate`, and build. Existing New Workspace tests
  still pass with the renamed closure. There are no new tests; it is a thin live wrapper.
- [ ] **Step 2:** Commit with "Add record and pause dependencies".

### Task C3: `RecordingControlsModel`: one operation and message per folder

**Files:**
- Create: `SlipstreamViewer/Models/RecordingControlsModel.swift`
- Test: `SlipstreamViewerTests/Models/RecordingControlsModelTests.swift`

**Interfaces:**
- Consumes: `\.recording`, `\.workspace.chooseFolder`.
- Produces:
  - `@MainActor @Observable final class RecordingControlsModel: ViewModel`, shared like
    `InstantAskModel`.
  - `enum RecordingOperation: Equatable { case pausing, recording }`
  - `struct RecordingMessage: Equatable { var text: String; var isFull: Bool }`, where
    `isFull` selects amber.
  - `init(onChanged: @escaping @MainActor (_ preferring: String?) async -> Void, onRecorded: @escaping @MainActor (String) -> Void)`.
    `onChanged` refreshes captures, selecting the given folder if one is passed.
    `onRecorded(folder)` asks chat to auto-link once.
  - `private(set) var operations: [String: RecordingOperation]`, keyed by normalized folder.
  - `private(set) var messages: [String: RecordingMessage]`.
  - `private(set) var footerMessage: RecordingMessage?`.
  - `func pauseTapped(folder: String) async`
  - `func recordTapped(folder: String) async`
  - `func recordFolderTapped() async`: choose a folder, record it, then `onChanged(folder)`. An
    already-recording folder joins (`ok`) and the refresh selects its row.

- [ ] **Step 1: Write failing tests** (`withDependencies`, `.mainSerialExecutor`, `expectNoDifference`):
  - Message mapping. One parameterised test covers every row of both error tables in
    endpoints.md: error and action map to the exact text, with `isFull` only for
    `CAPTURE_LIMIT_REACHED`.
  - "a second tap on the same folder is ignored while one runs": `operations[folder]` is set
    during the call and `record` is called once.
  - "record success clears the folder's message, refreshes and asks chat to link": `onChanged`
    and `onRecorded(folder)` are each called once.
  - "outcomeUnknown shows not confirmed and refreshes": the message is "Recording not
    confirmed. Checking…" (pause: "Couldn't pause: Slipstream didn't confirm it. Checking
    again…") and `onChanged` is called.
  - "a refused Record sets only that folder's message": other folders' messages are unchanged,
    and `onRecorded` is not called.
  - "record a folder: cancel does nothing": `chooseFolder` returns `nil`, so there is no
    `record` call.
  - "record a folder: success refreshes preferring the folder"; "a refusal sets the footer
    message": "Couldn't record notes: it overlaps a folder that's already recording."
- [ ] **Step 2:** Run `xcodebuild … test -only-testing:SlipstreamViewerTests/RecordingControlsModelTests`.
  Expect a FAIL.
- [ ] **Step 3:** Implement. A folder's operation is cleared in `defer`. A new tap clears that
  folder's message (and the footer message), which is "cleared on the next click".
- [ ] **Step 4:** Run the same command. Expect PASS.
- [ ] **Step 5:** Commit with "Track record and pause per folder".

### Task C4: Sidebar rows, header count, Pause/Record, footer

**Files:**
- Modify: `SlipstreamViewer/Models/CaptureStatus.swift`:
  - add `isPaused` (`stopped{detached}`);
  - `isInactive` no longer counts `notRecording` or `stopped{detached}` as inactive;
  - `stopped{detached}` capture text becomes "Paused";
  - remove `capture-limit-reached` from the wording maps and `detailText`.
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`:
  - `pickerSessions`, `isHideable` and `sidebarGroups`;
  - the new display helpers;
  - own `recording: RecordingControlsModel`;
  - check folder existence once per refresh in `loadSessions`.
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/WorkspaceSidebarView.swift`, `SlipstreamViewer/DesignTokens.swift`
- Test: `SlipstreamViewerTests/Models/CaptureStatusTests.swift`, `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes: C3, `\.terminalRuntime.folderExists`.
- Produces `ChangeStreamPageModel` row helpers:
  - `recordingCountText: String` ("6 recording"), counting rows whose `captureDot == .recording`;
  - `rowActionText(_:) -> String` ("Pause", "Record", "Pausing…", "Recording…");
  - `isRowActionDisabled(_:)`;
  - `rowActionTapped(_:) async`;
  - `rowMessage(_:) -> RecordingMessage?`;
  - `recordFolderText = "Record a folder…"`;
  - `recordFolderTapped() async`;
  - `footerMessage`.

- [ ] **Step 1: Write failing tests.**
  - `CaptureStatusTests`: `isPaused` and `isInactive` for every state and reason above;
    `captureText` for `stopped{detached}` is "Paused".
  - `ChangeStreamPageTests`:
    - "a paused row shows only while its folder exists": two detached captures, one folder
      existing. One paused row.
    - "a not-recording capture shows with Pause".
    - "archived and maintenance rows stay hidden unless selected".
    - "one row per folder": a recreated folder has an old detached capture and a new recording
      one. There is one row, it is the recording session, and Pause sends that folder's path.
    - "header counts recording rows only": 3 recording and 2 queued give "3 recording".
    - "a reply after the selection changed doesn't move it": start Record on A, select B,
      finish. The selection is still B and A's row updates.
- [ ] **Step 2:** Run `xcodebuild … test -only-testing:SlipstreamViewerTests/CaptureStatusTests -only-testing:SlipstreamViewerTests/ChangeStreamPageTests`.
  Expect a FAIL.
- [ ] **Step 3: Implement.**
  - `pickerSessions` keeps a session when it is selected, or when it is the
    `current(in: root)` capture for its folder and not `isInactive`. A paused row also needs its
    folder to exist.
  - Wire `recording`'s `onChanged` to `loadSessions(preferring:)`. Pass `onRecorded: { _ in }`
    for now; C6 wires it to the chat model.
  - Build the view from the approved frames: `qrTx8`, `OPNrE`, `pkqIf`, `T9EHei`, `W3IjdQ`,
    `G8j5Wn`. Read the measurements and colours from `exports/*.json`. Add only the missing
    values to `DesignTokens`.
  - The row button sits next to the archive icon on hover or focus, and is also an
    accessibility action.
- [ ] **Step 4:** Run the full `xcodebuild … test`. Expect PASS. Then run the app against
  `make demo` and compare each state with its PNG in `exports/`.
- [ ] **Step 5:** Commit with "Show paused workspaces in the sidebar with Pause and Record".

### Task C5: Ask: paused notice with Record

**Files:**
- Modify: `SlipstreamViewer/Models/CaptureStatus.swift` (`askNotice`: the paused text)
- Modify: `SlipstreamViewer/Views/Pages/AskAgentPage/AskAgentPageModel.swift`, `AskAgentPageView.swift`
- Modify: `ChangeStreamPageModel.swift` (pass `recording` into `AskAgentPageModel(...)` at ~411)
- Test: `SlipstreamViewerTests/Views/Pages/AskAgentPage/AskAgentPageTests.swift`, `CaptureStatusTests.swift`

**Interfaces:**
- Consumes: C3's `RecordingControlsModel`.
- Produces: `AskAgentPageModel` gains:
  - an init parameter `recording: RecordingControlsModel`;
  - `isPausedNoticeVisible: Bool`;
  - `recordButtonText` ("Record" / "Recording…");
  - `isRecordDisabled`;
  - `recordMessage: RecordingMessage?`;
  - `func recordTapped() async`.

- [ ] **Step 1: Write failing tests.**
  - `askNotice` for `stopped{detached}` is "This workspace is paused, so its chat can't
    receive questions. Record it to ask."
  - Other non-recording states keep today's text.
  - "Record from Ask uses the shared operation": with Record running from the sidebar for the
    folder, Ask's button shows "Recording…" and is disabled.
  - "after Record, Ask stays disabled until today's rules allow": `captureChanged` to
    `recording` with no linked chat gives `canSubmit == false` and the "No chat is connected
    yet…" notice.
  - "a refused Record shows the shared message in place of the notice".
- [ ] **Step 2:** Run the `AskAgentPageTests` and `CaptureStatusTests` filters. Expect a FAIL.
- [ ] **Step 3:** Implement. Lay out the view from frames `PHH8d` and `blDch`.
- [ ] **Step 4:** Run the full `xcodebuild … test`. Expect PASS.
- [ ] **Step 5:** Commit with "Offer Record from Ask when the workspace is paused".

### Task C6: Chat tabs skip paused workspaces

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift`:
  - `autoLink`: skip a folder whose `captures.current(in:)` is paused, using the captures
    `capturesArrived` already receives;
  - a new `func recorded(folder: String)` that runs `autoLink(in:)` once. `ChangeStreamPageModel`
    passes it as `RecordingControlsModel`'s `onRecorded`.
- Test: `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift`

A `CAPTURE_PAUSED` refusal needs no new code: it parses as `LinkRefusal.other` and shows
today's "Slipstream said: …" text.

- [ ] **Step 1: Write failing tests.**
  - "opening a paused workspace doesn't attach": `chatLink.link` is not called.
  - "a turn ending in a paused workspace doesn't attach".
  - "recorded(folder:) links the first tab with a message".
- [ ] **Step 2:** Run the `ChatPageTests` filter. Expect a FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test` and the full `xcodebuild … test`. Expect PASS.
- [ ] **Step 5:** Commit with "Keep chat tabs from restarting a paused workspace".

### Task C7: Finish

- [ ] `grep -rn "capture-limit-reached\|capture slot" SlipstreamViewer Sources` returns only
  `CapturesDecodingTests`' unknown-reason list.
- [ ] Manual check against `npm run qa:daemon`:
  - Pause a recording row, then Record it. The stream shows a gap.
  - Fill 32 slots. Record shows the amber message, and the header shows the real count.
  - **Record a folder…** with an overlapping folder shows the footer message.
  - Ask on a paused workspace shows Record.
- [ ] Run the Codex adversarial review, challenge pass and Excess Audit (global `CLAUDE.md`
  phase 3).
- [ ] Open PR 2 via `codex exec`. Title: `feature: pause and record workspaces from the sidebar`.

## Unresolved questions

None blocking. If the real-use check (D5) fails at 32, the cap changes and the app's wording
doesn't.
