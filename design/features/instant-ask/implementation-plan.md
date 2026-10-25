# Instant Ask Implementation Plan

> **For agentic workers:** this plan spans two repos, three stages and five PRs. Drive it with
> `orchestrate-feature`; each PR is implemented in a fresh session with
> superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use
> checkbox (`- [ ]`) syntax. The design folder lives in the **client** repo at
> `design/features/instant-ask/`; the daemon session reads it from there.

**Goal:** A question asked at a line is answered within seconds by a hidden, read-only copy of the
linked app chat tab. A change request from the thread goes to the real agent at once, and the
thread follows it to the agent's own report. Outside chats keep today's Ask.

**Architecture:** Stage 1 runs `claude -p --resume=<tab> --fork-session` as a one-shot process
(`AskForkClient`, on the existing `AgentProcessClient`) and records each answer with the daemon's
existing `record_question_exchange`. The fold, prompts and output parsing are pure
`SlipstreamCore` code. One app-wide `InstantAskModel` owns every copy run, recording and report.
Stage 2 adds one daemon verb and event for a request's progress, recorded in any order and folded
by status precedence. Each tab now echoes user messages (`--replay-user-messages`); the tab skips
live echoes, since it already drew the message, and a relay's echo is how the app knows the agent
read it. Stage 3 moves "which app tab is linked" into the app (`AppChatLinks`), so app tabs stop
attaching to the daemon.

**Tech Stack:** Swift 6 (complete strict concurrency, warnings are errors), SwiftUI on macOS 15,
swift-dependencies, swift-identified-collections, swift-sharing, Swift Testing, CustomDump,
swift-clocks (`TestClock`), XcodeGen. Daemon: TypeScript on Node, `node --test`, `tsc`.

**Spec:** [spec.md](./spec.md) is the source of truth: scope, acceptance criteria, Phase 5 and
Phase 7 dispositions and D1–D9. The contracts to implement are linked here, not copied:
[screens.md](./screens.md) (every state and all copy), [models.md](./models.md) (types, fold rules,
status precedence, lifetimes) and [endpoints.md](./endpoints.md) (daemon verbs, the copy's command
line, schemas, prompt templates, failure mapping, stage-2 probes).

**Base commits:** client `develop` @ `9b90323`; daemon `develop` @ `feffc30`. The local checkout
at `~/playola/slipstream` is stale (`5fb38ce`, before `record_question_exchange`). Daemon sessions
must start from a fresh `origin/develop`.

**Required skills for every client session** (project `CLAUDE.md`):
- `pfw-observable-models` for `InstantAskModel` and the `*PageModel`s
- `pfw-dependencies` for `AskForkClient` and `QuestionClient`
- `pfw-testing` and `pfw-custom-dump` for tests
- `pfw-identified-collections` for `IdentifiedArrayOf`
- `pfw-modern-swiftui` for views
- `pfw-issue-reporting` for `reportIssue`

Subagents invoke them too. The daemon session follows the daemon repo's `CLAUDE.md`/`AGENTS.md`.

## Global Constraints

- **Safety:** never point anything at the real `~/.slipstream`. QA uses `SLIPSTREAM_STORE` with a
  disposable daemon (`npm run qa:daemon` in the daemon repo). Claude probes and evals use a
  throwaway `CLAUDE_CONFIG_DIR` (for example `/tmp/ss-instant-ask/claude-config`) and a scratch
  repo. Never print or persist the daemon bearer token. Never commit captured data
  (`.slipstream/`, `sessions/`, `blobs/`, real `*.jsonl` transcripts). Test fixtures are
  hand-written minimal JSONL.
- **The copy is invisible.** No UI text, log line shown to the user, or prompt-visible reply
  mentions a copy, fork, read-only mode or Slipstream. Agent lines are in the agent's voice.
- **One writer.** The copy runs with exactly `Read`, `Grep`, `Glob`. Every edit is made by the
  real agent in its own tab.
- **The copy's command line** is exactly endpoints.md "CLI claude -p" (working directory: the tab's
  folder; environment: `AgentEnvironment.variables`). The prompt goes on stdin, and stdin is then
  closed.
- **Process limits:** 120 seconds from launch to exit. The copy runs on `AgentProcessClient`, so
  its limits are the runner's: each stdout line ≤ 1 MiB (`.overflow` past that), stderr kept only
  as a tail that is never shown or saved, and `shutdown` (close stdin, SIGTERM to the process
  group, SIGKILL 3 seconds later, reaped).
- **Ids:** every `request_id`, `relay_id`, `parent_session_id` and `chat_session_id` the app sends
  is a lowercase UUID string.
- **Control request size:** every encoded control line is checked against the socket's 1 MiB cap
  before sending, in the one encoder both question requests and relay updates use.
- **Copy is verbatim from screens.md:**

  | Use | Text |
  |---|---|
  | Answering | "AGENT · thinking…" (Send reply disabled) |
  | Couldn't answer | "Couldn't get an answer · <reason>", **Try again**. Reasons: "no reply within 120 seconds", "the chat couldn't be reached", "the reply couldn't be read", "it couldn't be saved" |
  | Pending root bar | "Waiting", then "Not delivered" after a failure (existing labels) |
  | Sent | "Sent · 14:02 · the agent will read this after its current step" |
  | Picked up | "Picked up · 14:03" |
  | Working | "Working · changes seen in greet.py" (one line per file) |
  | Done | "Done · sent 14:02 · picked up 14:03 · greet.py" |
  | Not done yet | "Not done yet · checking again when the agent's next turn ends" |
  | Not delivered | "Not delivered · the chat stopped before the agent read this", **Send again** |
  | Delivery unknown | "Delivery unknown · the app restarted before delivery was confirmed", **Send again** |
  | Couldn't check | "Couldn't check whether this was done · 14:05", **Check again** (disabled while a check runs) |
  | Console waiting | "Waiting · the agent will read this after its current step" |
  | Console not delivered | "Not delivered · the chat stopped before the agent read this" |
  | Console tag | "From Ask · greet.py:3-5" |
  | Question bar | "Working" (amber), "Done" (green) |
  | Ask, nothing connected | "No chat is connected yet. Send a message in a chat tab to connect it." (unchanged) |
  | Capture strip, app link | "Linked — changes are possibly the agent's" (unchanged wording) |

- Times on lines use the app's existing time formatting and the `@Dependency` time zone.
- Outside chats (Conductor, terminal) keep today's `ask` path, notices and thread copy, unchanged.
  A recorded thread never falls back to `ask`, and a hook thread never takes a recorded follow-up.
- Views use only `DesignTokens`. Sizes and colours come from this feature's `exports/screens/*.json`
  and `exports/design-tokens.json`.
- Tests never spawn `claude` or `slipstream`, never read `~/.claude`, never sleep. Time is a
  `TestClock`; ordering uses `.mainSerialExecutor`. `AskForkClient` tests override
  `agentProcess` with a fake handle (as `AgentFake` does); the one new runner test uses
  `SlipstreamViewerTests/Support/fake-claude.sh` in `ProcessIntegrationTests`.
- Client checks: `swift test` and
  `xcodebuild -scheme SlipstreamViewer -destination 'platform=macOS' test` (warnings are errors).
  Run `xcodegen generate` after adding files. Daemon checks: `npm test` and `npm run typecheck`.

## Review Focus

1. **Every ordinary chat message is now echoed.** Stage 2 turns on `--replay-user-messages` for
   every tab. A message the user types must still appear exactly once: live (the tab already drew
   it, and echoes are never drawn) and after a reload from the transcript, a mid-turn relay
   included. Covered by Task 10, `liveEchoIsNotDrawnAgain`, `reloadDrawsEachMessageOnce` and
   `reloadDrawsMidTurnRelayInsideItsTurn`.
2. **The echo arrives before the write returns.** An idle tab starts its turn at once, so the echo
   can be read before `relay(_:)` finishes. That must still count as Picked up, not leave the
   request Sent. Covered by Task 11, `echoBeforeWriteReturnsCountsAsPickup`.
3. **The thread's chat went away between the answer and the next message.** The tab can be closed,
   or relaunched (model change, Stop and retire). A follow-up or change request must go to the
   folder's linked tab. An echo only counts for the launch its relay was written to; a retired
   launch still resolves its own relays but never touches the current turn. Covered by Task 5,
   `followUpAfterThreadChatClosedUsesLinkedTab`, and Task 11, `echoFromEarlierLaunchIsIgnored`
   and `stopDeadlineRetireStillResolvesRelay`.
4. **The capture is deleted, or the app quits, while a copy runs.** Nothing may publish
   afterwards, and the process must be reaped, not orphaned. Covered by Task 5,
   `captureDeletedCancelsRunAndPublishesNothing` and `quitCancelsAndWaitsForRunningCopies`.
5. **Two questions in a row.** A second question on the same lines while the first is Answering
   gets its own temporary bar and its own thread. A follow-up can't be sent while the thread is
   Answering. Covered by Task 6, `twoNewQuestionsShowTwoPendingBars` and
   `sendReplyDisabledWhileAnswering`.

## PR graph

| PR | Stage | Repo | Tasks | Depends on | Suggested worker | Red → Green | QA |
|---|---|---|---|---|---|---|---|
| 1 · Instant answers | 1 | client | 1–6 | — | Claude `sonnet-5-1m`, high | `QuestionThreadsTests`, `QuestionsTests`, `ControlTransportTests`, `AskPromptTests`, `ForkOutputTests`, `AskForkClientTests`, `ProcessIntegrationTests`, `InstantAskModelTests`, `AskAgentPageTests`, `QuestionThreadPageTests`, `ChangeStreamPageTests`, `CaptureStatusTests` | probe results recorded in spec.md; stage 1 acceptance |
| 2 · Change request records | 2 | daemon | 7–8 | — | Claude `sonnet-5-1m`, high | `question-exchange-session`, new `question-relay-session`, `question-schema`, `daemon`, `recovery` tests | verbs on a disposable store |
| 3 · Chat tabs accept relayed messages | 2 | client | 9–11 | — (Task 9 gates 10–11) | Claude `sonnet-5-1m`, high | `ClaudeInvocationTests`, `TranscriptProjectionTests`, `ChatPageTests` | ordinary chat unchanged; relay echo |
| 4 · Change requests and progress | 2 | client | 12–14 | 1, 2, 3 | Claude `opus-4-8-1m`, high (restarts, retries, report reruns) | `QuestionThreadsTests`, `QuestionsTests`, `ControlTransportTests`, `AskPromptTests`, `ForkOutputTests`, `InstantAskModelTests`, page tests | stage 2 acceptance |
| 5 · App tabs stop attaching | 3 | client | 15–16 | 4, **and Brian's go-ahead after stages 1–2 have worked in real use** (spec scope 9) | Claude `sonnet-5-1m`, high | `ChatPageTests`, `CaptureStatusTests`, `AppChatLinksTests` | stage 3 acceptance |

PRs 1, 2 and 3 can run in parallel. Within stage 2 the daemon contract (PR 2) merges before the
client consumer (PR 4). PR 1 keeps one commit per task and stops at Task 4's probe gate if it
fails. Every PR targets `develop`. Titles follow the PR-title rules:
1 `feature: answer questions about a line right away, without waiting for the chat`;
2 `feature: keep a record of change requests sent from a question and how they went`;
3 `chore: let a chat tab take a message while it is working and tell when it was read`;
4 `feature: send change requests from a question to the agent and show their progress`;
5 `feature: keep Slipstream's setup messages out of chats run in the app`.

---

# Stage 1 — the copy answers

## PR 1 — Instant answers (client)

### Task 1: Decode recorded exchanges and fold them into threads

**Files:**
- Modify: `Sources/SlipstreamCore/Events.swift` (`EventPayload`, `rowlessTypes` :158)
- Modify: `Sources/SlipstreamCore/QuestionThreads.swift`
- Test: `Tests/SlipstreamCoreTests/DecodingTests.swift`, `Tests/SlipstreamCoreTests/QuestionThreadsTests.swift`

**Interfaces:**
- Produces (models.md "EventPayload", "QuestionExchangeRecorded", "QuestionThread / QuestionTurn /
  QuestionThreads"):

  ```swift
  case questionExchangeRecorded(QuestionExchangeRecorded)
  public struct QuestionExchangeRecorded: Equatable, Sendable {
    public var questionID, requestID, text, answerText, chatSessionID: String
    public var source: QuestionSource
    public var replyToQuestionID: String?
    public var recordedAtMs: Int64
  }
  public enum QuestionThreadLink: Equatable, Sendable { case hook, recorded(chatSessionID: String) }
  // QuestionThread
  public var link: QuestionThreadLink
  ```

  `relay` is added in Task 12, not here.

- [ ] **Step 1: Write the failing tests**
  - `decodesExchangeRecorded` against the daemon schema's example data, with `selected_text`.
    `answerText` is kept whole: a 20 000-byte answer decodes untrimmed.
  - `exchangeRecordedAddsNoFeedRow` (no "Unsupported event" marker).
  - `recordedRootStartsRecordedThread` (one answered turn, `answer.seq` = event seq,
    `link` = `.recorded(chatSessionID:)` with `conversation.parent_session_id`).
  - `recordedFollowUpAppendsAnsweredTurn`, `recordedFollowUpWithUnknownParentIgnored`,
    `recordedFollowUpOnHookThreadIgnored`.
  - `resumeAndUnlinkLeaveRecordedTurnsAlone` (never dropped, moved or re-sending).
  - `hookThreadLinkIsHook` (existing threads unchanged).
- [ ] **Step 2: Run** `swift test --filter "DecodingTests|QuestionThreadsTests"`. Expect FAIL.
- [ ] **Step 3: Implement.** Decode `context` with the same decoder `QuestionQueued` uses. Read only
  `parent_session_id` from `conversation`. A thread's link is set by its root and never changes.
- [ ] **Step 4: Run** `swift test`. Expect PASS (touched-area rule: all 27 existing
  `QuestionThreadsTests` stay green).
- [ ] **Step 5: Commit** `chore: read answers the app recorded itself into question threads`.

### Task 2: Send record_question_exchange

**Files:**
- Modify: `Sources/SlipstreamCore/Questions.swift` (`QuestionRequest`, new `ExchangeAcknowledgment`)
- Modify: `Sources/SlipstreamCore/ControlTransport.swift`
- Modify: `SlipstreamViewer/Dependencies/QuestionClient.swift`
- Modify: existing `QuestionRequest(...)` call sites (`AskAgentPageModel`, `QuestionThreadPageModel`)
- Test: `Tests/SlipstreamCoreTests/QuestionsTests.swift`, `Tests/SlipstreamCoreTests/ControlTransportTests.swift`

**Interfaces:**
- Produces (models.md "QuestionContext / QuestionRequest", "QuestionClient / ControlTransport"):

  ```swift
  public enum QuestionVerb: Equatable, Sendable {
    case ask(bindingGeneration: String)
    case recordExchange(answerText: String, conversation: ExchangeConversation)
  }
  public struct ExchangeConversation: Equatable, Sendable { public var parentSessionID, forkSessionID: String }
  public struct ExchangeAcknowledgment: Equatable, Sendable {
    public var sessionID, requestID, questionID: String; public var seq: Seq; public var duplicate: Bool
  }
  // QuestionRequest.verb replaces bindingGeneration
  // ControlTransport
  public func recordExchange(_ request: QuestionRequest) async throws -> ExchangeAcknowledgment
  // QuestionClient
  var record: @Sendable (QuestionRequest) async throws -> ExchangeAcknowledgment
  ```

  Task 12 adds `relay: ExchangeRelay?` to `.recordExchange`.

- [ ] **Step 1: Write the failing tests**
  - `encodesRecordExchangeExactly`: endpoints.md's request body, key for key; `harness` is
    `"claude-code"`; ids lowercased.
  - `encodesAskUnchanged` (today's bytes, so outside chats are untouched).
  - `recordExchangeRefusesOverOneMiB` (the shared encoder's check; relay updates reuse it).
  - `decodesExchangeAcknowledgment` from endpoints.md's real reply; `ackWithOtherRequestIDIsMalformed`;
    `ackWithOtherSessionIDIsMalformed`; `flatErrorReplyDecodes` (`{v, ok: false, code, message}`,
    `STORAGE_UNAVAILABLE` and `INVALID_CONTEXT`).
- [ ] **Step 2: Run** `swift test --filter "QuestionsTests|ControlTransportTests"`. Expect FAIL.
- [ ] **Step 3: Implement.** One `QuestionRequest` type, so both verbs share `encoded()`'s text and
  context checks. `encoded()` adds no answer-text check: a blank reply is caught by `ForkOutput`
  before anything is recorded, and the daemon refuses one anyway. `recordExchange` goes over the
  private `exchange`, like `ask`. A mismatched ack throws the same malformed-reply error `ask` uses.
- [ ] **Step 4: Run** `swift test` and the app test target. Expect PASS.
- [ ] **Step 5: Commit** `chore: let the app record a question together with its answer`.

### Task 3: Prompts, schemas and the copy's output

**Files:**
- Create: `Sources/SlipstreamCore/AskPrompt.swift`
- Create: `Sources/SlipstreamCore/ForkOutput.swift`
- Modify: `Sources/SlipstreamCore/ClaudeInvocation.swift` (`forkArguments`)
- Test: `Tests/SlipstreamCoreTests/AskPromptTests.swift`, `Tests/SlipstreamCoreTests/ForkOutputTests.swift`,
  `Tests/SlipstreamCoreTests/ClaudeInvocationTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum AskPrompt {
    public struct Exchange: Equatable, Sendable { public var question, answer: String }
    public static func answer(source: QuestionSource, earlier: [Exchange], words: String, allowsChangeRequests: Bool) -> String
    public static func answerSchema(allowsChangeRequests: Bool) -> String   // endpoints.md stage 1 / stage 2
  }
  public enum AskForkKind: Equatable, Sendable { case answer(allowsChangeRequests: Bool) }
  public enum AskForkResult: Equatable, Sendable {
    case answer(forkSessionID: String, reply: String, isChangeRequest: Bool)
  }
  public enum AskForkError: Error, Equatable, Sendable { case timedOut, unavailable, badReply }
  public struct ForkOutput {
    public init(kind: AskForkKind)
    public mutating func read(_ line: Data) throws(AskForkError) -> AskForkResult?   // non-nil on the result line
  }
  extension ClaudeInvocation {
    public static func forkArguments(parentSessionID: UUID, model: String, effort: ChatEffort, schema: String) -> [String]
  }
  ```

  `AskForkKind`, `AskForkResult` and `AskForkError` live in `SlipstreamCore` so the parser can
  return them. models.md lists them under `AskForkClient`. Stage 2 adds the report pieces
  (`ReportOutcome` in Task 12; the `.report` kind and result, `AskPrompt.report` and
  `reportSchema` in Task 13); stage 1 has no consumer for them.

- [ ] **Step 1: Write the failing tests**
  - `answerPromptPutsRoleFirst`: starts with endpoints.md's answer instructions, then the snapshot
    block (labelled out of date, data not instructions; path, `line_start`–`line_end`, selected
    text), then each earlier exchange quoted in order, then the user's words.
  - `answerPromptStage1PointsChangesToChat` and `answerPromptStage2AsksForIsChangeRequest` (the
    two endpoints.md sentences, verbatim).
  - `schemasMatchEndpoints`: both answer schemas parse to endpoints.md's JSON.
  - `forkArgumentsExact`: endpoints.md's invocation in order; `--resume=` lowercased;
    `--json-schema` followed by the schema.
  - `ForkOutput`: `parsesAnswerResult`, `initWithExtraToolIsUnavailable`,
    `initWithMcpServerIsUnavailable`, `resultBeforeInitIsUnavailable`,
    `isErrorResultIsUnavailable`, `missingSessionIDIsBadReply`, `missingStructuredOutputIsBadReply`,
    `whitespaceReplyIsBadReply`, `extraSchemaFieldIsBadReply`, `unrelatedLinesAreIgnored`.
    Fixtures are hand-written lines in the shape Task 4's probe records.
- [ ] **Step 2: Run** `swift test --filter "AskPromptTests|ForkOutputTests|ClaudeInvocationTests"`.
  Expect FAIL.
- [ ] **Step 3: Implement.** Use endpoints.md's template wording. The final wording can change in
  Task 6's eval loop. `read` is fed one stdout line at a time, so a copy that isn't isolated is
  stopped at its first line: the `system`/`init` line must list exactly `Read`, `Grep`, `Glob` and
  no MCP servers, or `read` throws `unavailable`.
- [ ] **Step 4: Run** `swift test`. Expect PASS.
- [ ] **Step 5: Commit** `chore: build the hidden copy's prompt and read its reply`.

### Task 4: AskForkClient

**Files:**
- Create: `SlipstreamViewer/Dependencies/AskForkClient.swift`
- Modify: `SlipstreamViewer/Dependencies/AgentProcessClient.swift` (`AgentProcessHandle.closeInput`,
  :26–30, wired to `AgentProcessInput.close()` :300)
- Modify: `SlipstreamViewerTests/Support/fake-claude.sh` (a mode that echoes stdin's length after
  EOF), `SlipstreamViewerTests/Support/AgentFake.swift` (`closeInput` on the fake handle)
- Modify: `design/features/instant-ask/spec.md` (probe results, under "Probes during Phase 4")
- Test: `SlipstreamViewerTests/Dependencies/AskForkClientTests.swift`,
  `SlipstreamViewerTests/Dependencies/ProcessIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 3 `forkArguments`, `ForkOutput`; `AgentEnvironment`; `AgentProcessClient.launch`.
- Produces (models.md "AskForkClient"):

  ```swift
  struct AskForkRequest: Equatable, Sendable {
    let parentSessionID: UUID; let folder: String; let environment: AgentEnvironment
    let model: String; let effort: ChatEffort; let prompt: String; let kind: AskForkKind
  }
  struct AskForkClient: Sendable {
    var run: @Sendable (AskForkRequest) async throws(AskForkError) -> AskForkResult
  }
  extension DependencyValues { var askFork: AskForkClient }
  // AgentProcessHandle gains
  var closeInput: @Sendable () async -> Void
  ```

  The live value launches through `@Dependency(\.agentProcess)`, so it owns no `Process` of its
  own. `testValue` is unimplemented.

- [ ] **Step 1: Probe** (throwaway `CLAUDE_CONFIG_DIR`, scratch repo, Claude CLI 2.1.293+). Run the
  exact command from `forkArguments` against a chat with one finished turn, with the prompt on
  stdin and stdin closed. Record in spec.md: that `-p` read the prompt from stdin; the
  `system`/`init` line's field names for tools and MCP servers (adjust Task 3's parser and
  fixtures if they differ); the `result` line; the tab's transcript checksum before and after; and
  that the project's session count is unchanged. If stdin isn't read, stop and report back before
  building.
- [ ] **Step 2: Write the failing tests.**
  - `ProcessIntegrationTests.closeInputClosesStdin` (with `fake-claude.sh`: the fake prints the
    length it read once stdin reaches EOF).
  - `AskForkClientTests`, with `agentProcess` overridden by a fake handle and a `TestClock`:
    `launchesForkArgumentsInFolderWithEnvironment`; `writesPromptThenClosesInput`;
    `resultLineReturnsAnswerAndShutsDown`; `notIsolatedInitShutsDownAsUnavailable`;
    `exitBeforeResultIsUnavailable`; `cleanExitBeforeResultIsBadReply`; `overflowIsBadReply`;
    `launchFailureIsUnavailable`; `overTimeLimitShutsDownAsTimedOut` (the clock advanced 120 s);
    `cancellationShutsDown`.
- [ ] **Step 3: Run** the app test target filtered to `AskForkClientTests|ProcessIntegrationTests`.
  Expect FAIL.
- [ ] **Step 4: Implement.** `closeInput` calls the runner's existing `process.input.close()`.
  The live `run` launches `AgentEnvironment.claudePath` with `forkArguments` (the schema picked
  from `kind`), writes the prompt, calls `closeInput`, and feeds each `.line` to `ForkOutput`. It
  races the run against a 120-second continuous-clock sleep and calls the handle's `shutdown` on
  a result, an error, the time limit or cancellation. `.exited` before a result is `unavailable`
  (`badReply` if the status was 0). `.overflow` is `badReply`. The stderr tail is dropped.
- [ ] **Step 5: Run** the full app test target. Expect PASS.
- [ ] **Step 6: Commit** `chore: run a one-shot read-only copy of a chat and return its reply`.

### Task 5: InstantAskModel (answers)

**Files:**
- Create: `SlipstreamViewer/Models/InstantAskModel.swift`
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift` (`linkedAppTab(forFolder:)`)
- Modify: `SlipstreamViewer/App/SlipstreamViewerApp.swift` (hold `InstantAskModel(chat:)` beside
  `chat`), `SlipstreamViewer/App/AppDelegate.swift` (termination drain)
- Test: `SlipstreamViewerTests/Models/InstantAskModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4 (`QuestionClient.record`, `AskPrompt`, `AskForkClient`).
- Produces (models.md "InstantAskModel"; `PendingAsk` and `AskFailure` exactly as there):

  ```swift
  @MainActor @Observable final class InstantAskModel {
    init(chat: ChatPageModel)
    private(set) var pending: IdentifiedArrayOf<PendingAsk>
    func ask(_ question: InstantQuestion) async
    func tryAgainTapped(requestID: String) async
    func threadsFolded(sessionID: String, threads: IdentifiedArrayOf<QuestionThread>)
    func captureDeselected(_ sessionID: String)
    func captureDeleted(_ sessionID: String)
    func quitConfirmed() async                 // cancels everything and waits for copies to exit
  }
  struct InstantQuestion: Equatable, Sendable {
    let storeID, sessionID, folder: String
    let source: QuestionSource
    let replyToQuestionID: String?
    let threadChatSessionID: String?            // nil for a new question
    let earlier: [AskPrompt.Exchange]
    let text: String
  }
  // ChatPageModel
  func linkedAppTab(forFolder folder: String) -> ChatTabModel?   // the tab the binding names, if it is an app tab
  ```

- [ ] **Step 1: Write the failing tests** (`askFork`, `questions`, clock and uuid overridden):
  - `askRunsCopyThenRecordsWithSameRequestID` (`.answering` → `.recording` → `.recorded`; the
    recording carries the tab's id as `parentSessionID` and the copy's session id).
  - `newQuestionUsesLinkedTab`; `followUpUsesThreadChat`;
    `followUpAfterThreadChatClosedUsesLinkedTab` (Review Focus 3); `copyUsesTabModelAndEffort`.
  - `copyFailureMapsToReason`: one case per endpoints.md failure-mapping row.
  - `unknownRecordingOutcomeRetriesIdenticalBody` (three attempts over about 5 s on the
    `TestClock`, byte-identical requests); `exhaustedRetriesAreCouldntRecord`;
    `tryAgainOnCouldntRecordResendsSameRequest`; `refusedRecordingIsNotSaved`;
    `tryAgainOnCouldntAnswerRunsNewCopyWithNewRequestID`;
    `lateEventAfterErrorDropsPendingEntry`.
  - `recordedEntryLeavesWhenFoldHasQuestionID`; `recordedEntryLeavesWhenCaptureDeselected`.
  - `closingPanelOrDeselectingDoesNotCancel` (the answer arrives after reselecting).
  - `captureDeletedCancelsRunAndPublishesNothing`; `quitCancelsAndWaitsForRunningCopies`
    (Review Focus 4).
  - `staleCompletionPublishesNothing` (an entry removed mid-run; generation check).
- [ ] **Step 2: Run** the app test target filtered to `InstantAskModelTests`. Expect FAIL.
- [ ] **Step 3: Implement.** One task per pending entry, kept in a dictionary keyed by
  `request_id` with an attempt counter. Every completion checks store id, capture, `request_id`
  and attempt before publishing. Stage 1 always uses `AskForkKind.answer(allowsChangeRequests:
  false)`. `AppDelegate` awaits `chat.quitConfirmed()` and `instantAsk.quitConfirmed()` together.
  `linkedAppTab` uses the binding rule `ChatPageModel` already applies for its link icon.
- [ ] **Step 4: Run** the full app test target. Expect PASS.
- [ ] **Step 5: Commit** `feature: answer questions from a read-only copy of the linked chat`.

### Task 6: Route Ask, show pending answers, and tune the prompt

**Files:**
- Modify: `SlipstreamViewer/Models/CaptureStatus.swift` (`askNotice` app route, models.md order)
- Modify: `SlipstreamViewer/Views/Pages/AskAgentPage/AskAgentPageModel.swift` (`askTapped` routes)
- Modify: `SlipstreamViewer/Views/Pages/QuestionThreadPage/QuestionThreadPageModel.swift` and
  `QuestionThreadPageView.swift` (pending turn, Try again, follow-ups on recorded threads)
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift` and
  `ChangeStreamPageView.swift` (pass `InstantAskModel`; call `threadsFolded`, `captureDeselected`
  and `captureDeleted`; pending root bars)
- Create: `Sources/AskEvals/main.swift` (an `ask-evals` executable target in `Package.swift`,
  depending on `SlipstreamCore`; not linked into the app)
- Test: `SlipstreamViewerTests/Models/CaptureStatusTests.swift`,
  `SlipstreamViewerTests/Views/Pages/AskAgentPage/AskAgentPageTests.swift`,
  `SlipstreamViewerTests/Views/Pages/QuestionThreadPage/QuestionThreadPageTests.swift`,
  `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes: Task 5's `InstantAskModel`.
- Produces: `AskRoute` (`.app`, `.outside`, `.none`), decided once from the folder's
  binding and tabs. `askNotice` and `askTapped` both read that one value: the app route's notice
  is `nil` once the tab `hasSentMessage`; the outside route keeps today's checks. Pending roots show as `QuestionBar`s
  with `id` = `request_id`.

- [ ] **Step 1: Write the failing tests**
  - `askNoticeAppTabWithMessageIsReady`; `askNoticeAppTabSetupPendingIsStillReady`;
    `askNoticeAppTabWithoutMessageIsNothingConnected` (D8); `askNoticeOutsideChatUnchanged`.
  - `askTappedOnAppRouteUsesInstantAsk`; `askTappedOnOutsideRouteSendsAsk` (today's request
    bytes).
  - `pendingRootShowsWaitingBarAtLines`; `failedPendingRootShowsNotDelivered`;
    `barAndOpenPanelMoveToQuestionIDOnFold`; `twoNewQuestionsShowTwoPendingBars` (Review Focus 5).
  - `answeringTurnShowsThinking`; `sendReplyDisabledWhileAnswering`;
    `couldntAnswerShowsReasonAndTryAgain` (all four reasons, verbatim);
    `followUpOnRecordedThreadUsesInstantAsk` (`earlier` = every turn so far);
    `recordedThreadNeverSendsAsk`; `hookThreadKeepsTodayFollowUp`.
  - `quittingWithoutThreadsKeepsTodayFlow` (no regression in the chat quit confirmation).
- [ ] **Step 2: Run** the four suites. Expect FAIL.
- [ ] **Step 3: Implement** the model wiring, then the views. Views bind only to model properties.
  The thread view appends any `pending` entry for that thread as its last turn.
- [ ] **Step 4: Run** the full app test target. Expect PASS.
- [ ] **Step 5: Eval loop.** `swift run ask-evals` (needs a throwaway `CLAUDE_CONFIG_DIR`; refuses
  to run without one) builds each case's chat live in a fresh scratch repo from a few scripted
  user turns, one of them killed mid-tool-call, so no transcript is ever committed. It then runs the
  copy with the real `AskPrompt`, `forkArguments` and `ForkOutput`, and prints pass or fail
  per case. Stage 1 checks: the reply never mentions a copy, fork, read-only mode or Slipstream; an
  unfinished tool call isn't called interrupted; a change request gets a reply pointing to the
  chat, never "On it". Tune the templates until every case passes, and paste the output in the PR
  body.
- [ ] **Step 6: Manual QA** on a disposable daemon: stage 1 acceptance 1–10 (spec.md). Compare
  Answering and Couldn't answer with their PNGs. Check the tab's transcript checksum before and
  after.
- [ ] **Step 7: Commit** `feature: answer questions about a line right away, without waiting for the chat`.

---

# Stage 2 — change requests and progress

## PR 2 — Change request records (daemon, `playola-radio/slipstream`)

### Task 7: `relay` on record_question_exchange

**Files:**
- Modify: `schemas/slipstream.question.exchange_recorded.v1.json` (optional `relay`)
- Modify: `src/public-events.ts` (exchange data type)
- Modify: `src/session.ts` (`recordQuestionExchange` :1196; relay registry)
- Modify: `src/recovery.ts` (`exchange_recorded` case :319 seeds the relay registry)
- Test: `src/question-exchange-session.test.ts`, `src/question-schema.test.ts`, `src/recovery.test.ts`

**Interfaces:**
- Produces: `exchange_recorded.v1` data gains `relay?: { relay_id, chat_session_id }`, copied from
  the request. A per-capture relay registry (`relay_id` → question id). Task 8 reads it.

- [ ] **Step 1: Write the failing tests** (endpoints.md "Daemon tests to add (stage 2)"):
  `relayCopiedIntoEvent`, `reusedRelayIDRefused`, `retryWithChangedRelayIsRequestConflict` (relay
  dropped, and relay added, on a retry), `malformedRelayIsProtocol` (uppercase id, empty or
  257-character `chat_session_id`, a control character), `eventWithRelayValidatesAgainstSchema`,
  `relayRegistryRebuiltFromLog`.
- [ ] **Step 2: Run** `node --test src/question-exchange-session.test.ts src/question-schema.test.ts src/recovery.test.ts`.
  Expect FAIL.
- [ ] **Step 3: Implement.** `relay` is part of the idempotency body. Reserve the `relay_id`
  synchronously, with the request's `inflightExchanges` entry (:1201), before the append is
  awaited. Release the reservation if the append fails.
- [ ] **Step 4: Run** `npm test` and `npm run typecheck`. Expect PASS.
- [ ] **Step 5: Commit** `feature: let a recorded answer carry the change request it accepted`.

### Task 8: record_question_relay_update and its event

**Files:**
- Create: `schemas/slipstream.question.relay_updated.v1.json`
- Modify: `src/public-events.ts` (register the type; `subject` = `question/<question_id>`)
- Modify: `src/session.ts` (`recordQuestionRelayUpdate` beside `recordQuestionExchange`)
- Modify: `src/daemon.ts` (`recordRelayUpdate` beside `recordExchange` :1703; `case` beside :2054)
- Modify: `src/recovery.ts` (rebuild the relay registry and request ids)
- Modify: `docs/ask-agent/contract.md` (new section "Change requests from recorded exchanges",
  after "Client-recorded exchanges", covering `relay` on the exchange too)
- Test: create `src/question-relay-session.test.ts`; modify `src/daemon.test.ts`,
  `src/question-schema.test.ts`, `src/recovery.test.ts`

**Interfaces:**
- Consumes: Task 7's relay registry.
- Produces: the verb, reply and event exactly as endpoints.md "CONTROL
  record_question_relay_update" and "EVENT slipstream.question.relay_updated.v1".

- [ ] **Step 1: Write the failing tests** (endpoints.md "Tests to add"):
  - Accepted: `eachKindAccepted`, `sendAgainRegistersNewRelay`, `updatesInAnyOrderAreAppended`
    (for example `reported` before `picked_up`), `concurrentUpdatesForOneRelayBothRecorded`.
  - Refused (`INVALID_RELAY_UPDATE`): `askQuestionRefused`, `unknownQuestionRefused`,
    `unknownRelayRefused` (any kind but `sent`), `relayIDOfOtherQuestionRefused`,
    `reusedRelayIDOnSentRefused`.
  - `idempotentRetryReturnsDuplicate`, `differentBodyIsRequestConflict`,
    `idempotencySurvivesRestart`.
  - `whitespaceReportTextIsProtocol`.
  - `bodilessRequestIsProtocol` (the capability check: `v`, `verb`, `session_id` only).
  - `relayUpdatedValidatesAgainstSchema`; `relayUpdatedAddsNoDispatchOrQueueCount`;
    `watchOnlyCaptureAccepts`.
- [ ] **Step 2: Run** `node --test src/question-relay-session.test.ts src/daemon.test.ts`. Expect FAIL.
- [ ] **Step 3: Implement.** Follow the `recordQuestionExchange` pattern: validate, check
  idempotency, then append. There is no order check: the app folds the steps by status
  precedence. A `sent` reserves its new `relay_id` synchronously before the append is awaited, as
  Task 7 does. Request ids are scoped to this verb. The error codes are endpoints.md's list.
- [ ] **Step 4: Run** `npm test` and `npm run typecheck`. Expect PASS.
- [ ] **Step 5: End-to-end on a disposable store:** record an exchange with `relay`, then
  `picked_up` and `reported done` over `control.sock`; read them back from the event log and
  check each against its schema. Paste the commands in the PR body.
- [ ] **Step 6: Commit** `feature: record the progress of change requests sent from a question`.

---

## PR 3 — Chat tabs accept relayed messages (client)

### Task 9: Stage-2 probes (gate)

**Files:**
- Modify: `design/features/instant-ask/spec.md` (a "Probes before stage 2" section)

- [x] **Step 1: Probe** on Claude CLI 2.1.293 (throwaway config, scratch repo), with a tab launched
  using `ClaudeInvocation.arguments` plus `--replay-user-messages`. Confirm each item in endpoints.md
  "Stage 2's first task":
  1. The echo carries the `uuid` the app sent, for an idle send and for a mid-turn write, and it
     parses as a prompt line (`isPrompt`).
  2. A mid-turn write is echoed when the agent reads it, not when it is written.
  3. A message queued during a turn is read after Stop (interrupt), and after a normal turn end.
  4. A fork resumed right after a turn ends includes that turn.
- [x] **Step 2: Record** each result in spec.md. **Stop and report back** if (1) or (2) fails: the
  pickup design rests on them. If (3) shows an interrupt drops queued input, record that Stop
  joins exit as a not-delivered signal (spec acceptance stage 2 item 5), and amend models.md
  "ChatTabModel / ChatPageModel", before Task 11.
- [x] **Step 3: Commit** `chore: record how chat tabs echo and queue messages`.

**Result (2026-10-25):** (1) partly failed: the echo carries the sent `uuid` but is an `isReplay`
line with no `promptId`. (2)–(4) passed; (3) found that the process starts a turn by itself for a
queued message. Brian approved amendments A–C (spec.md decision log, "Task 9 probe amendments
(A–C)"); Tasks 10–11 below include them.

### Task 10: Message ids, echoes and the "From Ask" mark

**Files:**
- Modify: `Sources/SlipstreamCore/ClaudeInvocation.swift` (`userMessage(_:uuid:)`,
  `--replay-user-messages`)
- Modify: `Sources/SlipstreamCore/ClaudeLines.swift` (`AgentLine.echo`, `AgentLine.queuedMessage`)
- Modify: `Sources/SlipstreamCore/TranscriptProjection.swift` (`RelayMark`, `userSent`, `markRelay`,
  echoes skipped, queued messages in history)
- Test: `Tests/SlipstreamCoreTests/ClaudeInvocationTests.swift`,
  `Tests/SlipstreamCoreTests/TranscriptProjectionTests.swift`,
  `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift`

**Interfaces:**
- Produces (models.md "ClaudeInvocation", "TranscriptProjection"):

  ```swift
  public static func userMessage(_ text: String, uuid: UUID? = nil) -> Data   // only relays pass a uuid
  // AgentLine gains
  case echo(uuid: String)                // a `user` line with isReplay == true (A)
  case queuedMessage(text: String)       // a `queued_command` attachment (B)
  // TranscriptItem.Kind.userMessage gains
  public var relay: RelayMark?
  public struct RelayMark: Equatable, Sendable {
    public var label: String
    public var delivery: Delivery
    public enum Delivery: Equatable, Sendable { case waiting, pickedUp, notDelivered }
  }
  // TranscriptProjection (userSent :61 gains relay; a relay's item id is its relay id)
  public mutating func userSent(_ text: String, id: String, relay: RelayMark? = nil)
  public mutating func markRelay(id: String, delivery: RelayMark.Delivery)
  ```

- [ ] **Step 1: Write the failing tests**
  - `userMessageCarriesTopLevelUUIDWhenGiven` (endpoints.md's line, lowercased);
    `ordinaryUserMessageHasNoUUID` (today's bytes); `argumentsIncludeReplay`.
  - `liveEchoIsNotDrawnAgain` and `reloadDrawsEachMessageOnce` (Review Focus 1; regression tests
    now that echoes are their own line).
  - `reloadDrawsMidTurnRelayInsideItsTurn` (no extra footer, no tool interrupted);
    `liveQueuedCommandNotDrawn`.
  - `relayMarkShownAndUpdated`; `reloadedRelayShowsUnmarked`.
- [ ] **Step 2: Run** `swift test --filter "ClaudeInvocationTests|TranscriptProjectionTests"` and
  `ChatPageTests`. Expect FAIL.
- [ ] **Step 3: Implement.** A `user` line with `isReplay == true` decodes as `.echo`, which the
  projection never draws, live or in history: the tab drew the message when it was sent. Task 11
  reads its `uuid` for pickup. A `queued_command` attachment decodes as `.queuedMessage`; history
  draws it unmarked at its place in the turn (not a turn boundary), `apply` ignores it. A reload
  draws prompts from the transcript as today, so a reloaded relay shows unmarked.
  `command_lifecycle` lines stay `.ignored`. This reverses the chat-console rule against
  `--replay-user-messages` (`design/features/chat-console/implementation-plan.md:47`); never
  drawing echoes is what keeps that rule's concern (messages drawn twice) covered. Say so in the
  PR body.
- [ ] **Step 4: Run** `swift test` and the full app test target (touched-area rule: every chat
  console test). Expect PASS.
- [ ] **Step 5: Commit** `chore: let chat tabs echo messages without drawing them twice`.

### Task 11: ChatTabModel.relay and delivery signals

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift`
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift` (`turnEnded` :434 forwards
  the tab id; relay deliveries forwarded)
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift` (the mark and its line)
- Test: `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift` (with `AgentFake`)

**Interfaces:**
- Consumes: Task 10.
- Produces:

  ```swift
  struct AskRelayMessage: Equatable, Sendable { let relayID: UUID; let text: String; let label: String }
  enum RelayDelivery: Equatable, Sendable { case pickedUp(relayID: UUID), exitedUnread(relayID: UUID) }
  // ChatTabModel
  func relay(_ message: AskRelayMessage) async throws
  // ChatPageModel
  var onTabTurnEnded: (UUID) -> Void        // set by InstantAskModel
  var onRelayDelivery: (UUID, RelayDelivery) -> Void
  ```

- [ ] **Step 1: Write the failing tests**
  - `relayWhileIdleStartsTurnWithoutTouchingDraft`; `relayMidTurnWritesNow`;
    `relayInsertsWaitingMark`.
  - `echoSetsPickedUpAndReports`; `echoBeforeWriteReturnsCountsAsPickup` (Review Focus 2);
    `duplicateEchoChangesNothing`; `echoFromEarlierLaunchIsIgnored` (Review Focus 3).
  - `exitAfterStdoutEOFWithoutEchoIsNotDelivered`; `turnEndWithoutEchoStaysWaiting`;
    `stopWithoutEchoStaysWaiting`.
  - `turnEndForwardsTabID`.
  - `ordinarySendStillBlockedMidTurn` (today's rule for the user's own sends is unchanged).
  - Turns the process starts by itself (C): `queuedRelayAfterStopRunsAsItsOwnTurn`,
    `queuedRelayAfterTurnEndRunsAsItsOwnTurn`, `sendRacingSelfStartedTurnKeepsTurnsInStep`,
    `failedWriteDoesNotClearSelfStartedTurn`, `stopDeadlineRetireStillResolvesRelay`,
    `reloadWhenIdleWaitsForUnreadRelay`, `pickupPublishedBeforeTurnEnded`.
- [ ] **Step 2: Run** `ChatPageTests`. Expect FAIL.
- [ ] **Step 3: Implement.** The tab tracks unread relay ids per process launch. An echo whose
  `uuid` (lowercased) is unread in its launch is pickup, reported at once. The launch's exit path
  checks them only after its event stream has ended (stdout read to EOF, or `outputGrace` after
  the exit: accepted, see spec.md). An echo while no turn is running starts a fresh turn (new id,
  Stop not pressed, the normal turn-start housekeeping); its `result` ends it with a footer and
  `onTabTurnEnded` fires once, stopped or failed endings included. A retired launch keeps reading
  only to resolve its unread relays and never changes the current turn or screen.
  `reloadWhenIdle` waits for the launch's unread relays to resolve. A failed write in `send()`
  doesn't clear a turn an echo has claimed.
- [ ] **Step 4: Run** the full app test target. Expect PASS (all 128+ `ChatPageTests`).
- [ ] **Step 5: Manual QA** (throwaway config): ordinary chat unchanged, every message once, before
  and after a relaunch. A relay written mid-turn shows Waiting, then Picked up. Compare with the
  chat console PNGs.
- [ ] **Step 6: Commit** `chore: let a chat tab take a message while it is working and tell when it was read`.

---

## PR 4 — Change requests and progress (client)

### Task 12: Relay events, the relay fold and the new requests

**Files:**
- Modify: `Sources/SlipstreamCore/Events.swift` (`.questionRelayUpdated`, `relay` on the exchange)
- Modify: `Sources/SlipstreamCore/QuestionThreads.swift` (`QuestionTurn.relays`, `QuestionRelay`)
- Modify: `Sources/SlipstreamCore/Questions.swift` (`ExchangeRelay`, `QuestionRelayUpdateRequest`,
  `RelayAcknowledgment`)
- Modify: `Sources/SlipstreamCore/ControlTransport.swift`, `SlipstreamViewer/Dependencies/QuestionClient.swift`
- Test: `Tests/SlipstreamCoreTests/DecodingTests.swift`, `QuestionThreadsTests.swift`,
  `QuestionsTests.swift`, `ControlTransportTests.swift`

**Interfaces:**
- Produces (models.md "QuestionRelayUpdated", "QuestionRelay", "QuestionClient / ControlTransport"):

  ```swift
  case questionRelayUpdated(QuestionRelayUpdated)
  public enum ReportOutcome: String, Equatable, Sendable { case done, notDoneYet = "not_done_yet" }
  public enum RelayUpdate: Equatable, Sendable {
    case sent(chatSessionID: String), pickedUp, notDelivered, reported(ReportOutcome, text: String)
  }
  public struct ExchangeRelay: Equatable, Sendable { public var relayID, chatSessionID: String }
  // QuestionVerb.recordExchange gains relay: ExchangeRelay?
  public struct QuestionRelay: Identifiable, Equatable, Sendable { … models.md fields … }
  public enum QuestionRelayStatus: Equatable, Sendable {
    case done, couldntCheck, notDelivered, notDoneYet, working, pickedUp, deliveryUnknown, sent
  }
  extension QuestionRelay {
    public func status(livePickup: Bool, liveWrite: Bool, lastCheckFailed: Bool) -> QuestionRelayStatus
  }
  // ControlTransport / QuestionClient
  var updateRelay: @Sendable (QuestionRelayUpdateRequest) async throws -> RelayAcknowledgment
  var supportsRelays: @Sendable () async throws -> Bool
  ```

- [ ] **Step 1: Write the failing tests**
  - `decodesRelayUpdated` (all four kinds); `relayUpdatedAddsNoFeedRow`;
    `decodesExchangeWithRelay`.
  - Fold: `exchangeWithRelayAddsSentRelay`, `sendAgainAddsNewRelayToSameTurn`,
    `pickedUpAndReportsFold`, `doneIsFinal`, `changedPathsAfterSentUntilDone` (first-seen order;
    none after `done`), `relaysListedPerTurn`, `updateForUnknownRelayIgnored`.
  - Any order (D9): `pickedUpAfterNotDeliveredCountsAsPickedUp`, `reportBeforePickupInLogStillFolds`,
    `doneStaysDoneAfterLaterNotDoneYet`.
  - Status precedence, one test per models.md row, plus
    `notDoneYetYieldsToLaterFileChange` and `livePickupCountsBeforeLogHasIt`.
  - Requests: `encodesExchangeRelay`, `encodesEachRelayUpdateKind` (through the shared encoder, so
    Task 2's size test covers it), `decodesRelayAcknowledgment`, `relayAckWithOtherRelayIDIsMalformed`.
  - Capability: `supportsRelaysTrueOnProtocol`, `supportsRelaysFalseOnUnknownVerb`.
- [ ] **Step 2: Run** `swift test --filter "DecodingTests|QuestionThreadsTests|QuestionsTests|ControlTransportTests"`.
  Expect FAIL.
- [ ] **Step 3: Implement** as models.md. `changedPaths` comes from the `file.changed` events the
  fold already sees.
- [ ] **Step 4: Run** `swift test`. Expect PASS.
- [ ] **Step 5: Commit** `chore: read the progress of change requests from the event log`.

### Task 13: InstantAskModel relays and reports

**Files:**
- Modify: `Sources/SlipstreamCore/AskPrompt.swift`, `Sources/SlipstreamCore/ForkOutput.swift` (the
  report pieces)
- Modify: `SlipstreamViewer/Models/InstantAskModel.swift`
- Test: `Tests/SlipstreamCoreTests/AskPromptTests.swift`, `Tests/SlipstreamCoreTests/ForkOutputTests.swift`,
  `SlipstreamViewerTests/Models/InstantAskModelTests.swift`

**Interfaces:**
- Consumes: Task 11 (`relay`, `onTabTurnEnded`, `onRelayDelivery`) and Task 12.
- Produces (models.md `RelayRun`, rules "Change request" through "Restart"):

  ```swift
  // SlipstreamCore
  extension AskPrompt {
    public static func report(source: QuestionSource, earlier: [Exchange], request: String) -> String
    public static func relayMessage(source: QuestionSource, earlier: [Exchange], words: String) -> String
    public static let reportSchema: String
  }
  // AskForkKind gains .report; AskForkResult gains
  case report(reply: String, outcome: ReportOutcome)
  // InstantAskModel
  private(set) var relayRuns: [String: RelayRun]
  func daemonConnected(storeID: String) async          // retries updates that couldn't be recorded
  func sendAgainTapped(questionID: String, relayID: String) async
  func checkAgainTapped(relayID: String) async
  func relayStatus(_ relay: QuestionRelay) -> QuestionRelayStatus
  func relaysFolded(sessionID: String, relays: [QuestionRelay])   // restart handover
  ```

- [ ] **Step 1: Write the failing tests**
  - Core: `reportPromptNamesTheRequest` (the user's words appear after "make this change:");
    `relayMessageQuotesQAAboveUsersWords`; `reportSchemaMatchesEndpoints`; `parsesReportResult`.
  - `noRelaysWhenDaemonLacksVerb` (stage-1 prompt and schema; no `relay` sent);
    `capabilityCheckedOncePerConnection`.
  - `changeRequestRecordsExchangeWithRelayThenWritesTab` (order: recorded first, then written);
    `relayTextQuotesQAAndKeepsUsersWords` (the user's words verbatim; nothing from the copy's
    reply).
  - `pickupRecordsPickedUp`, `exitUnreadRecordsNotDelivered`.
  - Recording: `eachUpdateRecordedOnItsOwn` (a failing update doesn't hold back the next);
    `failedUpdateRetriedOnReconnect` (same `request_id` after three attempts fail).
  - Reports: `turnEndAfterPickupStartsReport` (`AskForkKind.report`, the relay's tab),
    `turnEndDuringReportSetsRerun`, `twoTurnEndsDuringReportRunOneMore`,
    `doneEndsChecks`, `failedReportIsCouldntCheck`, `checkAgainClearsFailureAndRuns`,
    `checkAgainIgnoredWhileChecking`.
  - Restart: `pickedUpWithoutDoneChecksAtNextIdle`, `sentNeverPickedUpIsDeliveryUnknown`,
    `deliveryUnknownNeverResentAutomatically`.
  - Send again: `sendAgainRecordsSentWithNewRelayIDThenWrites`,
    `refusedSendAgainWritesNothing`, `sendAgainToClosedThreadChatUsesLinkedTab`.
  - Crash boundaries (spec stage 2 item 6), one test each, by rebuilding the model from a log
    prefix.
- [ ] **Step 2: Run** `InstantAskModelTests`. Expect FAIL.
- [ ] **Step 3: Implement** as models.md. Each relay update is retried on its own (three attempts,
  same `request_id`); one that still fails waits in `RelayRun.unrecorded` for `daemonConnected`.
  `supportsRelays` is asked the first time a change request needs it on a daemon connection, and
  the answer is kept for that connection.
- [ ] **Step 4: Run** the full app test target. Expect PASS.
- [ ] **Step 5: Eval loop.** Add stage-2 cases to `ask-evals` (the stage-2 answer schema, and the
  report schema): questions and change requests are told apart; an ambiguous "yes" after an offer
  counts as a change request; a report says `done` only when the change is in the scratch repo.
  Every stage-1 case still passes. Paste the output in the PR body.
- [ ] **Step 6: Commit** `feature: send change requests from a question to the agent and check what it did`.

### Task 14: Progress lines, bar labels and the console mark

**Files:**
- Modify: `SlipstreamViewer/Models/QuestionMemory.swift` (`QuestionBarStatus.working`, `.done`)
- Modify: `QuestionThreadPageModel.swift` / `QuestionThreadPageView.swift` (progress lines per
  turn, the Done fold, Send again, Check again)
- Modify: `ChangeStreamPageModel.swift` (bar status rules; `relaysFolded`; `daemonConnected`)
- Test: `QuestionThreadPageTests.swift`, `ChangeStreamPageTests.swift`

- [ ] **Step 1: Write the failing tests**
  - One line test per screens.md progress state, with its exact text.
  - `doneFoldsProgressToOneLineThenReport`; `twoRequestsShowUnderTheirOwnTurns` (newest attempt
    only); `idleAgentGoesFromOnItToPickedUp`.
  - Bar: `barWorkingWhileAnyTurnInProgress`, `barDoneWhenAllDoneAndSeen`,
    `unseenReportShowsNewReply`, `notDeliveredBarWhenNothingElseInProgress`.
  - `checkAgainDisabledWhileChecking`; `sendAgainShownForNotDeliveredAndDeliveryUnknown`.
- [ ] **Step 2: Run** both suites. Expect FAIL.
- [ ] **Step 3: Implement** the model properties, then the views.
- [ ] **Step 4: Run** the full app test target. Expect PASS.
- [ ] **Step 5: Manual QA** on a disposable daemon running PR 2: stage 2 acceptance 1–9. Include
  each crash boundary (quit the app at each step), an older daemon (`develop` before PR 2), and
  this app's events read by the previous app build. Compare every state with its PNG.
- [ ] **Step 6: Commit** `feature: show a change request's progress in the question thread`.

---

# Stage 3 — app tabs stop attaching

Start only when Brian confirms that stages 1 and 2 have worked in real use (spec scope 9).

## PR 5 — App tabs stop attaching (client)

### Task 15: AppChatLinks and the new link rules

**Files:**
- Create: `SlipstreamViewer/Models/AppChatLinks.swift` (`@Shared(.fileStorage)` `appChatLinks.json`,
  beside `chatTabs` in `ChatTabRecord.swift:43`)
- Modify: `ChatPageModel.swift` (Connect to Stream, auto-link and closing the tab write
  `AppChatLinks`; `linkedAppTab(forFolder:)` reads it first; one-time migration)
- Modify: `CaptureStatus.swift` (`chatText`/`chatDot` and `askNotice` read the app link)
- Test: create `SlipstreamViewerTests/Models/AppChatLinksTests.swift`; modify `ChatPageTests.swift`,
  `CaptureStatusTests.swift`

**Interfaces:**
- Produces (models.md "AppChatLinks", "ChatPageModel link rules — Changed (stage 3)"):
  `AppChatLinks` is `[String: UUID]`. With no entry, the first tab in strip order with a sent
  message is linked.

- [ ] **Step 1: Write the failing tests**
  - `connectWritesAppLinkAndRunsNoCommand` (`chatLink` unimplemented, so any call fails);
    `connectLeavesOutsideBindingAlone`; `closingLinkedTabRemovesEntry`;
    `noEntryUsesFirstTabWithMessage`.
  - Migration: `liveAppBindingCopiedThenUnlinkedOnce`, `migrationRunsOncePerFolder`,
    `outsideBindingNotMigrated`, `oldHookThreadBecomesReadOnly` (Send reply disabled).
  - `stripReadsLinkedForAppLink`; `askNoticeReadsAppLinkFirst`.
- [ ] **Step 2: Run** the three suites. Expect FAIL.
- [ ] **Step 3: Implement.** The migration copies the binding into `AppChatLinks` before calling
  the existing `ChatLinkClient.unlink(folder:replacing:)`.
- [ ] **Step 4: Run** the full app test target. Expect PASS.
- [ ] **Step 5: Commit** `feature: remember the linked chat tab in the app instead of in Slipstream`.

### Task 16: Remove the app-tab attach plumbing

**Files:**
- Modify: `ChatTabModel.swift` (delete `reloadWhenIdle` and `streamLinked`)
- Modify: `ChatPageModel.swift` (delete app-tab `linkFailures`, `strandedLinks`, the auto-link
  attach)
- Modify: `SlipstreamViewer/Dependencies/ChatLinkClient.swift` (delete `link`; `unlink` stays for
  the migration)
- Modify: tests that covered the removed paths (delete them, don't disable them)

- [ ] **Step 1: Delete** the code and its tests. Keep the outside-chat tests (`outsideChatText`,
  `changesBinding`, `bindingGeneration`, the outside `askNotice` gate).
- [ ] **Step 2: Run** the full app test target and `swift test`. Expect PASS, with no warnings.
- [ ] **Step 3: Manual QA** on a disposable daemon: stage 3 acceptance 1–4. A fresh app tab's chat
  shows no setup check, and `git status` in the folder shows no `.claude/settings.local.json`
  change.
- [ ] **Step 4: Commit** `feature: keep Slipstream's setup messages out of chats run in the app`.

---

## Spec acceptance map

| Spec item | Task |
|---|---|
| Stage 1: 1 | 5, 6 |
| Stage 1: 2 | 2, 5, 6 (QA checksum) |
| Stage 1: 3 | 3, 4 |
| Stage 1: 4 | 3, 4 |
| Stage 1: 5 | 5 |
| Stage 1: 6 | 5 |
| Stage 1: 7 | 5, 6 |
| Stage 1: 8 | 3, 6 (evals) |
| Stage 1: 9 | 6 |
| Stage 1: 10 | 6 (evals) |
| Stage 2: 1 | 7, 13 |
| Stage 2: 2 | 9, 11 |
| Stage 2: 3 | 12, 13, 14 |
| Stage 2: 4 | 13 |
| Stage 2: 5 | 9, 11 |
| Stage 2: 6 | 13, 14 (QA) |
| Stage 2: 7 | 8, 12 |
| Stage 2: 8 | 12, 13, 14 (QA) |
| Stage 2: 9 | 13, 14 |
| Stage 3: 1–4 | 15, 16 |

## Unresolved questions

None open in the design. Two probe gates can change it before building: Task 4 Step 1 (stage 1:
`-p` reads the prompt from stdin) and Task 9 (stage 2: echo ids and queued input after Stop). Each
says what to do if the probe fails.
