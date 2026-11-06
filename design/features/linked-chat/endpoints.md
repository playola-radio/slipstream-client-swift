# Linked chat — Endpoint changes

Slipstream's interface is not REST: the daemon (`playola-radio/slipstream`) exposes a CLI, verbs
on the owner-only `control.sock`, a GET-only reader, and the event log. Rows below use `CLI`,
`CONTROL` and `EVENT` in the Method column for those. Auth for all of them is local file
ownership of the store (`control.sock` is owner-only; the reader uses the in-memory bearer token,
never printed or persisted).

**Two daemon behaviors change:** the Claude version check, and what an unlink does to unanswered
questions. Everything else is an existing interface the app starts calling, listed so the
implementation session knows the exact contract. Daemon line references are at `origin/develop`
89eed57.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| Changed | CONTROL | `attach` (Claude root-transcript check) | store owner | Admit any Claude version and launch mode that passes the structural checks |
| Changed | CLI | `slipstream attach` (pre-flight) | store owner | Same check, run before the CLI installs config |
| Changed | CONTROL | `claim_question` / `answer_question` (after an unlink) | linked chat | Unanswered questions go to the next linked chat instead of being dropped |
| Changed | EVENT | `slipstream.question.dispatch_attempted.v1` (`target`) | reader token | Records which chat each attempt was handed to |
| Unchanged, newly called | CLI | `slipstream attach <folder>` | store owner | The app links a chat tab |
| Unchanged, newly called | CLI | `slipstream unlink --session <id>` | store owner | The app moves the link off the current chat |
| Unchanged, newly read | GET | `/v1/captures` (`binding.harness_session_id`) | reader token | The app learns which chat is linked |
| Unchanged, newly decoded | EVENT | `slipstream.agent.unlinked.v1` | reader token | The thread shows a moved question as re-sending |

## CONTROL attach (Claude root-transcript check)
- **Change:** Changed — behavior only; request and reply shapes unchanged.
- **Auth:** store owner (`control.sock`)
- **Where:** `verifyClaudeRootTranscript` (`src/claude-root-transcript.ts`), called by the daemon's
  `attach` and by the CLI pre-flight (`src/attach-workflow.ts:288-312`).
- **Request body:** unchanged (`{v:1, verb:"attach", worktree, harness:"claude-code", harness_session_id, root_transcript}`)
- **Behavior delta:**

  | Today | After |
  |---|---|
  | `RUNTIMES` pins `version`→`entrypoint` pairs (`2.1.280/284/300`→`sdk-ts`, `2.1.283`→`sdk-cli`); any other pair fails `unsupported-version` | `RUNTIMES` is deleted. The first identity record needs a non-empty string `version` and a non-empty string `entrypoint`, with no list of allowed values |
  | `entrypoint` must equal the pinned value for that version | `entrypoint` is any non-empty string; later records must repeat the same value (unchanged rule) |
  | Reason `unsupported-version` exists | Removed from `ClaudeRootResult`, with the CLI's "not a runtime Slipstream has verified" branch for Claude (`attach-workflow.ts:308`). Codex keeps its check |

  This is **broader structural admission**, not new verification. The remaining checks still fail
  closed: regular file opened without following symlinks, bounded head, every `sessionId` matches,
  first identity record has `cwd`, `version`, `entrypoint`, `userType: "external"`,
  `isSidechain: false`, `type` `user` or `attachment`, `realpath(cwd)` equals the worktree, later
  records consistent and `cwd` stays inside the root. Passing them does not prove the hook and
  answer tool work in that runtime: the link still reads `setup_pending` until the chat answers the
  setup check, so an unworkable runtime never reaches `connected`.

- **Response `200`:** unchanged — `{ "v": 1, "ok": true, "session_id": "…", "state": "recording", "binding_generation": "3", "agent_connection": "setup_pending", "created": false }`
  (`state` is the capture's lifecycle; the link's state is `agent_connection`, `daemon.ts:1317-1318`).
- **Errors:** unchanged codes; a version that was refused now succeeds or fails `IDENTITY_UNRESOLVED`
  for a structural mismatch.
- **Compatibility:** widening only; every transcript accepted today is still accepted. An app
  running against an old daemon or old CLI gets today's version refusal for unlisted versions,
  which the app shows as "Couldn't connect — update Slipstream". Claude 2.1.300 with `sdk-ts`
  links today; other versions the app accepts (minimum 2.1.293) need this change.
- **Tests to change:** `claude-root-transcript.test.ts` (unknown version and entrypoint now
  accepted; empty `version`/`entrypoint` and an `entrypoint` that changes between records still
  rejected), `daemon.test.ts:102-104`, `test/daemon-harness.ts:90`, `attach-workflow.test.ts`,
  `cli.test.ts:356`, `autocapture-acceptance.test.ts:716`.
- **Docs to change:** `docs/ask-agent/contract.md:230-235`, `docs/connect-agent-chat.md:62`,
  `README.md:154`.
- **Consumers:** Chat console; Conductor and terminal chats.

## CLI slipstream attach (pre-flight)
- **Change:** Changed — same delta as above; the CLI calls the same function before it installs
  the hook and answer tool, so it no longer refuses an unlisted Claude version.
- **Auth:** store owner
- **Consumers:** Chat console (via the app), terminal users.

## CLI slipstream attach <folder>
- **Change:** Unchanged; the app starts calling it.
- **Auth:** store owner. Run through `WorkspaceClient`'s existing `runSlipstream` pattern
  (`slipstream` from the login PATH, login-shell environment, stdout and stderr merged, last
  64 KiB kept).
- **Invocation:**
  - Arguments: `attach <tab folder>` (the folder is positional; `cli.ts:269`).
  - Environment, on top of the login-shell environment:
    - `CLAUDE_CODE_SESSION_ID=<tab id, lowercased>` (the tab id is the Claude session id).
    - `CLAUDE_CODE_EXECPATH=<the claude binary the app launches>`, so `claude mcp add` registers
      the answer tool with the same Claude the tab runs (`attach-workflow.ts:366`).
    - The base environment is the tab's own launch environment (`AgentEnvironment.variables`), so
      `CLAUDE_CONFIG_DIR` matches the tab's and the transcript search
      (`<CLAUDE_CONFIG_DIR ?? ~/.claude>/projects/*/<tab id>.jsonl`) looks where the tab writes.
    - `CODEX_THREAD_ID` and `CONDUCTOR_SESSION_ID` **removed** (the app may itself run inside a
      Codex or Conductor chat; with both chat ids set the CLI refuses, `attach-workflow.ts:232`).
  - The transcript must already exist, so the app only calls this for a tab whose chat has sent a
    message.
- **Side effects to expect:** starts the daemon if none is running (`ensureDaemon`,
  `attach-workflow.ts:64`); creates a capture for the folder if there is none
  (`daemon.ts:1304-1308`); installs the hook and answer tool into the folder.
- **Output** (merged, parsed line by line; never contains the bearer token). Success:
  ```text
  Installed the Slipstream question hook in /Users/me/slipstream/workspaces/playola/workspace-2/.claude/settings.local.json
  Installed the Slipstream answer tool for this workspace (claude mcp add --scope local).
  Recording /Users/me/slipstream/workspaces/playola/workspace-2; agent setup pending.
  Next step: …
  session_id: 6f3c1e0a-…
  agent_connection: setup_pending
  ```
  The `Installed …` lines appear only when config was added. The app does not use them: the
  linked tab's process is restarted when idle whenever it launched before the attach (models.md,
  `ChatTabModel.reloadWhenIdle`).
- **Outcome mapping** (`LinkOutcome`; exit code first, then the last `slipstream: …` line):

  | Exit | Output | `LinkOutcome` | App behavior |
  |---|---|---|---|
  | 0 | `session_id:` and `agent_connection:` lines | `.linked` | Refresh; reload the tab when idle |
  | 1 | `…transcript is still being written…` (CLI pre-flight) or `slipstream: IDENTITY_UNRESOLVED: root Claude transcript head is not complete yet…` (daemon, `daemon.ts:1270-1271`) | `.retryLater` | Try again at the next turn end while nothing is linked (models.md, auto-link) |
  | 3 | capture still starting after 90 s | `.retryLater` | Same |
  | 1 | `slipstream: BINDING_LIMIT_REACHED: …` | `.refused(.slotsFull)` | "Couldn't connect" (10 links in use) |
  | 1 | `slipstream: BINDING_EXISTS: …` | `.skipped` | Refresh; show whichever chat holds the link; never unlink it |
  | 1 | `…is not a runtime Slipstream has verified…` (old CLI pre-flight, `attach-workflow.ts:308`) | `.refused(.slipstreamTooOld)` | "Couldn't connect" (update Slipstream) |
  | 1 | `slipstream: IDENTITY_UNRESOLVED: root Claude transcript identity is unsupported-version` (new CLI, old daemon: `daemon.ts:1268-1274,1301`, relayed by `attach-workflow.ts:131`) | `.refused(.slipstreamTooOld)` | Same |
  | 1 | `…this chat is linked, but setup is incomplete…` (`attach-workflow.ts:81-90`) | `.refused(.setupIncomplete(message))` | "Couldn't connect" with the message; the link exists, and the failure is kept until setup is confirmed (models.md, `linkFailures`) |
  | 1 | any other `slipstream: …` line | `.refused(.other(message))` | "Couldn't connect" with the message |

  Every outcome, including failures, is followed by a `/v1/captures` refresh; a refused attach can
  still have linked the chat or created a capture. The two version-refusal rows are tested
  separately: old CLI with new daemon, and new CLI with old daemon.
- **Consumers:** Chat console (auto-link; **Connect to Stream**; the next tab after the linked tab
  closes).

## CLI slipstream unlink --session <id>
- **Change:** Unchanged; the app starts calling it.
- **Auth:** store owner, same `runSlipstream` pattern.
- **Invocation:** `unlink --session <capture session_id>` (the capture, not the chat).
- **Output** (`src/withdraw-workflow.ts:52-110`). Online, the daemon reply's fields as
  `key: value` lines:
  ```text
  session_id: 6f3c1e0a-…
  binding_generation: 3
  ```
  Nothing linked: `session_id: …` then `already_unlinked: true`. No daemon running: the CLI records
  the unlink offline, prints `slipstream: no daemon is running; the unlink is recorded…` on stdout
  and **exits 0**. All three map to `.unlinked`.
- **Errors:** exit 1 with `slipstream: <CODE>: <message>` from the daemon, or a plain
  `slipstream: <message>` for local failures (store locked). Maps to `.refused(.other(message))`.
  The unlink may have taken effect anyway (revocation happens before later failures,
  `daemon.ts:1549-1576`), so the app refreshes and does not attach.
- **Order:** a move is one queued operation (`ChatLinkClient.link(replacing: G)`): re-read
  `/v1/captures`, stop if the live binding's generation is not `G`, then `unlink`, then `attach`
  for the chosen tab. `attach` alone can't replace a link (`BINDING_EXISTS`). The whole operation,
  including the re-read, holds the app-wide actor, so no two app operations interleave.
  This is best-effort: `unlink` revokes whatever binding exists when it runs
  (`daemon.ts:1536-1549`), so something outside the app that replaces the link between the re-read
  and the unlink loses it (accepted, models.md `ChatLinkClient`); another workspace can take the
  freed slot before the attach. The app reports what the refresh shows and never retries a move on
  its own.
- **Consumers:** Chat console (**Connect to Stream** on another tab or over an outside chat;
  closing the linked tab).

## CONTROL claim_question / answer_question (after an unlink)
- **Change:** Changed — behavior only; request and reply shapes unchanged.
- **Auth:** the linked chat (the handlers already refuse any caller that is not the folder's linked
  root chat, `daemon.ts:1714-1767`).
- **Where:** `src/session.ts` (`onCommitted` :360-380, `seedTaskState` :315-328, `claimQuestion`
  :1198-1217, `answerQuestion` :1221-1249) and `src/recovery.ts`.
- **Behavior delta:**

  | Today | After |
  |---|---|
  | `agent.unlinked.v1` clears every claimable question (`session.ts:361-365`); the user must ask again | An unlink keeps every question queued after the latest `session.resumed` that has no answer; the next linked chat can claim it until its original `expires_at_ms`. A resume still drops them (D1 unchanged) |
  | `claimQuestion` hands out only questions whose queued `target` is the caller | The queued target's chat id no longer limits claiming; worktree, expiry and the one-claim reservation still do. The handler has already proved the caller is the linked chat |
  | An attempt records only `question_id`, `queued_seq`, `attempted_at_ms` | It also records `target` (the chat it was handed to) |
  | `answerQuestion` accepts an answer only from the queued target, with the latest attempt's seq | Accepts an answer from any chat an attempt was handed to (attempts without `target` use the queued target), while that chat is linked; `attempt_seq` is that chat's latest attempt |
  | Recovery seeds claimable questions from `taskResetSeq` (resume or unlink) | Recovery seeds them from the latest resume, minus any question with an answer or with an attempt after the latest unlink, so a restart after a move re-offers the same questions |

  A question that passed its ownership check just before an unlink commits is queued for the old
  chat after it (`session.ts:1144-1149`); it is claimable by the new chat like any other.
- **Unchanged:** a question the linked chat claimed is not offered again while that chat stays
  linked (contract D2). An old chat that is unlinked can neither claim nor answer
  (`SESSION_NOT_SELECTED`). A chat linked again later (A→B→A) can answer its original copy.
- **Docs to change:** `docs/ask-agent/contract.md` D2 ("never automatically offers that question
  again after commit") gains the unlink exception.
- **Consumers:** the linked chat's question hook and answer tool; Question thread (reads the result
  as events).

## EVENT slipstream.question.dispatch_attempted.v1
- **Change:** Changed — adds one field.
- **Data:**
  ```json
  { "question_id": "…", "queued_seq": "412", "attempted_at_ms": 1761300100000, "target": { "harness": "claude-code", "harness_session_id": "0b8e6c52-…", "worktree": "/Users/me/slipstream/workspaces/playola/workspace-2" } }
  ```
- **Compatibility:** additive. Older events have no `target`; readers fall back to the question's
  queued target. The client ignores the field.
- **Consumers:** daemon answer ownership.

## GET /v1/captures
- **Change:** Unchanged; the app reads one field it used to drop.
- **Auth:** reader token
- **Response `200`** (excerpt — the fields newly read):
  ```json
  { "as_of_ms": 1761300000000, "binding_slots": { "used": 1, "limit": 10 }, "captures": [{ "session_id": "6f3c1e0a-…", "root": "/Users/me/slipstream/workspaces/playola/workspace-2", "binding": { "harness": "claude-code", "harness_session_id": "0b8e6c52-…", "binding_generation": "3", "state": "connected", "reason": null } }] }
  ```
  A revoked link keeps its row with `state: "unlinked"` and the old `harness_session_id`
  (`daemon.ts:597-606`), so the app treats only `setup_pending` and `connected` as "this chat is
  linked".
- **Consumers:** Chat console (link icon, outside-chat label, the generation check inside each
  link operation), Ask panel notices.

## EVENT slipstream.agent.unlinked.v1
- **Change:** Unchanged; the client starts decoding it (it is `.unsupported` today).
- **Auth:** reader token, via the existing `GET /v1/sessions/:id/events` follower.
- **Data:**
  ```json
  { "session_id": "6f3c1e0a-…", "binding_generation": "3", "reason": "unlinked" }
  ```
  `reason` is `unlinked`, `detached` or `archived`; only `unlinked` marks turns as re-sending. The client keeps only `reason`.
- **Consumers:** Question thread (marks unanswered turns as re-sending).
