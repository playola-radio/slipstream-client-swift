# Instant Ask — Model changes

Slipstream has no database. "Models" here are the client's Swift types (`SlipstreamCore` and
`SlipstreamViewer`) and the daemon's public event data. Every change is tagged with the stage that
ships it (1 = the copy answers, 2 = change requests and progress, 3 = app tabs stop attaching).

The daemon log stays the record of every thread: answers are recorded with the existing
`record_question_exchange`, and a change request's delivery and report with one new verb and event
(`endpoints.md`). The client persists one new thing, in stage 3: which app tab is linked per folder.

Revised after the Phase 5 review (spec.md "Adversarial review"); finding numbers are in brackets.
Simplified in Phase 7 (spec.md "Simplicity gate").

| Stage | Change | Model | Where | Summary |
|---|---|---|---|---|
| 1 | Changed | `EventPayload` | `Sources/SlipstreamCore/Events.swift` | Decodes `question.exchange_recorded.v1` (stage 1) and `question.relay_updated.v1` (stage 2) |
| 1 | New | `QuestionExchangeRecorded` | `Sources/SlipstreamCore/Events.swift` | One answered question, recorded by the client, with the chat that answered it |
| 1 | Changed | `QuestionThread`, `QuestionTurn`, `QuestionThreads` | `Sources/SlipstreamCore/QuestionThreads.swift` | Threads carry their link (hook, or recorded with its chat); recorded exchanges fold into answered turns |
| 1 | Changed | `QuestionContext`, `QuestionRequest` | `Sources/SlipstreamCore/Questions.swift` | Encodes a `record_question_exchange` request alongside `ask` |
| 1 | Changed | `QuestionClient`, `ControlTransport` | `SlipstreamViewer/Dependencies/QuestionClient.swift`, `Sources/SlipstreamCore/ControlTransport.swift` | Adds `record` (stage 1), `updateRelay` and `supportsRelays` (stage 2) beside `send` |
| 1 | New | `ExchangeAcknowledgment` | `Sources/SlipstreamCore/Questions.swift` | The reply to `record_question_exchange` |
| 1 | New | `AskForkClient` | `SlipstreamViewer/Dependencies/AskForkClient.swift` | Runs one hidden copy of a tab's chat as a one-shot process on `AgentProcessClient` and returns its structured reply |
| 1 | Changed | `AgentProcessHandle` | `SlipstreamViewer/Dependencies/AgentProcessClient.swift` | Adds `closeInput`, so a one-shot run can finish its stdin |
| 1 | New | `InstantAskModel` | `SlipstreamViewer/Models/InstantAskModel.swift` | App-wide owner of every copy run, recording and report |
| 1 | Changed | `CaptureStatus.askNotice` | `SlipstreamViewer/Models/CaptureStatus.swift` | App-tab route: ready once the linked tab has sent a message |
| 2 | New | `QuestionRelayUpdated` | `Sources/SlipstreamCore/Events.swift` | One step of a change request: sent, picked up, not delivered, reported |
| 2 | New | `QuestionRelay` | `Sources/SlipstreamCore/QuestionThreads.swift` | A change request's progress, folded from the exchange, relay events and file changes |
| 2 | Changed | `QuestionBarStatus` | `SlipstreamViewer/Models/QuestionMemory.swift` | Adds `working` and `done` |
| 2 | Changed | `ClaudeInvocation` | `Sources/SlipstreamCore/ClaudeInvocation.swift` | User messages carry a `uuid`; the tab echoes them back |
| 2 | Changed | `TranscriptProjection` | `Sources/SlipstreamCore/TranscriptProjection.swift` | Relayed messages carry a delivery state |
| 2 | Changed | `ChatTabModel`, `ChatPageModel` | `SlipstreamViewer/.../ChatPage/` | Live echoes aren't drawn again; `relay(_:)` writes a request now, whether the tab is idle or mid-turn; turn ends reach `InstantAskModel` |
| 2 | Changed (daemon) | `exchange_recorded.v1` data | daemon `schemas/`, `src/public-events.ts` | Optional `relay`: the exchange and its first send in one event [6] |
| 2 | New (daemon) | `relay_updated.v1` data | daemon `schemas/`, `src/public-events.ts` | New event |
| 3 | New (persisted) | `AppChatLinks` | `SlipstreamViewer/Models/AppChatLinks.swift` | Which app tab answers Ask, per folder |
| 3 | Changed | `CaptureStatus.chatText` / `chatDot` | `SlipstreamViewer/Models/CaptureStatus.swift` | An app link reads "Linked" without a daemon binding |
| 3 | Changed | `ChatPageModel` link rules | `SlipstreamViewer/.../ChatPage/ChatPageModel.swift` | Connect to Stream writes `AppChatLinks`; it no longer attaches or unlinks |
| 3 | Removed | `ChatTabModel.reloadWhenIdle` | `SlipstreamViewer/.../ChatPage/ChatTabModel.swift` | Nothing is installed into an app tab, so nothing needs a reload |
| — | Unchanged | `ChatTabRecord` | `SlipstreamViewer/Models/ChatTabRecord.swift` | No link field; the link lives in `AppChatLinks` |
| — | Unchanged | `ChatTabModel.hasSentMessage` | `SlipstreamViewer/.../ChatPage/ChatTabModel.swift` | Still set at the first turn's end; dropped from this design [15] |

## EventPayload — Changed (stages 1, 2)

| Case | Wire type | Change |
|---|---|---|
| `.questionExchangeRecorded(QuestionExchangeRecorded)` | `slipstream.question.exchange_recorded.v1` | Added in stage 1 (today `.unsupported`) |
| `.questionRelayUpdated(QuestionRelayUpdated)` | `slipstream.question.relay_updated.v1` | Added in stage 2 |

Neither adds a feed row. Both are listed in `rowlessTypes` so the feed's "Unsupported event" marker
never shows for them.

## QuestionExchangeRecorded — New (stage 1)

| Field | Type | Wire key | Notes |
|---|---|---|---|
| `questionID` | `String` | `question_id` | Daemon-assigned; the thread id for a root |
| `requestID` | `String` | `request_id` | The client's idempotency key |
| `text` | `String` | `text` | The user's words |
| `source` | `QuestionSource` | `context` | Decoded exactly as `QuestionQueued.source`, `selected_text` included |
| `answerText` | `String` | `answer_text` | Kept whole: no 16 KiB trim, unlike `question.answered.v1` |
| `replyToQuestionID` | `String?` | `reply_to_question_id` | Present on follow-ups |
| `recordedAtMs` | `Int64` | `recorded_at_ms` | The turn's time and its answer's time |
| `chatSessionID` | `String` | `conversation.parent_session_id` | The tab whose copy answered [3]. The rest of `conversation` is not decoded |
| `relay` | `ExchangeRelay?` | `relay` | Stage 2: `{ relayID, chatSessionID }` when this answer accepted a change request. It is that request's `sent` [6] |

## QuestionThread / QuestionTurn / QuestionThreads — Changed (stage 1)

| Field | Type | Change | Notes |
|---|---|---|---|
| `QuestionThread.link` | `QuestionThreadLink` (`.hook`, `.recorded(chatSessionID: String)`) | Added | Set by the root's event; a thread never changes link. A recorded thread's `chatSessionID` is the root's: the thread's chat [3] |
| `QuestionTurn.relays` | `[QuestionRelay]` | Added (stage 2) | Change requests accepted by this turn's answer, oldest first [16] |

Fold rules (`QuestionThreads.apply`):

- `.questionExchangeRecorded` with no `replyToQuestionID` starts a `.recorded` thread with one
  answered turn (`answer.seq` = the event's seq). With one, it appends an answered turn to its
  root's thread; an unknown parent is ignored, as for `questionQueued` today.
- An exchange with `relay` adds a relay to its turn, already `sent` at the event's seq.
- Recorded turns never enter `undispatchedQuestionIDs` or `queuedSinceResumeIDs`, so
  `sessionResumed` and `agentUnlinked` never mark them dropped or moved.
- A recorded follow-up is ignored when its root is a `.hook` thread (the daemon refuses that chain
  anyway, contract "Client-recorded exchanges").

**The thread's chat [3].** Follow-ups, change requests and **Send again** go to the thread's chat
while that tab is open. If the tab has been closed they go to the folder's linked tab; the
earlier exchanges are quoted in the copy's message either way (`endpoints.md`). A thread never
switches between `.hook` and `.recorded`.

**What is not in the log:** a question whose answer hasn't been recorded. The daemon assigns a
`question_id` only when the question and its answer are recorded together, so Answering and
Couldn't answer live in `InstantAskModel` memory (below). An app quit during those seconds loses
that one unanswered question; everything recorded survives.

## QuestionContext / QuestionRequest — Changed (stage 1)

`QuestionRequest` gains a second verb. One type, because both share every validation rule
(`encoded()`'s text and context checks):

| Field | Type | Change | Notes |
|---|---|---|---|
| `verb` | `.ask(bindingGeneration: String)` or `.recordExchange(answerText: String, conversation: ExchangeConversation, relay: ExchangeRelay?)` | Changed (was the fixed verb `ask` plus `bindingGeneration`) | Encodes the verb's own fields. `relay` is stage 2 |
| `ExchangeConversation` | `{ parentSessionID, forkSessionID }`, harness always `claude-code` | New | The tab's id and the copy's returned `session_id` |
| `ExchangeRelay` | `{ relayID, chatSessionID }` | New (stage 2) | Lowercase UUIDs |

`encoded()` refuses a request whose encoded line is over the control socket's 1 MiB cap. Relay
updates use the same encoder, so the check is written once. A blank answer is caught earlier, by
the copy's output check (`AskForkClient` below); the daemon refuses one too. Retries re-send the
same prepared request.

## QuestionClient / ControlTransport — Changed (stages 1, 2)

| Closure | Signature | Verb |
|---|---|---|
| `send` | unchanged | `ask` |
| `record` | `(QuestionRequest) async throws -> ExchangeAcknowledgment` | `record_question_exchange` (stage 1) |
| `updateRelay` | `(QuestionRelayUpdateRequest) async throws -> RelayAcknowledgment` | `record_question_relay_update` (stage 2) |
| `supportsRelays` | `() async throws -> Bool` | the same verb with no fields; `false` on `unknown verb` (stage 2). Asked the first time it's needed on a daemon connection, and kept for that connection [14] |

- `ExchangeAcknowledgment { sessionID, requestID, questionID, seq, duplicate }` [7].
  `QuestionAcknowledgment` stays as is for `ask`; it requires `queued_at_ms` and `expires_at_ms`
  (`Questions.swift:96`), which an exchange reply doesn't have.
- `RelayAcknowledgment { sessionID, requestID, questionID, relayID, seq, duplicate }`.
- `QuestionRelayUpdateRequest { sessionID, requestID, questionID, relayID, update: RelayUpdate }`
  lives in `Questions.swift` and goes through the same encoder as `QuestionRequest`.
- An acknowledgment whose ids don't match the request is malformed: an unknown outcome [18].
- `ControlTransport` gains the matching public methods over its private `exchange`. Tests decode
  real daemon replies, including the flat `{v, ok: false, code, message}` error.

## AskForkClient — New (stage 1)

`@Dependency` struct-of-closures client. One closure. The live value launches the copy through
the existing `AgentProcessClient`, with the tab's environment and folder. The runner's handle
gains one closure, `closeInput` (wired to `AgentProcessInput.close()`,
`AgentProcessClient.swift:300`), so the prompt can be written and stdin finished [13].

```swift
struct AskForkClient: Sendable {
  var run: @Sendable (AskForkRequest) async throws(AskForkError) -> AskForkResult
}

struct AskForkRequest: Equatable, Sendable {
  let parentSessionID: UUID      // the thread's chat, or the linked tab for a new question
  let folder: String
  let environment: AgentEnvironment
  let model: String              // that tab's current choice
  let effort: ChatEffort
  let prompt: String             // built from the templates in endpoints.md
  let kind: AskForkKind          // .answer (stage 1) or .report (stage 2): picks the output schema
}

enum AskForkResult: Equatable, Sendable {
  case answer(forkSessionID: String, reply: String, isChangeRequest: Bool)
  case report(reply: String, outcome: ReportOutcome)      // stage 2
}

enum AskForkError: Error, Equatable, Sendable { case timedOut, unavailable, badReply }
```

- **Process:** the runner's. The prompt is written to stdin, then `closeInput`. Each stdout line
  is fed to `ForkOutput`; the runner caps a line at 1 MiB (`.overflow`). Its stderr tail is never
  shown or saved.
- **Time limit:** 120 seconds from launch to exit, on the continuous clock, then `timedOut`.
  Probes ran 3–10 s on small chats.
- **Stopping:** on a result, an error, the time limit or cancellation, the handle's `shutdown`
  (close stdin, SIGTERM to the process group, SIGKILL 3 seconds later, reaped).
- **Isolation check [8]:** the first output line (`system`/`init`) must list exactly the tools
  `Read`, `Grep`, `Glob` and no MCP servers; otherwise the copy is stopped at once as
  `unavailable` and nothing is read.
- **Errors:** `unavailable` is a failed launch, a copy that isn't isolated, an `is_error` result,
  or an exit before a result. `badReply` is a clean exit with no result, an overflowing line, a
  missing `session_id` or `structured_output`, a schema mismatch, or a `reply` that is empty after
  trimming.
- `testValue` is unimplemented; tests override `run`, and `AskForkClient`'s own tests override
  `agentProcess`.

The command line, both output schemas and the prompt templates are in `endpoints.md`.

## InstantAskModel — New (stage 1; relays in stage 2)

`@MainActor @Observable`, one per app, held by `SlipstreamViewerApp` beside `chat`
(`SlipstreamViewerApp.swift:7`) and passed to `ChangeStreamPageView`. It holds the app's
`ChatPageModel` to find a tab by id (folder, model, effort, open or closed), relay into it and hear
its turn ends. It owns every copy run, every recording call and every report (plan §2.8: one owner
per async operation).

**Lifetime [4].** Closing the panel or selecting another capture cancels nothing. Work stops only
when its capture is deleted or the app quits: `AppDelegate`'s termination drain
(`AppDelegate.swift:27`) cancels it and waits for running copies to exit, beside the chat tabs.

| Property | Type | Notes |
|---|---|---|
| `pending` | `IdentifiedArrayOf<PendingAsk>` | Questions whose answer hasn't folded into a thread yet. Memory only |
| `relayRuns` | `[String: RelayRun]` (relay id) | Stage 2: live delivery and report state for relays this app run knows about. Memory only |

```swift
struct PendingAsk: Identifiable, Equatable, Sendable {
  let id: String                 // the request_id, a fresh lowercase UUID
  let storeID: String
  let sessionID: String          // the capture
  let chatSessionID: UUID        // the tab whose copy answers
  let source: QuestionSource
  let replyToQuestionID: String?
  let text: String
  let askedAtMs: Int64
  var state: State
  enum State: Equatable, Sendable {
    case answering
    case recording(AskForkResult)
    case recorded(questionID: String)
    case couldntAnswer(AskFailure)
    case couldntRecord(AskForkResult)   // the outcome is unknown; the exact request is kept
  }
}

enum AskFailure: Equatable, Sendable { case noReply, chatUnavailable, badReply, notSaved }

struct RelayRun: Equatable, Sendable {
  var delivery: Delivery         // .writing, .waitingForEcho, .pickedUp, .exitedUnread
  var report: Report             // .idle, .checking(rerun: Bool), .failed
  var unrecorded: [QuestionRelayUpdateRequest]  // retries ran out; tried again on reconnect
}
```

- **Ask:** adds a `PendingAsk(.answering)`, runs `AskForkClient.run(.answer)` for the thread's
  chat (a new question: the linked tab), then records the exchange with the same `request_id`.
  An unknown outcome retries with the identical body (contract rule), up to 3 attempts over about
  5 seconds. On the acknowledgment the entry becomes `.recorded`; it leaves `pending` once the
  selected capture's fold has that `question_id`, or when that capture is deselected (selecting it
  again replays the log).
- **Failures [11, 17]:** a copy failure sets `.couldntAnswer` (`timedOut` → `noReply`;
  `unavailable` → `chatUnavailable`; `badReply` → `badReply`; a refused recording → `notSaved`). Retries that run out set
  `.couldntRecord`. **Try again** on `.couldntRecord` retries the same request; on
  `.couldntAnswer` it runs a new copy with a new `request_id`. If the exchange's event folds in
  after an error showed, the entry is dropped and the thread shows the answer.
- **Pending roots [17]:** a pending entry with no `replyToQuestionID` shows as a question bar at its
  source lines, keyed by its `request_id`: "Waiting" while answering or recording, "Not
  delivered" after a failure. Clicking it opens the thread view on that entry. When the exchange
  folds in, the bar and an open panel move to the `question_id`.
- **Thread view:** `QuestionThreadPageModel` shows the folded thread with any `pending` entry for it
  appended as its last turn, so Answering looks the same for a new question and a follow-up.
- **Stage 1 has no change requests [14].** Stage 1's answer prompt has no change-request field
  (`endpoints.md`). In stage 2 the same holds when `supportsRelays` is `false` for the
  current daemon connection.
- **Change request (stage 2):** when the answer says `isChangeRequest`, the exchange is recorded
  with `relay` (a new relay id, the thread's chat): that is the request's `sent`, in the same event
  as the "On it" answer [6]. Then the request is written to the tab. A crash between the two
  leaves a sent request with no live write, which shows as Delivery unknown after restart.
- **Recording relay steps [2] (D9):** each update is recorded on its own, retried with the same
  `request_id` up to 3 attempts. One whose retries run out waits in `unrecorded` and is tried again
  when the daemon connection comes back (`daemonConnected`); it never holds back another update.
  The daemon accepts steps in any order and the fold sorts them out (`QuestionRelay` below). What
  the app saw (pickup, exit) shows at once from `relayRuns`; the log catches up. **Send again**
  still writes to the tab only after its `sent` is acknowledged; a refused one writes nothing.
- **Reports [5]:** a turn end in a tab with a relay `pickedUp` and no `done` report starts a check
  when `report` is `.idle` or `.failed`. A turn end during a check sets `rerun`; when the check
  returns `not_done_yet` with `rerun` set, it checks again at once. `done` ends the relay's checks.
  A failed check sets `.failed` (Couldn't check); starting a check clears it, and **Check again**
  is disabled while a check runs.
- **Restart:** `ChangeStreamPageModel` hands over the selected capture's open relays as they fold.
  One picked up with no `done` report is checked the next time its tab is idle, if the tab is still
  open. One `sent` and never picked up shows Delivery unknown and is never re-sent automatically.
- **Generation check:** every completion is matched by store id, capture, `request_id` (or
  `relay_id`) and attempt; a completion for an entry that is gone publishes nothing.

## CaptureStatus.askNotice — Changed (stage 1)

Order of checks; the first that applies wins:

1. Capture availability `unavailable` or `unknown` → today's unknown notice.
2. Not recording → today's recording notice.
3. **App route:** the folder's linked chat is an app tab that has sent a message
   (`hasSentMessage`, unchanged: set when the first turn ends) → ready (no notice). The binding's
   `setupPending` / unconfirmed state is ignored for app tabs.
4. **Outside route:** a live binding to an outside chat → today's checks, unchanged.
5. Nothing → "No chat is connected yet. Send a message in a chat tab to connect it."

In stages 1 and 2 "the linked chat" is read from the daemon binding (linked-chat's rule). In stage 3
it is read from `AppChatLinks` first, then the binding. A brand-new tab can't be asked about during
its first turn, as today [15].

## QuestionRelayUpdated — New (stage 2)

| Field | Type | Wire key | Notes |
|---|---|---|---|
| `questionID` | `String` | `question_id` | The recorded exchange whose answer accepted the request |
| `relayID` | `String` | `relay_id` | One delivery attempt; also the `uuid` of the message written to the tab |
| `update` | `RelayUpdate` | `update` | One of the four below |
| `recordedAtMs` | `Int64` | `recorded_at_ms` | The time shown on the line |

```swift
enum RelayUpdate: Equatable, Sendable {
  case sent(chatSessionID: String)   // Send again only; a first send rides on the exchange
  case pickedUp
  case notDelivered
  case reported(ReportOutcome, text: String)
}

enum ReportOutcome: String, Equatable, Sendable { case done, notDoneYet = "not_done_yet" }
```

## QuestionRelay — New (stage 2)

A pure fold, so every window and every restart shows the same progress.

| Field | Type | Notes |
|---|---|---|
| `id` | `String` | `relay_id` |
| `questionID` | `String` | The turn it belongs to |
| `chatSessionID` | `String` | The tab it was written to; reports use this tab |
| `sent` | `(seq: Seq, atMs: Int64)` | From the exchange's `relay`, or a `sent` update |
| `pickedUp` | `(seq: Seq, atMs: Int64)?` | The earliest `picked_up` |
| `isNotDelivered` | `Bool` | A `not_delivered` and no `picked_up` |
| `report` | `(outcome: ReportOutcome, text: String, seq: Seq)?` | Any `done` report, else the latest `reported` |
| `changedPaths` | `[String]` | Derived: paths of `file.changed` events with seq after `sent.seq`, up to a `done` report, first-seen order |

**Any order (D9).** The daemon doesn't check the order of a relay's steps, so the fold doesn't
depend on it: a pickup counts even if `not_delivered` was recorded first, a `done` stays final
whatever follows it, and an update for a relay the fold doesn't know is ignored.

**`changedPaths` is a log interval [19]:** the files seen changing between the request's send and
its `done` report. It is shown once the request is picked up. It says nothing about who changed
them, which is why the line reads "changes seen in". A gap in the capture means changes not seen.

Status, first match wins. "Picked up" also counts a pickup this app run saw that the log doesn't
have yet (`relayRuns`):

| Status | Rule | Line |
|---|---|---|
| `done` | report is `done` | "Done · sent 14:02 · picked up 14:03 · greet.py" |
| `couldntCheck` | this run's last check failed | "Couldn't check whether this was done · 14:05", **Check again** |
| `notDelivered` | `isNotDelivered` | "Not delivered · the chat stopped before the agent read this", **Send again** |
| `notDoneYet` | the latest report is `not_done_yet` and no file changed after it [16] | "Not done yet · checking again when the agent's next turn ends" |
| `working` | picked up and `changedPaths` not empty | "Working · changes seen in greet.py" (one line per path) |
| `pickedUp` | picked up | "Picked up · 14:03" |
| `deliveryUnknown` | sent, and no live write for it in this app run | "Delivery unknown · the app restarted before delivery was confirmed", **Send again** |
| `sent` | sent | "Sent · 14:02 · the agent will read this after its current step" |

- **"Changes seen in", not "edited":** see `changedPaths` above.
- **No line counts.** The app computes none (`FileChange` carries only path, snapshots and time).
- **Send again** writes the same request to the thread's chat (above) with a new `relay_id`,
  recorded as a `sent` update first.
- **Lines per turn [16]:** a turn shows its newest relay's lines, under that turn's answer. A thread
  with two change requests shows each under its own turn.

## QuestionBarStatus — Changed (stage 2)

| Case | Change | Rule |
|---|---|---|
| `working` | Added | Any turn's newest relay is `sent`, `pickedUp`, `working`, `notDoneYet` or `couldntCheck`. Label "Working", amber |
| `done` | Added | Every turn's newest relay is `done` and the latest report has been seen. Label "Done", green |

An unseen answer or `done` report shows `newReply`, as an unseen answer does today; it wins over
both. `notDelivered` and `deliveryUnknown` relays show `notDelivered` when no other relay in the
thread is in progress.

## ClaudeInvocation — Changed (stage 2)

| Change | Notes |
|---|---|
| `userMessage(_ text: String, uuid: UUID? = nil)` | A relay passes its `relay_id` as a top-level `uuid`; ordinary sends are unchanged |
| `--replay-user-messages` added to `arguments` | The tab echoes each user message when the agent reads it |

## TranscriptProjection — Changed (stage 2)

| Change | Notes |
|---|---|
| `userSent(_:id:relay:)` | Gains an optional `RelayMark`. A relay's item id is its `relay_id` (`TranscriptProjection.swift:61`) |
| `markRelay(id:delivery:)` | New: updates a relayed message's mark |
| `TranscriptItem.Kind.userMessage` gains `relay: RelayMark?` | `RelayMark { label: String, delivery: .waiting / .pickedUp / .notDelivered }`; `label` is "From Ask · greet.py:3-5" |

The relayed text is the user's own words with the quoted question and answer above them, built by
`InstantAskModel`, so it reads correctly in the transcript even where the mark isn't shown, as
after a reload: a reloaded relay shows unmarked.

## ChatTabModel / ChatPageModel — Changed (stage 2)

| Change | Notes |
|---|---|
| Live echoes skipped | `received(_ line:)` (`ChatTabModel.swift:465`) never draws a live `.user` prompt line (`isPrompt`, `TranscriptProjection.swift:90`): the tab drew it when it was sent. A reload still draws prompts from the transcript |
| `relay(_ message: AskRelayMessage) async throws` | Idle: starts a turn with it, as `send` does, without touching the draft. Mid-turn: writes it to stdin now. Inserts the marked message as `waiting` |
| Echo seen | The echo with the relay's `uuid`, from this process launch, sets the message `pickedUp`; `InstantAskModel` records `picked_up` |
| Process exited, output read to the end, no echo | Sets `notDelivered`; `InstantAskModel` records `not_delivered` [1] |
| Turn ended or Stop pressed, no echo | Nothing changes: the message is still queued and the process reads it next (stage 2's first check). Only an exit proves it was never read [1] |
| Turn ends | `ChatPageModel` already sets each tab's `onTurnEnded` (`ChatPageModel.swift:423`); its `turnEnded(_:)` also tells `InstantAskModel` the tab id |

`AskRelayMessage { relayID: UUID, text: String, label: String }`.

## Daemon event data — Changed and New (stage 2)

- **`exchange_recorded.v1` gains optional `relay`** `{ relay_id, chat_session_id }`, copied from
  the request. It counts as that relay's `sent` [6].
- **`relay_updated.v1`** mirrors its verb (`endpoints.md`).
- **No order checks (D9):** the daemon appends a relay's steps in whatever order they arrive;
  the client's fold applies status precedence. A `sent` reserves its new `relay_id`
  synchronously before awaiting the append, as `inflightExchanges` does for exchanges
  (`src/session.ts:1201`). Refusals are in `endpoints.md` (`INVALID_RELAY_UPDATE`). Idempotent on
  `request_id`.

## AppChatLinks — New (persisted, stage 3)

| Field | Type | Notes |
|---|---|---|
| (whole value) | `[String: UUID]` (folder → tab id) | `@Shared(.fileStorage)` `appChatLinks.json` in Application Support, beside `chatTabs` |

- **Key:** the folder string exactly as stored in `ChatTabRecord.folder`.
- **Written** by **Connect to Stream** on an app tab, and once by the migration below. Closing that
  tab removes the entry.
- **No entry:** the linked app tab is the first tab in strip order with a sent message, as
  auto-link picks today.
- **Source of truth:** the app is the only authority on which app tab answers Ask. The daemon's
  binding stays the authority for outside chats only.
- **Outside chats:** an outside chat's binding is left alone; Connect to Stream on an app tab no
  longer unlinks it. A new Ask question goes to the app tab the user picked. Recorded threads keep
  their chat (above); hook threads stay with the outside chat.
- **Migration [10]:** on stage 3's first launch, a live daemon binding to an app tab is copied into
  `AppChatLinks` for its folder, then unlinked once (`ChatPageModel` below), so the user's choice
  survives.
- **Old hook threads on app tabs [10]:** after that unlink they read as today's thread whose chat
  was unlinked: readable, with Send reply disabled. A new question starts a recorded thread.

## CaptureStatus.chatText / chatDot — Changed (stage 3)

An app link (from `AppChatLinks` or the first-tab rule) reads "Linked — changes are possibly the
agent's", with today's linked dot, the same as a bound chat. An outside binding keeps today's text.

## ChatPageModel link rules — Changed (stage 3)

- Auto-link and `ChatLinkClient.link` are no longer called for app tabs; the app tab icon reads
  from `AppChatLinks`. `ChatLinkClient.unlink` is called once for a live binding left on an app tab
  from before stage 3 (`endpoints.md`); `link` is then deleted.
- `linkFailures` stays for outside-chat cases only; an app link can't fail.

## ChatTabModel.reloadWhenIdle — Removed (stage 3)

It existed to load a newly installed hook and answer tool (linked-chat). App tabs get neither.

## ChatTabRecord — Unchanged

No link field: the per-folder link is one value per folder, not one per tab, so it lives in
`AppChatLinks`.
