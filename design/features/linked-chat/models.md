# Linked chat — Model changes

Slipstream has no database. "Models" here are the client's Swift types (`SlipstreamCore` and
`SlipstreamViewer`) and the daemon's public event data. **Nothing new is persisted on disk by the
client.** Which tab is linked is never stored by the app: it is read from the daemon's binding.
The one daemon data change is a `target` field on `question.dispatch_attempted.v1`
(`endpoints.md`).

| Change | Model | Where | Summary |
|---|---|---|---|
| Changed | `CaptureBinding` | `Sources/SlipstreamCore/Captures.swift` | Keeps `harness_session_id` so the app knows *which* chat is linked |
| Changed | `EventPayload` | `Sources/SlipstreamCore/Events.swift` | Decodes `slipstream.agent.unlinked.v1` (today `.unsupported`) |
| Changed | `QuestionTurn`, `QuestionThreads` | `Sources/SlipstreamCore/QuestionThreads.swift` | A turn an unlink moved shows "Re-sending" until a chat picks it up |
| New | `LinkOutcome` | `Sources/SlipstreamCore/LinkOutcome.swift` | Typed result of one link operation, parsed from exit code and output |
| New | `ChatLinkClient` | `SlipstreamViewer/Dependencies/ChatLinkClient.swift` | Runs each whole link operation (re-read, check, unlink, attach) one at a time app-wide |
| New (memory only) | `ChatPageModel.linkFailures` | `SlipstreamViewer/.../ChatPage/ChatPageModel.swift` | The "Couldn't connect" state of a tab |
| Changed (memory only) | `ChatTabModel.reloadWhenIdle` | `SlipstreamViewer/.../ChatPage/ChatTabModel.swift` | Restart a running chat after it is linked |
| Changed (behavior) | `QuestionThreadPageModel` | `SlipstreamViewer/.../QuestionThreadPage/` | Follow-ups use the current link |
| Changed (daemon) | `dispatch_attempted.v1` data | daemon `src/session.ts` | Adds `target`, the chat the question was handed to |
| Unchanged | `ChatTabRecord` | `SlipstreamViewer/Models/ChatTabRecord.swift` | No link field; the linked tab is derived |

## CaptureBinding — Changed

| Field | Type | Wire key | Change | Notes |
|---|---|---|---|---|
| `harnessSessionID` | `String?` | `harness_session_id` | Added | Already sent by `GET /v1/captures` (`daemon.ts:597-606`); the client dropped it |

- Decodes with `decodeIfPresent`: a missing key reads as "outside chat", never a decode failure
  that hides the whole capture row.
- **Derived, not stored:** `isLinked(toChat:)` is true when `harnessSessionID` parses to the tab's
  UUID (so case never matters) **and** `state` is `.connected` or `.setupPending`. A revoked link
  keeps its row with `state: unlinked` and the old id (`daemon.ts:597-606`), so the id alone is not
  enough. No harness check is needed: an app tab's id is a fresh UUID no other harness reuses.
  "Outside chat connected" is a live binding that matches no tab in that folder. The icon is blue
  when `.connected`, amber when `.setupPending`.
- `.unavailable` and `.unknown` show no tab icon and keep today's notices; the app never links
  over them.

## EventPayload — Changed

| Case | Wire type | Fields kept | Change |
|---|---|---|---|
| `.agentUnlinked(AgentUnlinked)` | `slipstream.agent.unlinked.v1` | `reason: String` (`unlinked`, `detached`, `archived`, …) | Added (was `.unsupported`) |

- `slipstream.agent.binding.v1` stays `.unsupported`: nothing reads it (the binding comes from
  `GET /v1/captures`).
- The feed's "Unsupported event" marker no longer shows for unlink events; they add no feed row.

## QuestionTurn / QuestionThreads — Changed

The daemon, not the client, hands a moved question to the next linked chat (`endpoints.md`). The
fold only mirrors that so the thread can say so.

| Field | Type | Change | Notes |
|---|---|---|---|
| `QuestionTurn.isMoved` | `Bool` | Added | An unlink happened while it was unanswered, and no chat has picked it up since |
| `QuestionTurn.Status.resending` | case | Added | Shown while `isMoved` |

Rules (`QuestionThreads.apply`), a pure fold of the event log, so every window and every restart
reaches the same state:

- `.agentUnlinked` with `reason == "unlinked"`: every unanswered, undropped turn sets `isMoved` and
  goes back into `undispatchedQuestionIDs`, dispatched or not. This mirrors the daemon re-arming
  it for the next chat.
- `.agentUnlinked` with any other reason: no change (detach and archive are out of scope).
- `.questionDispatchAttempted`: clears `isMoved` (a chat has it; the status returns to `waiting`).
- `.sessionResumed`: unchanged. Any turn in `undispatchedQuestionIDs`, moved ones included, is
  dropped, as the daemon drops it.
- `.questionAnswered`: unchanged. A late answer from either chat answers the turn.

Status order: `answered`, then `notDelivered` (recording restarted, today's rule), then `resending`
when `isMoved`, else `waiting`.

Display (`QuestionThreadPageModel.unansweredText`): `resending` → "Re-sending to the newly
connected chat — waiting for the agent to answer…"; the other cases keep today's text. The question
bar's amber accent, unread answers and follow-up disabling treat `resending` like `waiting`.

A moved question whose pickup expiry passes before any chat claims it keeps showing "Re-sending",
the same way an unmoved question past its expiry keeps showing "waiting" today. No expiry state is
added for this feature.

## LinkOutcome — New

The typed result of one link operation (below), parsed from the exit code and merged output of
its last `slipstream attach` or `unlink` run (`WorkspaceClient` keeps the last 64 KiB, which always
includes the final lines).

```swift
enum LinkOutcome: Equatable, Sendable {
  case linked                  // attach exit 0
  case unlinked                // unlink exit 0, online or recorded offline
  case skipped                 // the binding was not what the caller expected; nothing changed
  case retryLater              // transcript head not complete yet, or exit 3
  case refused(LinkRefusal)    // exit 1
}

enum LinkRefusal: Equatable, Sendable {
  case slipstreamTooOld        // the Claude-version refusal from an old CLI or daemon
  case slotsFull               // BINDING_LIMIT_REACHED
  case setupIncomplete(String) // linked, but installing the hook or answer tool failed
  case other(String)           // the CLI's last "slipstream: …" line
}
```

Matching rules are in `endpoints.md`. Every outcome, success or failure, is followed by a
`/v1/captures` refresh: the binding there is the only authority on what is linked.

## ChatLinkClient — New

`@Dependency` struct-of-closures client. Each closure is one **whole** operation: the live value
runs it start to finish (re-read, check, unlink, attach) through one app-wide actor, so two
windows' operations never interleave.

| Closure | Signature | Steps |
|---|---|---|
| `link` | `(folder: String, tabID: UUID, replacing: String?) async -> LinkOutcome` | Read `/v1/captures`. `replacing == nil` (auto-link): if the folder has a live binding, return `.skipped`; else attach. `replacing == G` (user move, or the linked tab closed): if the live binding's generation is not `G`, return `.skipped`; else unlink it (when live), then attach |
| `unlink` | `(folder: String, replacing: String) async -> LinkOutcome` | Read `/v1/captures`; if the live binding's generation is not `replacing`, return `.skipped`; else `slipstream unlink --session <its capture>`. Used only when the linked tab closes and no other tab has sent a message |

Attach runs with the tab's own launch environment (`AgentEnvironment.variables`, so the Claude
config directory always matches the tab's) plus the variables in `endpoints.md`. `testValue` is
unimplemented; tests override it.

**Accepted race (Decision A):** the daemon's `unlink` takes only a capture session id and revokes
whatever binding exists at that moment (`daemon.ts:1536-1549`). If something outside this app (the
CLI, a Conductor chat) replaces the link between the actor's re-read and its unlink — a window of
milliseconds — the app removes that newer link. The app never unlinks a binding it did not just
read and match; it can't promise more without a conditional unlink in the daemon, which is out of
scope. The refresh after the operation shows the user what happened.

## ChatPageModel.linkFailures — New (memory only)

| Field | Type | Notes |
|---|---|---|
| `linkFailures` | `[UUID: LinkRefusal]` (tab id → why) | Set when a link operation for that tab is refused; cleared as below |

Drives the "Couldn't connect" state: orange icon and the tooltip copy in `screens.md`. It clears
when a refresh shows this tab `connected`, the tab closes, or the user chooses **Connect to Stream**
again. `setupPending` does not clear it: after a setup refusal the binding already points at this
tab (`attach-workflow.ts:81-90`), so only a passed setup check (`connected`) is recovery. While it
is set the tab shows "Couldn't connect", not the amber icon.

Link rules owned by `ChatPageModel`:

- **Auto-link** runs only while the binding is absent or `.unlinked`, on two moments: a workspace
  window opens, or any tab's turn ends. It calls `link(replacing: nil)` for the first tab in strip
  order whose chat has sent a message. An ordinary refresh never starts one, and auto-link never
  unlinks anything. `.retryLater` (the transcript head not complete yet) waits for the next turn
  end; there is no timer.
- **Connect to Stream** (user choice): `link(replacing: G)`, where `G` is the generation the user
  saw (`nil` when nothing was linked). `.skipped` shows the refreshed state. Disabled for a tab
  whose chat has not sent a message (no transcript yet).
- **Closing the linked tab:** `link(replacing: G)` for the first remaining tab with a message, or
  `unlink(replacing: G)` when there is none.
- Link moves are best-effort. If the attach fails after the unlink succeeded, the workspace ends up
  unlinked and the tab shows "Couldn't connect"; there is no rollback.
- While nothing is linked and no tab has sent a message, the first tab shows the amber waiting
  icon (it is the tab auto-link will pick).

## ChatTabModel.reloadWhenIdle — Changed (memory only)

| Field | Type | Notes |
|---|---|---|
| `reloadWhenIdle` | `Bool` | Set on the tab just linked when its chat process launched before the attach finished |

A running Claude doesn't load newly installed hooks or MCP tools, and an app tab's process always
predates its own attach (attach needs the transcript).

- When the flag is set on an idle tab, or when the tab's running turn ends, the model calls the
  existing `shutdown()` (the path `choiceSelected` uses, `ChatTabModel.swift:255-262`) and clears
  the flag. Nothing is sent and no process is started.
- The next `send` finds no process and launches one with `--resume`, which loads the hook and
  answer tool. `send` already awaits a retirement in progress (`ChatTabModel.swift:190`), so it can
  never reuse the old process, and it refuses input while a turn runs, so a reload can't cut a
  turn short.

This is keyed to "the process predates the attach", not to whether this attach installed files,
so a tab that was already running when another tab installed the config is covered too.

## QuestionThreadPageModel — Changed (behavior)

- `captureChanged(_:)` replaces its cached binding generation with the current one instead of only
  filling a `nil` one (`QuestionThreadPageModel.swift:153-155`), so a new follow-up after a move
  uses the new link. A follow-up already in flight keeps its request id and body.

## dispatch_attempted.v1 data — Changed (daemon)

| Field | Type | Change | Notes |
|---|---|---|---|
| `target` | `{ harness, harness_session_id }` | Added | The chat this attempt was handed to; answer ownership checks it. Events written before this change have no `target` and fall back to the question's queued target |

The client does not decode it.

## ChatTabRecord — Unchanged

No `isLinked` field. Storing it would duplicate the daemon's binding and drift whenever an outside
chat, the CLI, or another window changes the link.
