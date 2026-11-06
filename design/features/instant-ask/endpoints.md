# Instant Ask — Endpoint changes

Slipstream's interface is not REST: the daemon (`playola-radio/slipstream`) exposes a CLI, verbs
on the owner-only `control.sock`, a GET-only reader, and the event log. The app also launches the
Claude CLI. Rows below use `CLI`, `CONTROL` and `EVENT` in the Method column. Auth for the daemon
is local file ownership of the store (`control.sock` is owner-only; the reader uses the in-memory
bearer token, never printed or persisted).

**Daemon changes (stage 2):** a new control verb and its event for a change request's progress,
and an optional `relay` field on the existing `record_question_exchange`, so an accepted change
request and its first send are one event. Everything else is an existing interface the app starts
calling, or stops calling. Daemon references are at `origin/develop` feffc30.

Revised after the Phase 5 review (spec.md "Adversarial review"); finding numbers are in brackets.
Simplified in Phase 7 (spec.md "Simplicity gate"); relay steps are accepted in any order (D9).

| Stage | Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|---|
| 1 | Unchanged, newly called | CONTROL | `record_question_exchange` | store owner | Record a question with the answer the copy gave |
| 1 | Unchanged, newly decoded | EVENT | `slipstream.question.exchange_recorded.v1` | reader token | Show recorded answers in threads |
| 1 | New use | CLI | `claude -p --resume <tab> --fork-session …` | user's Claude login | Run the hidden copy that answers or reports |
| 2 | Changed | CONTROL | `record_question_exchange` | store owner | Optional `relay`: the answer accepted a change request [6] |
| 2 | Changed | EVENT | `slipstream.question.exchange_recorded.v1` | reader token | Carries `relay` when present |
| 2 | New | CONTROL | `record_question_relay_update` | store owner | Record one later step of a change request |
| 2 | New | EVENT | `slipstream.question.relay_updated.v1` | reader token | Show a change request's progress after restarts and in the log |
| 2 | Changed use | CLI | the tab's own `claude` process (stdin, `--replay-user-messages`) | user's Claude login | Write the change request into the tab and see when it is read |
| 3 | No longer called for app tabs | CLI | `slipstream attach <folder>`, `slipstream unlink --session <id>` | store owner | App tabs link inside the app |
| — | Unchanged | CONTROL | `ask` | store owner | Questions to outside chats (Conductor, terminal) |

## CONTROL record_question_exchange
- **Change:** Unchanged in stage 1 (daemon PR #76); the app starts calling it. Stage 2 adds the
  optional `relay` field below.
- **Auth:** store owner (`control.sock`), through `ControlTransport` like `ask`.
- **Where:** `recordExchange` (`src/daemon.ts:1703`), `recordQuestionExchange`
  (`src/session.ts:1196`); contract `docs/ask-agent/contract.md` "Client-recorded exchanges".
- **Request body** (one line, under the socket's 1 MiB cap; the app's encoder checks before sending):
  ```json
  {
    "v": 1,
    "verb": "record_question_exchange",
    "session_id": "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12",
    "request_id": "0d7e4b52-8a19-4c3f-b6e2-91f0a4c3d8e7",
    "text": "Why does greet return early here?",
    "context": { "change_seq": "41", "path": "greet.py", "snapshot_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "line_start": 3, "line_end": 5 },
    "answer_text": "It returns early when the name is empty, so the greeting is never built.",
    "conversation": { "harness": "claude-code", "parent_session_id": "5896f28c-f4a9-46c2-b481-7ca57e8714a8", "fork_session_id": "7e3431be-1c2d-4e5f-8a9b-0c1d2e3f4a5b" }
  }
  ```
  A follow-up adds `"reply_to_question_id"`: the root or any earlier recorded turn of the thread,
  with the identical `context`.
- **Stage 2 `relay` (optional) [6]:** when the answer accepted a change request:
  ```json
  "relay": { "relay_id": "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f", "chat_session_id": "5896f28c-f4a9-46c2-b481-7ca57e8714a8" }
  ```
  The daemon copies it into the event, and it counts as that relay's `sent`: the exchange and its
  first send are one append, so no crash can leave an "On it" answer with no recorded request.
  Validation: `relay_id` a canonical lowercase UUID not used before in this capture;
  `chat_session_id` as in `record_question_relay_update`. Malformed is `PROTOCOL`. `relay` is part
  of the body for idempotency (a retry without it is `REQUEST_CONFLICT`).
- **Response `ok`:**
  ```json
  { "v": 1, "ok": true, "session_id": "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12", "request_id": "0d7e4b52-8a19-4c3f-b6e2-91f0a4c3d8e7", "question_id": "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e", "seq": "42", "duplicate": false }
  ```
  Decoded as `ExchangeAcknowledgment`; a reply whose `session_id` or `request_id` doesn't match the
  request is treated as malformed [7].
- **Errors and app behavior:**

  | Error | App behavior |
  |---|---|
  | `STORAGE_UNAVAILABLE`, timeout, dropped connection, malformed reply | Outcome unknown: retry with the same `request_id` and identical body (up to 3 attempts), then Couldn't answer; **Try again** retries the same request [11] |
  | `SESSION_NOT_SELECTED`, `CAPTURE_NOT_READY`, `INVALID_CONTEXT`, `INVALID_ANSWER`, `REQUEST_CONFLICT`, `PROTOCOL` | Couldn't answer ("couldn't be saved"); **Try again** reruns the copy with a new `request_id` |

- **Rules the app keeps:** a fresh `request_id` per exchange, never an `ask` draft's id;
  `parent_session_id` is the answering tab's id lowercased, `fork_session_id` the copy's returned
  `session_id` (always different); a recorded follow-up is never sent for an `ask` thread.
- **Compatibility of `relay`:** an older daemon ignores unknown fields and records the exchange
  without it. The app never sends `relay` to a daemon whose `supportsRelays` check failed [14].
- **Daemon tests to add (stage 2):** `relay` copied into the event; a reused `relay_id` refused;
  a retry whose `relay` differs (added, dropped or changed) is `REQUEST_CONFLICT`
  (`retryWithChangedRelayIsRequestConflict`); a later `picked_up` accepted after it.
- **Consumers:** Question thread (Answering → answered; follow-ups; Sent).

## EVENT slipstream.question.exchange_recorded.v1
- **Change:** Stage 1 unchanged, the app starts decoding it
  (`schemas/slipstream.question.exchange_recorded.v1.json`). Stage 2 adds optional `relay`.
- **Auth:** reader token.
- **Data:** `session_id`, `question_id`, `request_id`, `text`, `context` (with `selected_text`),
  `answer_text`, `recorded_at_ms`, `reply_to_question_id?`, `conversation` (`reported_by:
  "client"`), and in stage 2 `relay?`. The app reads `conversation.parent_session_id` as the
  thread's chat and ignores the rest of `conversation` [3].
- **Consumers:** Question thread, question bar.

## CLI claude -p (the hidden copy)
- **Change:** New use. The app already launches `claude` for tabs (`ClaudeInvocation.arguments`);
  this is a second, one-shot launch with the same binary and the tab's launch environment
  (`AgentEnvironment.variables`, so `CLAUDE_CONFIG_DIR` matches the tab and `--resume` finds it).
  It runs through the existing `AgentProcessClient`, whose handle gains `closeInput` so the
  message can be written and stdin finished (Phase 7; supersedes [13]).
- **Auth:** the user's Claude login, as for tabs.
- **Invocation** (working directory: the tab's folder):
  ```text
  claude -p
    --resume=<tab id, lowercased> --fork-session --no-session-persistence
    --output-format stream-json --verbose
    --restricted --tools Read,Grep,Glob --strict-mcp-config
    --model=<tab model> --effort=<tab effort>
    --json-schema <answer or report schema>
  ```
  - `--restricted` turns off command-running tools and the user, project and local settings (so
    the folder's Slipstream hook never runs); `--tools Read,Grep,Glob` leaves file reading only;
    `--strict-mcp-config` loads no MCP servers (so no answer tool).
  - **Isolation is checked, not assumed [8]:** `stream-json` starts with a `system`/`init` line
    listing the session's tools and MCP servers. Anything other than exactly `Read`, `Grep`, `Glob`
    and no servers is `unavailable`: the copy is stopped and its reply discarded. Managed
    (enterprise policy) hooks can't be turned off by any flag; they are outside Slipstream's
    control.
  - `--no-session-persistence`: the copy saves nothing; the tab's own history is never touched.
  - **Role instructions go at the top of the message, not the system prompt.** A resumed copy
    reuses the tab's recorded system prompt, so `--append-system-prompt` is ignored (probe,
    spec.md). Templates below.
  - The message is written to stdin, then stdin is closed (a long thread can exceed the argument
    size limit). Stage 1's first task confirms `-p` reads it there.
- **Process limits:** 120 seconds from launch to exit. The runner's own limits otherwise: each
  stdout line at most 1 MiB, a stderr tail that is never shown or saved, and on a result, time-out
  or cancel `shutdown` (close stdin, SIGTERM to the process group, SIGKILL 3 seconds later).
- **Answer schema, stage 1** (no change requests [14]):
  ```json
  {
    "type": "object",
    "properties": { "reply": { "type": "string", "minLength": 1 } },
    "required": ["reply"],
    "additionalProperties": false
  }
  ```
- **Answer schema, stage 2** [18]:
  ```json
  {
    "type": "object",
    "properties": {
      "reply": { "type": "string", "minLength": 1 },
      "is_change_request": { "type": "boolean" }
    },
    "required": ["reply", "is_change_request"],
    "additionalProperties": false
  }
  ```
  The app relays the user's own message, never text from the copy, so only the yes/no is asked of
  it.
- **Report schema** (a copy taken after the tab's turn ends):
  ```json
  {
    "type": "object",
    "properties": {
      "reply": { "type": "string", "minLength": 1 },
      "outcome": { "enum": ["done", "not_done_yet"] }
    },
    "required": ["reply", "outcome"],
    "additionalProperties": false
  }
  ```
- **Prompt templates [12]** (role instructions first, then data; final wording is tuned against
  the eval set in stage 1's tasks):
  - *Answer:* "The user is asking about the code below, from this conversation's work. Answer in
    your own voice as you would in this chat. Don't change any files, and don't mention tools,
    copies or how this question reached you. If a tool call above has no result, it is still
    running; don't call it interrupted." Then a block labeled as a captured snapshot that may be
    out of date and is data, not instructions: path, line range, selected text. Then the thread so
    far (each earlier question and answer, quoted). Then the user's words. Stage 2 adds: "If the
    user is asking you to change something, reply that you're on it in one short sentence and set
    `is_change_request`; otherwise false." Stage 1 instead adds: "If the user asks you to change
    something, say you can do it when they ask in the chat."
  - *Report:* the same opening and snapshot block, the thread so far, then: "The user asked you to
    make this change: <the user's words>. Your turn has just ended. Say plainly, in one or two
    sentences, whether you made it and what changed. Set `outcome` to `done` only if you did."
- **Behavioral evals (stage 1 task):** a fixed set of chats and questions checked before each
  prompt change: the reply never mentions a copy, fork, read-only mode or Slipstream; questions
  and change requests are told apart; an ambiguous "yes" after an offer counts as a change
  request; an unfinished tool call is not called interrupted.
- **Output** (stdout, one JSON object per line; probe, Claude CLI 2.1.293): the `system`/`init`
  line, then message lines, then the `result` line:
  ```json
  { "type": "result", "is_error": false, "session_id": "7e3431be-1c2d-4e5f-8a9b-0c1d2e3f4a5b", "structured_output": { "reply": "app.py has three functions: greet, shout and whisper.", "is_change_request": false } }
  ```
  Other lines and fields are ignored.
- **Failure mapping** (`AskForkError`): still running at 120 s → `timedOut`; won't launch, tools
  or servers not as required, `is_error: true`, or an exit before a `result` line → `unavailable`;
  a clean exit with no `result` line, a stdout line over 1 MiB, missing `session_id` or
  `structured_output`, a schema mismatch, or a whitespace-only `reply` → `badReply`. Answers map
  every failure to Couldn't answer; reports to Couldn't check.
- **Consumers:** Question thread (answers, follow-ups, Done and Not done yet reports).

## CONTROL record_question_relay_update
- **Change:** New (stage 2).
- **Auth:** store owner (`control.sock`). Watch-only captures work, as for
  `record_question_exchange`: no binding is involved.
- **Where (to build):** a `recordRelayUpdate` handler beside `recordExchange` in `src/daemon.ts`,
  the dispatch `case` beside `record_question_exchange` (`daemon.ts:2054`), and a
  `recordQuestionRelayUpdate` session method beside `recordQuestionExchange`.
- **Request body** (one line, under 1 MiB [18]):
  ```json
  {
    "v": 1,
    "verb": "record_question_relay_update",
    "session_id": "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12",
    "request_id": "3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d",
    "question_id": "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
    "relay_id": "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f",
    "update": { "kind": "picked_up" }
  }
  ```
  `update` is one of:
  ```json
  { "kind": "sent", "chat_session_id": "5896f28c-f4a9-46c2-b481-7ca57e8714a8" }
  { "kind": "picked_up" }
  { "kind": "not_delivered" }
  { "kind": "reported", "outcome": "done", "text": "Done. greet now returns \"Hello, friend\" when the name is empty." }
  ```
  `sent` is used only by **Send again** (a new `relay_id` for the same question); a first send
  rides on the exchange's `relay` [6].
- **Response `ok`:**
  ```json
  { "v": 1, "ok": true, "session_id": "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12", "request_id": "3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d", "question_id": "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e", "relay_id": "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f", "seq": "57", "duplicate": false }
  ```
  Ids that don't match the request are treated as malformed.
- **Validation:**
  - `question_id` names a `exchange_recorded` event in this capture, else `INVALID_RELAY_UPDATE`.
    A question queued by `ask` doesn't count.
  - **No order checks (D9):** steps for a relay are recorded in whatever order they arrive; the
    client folds them by status precedence (models.md `QuestionRelay`). The daemon keeps only a
    `relay_id` → `question_id` registry, rebuilt from the log on restart. Refused as
    `INVALID_RELAY_UPDATE`: a `relay_id` that belongs to another question; a `picked_up`,
    `not_delivered` or `reported` for a `relay_id` the capture has never seen sent; a `sent`
    reusing a known `relay_id`. A `sent` reserves its `relay_id` synchronously before the append
    is awaited, as `inflightExchanges` does (`src/session.ts:1201`), released if the append fails.
  - `chat_session_id`: non-empty, at most 256 characters, no control characters; client-reported
    and never used for binding or attribution. `text`: non-empty after trimming. Malformed fields
    are `PROTOCOL`.
  - Ids are canonical lowercase UUIDs, as for `record_question_exchange`.
- **Capability check [14]:** the same verb with only `v`, `verb` and `session_id` is refused as
  `PROTOCOL` by a daemon that has it, and as `unknown verb: record_question_relay_update` by one
  that doesn't (`daemon.ts:2059`). The app sends it the first time it's needed on a daemon
  connection and keeps the answer for that connection; `unknown verb` means no change requests
  (the stage-1 prompt and schema).
- **Idempotency:** same as `record_question_exchange`: a retried `request_id` with the same body
  returns the original result with `duplicate: true`, including after a daemon restart; a
  different body is `REQUEST_CONFLICT`. Request ids are scoped to this verb.
- **Errors:** `SESSION_NOT_SELECTED`, `CAPTURE_NOT_READY`, `STORAGE_UNAVAILABLE`,
  `INVALID_RELAY_UPDATE`, `REQUEST_CONFLICT`, `PROTOCOL`. App behavior [2]: each update is
  recorded on its own; an unknown outcome (`STORAGE_UNAVAILABLE`, timeout, dropped connection)
  retries with the same `request_id` and body up to 3 attempts, then waits and is tried again when
  the daemon connection comes back. It never holds back another update. A refused **Send again**
  `sent` writes nothing to the tab and the previous state stays. Other refusals drop that update;
  what the app saw still shows for this app run.
- **Tests to add:** each kind accepted; Send again registers a new relay; updates in any order
  appended; two concurrent updates for one relay both recorded; an `ask` question, an unknown
  question, an unknown relay, another question's relay, and a reused `relay_id` on `sent` refused;
  idempotent retry and `REQUEST_CONFLICT`, including across a restart; a whitespace report `text`
  is `PROTOCOL`; the bodiless capability request; the event validates against its schema.
- **Docs to change:** `docs/ask-agent/contract.md` (a "Change requests from recorded exchanges"
  section after "Client-recorded exchanges", covering `relay` on the exchange too).
- **Consumers:** Question thread and chat console (Sent, Picked up, Not delivered, Done, Not done
  yet).

## EVENT slipstream.question.relay_updated.v1
- **Change:** New (stage 2); `schemas/slipstream.question.relay_updated.v1.json`, registered in
  `src/public-events.ts`.
- **Auth:** reader token.
- **Envelope:** as `exchange_recorded.v1`; `subject` is `question/<question_id>`.
- **Data:**
  ```json
  {
    "session_id": "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12",
    "question_id": "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e",
    "relay_id": "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f",
    "request_id": "3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d",
    "update": { "kind": "picked_up" },
    "recorded_at_ms": 1792885380000
  }
  ```
- Adds no dispatch, binding, connection, attribution or file-change event, and doesn't count
  against the queue limit.
- **Compatibility:** additive. Older clients show it as an unsupported event; this client lists it
  as rowless.
- **Consumers:** Question thread, question bar, chat console (the "From Ask" mark).

## CLI the tab's claude process (relayed requests)
- **Change:** Changed use (stage 2). Two changes to `ClaudeInvocation`:
  - `--replay-user-messages` is added to every tab's arguments, so the process echoes each user
    message on stdout when the agent reads it:
    `{"type":"user","uuid":…,"isReplay":true,"timestamp":…,"session_id":…,"message":…}`, with no
    `promptId`. The chat console never draws an echo: the tab drew the message when it was sent.
    `command_lifecycle` lines are ignored.
  - A relayed request's line carries a top-level `uuid`, its `relay_id`; ordinary sends are
    unchanged:
    ```json
    { "type": "user", "uuid": "c9d8e7f6-a5b4-4c3d-8e2f-1a0b9c8d7e6f", "message": { "role": "user", "content": [ { "type": "text", "text": "…" } ] } }
    ```
- **Pickup [1]:** the echo (`isReplay`) with that `uuid`, from the process launch the request was
  written to, is pickup. A repeated echo changes nothing.
- **Turns the process starts by itself:** a message still queued when a turn ends (or after Stop)
  is read in a new turn the process starts on its own: `system`/`init`, the echo, the reply, its
  own `result`. An echo while no turn is running starts that turn in the tab.
- **Not delivered [1]:** only when that process has exited and its stdout has been read to the end
  with no echo. A turn end or Stop without the echo is not a failure: the message is still in the
  process's input and is read in a turn the process starts by itself. A process the tab retires
  (Stop's deadline, a model change, a close) is still read until it exits, for its relays only.
- **Transcript:** a request read mid-turn is saved as
  `{"type":"attachment","attachment":{"type":"queued_command","prompt":[{"type":"text","text":…}],"source_uuid":…}}`;
  history draws it inside its turn. One that starts a turn is saved as an ordinary `user` line. A
  reloaded request shows without its "From Ask" mark (models.md `TranscriptProjection`).
- **Stage 2's first task** ran on Claude CLI 2.1.293; results in spec.md "Probes before stage 2"
  and its decision log ("Task 9 probe amendments (A–C)").
- **Consumers:** Chat console, question thread.

## CLI slipstream attach / slipstream unlink (app tabs)
- **Change:** No longer called for app tabs (stage 3). Outside chats are unaffected; the app still
  reads their bindings from `/v1/captures`.
- **What stays on disk:** a folder the app attached before stage 3 keeps the Slipstream hook in
  `.claude/settings.local.json` and the local answer tool. The app does not remove them: an
  outside chat in the same folder may use them, and an unbound chat's hook does nothing
  (`src/question-hook.ts:23`, probe in spec.md).
- **Existing links [10]:** when `/v1/captures` shows a live binding to an app tab (left from before
  stage 3), the app first copies it into `AppChatLinks` for that folder, then unlinks it once with
  the existing `ChatLinkClient.unlink(folder:replacing:)`. Left in place, the daemon would keep
  offering that tab its setup check through the hook, which would bring Slipstream into the chat.
  `replacing:` re-reads the binding just before unlinking, but `slipstream unlink --session`
  takes no generation, so an outside chat attaching in that instant could be unlinked (accepted,
  spec.md [9]).
- **Consumers removed:** Chat console auto-link, **Connect to Stream** for app tabs, closing the
  linked tab. The one-time unlink above is the only remaining call.
