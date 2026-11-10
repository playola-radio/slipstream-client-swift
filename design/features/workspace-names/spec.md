# Workspace names

Give every sidebar workspace a short, steady name that says what it is about. The agent sets
the name once the work is clear. Brian can rename any workspace, and his name always wins.

Supersedes `design/features/stream-names/` (approved 2026-10-14, never implemented). That
design is reused for storage and validation. What changes is how the agent supplies the name
and where the user renames it.

## Base commits

| Repo | Branch | SHA |
|---|---|---|
| Client `playola-radio/slipstream-client-swift` | `develop` | `3f49250` |
| Daemon `playola-radio/slipstream` (owns the wire contract) | `origin/develop` | `4117951` |

## Target surfaces

- `client`: the macOS app (`SlipstreamViewer`) and `SlipstreamCore`.
- Daemon: store, control socket, `GET /v1/sessions`, MCP tool list, `SKILL.md`, README,
  `docs/ask-agent/contract.md`.

## The problem

From Brian, 2026-11-10: "looking at the sidebar and not knowing who is doing what." Sidebar
rows show the worktree folder name (`tacoma-v2`, `bilbao-v1`). That name says nothing about
the work.

## Scope

1. **Steady name.** Each workspace gets a short display name of 2–5 words, for example
   "Workspace rename menu". It is a separate name, not the latest task title. Brian chose this
   over showing the latest task title.
2. **The agent names it once the work is clear.** It does this at its first real task, not at
   attach. It may rename later if the work genuinely changes direction.
3. **Brian renames any time.** Right-click a sidebar row and choose **Rename…**. Once he has
   renamed a workspace, the agent's names never replace his. They are still stored but never
   shown.
4. **Fallback.** Before any name exists, the row shows the folder name, as it does today.
5. **Display-only.** Renaming never changes the folder, the branch or the worktree.
6. **Every row.** This applies to every sidebar row, including Conductor-linked and
   terminal-linked workspaces.
7. **Every label.** The name replaces the folder name in the breadcrumb (top bar) and
   anywhere else the app labels a workspace (see "Label surfaces").

## Non-goals

- Renaming folders, branches or worktrees.
- Rename history, or a rename record in the session log.
- Unique names. Duplicates are allowed.
- HTTP write endpoints. HTTP stays GET-only.
- Inheriting a name across sessions. A genuinely new session for the same worktree starts
  unnamed; see D3.
- Naming captures that have no session history yet. Their Rename item is disabled; see D7.
- Fixing first-turn linking of fresh app chats. The agent names the workspace on its first
  linked turn; see D9.
- `slipstream attach --name`, CLI `--name`, attach-output naming lines, and a
  `workspace-names-v1` attach feature gate. All of these came from stream-names and are
  dropped.

## Decisions

**D1 — Storage (kept from stream-names D1).** Names live in a sidebar file
`sessions/<id>/name.json`:

```json
{ "version": 1, "agent_name": "…" | null, "user_name": "…" | null }
```

The daemon publishes it crash-safe, under one daemon-wide metadata lock that teardown
drains. That lock is also the authority fence: a teardown, activation-loss or store-lock-loss
transition serializes with its holder, so a write admitted while it owns the fence either
commits before revocation takes effect or sees revocation before it can submit its rename.
Each writer re-checks its authority immediately before publishing (see
[endpoints.md](./endpoints.md)).

**D2 — Effective name (kept).** The name shown is `user_name ?? agent_name ?? folder name`.

**D3 — The named unit is the session id, not the path.** A normal resume keeps the session
id, so it keeps the name. A genuinely new session for the same worktree starts unnamed and
inherits nothing by path.

**D4 — Validation (kept from stream-names D3).** The steps run in this order:

1. Reject C0 and C1 control characters, U+2028 and U+2029. This check runs before trimming.
2. Trim with ECMAScript trim.
3. Reject an empty name.
4. Reject a name longer than 64 UTF-8 bytes.

A rejection returns `INVALID_NAME`. The daemon tests these rules against an inline case
table. The app checks the same rules live only to drive the dialog's states; the daemon is
the authority. The 2–5 word target is guidance in the tool
description, not something the daemon validates.

**D5 — The agent names the workspace through a separate MCP tool.** The tool is
`slipstream_name_workspace(name, replace_existing?)`, backed by a new control verb,
`name_workspace`. It is not a parameter on `slipstream_begin_task`, for four reasons (Codex
consult, grounded in daemon code):

- begin_task's `request_id` dedupe and the forwarder's retry cover only the task event.
- begin_task's schema forbids extra properties.
- An older forwarder extracts only `title`, so a name sent through begin_task would be
  dropped silently.
- A separate tool has its own clear semantics.

The tool has these rules:

- **Who can call it.** It requires the same identity triple (`harness`, `harness_session_id`,
  `worktree`) as begin_task, and the same linked-chat checks.
- **Default.** It sets `agent_name` only if none is set yet. With `replace_existing: true`,
  it replaces `agent_name`. This keeps the name steady when an agent calls the tool on every
  task, while still allowing a deliberate rename when the direction changes. The default is
  my call, from the Codex recommendation.
- **User name.** It never touches `user_name`.
- **Reply.** It returns `{ changed }`.
- **Instructions.** The begin_task tool description, the new tool's description and
  `SKILL.md` all tell the agent when to call it: on the first task, once the work is clear,
  with a 2–5 word name. They say to replace the name only if the work changes direction.
- **Compatibility.** The tool keeps the existing exact daemon-build-match gate.

**D6 — Brian renames through `rename_session` (kept from stream-names).** The control verb
`rename_session { session_id, name | null }` writes or clears `user_name` and replies
`{}`. `null` clears `user_name`, which is the "Use agent's name" menu item.
Saving the displayed agent name as Brian's own name is allowed; it pins that name.

**D7 — Rows with no session history.** Some rows exist only in `/v1/captures` and have no
session directory. Their Rename item is disabled, with the reason in a tooltip. The agent cannot name these
rows either until it starts a task. This is my call; Codex proposed adding metadata init for
admitted captures, and I chose the simpler option.

**D8 — Refresh by polling.** The app polls `GET /v1/sessions` every 2 seconds while the
window is visible and the app is active.

- The rule from stream-names was "no polling", and D8 reverses it. The existing refresh
  moments do not show an agent-set name promptly.
- **One refresh owner.** `ChangeStreamPageModel` owns every session-list refresh. The poll
  tick and the refresh after a rename go through the existing coalescing `reloadSessions()`,
  so ticks never pile up: a request that arrives while one is in flight marks "run again".
  Other existing callers still load directly; the existing generation check is what keeps a
  stale response from publishing.
- **Cheap ticks.** A session's start record is immutable, so it is fetched only until the
  session's folder is known; a steady poll tick costs one `/v1/sessions` and one
  `/v1/captures` request. The timestamp session label goes: nothing reads it once every label
  surface uses the name resolver. The
  daemon-side cost (a tombstone and tail read per retained session, plus one `name.json`
  read) is accepted at a few dozen sessions every 2 s.
- **Lifetime.** The poll runs in a task started when the window appears and the app is
  active, and cancelled when the window disappears or the app resigns active. Reactivation
  refreshes immediately, then resumes the 2 s cadence.
- **One publication step.** A refresh updates `sessions` and the `selectedSession` snapshot
  together, including `naming`, so the sidebar and breadcrumb never disagree.
- A failed poll keeps the current labels.
- `naming` is absent from older daemons, and the client treats that as "no names".

**D9 — First-turn limitation accepted.** A fresh app chat is not linked or tool-capable on
its first turn, so it names the workspace on its first linked turn. That still matches "once
it becomes clear what the workspace is about".

**D10 — Rename UI.**

- Right-clicking a row opens an icon-led menu (Conductor style) with **Rename…**, **Use
  agent's name** and, below a divider, **Archive** where the row can be archived today. New
  items go above the divider.
- **Rename…** is enabled or disabled with no inline explanation; a disabled item shows its
  reason as a tooltip (Brian).
- **Use agent's name** is enabled only while a user name is set.
- **Rename…** opens a "Rename workspace" dialog, modeled on Conductor's (Brian). It replaces
  the inline row edit. The field opens with the current name selected. Return saves and Esc
  cancels. There is no "Also rename branch" option, because renaming is display-only.
- One model owns every name mutation (Rename and "Use agent's name"): the target session id,
  the draft, the active mutation and the error. It serializes them: while either a rename or
  clear is in flight, neither menu action starts another mutation. A rename completion only
  updates the dialog if that same session's dialog is still open.
- The dialog's draft is captured when it opens; polls never change it.
- While saving, Cancel, Esc and the field are disabled, so the dialog can't be dismissed
  mid-write.
- After any write, success or failure, the owner requests a list refresh, so a write whose
  reply was lost still shows up.
- "Workspace gone" shows only on `SESSION_NOT_FOUND` (the session was deleted). Archiving
  keeps history, so an archived workspace can still be renamed.
- A failed "Use agent's name" uses the existing workspace-failure alert
  (`workspaceFailed(title:text:)`), titled "Couldn't switch back to the agent's name". Its
  message is the raw error, and the alert gains a "Copy error" button.
- Every failure shows the whole error: a headline that names the failure plus the raw
  `CODE: message` in a selectable monospace block with Copy ([screens.md](./screens.md#rename-workspace-dialog)).
- There is no double-click rename and no toolbar picker; the picker no longer exists.

Brian chose right-click → Rename, the Conductor-style menu and dialog, and the tooltip. The
rest are my calls.

## Label surfaces

The effective name replaces the folder name in each of these places:

- the sidebar row (`SidebarGroup.rowName`);
- the breadcrumb (`breadcrumbWorkspaceText`);
- the queued-question notice (today `SessionOption.label`);
- the "No chat connected" copy in `InstantAskModel` (it is passed the display name instead of
  building one from the folder);

Terminal and recording strings keep the folder name: they are about the folder itself
("Setting up tacoma-v2…" runs before any session exists).

All of them go through one resolver, `SidebarGroup.rowName(_:)`. `SessionOption.label`
stays only as that resolver's last fallback; no other copy of the effective name is stored.

These places are unchanged:

- The window title stays "Slipstream".
- No notification uses the name.

## Acceptance criteria

Daemon:
1. `name_workspace` on an unnamed session sets `agent_name` and replies `changed: true`; a
   second call without `replace_existing` replies `changed: false` and leaves it.
2. `replace_existing: true` replaces `agent_name`; the same name replies `changed: false`.
3. `name_workspace` never changes `user_name`; `rename_session` never changes `agent_name`.
   Interleaved writes from both keep both fields.
4. `rename_session` with `null` clears `user_name`; the list then shows `agent_name`.
5. Every case in the validator's case table is accepted or rejected as listed, with the
   listed reason.
6. Activation loss, store-lock loss and shutdown injected between admission and
   publication: nothing is published, and the reply is `STORAGE_UNAVAILABLE`. Unlink drains
   an in-flight name write.
7. A rename racing a delete leaves the session removed; `gc` removes any leftover
   `name.json`.
8. A malformed `name.json` reports both names `null` for that session and logs once; the
   rest of the list is unaffected; the next write replaces the file.
9. A non-boolean `replace_existing` is rejected with `PROTOCOL` through the MCP tool.
10. A lost reply to the tool returns `OUTCOME_UNKNOWN` without a resend.

Client:
11. Rows, breadcrumb, queued-question notice and "No chat connected" copy all show
    `user ?? agent ?? folder`, and update together within one refresh.
12. An agent name set while the app is active appears within one poll (≤ 2 s plus request
    time); no poll runs while the window is hidden or the app is inactive.
13. Poll ticks coalesce while a refresh is in flight, and a steady tick fetches no start
    records (TestClock, controlled responses).
14. Each dialog state in [screens.md](./screens.md) is reachable from the model with the
    listed copy; the draft is unchanged by a poll.
15. Decoding: absent or malformed `naming` → `nil`, and the rest of the list still decodes;
    both inner values may be `null`.
16. Clearing sends `"name": null` explicitly.
17. A new client with an older daemon shows folder names and a disabled Rename.

## Open questions

None blocking. Brian can override D7 (disabled Rename on history-less rows) and D9 (naming
on the first linked turn) if either feels wrong in use.

## Adversarial review (Phase 5)

Codex (gpt-6-astra, high effort, read-only, grounded in client `3f49250` and daemon `4117951`),
2026-11-10. Dispositions:

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Resending a name isn't safe under intervening writes or relinks | Blocking | **Resolved.** No automatic resend in the forwarder or the app; a lost reply returns `OUTCOME_UNKNOWN` / "may have saved" ([endpoints.md](./endpoints.md)) |
| 2 | An authority check at the front of the lock doesn't protect publication | Blocking | **Resolved.** Binding captured at entry, write registered in the capture's in-flight set, and authority re-checked immediately before the atomic rename; post-publication revocation mirrors `beginTask` |
| 3 | "Generation-protected" polling doesn't name one refresh owner, and each refresh fans out to every session's start record | Blocking | **Resolved.** D8: one coalescing owner sharing `refreshGeneration`, start records cached per id, an explicit lifetime |
| 4 | `sessions` and `selectedSession` are separate snapshots; `label` is another stored name | Should-fix | **Resolved.** One resolver; one publication step updates both snapshots ([Label surfaces](#label-surfaces)) |
| 5 | "Workspace gone" claimed archive, but archive keeps history and rename accepts it | Should-fix | **Resolved.** Gone only on `SESSION_NOT_FOUND`; copy changed to "deleted" (screen C, needs re-approval) |
| 6 | Undesigned outcomes: clear failure, older-daemon tooltip, invalid characters, refresh after write, draft vs poll, late completion | Should-fix | **Resolved** in D10 and [screens.md](./screens.md): one mutation owner with a generation check, a stable draft, an alert for a failed clear, copy variants on existing frames. "Saved but refresh failed" needs no state: the dialog closes on success and the next poll updates the row |
| 7 | `decodeIfPresent` and synthesized optionals don't enforce the wire contract; a clear must send `null` | Should-fix | **Resolved** ([models.md](./models.md), [endpoints.md](./endpoints.md)) |
| 8 | The forwarder drops a non-boolean `replace_existing`; no ack validation; success text overclaims | Should-fix | **Resolved** |
| 9 | One malformed `name.json` takes down the whole session list | Should-fix | **Resolved differently from Codex's options.** Names are display-only, so a malformed file reads as unnamed with a logged warning, and the next write repairs it. Codex advised against silent fallback; the log line keeps it visible, and losing a label beats losing the list |
| 10 | No acceptance criteria for the risky behaviour; the fixture can't be loaded into Swift as-is | Should-fix | **Resolved.** [Acceptance criteria](#acceptance-criteria); `wire_only` fixture group |
| 11 | Per-session vs daemon-wide lock contradiction; "wedged" isn't a lifecycle state | Nit | **Resolved.** One daemon-wide chain; admission is "not compromised and not tearing down" |

No blocking findings remain.

Phase 7 (below) later simplified the mechanisms behind findings #2, #6, #7 and #10, with
Brian's approval.

## Simplicity gate (Phase 7)

Codex (gpt-6-astra, read-only) and a Claude Opus reviewer, run in parallel and grounded in
client `6de9526` and daemon `4117951`, 2026-11-10. Dispositions:

| # | Finding | From | Disposition |
|---|---|---|---|
| 1 | Fold agent naming into `slipstream_begin_task` | Opus | **Rejected** (Brian: "separate is good"). Codex: a bad name would fail the task, and begin_task's resend would have to replay the name write |
| 2 | Drop the shared fixture, the client validator module and cross-repo SHA pinning | Opus (Codex: drop the pin test) | **Adopted** (Brian). Daemon tests an inline table; the dialog model checks empty, too long and control characters live; `INVALID_NAME` covers the rest. Reverses Phase-5 #10 |
| 3 | Lenient `naming` decoding | Opus | **Adopted** (Brian). Malformed → `nil`, like `agent_connection`. Reverses Phase-5 #7's strict decoding |
| 4 | Drop the binding re-check before publishing an agent name, and the post-publication `STALE_BINDING` remap | Opus | **Adopted** (Brian). The write targets the session linked at entry; store-safety check kept. Reverses part of Phase-5 #2 |
| 5 | Delete timestamp session labels; fetch start records only until the folder is known | Codex | **Adopted.** Nothing reads the label once the queued notice uses the resolver |
| 6 | Drop `rename_session`'s delete re-check | Opus | **Adopted.** A stray `name.json` in a tombstoned directory is already harmless |
| 7 | Drop the lock-entry teardown re-check | Opus | **Adopted.** The publication check covers it |
| 8 | Don't re-validate names on read | Opus | **Adopted.** The daemon is the only writer |
| 9 | Drop `session_id` from both replies and the client echo check | Opus | **Adopted.** No consumer; each request has its own socket |
| 10 | Generation counter in the naming model | Opus | **Adopted** as "same dialog still open" guard; Cancel/Esc are disabled while saving |
| 11 | Duplicate flags (`isFieldDisabled`/`isCancelDisabled`, a second app-active flag) | Opus | **Adopted.** One `isSaving`; reuse the chat model's `isAppActive` |
| 12 | Recording and terminal label plumbing | Opus | **Adopted.** Those strings are about the folder |
| 13 | Copying `beginTask`'s admission block | Codex | **Adopted.** One synchronous shared helper, with no await before `track` |
| 14 | Duplicate docs, an impossible resume test, tests re-testing existing loading | Opus | **Adopted** |
| 15 | A selection assertion the model can't observe | Codex | **Adopted.** Model test checks the current name; selection is checked in manual QA |
| 16 | New `WorkspaceNameClient` file instead of a closure on an existing client | both | **Rejected.** `RecordingClient` is record/pause and `DaemonClient` is HTTP reads; one small, correctly named file reads better |
| 17 | Route every existing direct `loadSessions` caller through the coalescer | Codex | **Rejected.** The generation check already prevents stale publishes; rerouting is new scope |
| 18 | Drop the older-daemon tooltip once the daemon is bundled | Opus | **Rejected for now.** Bundling isn't on the base commits |

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: [endpoints.md](./endpoints.md)
- Models: [models.md](./models.md)

## Decisions log

- 2026-11-10: Brian chose a steady 2–5 word name over the latest task title (option 2). He
  approved the agent naming the workspace once the work is clear, with renames allowed if the
  direction changes ("yes that's perfect").
- 2026-11-10: Brian chose right-click → Rename as the only manual entry point.
- 2026-11-10: Brian approved the full playback, including my calls on "Use agent's name",
  inline edit, label surfaces, display-only renaming, all rows and the folder fallback. He
  also approved sizing this as a written design with two PRs, daemon first ("that's good --
  let's continue").
- 2026-11-10: Brian approved Screen A, sidebar rows show names (frame `m4oCq`, rev 1): no visual distinction between agent and user names; the folder name is the fallback; the breadcrumb uses the name ("yes looks good").
- 2026-11-10: Brian asked for a Conductor-style menu and rename dialog ("lets do it more like
  this"), then for no inline explanation on a disabled Rename, only a tooltip with the reason.
- 2026-11-10: Brian approved Screen B, row context menu (frames `xfT4i`, `xZXUI`, `U3Dpwr`,
  rev 2 with tooltip), and Screen C, rename dialog (frames `T7NimN`, `VsUYq`, `vSnUH`,
  `I3qxN`, `WQ2uK`, `q1Niht`, rev 1, which has the display-only helper line and no "Also
  rename branch" option) ("looks good -- saved it").
- 2026-11-10: Brian approved `models.md` and `endpoints.md` (rev 1), including my calls: no
  new attach-feature flag, Archive in the row menu, and the fixture renamed to
  `workspace-name-cases.json` ("yes go ahead").
- 2026-11-10: Codex architecture consult (gpt-6-astra, session `01a1c6f8…`). I adjudicated
  it as D3, D5, D7, D8 and D9 above.
- 2026-11-10: Brian approved the Phase-5 review dispositions and two copy changes to screen C
  (rev 2): Save failed → "Couldn't confirm the name was saved — Slipstream didn't respond. Try
  again."; Workspace gone → "This workspace was deleted, so it can't be renamed." Also the
  invalid-character message and the older-daemon tooltip as copy variants on existing frames
  ("yes looks good"). Frames `WQ2uK` and `q1Niht` still show the rev-1 copy; they are updated
  and re-exported in Phase 8.
- 2026-11-10: Brian approved the Phase-7 simplicity dispositions that reverse Phase-5 fixes
  (#2, #3, #4 above) and kept the separate naming tool ("1. Ok separate is good 2. Ok all
  good").
- 2026-11-10: Brian accepted full error text for rename failures (answer to question 3): Save
  failed shows a headline that names the failure plus the raw `CODE: message` in a selectable
  monospace block with Copy; the clear-failure alert shows the raw error and a "Copy error"
  button (screen C rev 3, frame `WQ2uK`). My call: today's control transport keeps no detail
  for "couldn't connect" and "no reply" (no errno, no step), so those two show a fixed
  sentence after their code. Capturing that detail changes `QuestionError` for every caller
  and is left to a separate change.
- 2026-11-10: Brian approved screen C rev 3 ("saved and approved"): frame `WQ2uK` with the
  "didn't reply" headline and the raw-error block with Copy, and frame `q1Niht` with the
  "deleted" copy. All frames re-exported in Phase 8.
