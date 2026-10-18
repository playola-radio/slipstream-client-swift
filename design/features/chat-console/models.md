# Chat console — Model changes

The daemon is untouched. Every model here is a client Swift type, plus one small record list
persisted locally. The conversations themselves are not stored by Slipstream: they live in
Claude's own transcript files (see spec.md, "Existing contracts").

| Change | Model | Where | Summary |
|---|---|---|---|
| Changed | `SessionOption` | client `SlipstreamViewer/Models/FeedContent.swift` | Keeps the stream's folder (`root`) instead of dropping it after labelling |
| New | `ChatTabRecord` | client, persisted as one JSON file via `@Shared(.chatTabs)` | One open chat tab: its Claude session id, folder, model, effort, waiting flag |
| New | `ChatEffort` | client | The CLI's `--effort` levels |
| New | `AgentLine` | client `Sources/SlipstreamCore/` | One decoded line of Claude's stdout or transcript file (only the kinds v0.1 reads) |
| New | `TranscriptItem` | client `Sources/SlipstreamCore/` | One displayable row of the transcript |

## SessionOption — Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `root` | `String?` | Added | Absolute folder from the stream's `slipstream.session.started.v1` (`SessionStarted.root`), normalised (standardised, symlinks resolved), set in the same `loadSessions` pass that builds the label. `nil` until that stream's start record has loaded (or while it keeps failing). Read by the chat to pick the workspace's tabs |

- **Source of truth:** the daemon's start event; not persisted.
- **Carried across refreshes:** a rebuilt option keeps the previous option's (or
  `selectedSession`'s) `root` until a new one arrives, as `agentConnection` is carried today,
  and `selectedSession.root` is updated in the same place as its label.
- **While `root` is nil** the chat area shows the "No workspace" state for that stream.

## ChatTabRecord (`@Shared(.chatTabs)`) — New

Persisted as one JSON array, in tab order (oldest first), in a swift-sharing `fileStorage`
key at `<Application Support>/<bundle id>/chatTabs.json`. Only `ChatPageModel` writes it, on
the main actor.

```json
[{ "id": "4bad416c-1d04-4063-9e76-61ebb936ae06", "folder": "/Users/brian/code/slipstream-client-swift", "model": "claude-opus-5-5", "effort": "high", "isWaiting": true }]
```

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | UUID | no | new UUID | The Claude session id: passed as `--session-id` on the first launch and `--resume` after. Unique |
| `folder` | String | no | | Absolute path; the tab belongs to every stream whose `root` equals it. Also the process `cwd` |
| `model` | String | no | the current tab's, else `claude-opus-5-5` | `--model`. Read by the picker and at launch |
| `effort` | `ChatEffort` raw value | no | the current tab's, else `high` | `--effort` |
| `isWaiting` | Bool | no | `false` | Set when a turn ends while the tab isn't on screen (spec "Waiting marker"); cleared when a message to it is written successfully. Read by the tab title and the stream picker. Survives relaunch (Brian); can't be rebuilt from Claude's files, so it is stored |

- **Not stored, derived instead:**
  - Tab title: the latest `ai-title` line in the tab's transcript file; "New chat" if none.
  - First launch vs resume: whether the transcript file for `id` is found (found →
    resume, not found → new, unreadable → error; spec "Launch").
  - History: read from the transcript file when a tab is first shown after launch, and on
    Try again.
  - Working/idle, turn state, timers, drafts, process: in memory only (`ChatPageModel`); every
    agent is stopped on quit.
- **Integrity:** `id` unique (new ids come from `uuid`); `folder` absolute. Closing a tab deletes its record (and so its waiting flag). Records
  whose folder no stream currently reports are kept but not shown; v0.1 does no pruning.
- **Source of truth:** Slipstream is authoritative only for which tabs are open, their
  picker choice and the waiting flag. Everything about the conversation comes from Claude's
  files.
- **Unreadable data:** if the file can't be decoded the app starts with no tabs and the next
  write replaces it; the conversations themselves are untouched in Claude's files (simplicity
  gate #7).
- **Migration:** none; a missing key means no tabs. When Codex arrives, records gain a
  provider field and a missing one means `claude`.

## ChatEffort — New

`enum ChatEffort: String, Codable, CaseIterable { low, medium, high, xhigh, max }`, shown as
Low / Medium / High / Extra high / Max. Raw values are the CLI's `--effort` values.

## AgentLine — New

Decoded from one framed JSON line (framing rules in spec "Runtime design → Transcript"), by
one Claude adapter shared by the live stdout reader and the transcript file reader. Lines of
an unknown kind decode to `.ignored`. A supported line that doesn't decode, or a line over
the 1 MiB cap (discarded through its newline), decodes to `.gap` (a gap row); a control
request that doesn't decode is `.gap` too (it goes unanswered; Stop resolves the turn).

| Case | From | Payload |
|---|---|---|
| `assistant` | stdout and file `assistant` | `uuid`, `timestamp?`, content blocks: `text(String)`, `thinking(String)`, `toolUse(id, name, input JSON)` |
| `user` | stdout and file `user` | `uuid`, `timestamp?`, `isPrompt` (file: has `promptId`), content blocks: `text(String)`, `toolResult(toolUseID, text, isError)` |
| `result` | stdout `result` | `durationMs`, `isError`, `resultText` |
| `title` | file `ai-title` | `aiTitle` |
| `controlRequest` | stdout `control_request` | `requestID`, `subtype`, and the request's `input` JSON for `can_use_tool` (answered per spec "Existing contracts") |
| `gap` | a supported line (including a control request) that didn't decode, or an over-long line | — |
| `ignored` | anything else (including `system`/`init`, `session_state_changed` and `control_response`), and `isSidechain: true` file lines | — |

`tool_result.content` is a string or an array of blocks; text blocks are joined, any other
block becomes `[image]`/`[<type>]`. `timestamp` exists only on file lines; history footers use
it (spec "Transcript").

## TranscriptItem — New

What the transcript view shows, built from `AgentLine`s by one function used for both live and
resumed tabs.

| Case | Shows as |
|---|---|
| `userMessage(text)` | Grey right-aligned bubble |
| `reply(text)` | Plain text (markdown) |
| `thinking(text)` | Dim collapsible "Thinking" block, collapsed state in memory only |
| `toolCall(id, name, target, status, detail?)` | Muted one-liner; `detail` is the tool result, shown when expanded. `status` is `running`, `done`, `failed` (`tool_result.is_error`) or `stopped` (the turn ended with no result for it); the verb's tense comes from it ("Running `…`" with a spinner, "Ran `…`", "Ran `…` · failed"). Target comes from the tool's main input (`Edit` + `file_path` → "Edited `File.swift`"; `Bash` + `command` → "Ran `…`"; unknown tools → the tool name) |
| `turnFooter(ending, duration, time)` | "41s · 3:09 PM", copy (copies the turn's reply rows), "…"; a stopped turn reads "Stopped · 41s · 3:09 PM" |
| `gap` | "Part of this conversation couldn't be shown". Failed-turn and can't-start messages are not rows; they show in the tab's error area with Try again |

Each item has a stable id: the tool-use id for tool calls, otherwise the line `uuid` plus
block index; locally added user bubbles and footers use a client UUID. Live and history never
overlap (spec "Transcript"), so ids never need reconciling.
