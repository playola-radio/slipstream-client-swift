# Linked Chat Implementation Plan

> **For agentic workers:** this plan spans two repos and four PRs. Drive it with
> `orchestrate-feature`; each PR is implemented in a fresh session with
> superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use
> checkbox (`- [ ]`) syntax. The design folder lives in the **client** repo at
> `design/features/linked-chat/`; the daemon sessions read it from there.

**Goal:** Ask-at-a-line reaches a chat tab the app runs. The app links a tab itself, shows which
tab is linked, and lets the user move the link. Questions a link move interrupted go to the newly
linked chat.

**Architecture:** Two daemon changes: any Claude version that passes the transcript checks can
link, and an unlink keeps unanswered questions for the next linked chat instead of dropping them.
In the client, decoding and `LinkOutcome` parsing live in `SlipstreamCore`. Running
`slipstream attach`/`unlink` is a new `ChatLinkClient` dependency that runs whole link operations
one at a time. `ChatPageModel` owns the link rules (auto-link, Connect to Stream, closing the
linked tab, "Couldn't connect"). `ChangeStreamPageModel`, the window's one event follower, feeds
it the captures it already reads. Which tab is linked is never stored: it is derived from
`/v1/captures`. The client sends no re-asks; the question fold only marks a moved question as
"Re-sending" until a chat picks it up again.

**Tech Stack:** Swift 6 (complete strict concurrency, warnings are errors), SwiftUI on macOS 15,
swift-dependencies, swift-identified-collections, swift-sharing, Swift Testing, CustomDump,
swift-clocks (`TestClock`), XcodeGen. Daemon: TypeScript, Node, its existing test runner.

**Spec:** [spec.md](./spec.md) is the source of truth (scope, Phase 5, re-review and Phase 7
dispositions). Contracts to implement, pointed at here and not copied:
[screens.md](./screens.md) (every state and all copy), [models.md](./models.md) (types, fold
rules, link rules), [endpoints.md](./endpoints.md) (daemon deltas, CLI invocation and outcome
table).

**Base commits:** client `develop` @ `30027d3`; daemon `develop` @ `89eed57`.

**Required skills for every client session** (project `CLAUDE.md`):
- `pfw-observable-models` for `*PageModel`
- `pfw-dependencies` for `ChatLinkClient`
- `pfw-testing` and `pfw-custom-dump` for tests
- `pfw-identified-collections` for `IdentifiedArrayOf`
- `pfw-modern-swiftui` for views
- `pfw-issue-reporting` for `reportIssue`

Subagents invoke them too. The daemon sessions follow the daemon repo's `CLAUDE.md`/`AGENTS.md`.

## Global Constraints

- **Safety:** never point anything at the real `~/.slipstream`; QA uses `SLIPSTREAM_STORE` with a
  disposable daemon (`npm run qa:daemon` in the daemon repo). Never print or persist the daemon
  bearer token. Never commit captured data (`.slipstream/`, `sessions/`, `blobs/`, `*.jsonl`
  transcripts); test fixtures are hand-written minimal JSONL.
- **Nothing new on disk in the client.** No `isLinked` on `ChatTabRecord`; no Keychain.
- **Linked tab, derived:** binding `harnessSessionID` parses to the tab's UUID (case-insensitive),
  state `.connected` or `.setupPending`, capture root (normalized with
  `ChangeStreamPageModel.normalizedFolder`) equals the tab's folder.
- **Attach environment** (endpoints.md "CLI slipstream attach"): `AgentEnvironment.variables` (the
  same login-shell environment the tab launches with, so `CLAUDE_CONFIG_DIR` already matches) plus
  `CLAUDE_CODE_SESSION_ID=<tab id, lowercased>` and
  `CLAUDE_CODE_EXECPATH=<AgentEnvironment.claudePath>`; `CODEX_THREAD_ID` and
  `CONDUCTOR_SESSION_ID` removed.
- **Copy is verbatim from screens.md:**

  | Use | Text |
  |---|---|
  | Tab menu | "Connect to Stream", "Close Tab" |
  | Disabled hint | "Send this chat a message first." |
  | Link icon hover title | "Connected to Stream" |
  | Waiting hover body | "Waiting for it to confirm. It connects the next time the agent works — send it a message to connect now." |
  | Outside label | "Stream: outside chat" |
  | Failure hover title | "Couldn't connect to Stream" |
  | Too old | "This version of Slipstream can't connect chats run in the app. Update Slipstream, then right-click the tab and choose Connect to Stream to try again." |
  | Slots full | "Slipstream is already connected to 10 chats, its limit. Unlink one with `slipstream unlink`, then right-click the tab and choose Connect to Stream to try again." |
  | Setup incomplete / other | "Slipstream said: <its message> Right-click the tab and choose Connect to Stream to try again." |
  | Ask, nothing connected | "No chat is connected yet. Send a message in a chat tab to connect it." |
  | Ask, tab waiting | "The chat tab connected to this stream hasn't confirmed it can answer yet. It confirms the next time the agent works — send it a message to confirm now." |
  | Thread, re-sending | "Re-sending to the newly connected chat — waiting for the agent to answer…" |

- Outside-chat links keep today's Ask notices (`CaptureStatus.askNotice`), unchanged.
- Views use only `DesignTokens`; icon sizes and colours come from this feature's
  `exports/screens/*.json` and `exports/design-tokens.json`.
- Tests never spawn `claude` or `slipstream`, never read `~/.claude`, never sleep. Time is
  `TestClock`; ordering uses `.mainSerialExecutor`.

## Review Focus

1. **Two app operations can race.** An auto-link and a Connect to Stream fired together must run
   one after the other, and the second must see the first's result (`.skipped`, not a second
   unlink). Covered by Task 3, `operationsRunOneAtATime` and `secondOperationSeesFirstResult`.
2. **A question queued in the gap of a move.** An ask that passes its ownership check just before
   the unlink commits is queued for the old chat after it (`session.ts:1144-1149`). The new chat
   must still be able to claim and answer it. Covered by Task 2,
   `questionQueuedForOldChatAfterUnlinkIsClaimableByNewChat`.
3. **Re-delivery survives a daemon restart.** A moved, unanswered question must still be
   claimable after the daemon recovers the session from disk, and a resume must still drop it.
   Covered by Task 2, `recoveredSessionKeepsMovedQuestionClaimable` and
   `resumeAfterUnlinkDropsMovedQuestion`.
4. **The linked tab's process predates its attach.** After linking, the tab must be restarted
   when idle so the hook and answer tool load, without cutting a turn short. Covered by Task 4,
   `linkedIdleTabRestarts` and `linkedWhileWorkingRestartsAfterTurnEnds`.
5. **Partial failures.** A refused attach can still have linked the chat (setup incomplete) or
   left the workspace unlinked (attach failed after unlink); the refresh must show the truth and
   the failure must persist as specified. Covered by Task 4,
   `setupFailureSurvivesLinkedRefresh` and `attachFailureAfterUnlinkLeavesUnlinkedWithFailure`.

## PR graph

| PR | Repo | Tasks | Depends on | Red → Green | QA |
|---|---|---|---|---|---|
| D · Any Claude version links | daemon | 1 | — | `claude-root-transcript` tests fail → pass | attach an app-launched `sdk-ts` 2.1.293 chat on a disposable store |
| E · Questions follow the link | daemon | 2 | — | `session` re-delivery tests fail → pass | move a link with a question waiting, on a disposable store |
| B · Chat tab linking | client | 3–5 | D for QA | `ChatLinkClientTests`, `ChatPageTests` link suites fail → pass | spec acceptance 1–5, 7 on a disposable daemon |
| C · Re-sending status | client | 6 | E and B for QA | `QuestionThreadsTests` move suite fails → pass | spec acceptance 6 |

D, E, B and C can all be written in parallel; QA needs the daemon PRs merged (or their branches
running in `qa:daemon`). Every PR targets `develop`. Titles follow the PR-title rules:
D `feature: let chats on any recent Claude version connect to Slipstream`;
E `feature: keep unanswered questions when the linked chat changes`;
B `feature: link a chat tab to the stream and show which one is linked`;
C `feature: show when a question moves to a newly linked chat`.

---

## PR D — Any Claude version links (daemon, `playola-radio/slipstream`)

### Task 1: Drop the fixed Claude version list

**Files** (endpoints.md "CONTROL attach" lists the exact lines):
- Modify: `src/claude-root-transcript.ts` (delete `RUNTIMES` and the `unsupported-version` reason)
- Modify: `src/attach-workflow.ts:288-312` (remove the Claude "not a runtime Slipstream has
  verified" branch; Codex keeps its check)
- Test: `src/claude-root-transcript.test.ts`, `src/daemon.test.ts:102-104`,
  `src/test/daemon-harness.ts:90`, `src/attach-workflow.test.ts`, `src/cli.test.ts:356`,
  `src/autocapture-acceptance.test.ts:716`
- Docs: `docs/ask-agent/contract.md:230-235`, `docs/connect-agent-chat.md:62`, `README.md:154`

**Interfaces:**
- Produces: `verifyClaudeRootTranscript` accepts any non-empty string `version` and `entrypoint`
  on the first identity record; later records must repeat both. `ClaudeRootResult` has no
  `unsupported-version`.

- [ ] **Step 1: Write the failing tests** in `claude-root-transcript.test.ts`:
  - `acceptsUnlistedVersionAndEntrypoint`: `version: "2.1.293"`, `entrypoint: "sdk-ts"` → ok.
  - `acceptsUnknownEntrypoint`: `entrypoint: "some-future-mode"` → ok.
  - `rejectsEmptyVersion`, `rejectsEmptyEntrypoint`, `rejectsNonStringVersion` → fail closed.
  - `rejectsEntrypointChangingBetweenRecords` → fail closed (existing rule, keep a test).
  - Keep every existing structural rejection test (symlink, session id mismatch, `cwd` outside
    root, sidechain, `userType`).
- [ ] **Step 2: Run** `node --test src/claude-root-transcript.test.ts`. Expect the two accept tests
  to FAIL with `unsupported-version`.
- [ ] **Step 3: Implement.** Delete `RUNTIMES` and its lookup; validate non-empty strings. Update
  the CLI pre-flight and the fixtures/tests that pinned a listed version.
- [ ] **Step 4: Run** `npm test` and the repo's lint. Expect PASS.
- [ ] **Step 5: End-to-end on a disposable store** (`SLIPSTREAM_STORE`, `npm run qa:daemon`):
  launch a chat the way the app does (`claude --print … --session-id=<uuid>`), send one message,
  run `slipstream attach <folder>` with `CLAUDE_CODE_SESSION_ID` set; expect `session_id:` and
  `agent_connection: setup_pending`; then resume it (`--resume=<uuid>`), let the agent work once,
  expect `connected`; ask a question, expect an answer. Record the versions and launch modes seen
  in the PR body.
- [ ] **Step 6: Commit** `feature: admit any Claude version that passes the transcript checks`.

---

## PR E — Questions follow the link (daemon, `playola-radio/slipstream`)

### Task 2: An unlink keeps unanswered questions for the next linked chat

**Files** (endpoints.md "CONTROL claim_question / answer_question" has the full delta):
- Modify: `src/session.ts` (`onCommitted` :360-380, `seedTaskState` :315-328, `claimQuestion`
  :1198-1217, `answerQuestion` :1221-1249)
- Modify: `src/recovery.ts` (expose the latest `session.resumed` seq separately from
  `taskResetSeq`, and the latest `agent.unlinked` seq)
- Modify: the `question.dispatch_attempted.v1` schema and type (add `target`)
- Test: `src/session.test.ts` (or the file holding today's claim/answer tests), `src/recovery.test.ts`
- Docs: `docs/ask-agent/contract.md` (D2 "never automatically offers that question again" gains
  the unlink exception; the "queued before the latest resume is never claimable" rule is unchanged)

**Interfaces:**
- Produces: after `agent.unlinked.v1`, every question queued after the latest `session.resumed`
  that has no committed answer is claimable again by whichever chat is linked next, until its
  original `expires_at_ms`. `dispatch_attempted.v1` data gains `target` (the chat it was handed
  to). A chat may answer a question that was ever handed to it, while it is the linked chat.

- [ ] **Step 1: Write the failing tests:**
  - `unlinkKeepsUndispatchedQuestionForNextChat`: queue for A, unlink, link B → B claims it.
  - `unlinkReoffersDispatchedUnansweredQuestion`: A claims, unlink, link B → B claims it again.
  - `answeredQuestionIsNotReoffered`; `expiredQuestionIsNotReoffered` (original expiry kept).
  - `questionQueuedForOldChatAfterUnlinkIsClaimableByNewChat` (Review Focus 2).
  - `newChatAnswerIsAccepted`; `oldChatCannotAnswerWhileUnlinked` (`SESSION_NOT_SELECTED`);
    `returningChatAnswerCounts` (A→B→A, A answers its original copy).
  - `resumeAfterUnlinkDropsMovedQuestion` (D1 rule unchanged).
  - `recoveredSessionKeepsMovedQuestionClaimable` (rebuild from disk after the unlink).
  - `dispatchAttemptRecordsTarget`; `oldAttemptWithoutTargetStillAnswerable` (owner falls back to
    the queued target).
  - Keep `concurrentClaimsHaveOneWinner` and every existing claim/answer test.
- [ ] **Step 2: Run** `node --test src/session.test.ts src/recovery.test.ts`. Expect the new tests
  to FAIL.
- [ ] **Step 3: Implement.**
  - `onCommitted`: on `agent.unlinked.v1`, instead of clearing `unattemptedQuestions`, re-arm it
    with every question in `questionsById` queued after the latest resume and absent from
    `committedAnswers` (a resume still clears it).
  - `seedTaskState`: a question is claimable when it was queued after the latest resume, has no
    answer, and has no attempt after the latest unlink.
  - `claimQuestion`: drop the stored-target harness/session match; keep worktree, expiry and
    reservation. The control handler already proves the caller is the linked chat
    (`daemon.ts:1726-1731`). Record `target` on the attempt.
  - `answerQuestion`: the owner check passes when any attempt for that question targeted the
    caller (old attempts without `target` use the queued target); `attempt_seq` is the caller's
    latest attempt.
- [ ] **Step 4: Run** `npm test` and the repo's lint. Expect PASS.
- [ ] **Step 5: End-to-end on a disposable store:** link chat A, ask a question, unlink, attach
  chat B, let B work once; expect B to receive and answer the question, and the question's
  `answered.v1` to carry B's attempt seq.
- [ ] **Step 6: Commit** `feature: hand unanswered questions to the next linked chat`.

---

## PR B — Chat tab linking (client)

### Task 3: Link data and ChatLinkClient

**Files:**
- Modify: `Sources/SlipstreamCore/Captures.swift` (`CaptureBinding.harnessSessionID`)
- Create: `Sources/SlipstreamCore/LinkOutcome.swift`
- Create: `SlipstreamViewer/Dependencies/ChatLinkClient.swift`
- Test: `Tests/SlipstreamCoreTests/CapturesDecodingTests.swift`,
  `Tests/SlipstreamCoreTests/LinkOutcomeTests.swift`,
  `SlipstreamViewerTests/Dependencies/ChatLinkClientTests.swift`

**Interfaces:**
- Consumes: `DaemonClient.discover`/`listCaptures`; `AgentEnvironmentClient.resolve`;
  `WorkspaceClient.run(_:_:environment:)` (already internal, `WorkspaceClient.swift:105`).
- Produces:

  ```swift
  // CaptureBinding
  public var harnessSessionID: String?
  public func isLinked(toChat id: UUID) -> Bool   // id matches, state .connected/.setupPending
  // LinkOutcome, LinkRefusal exactly as models.md
  extension LinkOutcome {
    public static func attach(exitCode: Int32, output: String) -> LinkOutcome
    public static func unlink(exitCode: Int32, output: String) -> LinkOutcome
  }
  struct ChatLinkClient: Sendable {
    var link: @Sendable (_ folder: String, _ tabID: UUID, _ replacing: String?) async -> LinkOutcome
    var unlink: @Sendable (_ folder: String, _ replacing: String) async -> LinkOutcome
  }
  extension DependencyValues { var chatLink: ChatLinkClient }
  ```

  The live value builds both from a testable core, `ChatLinkOperations(captures:run:)`, that
  takes "read captures for a folder" and "run slipstream with arguments and environment" as
  closures, and serializes every call through one actor.

- [ ] **Step 1: Write the failing tests**
  - `bindingDecodesChatID`, `bindingWithoutChatIDStillDecodes` (`nil`, row kept).
  - `isLinkedMatchesUUIDCaseInsensitively`, `isLinkedFalseWhenUnlinkedWithOldID`,
    `isLinkedTrueWhenSetupPending`.
  - One test per row of the endpoints.md outcome table, using that row's exact text:
    `attachSuccess`, `attachTranscriptStillBeingWrittenRetries`,
    `attachDaemonHeadNotCompleteRetries`, `attachExit3Retries`, `attachSlotsFull`,
    `attachBindingExistsSkips`, `attachOldCLIVersionRefusal`, `attachOldDaemonVersionRefusal`,
    `attachSetupIncompleteKeepsMessage`, `attachOtherKeepsLastSlipstreamLine`.
  - `unlinkOnline`, `unlinkAlreadyUnlinked`, `unlinkOfflineExit0`, `unlinkErrorIsOther`.
  - `attachOutputCutToLast64KiBStillParses` (leading lines missing).
  - Against `ChatLinkOperations` with fake closures: `autoLinkSkipsWhenLiveBindingExists`,
    `autoLinkAttachesWhenUnlinked`, `moveSkipsWhenGenerationChanged`, `moveUnlinksThenAttaches`
    (records `unlink --session <capture id>` then `attach <folder>`),
    `moveWithNothingLiveOnlyAttaches`, `unlinkRefusedDoesNotAttach`, `attachEnvironment`
    (exactly the Global Constraints variables; `CODEX_THREAD_ID` and `CONDUCTOR_SESSION_ID`
    absent; session id lowercased), `operationsRunOneAtATime` (the second's capture read happens
    after the first's last run), `secondOperationSeesFirstResult` (two auto-links → one attach,
    one `.skipped`).
- [ ] **Step 2: Run** `swift test --filter "CapturesDecodingTests|LinkOutcomeTests"` and the app
  test target filtered to `ChatLinkClientTests`. Expect FAIL.
- [ ] **Step 3: Implement.** `decodeIfPresent` for the chat id. Parse exit code first, then the
  last `slipstream: …` line; the message kept is that line without the `slipstream: ` prefix.
  Capture lookup matches `normalizedFolder(root) == folder`. The live `run` reuses
  `WorkspaceClient`'s `slipstream` resolution and 64 KiB tail. `testValue` is unimplemented.
- [ ] **Step 4: Run** `swift test` and the app test target. Expect PASS.
- [ ] **Step 5: Commit** `chore: read which chat is linked and run link operations one at a time`.

### Task 4: Link rules in the chat models

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift`
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift`
- Test: `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift`

**Interfaces:**
- Consumes: Task 3 `chatLink`, `CaptureBinding.isLinked(toChat:)`.
- Produces:

  ```swift
  // ChatPageModel
  func capturesArrived(_ captures: [CaptureSummary])        // called by ChangeStreamPageModel after every refresh
  var onLinkChanged: () async -> Void                        // set by ChangeStreamPageModel; refreshes captures
  func linkIcon(for tab: ChatTabModel) -> ChatLinkIcon?      // .connected, .waiting, .failed
  func linkHoverTitle(for tab: ChatTabModel) -> String?
  func linkHoverText(for tab: ChatTabModel) -> String?
  var outsideChatText: String?                               // "Stream: outside chat"
  var isAppTabLinked: Bool { get }                           // for the Ask notice
  func isConnectEnabled(_ tab: ChatTabModel) -> Bool
  let connectText, closeTabText, connectDisabledText
  func connectTapped(_ id: UUID) async
  // ChatTabModel
  var hasSentMessage: Bool { get }                           // history non-empty or a turn has ended
  var reloadWhenIdle: Bool
  ```

  `linkFailures: [UUID: LinkRefusal]` is private.

- [ ] **Step 1: Write the failing tests** (rules exactly as models.md "ChatPageModel.linkFailures"
  and "ChatTabModel.reloadWhenIdle"; `chatLink` overridden):
  - Derivation: `linkedTabShowsConnectedIcon`, `setupPendingShowsWaitingIcon`,
    `unlinkedWithOldIDShowsNoIcon`, `outsideChatShowsLabelAndNoIcon`,
    `firstTabWaitsWhenNothingLinkedAndNoMessage`, `unavailableAndUnknownShowNothing`.
  - Auto-link: `windowOpenLinksFirstTabWithMessage` (strip order, skips a tab without a message),
    `turnEndingWhileNothingLinkedLinks`, `turnEndingWhileLinkedDoesNothing`,
    `ordinaryRefreshNeverStartsAutoLink`, `retryLaterWaitsForNextTurnEnd`.
  - Connect to Stream: `connectPassesSeenGeneration`, `connectOverOutsideChatPullsItIn`,
    `connectDisabledWithoutMessage`, `skippedShowsRefreshedState`.
  - Closing: `closingLinkedTabMovesLinkToFirstTabWithMessage`,
    `closingLinkedTabWithNoOtherMessageUnlinks`, `closingUnlinkedTabChangesNothing`.
  - Failures: `refusalShowsFailedIconWithReasonText` (one per `LinkRefusal` copy),
    `refusalClearsWhenTabReadsConnected`, `setupFailureSurvivesLinkedRefresh`,
    `failureClearsOnRetryAndOnClose`, `attachFailureAfterUnlinkLeavesUnlinkedWithFailure`,
    `everyOutcomeRefreshesCaptures`.
  - Reload: `linkedIdleTabRestarts`, `linkedWhileWorkingRestartsAfterTurnEnds`,
    `nextSendResumes` (launch mode `.resume`).
- [ ] **Step 2: Run** `ChatPageTests`. Expect FAIL.
- [ ] **Step 3: Implement.** The reload uses the existing `shutdown()` (the same path
  `choiceSelected` uses, `ChatTabModel.swift:255-262`); `send` already awaits a retirement in
  progress (`ChatTabModel.swift:190`). The folder's binding comes only from `capturesArrived`; the
  model never reads captures itself.
- [ ] **Step 4: Run** `ChatPageTests`, then the full app test target (touched-area rule: closing,
  tabs and send have existing tests). Expect PASS.
- [ ] **Step 5: Commit** `feature: link a chat tab to the stream automatically and on request`.

### Task 5: Wire it to the window, the Ask notices and the tab strip

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`
  (call `chat.capturesArrived` from `captureResultArrived`; set `chat.onLinkChanged` to
  `loadSessions()`)
- Modify: `SlipstreamViewer/Models/CaptureStatus.swift` (`askNotice` gains the app-tab cases)
- Modify: `SlipstreamViewer/Views/Pages/AskAgentPage/AskAgentPageModel.swift` (passes
  `isAppTabLinked`)
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift` (tab icon, hover, context
  menu, outside label)
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`,
  `SlipstreamViewerTests/Views/Pages/AskAgentPage/AskAgentPageTests.swift`

**Interfaces:**
- Consumes: Task 4 `capturesArrived`, `onLinkChanged`, `isAppTabLinked`, view properties.
- Produces: `CaptureStatus.askNotice(agentConnection:isAppTabLinked:)`. Nothing linked → the
  "nothing connected" copy. Linked to an app tab but not yet `connected` → the "tab waiting" copy.
  Linked to an outside chat → today's wording. Every other branch is unchanged.

- [ ] **Step 1: Write the failing tests**
  - `capturesReachChatAfterEveryRefresh`; `linkChangeRefreshesCaptures`.
  - `askNoticeNothingConnected`, `askNoticeTabWaiting`, `askNoticeOutsideChatKeepsTodayWording`,
    `askNoticeConnectedTabIsNil`.
- [ ] **Step 2: Run.** Expect FAIL.
- [ ] **Step 3: Implement** the model wiring, then the view: link icon beside the tab title,
  `.help` hover, `.contextMenu` with Connect to Stream (disabled with the hint) and Close Tab, the
  outside label at the strip's right end. Views bind to Task 4 properties only.
- [ ] **Step 4: Run** the full app test target. Expect PASS.
- [ ] **Step 5: Manual QA** on a disposable daemon running PR D: every Chat console and Ask panel
  state in screens.md, compared with its PNG.
- [ ] **Step 6: Commit** `feature: show which chat tab is linked and let the user move it`.

---

## PR C — Re-sending status (client)

### Task 6: Mark questions moved by an unlink

**Files:**
- Modify: `Sources/SlipstreamCore/Events.swift` (`EventPayload.agentUnlinked`)
- Modify: `Sources/SlipstreamCore/QuestionThreads.swift`
- Modify: `SlipstreamViewer/Views/Pages/QuestionThreadPage/QuestionThreadPageModel.swift`
  (`unansweredText`, `captureChanged`)
- Test: `Tests/SlipstreamCoreTests/DecodingTests.swift`,
  `Tests/SlipstreamCoreTests/QuestionThreadsTests.swift`,
  `SlipstreamViewerTests/Views/Pages/QuestionThreadPage/QuestionThreadPageTests.swift`

**Interfaces:**
- Produces (models.md "EventPayload", "QuestionTurn / QuestionThreads"):

  ```swift
  case agentUnlinked(AgentUnlinked)
  public struct AgentUnlinked: Equatable, Sendable { public var reason: String }
  // QuestionTurn
  public var isMoved: Bool
  // QuestionTurn.Status gains .resending
  ```

- [ ] **Step 1: Write the failing tests**
  - `decodesAgentUnlinked`; `unlinkEventAddsNoFeedRow` (no "Unsupported event" marker).
  - `unlinkMarksUnansweredTurnsResending` (dispatched and undispatched);
    `answeredTurnUnaffectedByUnlink`; `detachedAndArchivedChangeNothing`.
  - `dispatchAfterMoveReturnsToWaiting`.
  - `resumeAfterMoveIsNotDelivered` (the moved turn counts as undispatched again).
  - `lateAnswerAnswersMovedTurn`.
  - `resendingText`, `recordingRestartedKeepsTodayText`,
    `resendingCountsAsWaitingForUnreadAndFollowUps`.
  - `followUpUsesCurrentGeneration` (a later `captureChanged` replaces the cached generation);
    `inFlightFollowUpKeepsItsBody`.
- [ ] **Step 2: Run** `swift test --filter "DecodingTests|QuestionThreadsTests"` and
  `QuestionThreadPageTests`. Expect FAIL.
- [ ] **Step 3: Implement.** On `.agentUnlinked` with `reason == "unlinked"`, every unanswered,
  undropped turn sets `isMoved` and goes back into `undispatchedQuestionIDs`, mirroring the
  daemon. `.questionDispatchAttempted` clears `isMoved`. `captureChanged` assigns the current
  generation instead of only filling a `nil` one (`QuestionThreadPageModel.swift:153-155`).
- [ ] **Step 4: Run** `swift test` and the full app test target (touched-area rule: the fold and
  question thread have existing suites). Expect PASS.
- [ ] **Step 5: Manual QA** on a disposable daemon running PRs D and E with PR B's app: ask, move
  the link with Connect to Stream, watch "Re-sending…", get the answer from the new tab. Compare
  with the Question thread PNG.
- [ ] **Step 6: Commit** `feature: show when a question moves to a newly linked chat`.

---

## Spec acceptance (QA for PRs B and C)

On a disposable store, with PRs D and E's daemon:
1. New workspace: the first tab waits; after its first reply it links (amber), then connected
   after the agent works.
2. Ask a question; the linked tab answers it.
3. Second tab: right-click → Connect to Stream; the icon moves.
4. Close the linked tab; the link moves to the remaining tab with a message.
5. Link an outside chat with `slipstream attach` in a terminal; the strip shows "Stream: outside
   chat"; Connect to Stream on a tab pulls it in.
6. Ask, then move the link before it is answered: the thread shows "Re-sending…" and the new tab
   answers it. Repeat with the app closed during the move: the answer still arrives.
7. Fill all 10 slots from other workspaces; Connect to Stream shows "Couldn't connect" with the
   slots copy.

## Unresolved questions

None. The Ask notice for "nothing connected" and the dropped "Not delivered after a move" copy
were settled in Phase 7 (spec.md).
