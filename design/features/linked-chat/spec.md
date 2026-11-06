# Linked chat — Ask reaches a chat tab in the app

**Status:** Phase 1 (scope) approved by Brian 2026-10-24. Phase 3 complete (all screens approved). Phase 4 complete (models and endpoints approved). Phase 5 review done; dispositions approved and applied. Phase 6 plan written. Phase 7 simplicity gate done; cuts applied, the three that changed approved decisions approved by Brian.

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `30027d33261924371b2611adb58a7fa4aa9506d9` (develop)
- Daemon (`playola-radio/slipstream`): `89eed57601be4583b8f7eecf9445b7fc3e42c390` (develop)

## Target surfaces

- `client` — the macOS app (chat tab strip, Ask notices, linking).
- Daemon — the Claude version check for linked chats (below). No new wire verbs are expected;
  Phase 4 confirms.

## Why

Ask-at-a-line currently answers "No chat linked" unless the user runs `slipstream attach`
inside an outside chat. The app already runs the agent chat in its own tabs, so the app should
link one of those tabs itself. Slipstream is moving to be self-sufficient (Brian, 2026-10-24;
client PR #39, daemon PR #83); outside hosts stay supported as an option.

## Scope

1. **Ask is unchanged.** The Ask button, composer and question thread behave as today, except
   that questions go to a chat tab in the app instead of requiring `slipstream attach`, and
   questions interrupted by a link move go to the newly linked chat (item 7).
2. **Auto-link.** A workspace with nothing linked automatically links its first chat tab — the
   first tab in strip order whose chat has sent a message (Slipstream can't link a chat before
   its first message). Until then the first tab shows the amber "waiting" icon. While nothing is
   linked, auto-link runs when a window opens and at the end of every reply, and never unlinks
   anything. If Slipstream says to try again shortly, the next reply's end tries again; there is
   no timer (Phase 7, Brian approved).
3. **Indicator.** The linked tab shows a small link icon beside its title in the tab strip.
4. **Moving the link.** Right-click any tab → **Connect to Stream** moves the link to that tab
   (menu wording: Brian, 2026-10-24). It is greyed out, with "Send this chat a message first.",
   on a tab whose chat hasn't sent a message. Moves are best-effort (unlink, then attach, run as
   one operation at a time across the app): if the attach fails, the workspace is left unlinked
   and the tab shows "Couldn't connect" (item 10). The app only unlinks the link it just read; a
   link that something outside the app swaps in during that instant can still be removed
   (accepted, Decision A).
   (Claude's call, Brian delegated it as "closest to best practice": context menu plus a
   persistent icon on the linked tab; no hover icon on every tab, to avoid clutter.)
5. **Outside chat already linked.** If a Conductor or terminal chat holds the link, the app
   leaves it linked (Brian). A small "Stream: outside chat" label sits at the right end of the tab
   strip, and **Connect to Stream** on any tab pulls the link into the app (Brian: "there should be
   some way to pull it here").
6. **Closing the linked tab** (Claude's call): the link moves to the first remaining tab in strip
   order whose chat has sent a message; if none has, the first tab waits as in item 2. Closing the
   last tab already opens a fresh one (`ChatPageModel.swift:160-171`).
7. **Re-sending when the link moves** (Brian, 2026-10-24: "it should re-ask automatically";
   mechanism revised in Phase 7, Brian approved). Today the daemon drops unanswered questions
   when a link moves. After this change it keeps them and hands them to the next linked chat,
   including questions the old chat had received but not yet answered, until each question's
   original pickup expiry. The app sends nothing extra.
   - The question thread shows "Re-sending to the newly connected chat…" from the move until a
     chat picks the question up, then today's waiting line. One question stays one question; an
     answer from either chat answers it, including a late answer from the old chat after the link
     returns to it.
   - This works with the app closed: the daemon does the handing over.
   - Questions dropped because recording restarted are still dropped: they point into the old
     recording. They keep today's "Ask again" wording.
   - The new chat gets the question and selected code, not the thread's earlier back-and-forth.
8. **Setup behind the scenes** (Claude's call; revised in Phase 5): the app links a tab after
   its first message, because `slipstream attach` needs the chat's transcript. That attach also
   installs the Slipstream hook and answer tool. A running chat doesn't load them, so once the
   linked tab is idle the app shuts its process down; the next message resumes the conversation
   with `--resume` and loads them. The rule is "the process started before the attach", not
   "this attach installed files", so a tab that was running when another tab installed them is
   covered too.
9. **All Claude versions possible** (Brian, 2026-10-24: "We should support all claude versions
   possible"). The daemon drops its fixed list of tested version/launch-mode pairs
   (`src/claude-root-transcript.ts:8-13`) and admits any Claude version whose root transcript
   passes the existing structural checks (matching session id, root folder inside the
   workspace, `userType: external`, not a subagent, consistent version/launch mode across
   records). Anything that fails those checks still fails closed. This is broader admission,
   not new verification: a runtime whose hook or answer tool doesn't work still never reaches
   `connected`, because the setup check gates it. The plan requires end-to-end tests with
   app-launched new and resumed chats.

   Evidence: an app-run chat in `~/slipstream/workspaces/playola/workspace-2` wrote
   `version 2.1.293`, `entrypoint sdk-ts`, which the current list rejects. Local transcripts
   show versions 2.1.237–2.1.300 across launch modes `cli`, `sdk-ts` and `sdk-cli`.
10. **Couldn't connect** (Claude's call, approved by Brian in Phase 5): when linking a tab fails,
    the tab shows an orange broken-link icon whose hover gives the reason (old Slipstream, all 10
    link slots in use, or Slipstream's own message) and says to retry with Connect to Stream.
    Memory only; it clears when the tab's link reads `connected`, the tab closes, or the user
    retries. (A setup failure leaves the tab linked but `setup_pending`, so only `connected`
    counts as recovery.)

## Non-goals

- No change to the Ask composer or answer display; the question thread gains only its
  "Re-sending" line (item 7).
- The daemon still never launches agents; the app does.
- A chat the app runs is never a capture source and never emits file-change events.
- No fork-based Ask (`--fork-session` + `record_question_exchange`); superseded 2026-10-24.
- No change to Codex linking.
- No hover link icon on every tab.

## Decision log

- 2026-10-18 the client-run chat was not to use `slipstream attach`. **Reversed by Brian
  2026-10-24:** the app links its own chat tab using the attach/answer-tool route.
- 2026-10-24 Brian: auto-link the first chat tab; outside link stays until pulled in; support
  all Claude versions possible. Phase 1 scope approved ("Looks good").
- 2026-10-24 Brian approved the **Chat console** screen (4 states in `screens.md`, nodes `bgbqq`,
  `A5mpnw`, `x19r6e`, `QNVHN`) with one change: the menu item reads **Connect to Stream**, not
  "Use for Ask". Claude aligned the hover title ("Connected to Stream") and the outside label
  ("Stream: outside chat") to match.
- 2026-10-24 Brian approved the **Ask panel** notices ("yes"; 2 states in `screens.md`, nodes
  `s2EAnj`, `liVhQ`). Outside-chat links keep today's `slipstream attach` wording.
- 2026-10-24 Brian: questions interrupted by a link move are re-sent automatically (scope item
  7). Brian approved the **Question thread** screen ("yes"; 2 states in `screens.md`, nodes
  `Ycgxv`, `nohgj`). (`nohgj` was removed in Phase 7.)
- 2026-10-24 Brian approved **models.md** and **endpoints.md** ("yes"). This settles two earlier
  open questions: the client keeps `harness_session_id`, and Claude's `entrypoint` may be any
  non-empty string that stays the same across records (no fixed list).

- 2026-10-24 Phase 5 (Codex adversarial review, `/tmp/linked-chat-review.txt`; findings and
  dispositions below). Brian approved every proposed disposition ("Agree with all go ahead"),
  including **Decision A** — no new daemon verb for an atomic link swap; link moves are
  best-effort, one app operation at a time, reconciled from `/v1/captures` — and **Decision B** —
  three new Chat console states.
- 2026-10-24 Brian approved the three new **Chat console** states ("yes"; nodes `ui5E0`,
  `ex52E`, `M4jmt` in `screens.md`): Connect to Stream greyed out, first tab waiting, and
  Couldn't connect. This replaces the earlier "pending link" choice (`pendingLinkTabIDs`), which
  is removed from `models.md`.

## Adversarial review (Phase 5)

Codex (`gpt-6-astra`), read-only, against client `cf5b8df` and daemon `89eed57`. Twelve findings;
none left blocking.

> Phase 7 replaced the client re-send design these findings were about (1, 4, 5, 6, 11, R2, R3 and
> the verification pass). Their dispositions stay below as history; the current contract is in
> `models.md` and `endpoints.md`, and the acceptance tests in the plan.

| # | Finding | Disposition |
|---|---|---|
| 1 | A dispatched question is not dead after unlink: after A→B→A, A can still answer it | **Resolved.** A re-send is another attempt at the same turn; every attempt id is kept and an answer to any of them answers the turn (`models.md` QuestionTurn) |
| 2 | Unlink then attach can't keep the previous link or survive concurrent moves | **Accepted with rationale** (Decision A). Best-effort moves, one app-wide queue of whole link operations, a generation check before unlink, refresh after every outcome. No rollback promise (scope item 4). Narrowed in the re-review (R1) |
| 3 | Setup before launch is impossible: attach needs the transcript | **Resolved.** Scope item 8 revised: link after the first message, then reload the process when idle |
| 4 | Re-send deadline and status order contradict the 30 minutes | **Resolved.** `deadlineMs` is the original expiry across hops; it limits re-sending, not pickup; terminal drop reasons outrank "re-sending"; "re-sent" and "too late" are derived |
| 5 | Replay could trigger re-sends from an intermediate state | **Resolved.** Folding stays pure; the window's existing follower re-sends only after catch-up plus a `connected` refresh, with generation checks; unwatched workspaces wait |
| 6 | Re-sends break reply drafts, unread answers and follow-up generation | **Resolved.** `models.md` QuestionThreadPageModel: drafts match any attempt; `resending` counts as waiting; new follow-ups use the current generation |
| 7 | CLI contract errors (attach `state`, exit 1 vs 3, capture creation, partial failures, `ensureDaemon`, unlink output, uncoded errors) | **Resolved.** `endpoints.md` corrected; typed `LinkOutcome`; refresh after every outcome |
| 8 | Restart rule keyed to install lines misses already-running sibling tabs | **Resolved.** Reload is keyed to "process started before the attach" (`ChatTabModel.reloadWhenIdle`) |
| 9 | Missing or unreachable UI states | **Resolved.** Three new Chat console states; "next tab" defined; last-tab case already replaced by a fresh tab. Detached/archived recordings keep today's behavior (out of scope) |
| 10 | Dropping the version list is broader admission, not equal verification; "every app tab is refused today" is false | **Resolved.** Scope item 9 and `endpoints.md` reworded; end-to-end tests required; Phase 2 claim corrected |
| 11 | Ask errors and capacity incomplete | **Resolved.** Full ask error table; retries only on the next trigger, no loop; anything not re-sent shows "Not delivered" at its deadline |
| 12 | Identity definitions loose | **Resolved.** Decode `harness` too, optional fields, canonical UUID comparison, derived flags |

Acceptance tests the plan must carry (from the review): new and resumed app-launched chats end to
end (attach → setup check → confirmation → question → answer) on a disposable store; missing,
partial, ambiguous and mismatched transcripts, custom config directory, inherited Codex identity,
UUID case; two running tabs, mid-turn attach and idle reload; concurrent auto-links and explicit
moves, stale unlink, slot 10/11, attach failure after unlink; A→B→A late answer; UUIDv5 test
vectors and duplicate sends; older-generation parent accepted with the same context, changed
context rejected; deadline across hops, exactly at expiry; recording restart after a re-send;
replay with no premature sends; open reply picks up the new generation; every `LinkOutcome`;
queue saturation; both compatibility directions; and the full existing question, reply, chat,
capture-status and daemon attach/ask/answer suites.

### Re-review

Codex (`gpt-6-astra`), read-only, against client `cf5b8df` and daemon `89eed57`, on the revised
docs (`/tmp/linked-chat-rereview.txt`). Verdict "not ready"; seven findings, all resolved or
accepted below. None left blocking.

| # | Finding | Disposition |
|---|---|---|
| R1 | Serializing single calls doesn't serialize a move; `unlink` revokes whatever binding exists, so "never unlink an unchosen binding" was false | **Resolved + accepted.** `ChatLinkClient` closures are now whole operations (re-read → generation check → unlink → attach) on the app-wide queue. The remaining race with something outside the app is accepted in writing (models.md `ChatLinkClient`, scope item 4); the overclaim is removed |
| R2 | An accepted re-send could show "Re-sending" forever after it expired | **Resolved.** Each attempt keeps its expiry, target chat and dispatch state; an undispatched re-send past its own expiry shows "Not delivered". Copy changed to "Not delivered — the link moved before it was answered. Ask again." (mockup `nohgj` updated). **Superseded in Phase 7:** the state and its copy are removed |
| R3 | No verifiable catch-up point; a committed-but-failed ask or `duplicate: true` could be mistaken for delivery | **Resolved.** Catch-up means the follower applied events through `durable_seq` from `GET /v1/sessions`, read after each link change or send outcome. Eligibility: the latest attempt was dropped by an unlink or targets another chat; replies only move the head, never count as delivery |
| R4 | The new-CLI/old-daemon version refusal (`IDENTITY_UNRESOLVED: … unsupported-version`) was unmapped | **Resolved.** Both forms map to `slipstreamTooOld` (and the daemon's "not complete yet" form to `retryLater`); both compatibility directions are tested |
| R5 | A setup failure would be erased by the refresh that shows the tab linked | **Resolved.** `setupIncomplete` stays until the link reads `connected`, a later attempt succeeds, the tab closes, or the user retries |
| R6 | Auto-link retries contradicted the closed list of start moments, and couldn't fire on an idle tab | **Resolved.** Starting and continuing are separate: `retryLater` retries on the clock (5 s, at most 3), one per window, with stated cancellation |
| R7 | `tryAgain` relaunches immediately; the reload described it wrongly | **Resolved.** The reload reuses only `retireProcess()`; the next send launches with `--resume` and awaits any retirement in progress |

Added acceptance tests: an operation interleaving two windows' moves; a re-send that expires
undispatched; a committed ask that fails `STALE_BINDING`, then a re-send under a new id; a
`duplicate: true` reply aimed at the old chat; a setup failure that survives the refresh; auto-link
retry on an idle tab, and its cancellation; send during a pending reload; A→B→A before any
re-send still re-sends to A.

Verification pass (Codex `gpt-6-astra`, read-only, `/tmp/linked-chat-verify.txt`): R1–R7 all
confirmed fixed. It found one new defect: endpoints.md required the latest attempt to target a
different chat, which would strand a question after A→B→A (the unlink clears A's pending copy,
`session.ts:361-365`). **Resolved:** both docs now re-send when the latest attempt was dropped by an
unlink *or* targets another chat.

## Simplicity gate (Phase 7)

Two read-only reviews of the plan against the real code, run in parallel: Codex (`gpt-6-astra`,
`/tmp/linked-chat-simplicity-codex.txt`) and a Claude Opus subagent. Both asked whether the whole
feature, and each piece, could be smaller.

**Approved by Brian 2026-10-24 ("1. yes 2. yes 3. sure")** — these change earlier decisions:

1. **The daemon keeps moved questions; the client stops re-sending.** Replaces the client re-send
   machinery (attempt history, request ids derived from the original question, catch-up gating
   on `durable_seq`, the ask error table, expiry wake-ups) with one daemon change: an unlink
   keeps unanswered questions claimable by the next linked chat, and answer ownership follows the
   chat each attempt went to. New PR E. Removes the "Not delivered in time" state (`nohgj`).
2. **No auto-link retry timer.** Auto-link runs at the end of every reply while nothing is linked;
   `retryLater` waits for the next one.
3. **The Ask "No chat tab open" notice becomes "nothing connected".** The old state couldn't show
   (the workspace always keeps a tab). New copy: "No chat is connected yet. Send a message in a
   chat tab to connect it." (node `s2EAnj`).

Other dispositions (no earlier decision changed):

| Finding | From | Disposition |
|---|---|---|
| Fold the standalone client data PR into the behavior PRs | both | **Adopted.** PRs are D, E (daemon), B, C (client) |
| `LinkOutcome.linked` payloads (`sessionID`, `agentConnection`) unread | both | **Adopted.** Bare `.linked` |
| `claudeConfigDir` parameter duplicates the tab's environment | both | **Adopted.** Attach uses `AgentEnvironment.variables` |
| Ask notice Boolean (`isConfirmed`) duplicates the binding state | both | **Adopted.** Notice derives confirmation from `agentConnection` |
| Redundant request-id tests | both | **Adopted** (moot after 1) |
| Slim attempt records; `resendCandidates` prefilter | Codex | **Adopted** (moot after 1) |
| `AgentUnlinked.bindingGeneration` unread | Codex | **Adopted.** Only `reason` is kept |
| `bindingGenerationChanged` duplicates `captureChanged` | Codex | **Adopted.** `captureChanged` replaces the cached generation |
| "Expose `WorkspaceClient.run`" step: already internal with an environment parameter | Codex | **Adopted.** Step removed |
| `CaptureBinding.harness` unread once the tab id is a fresh UUID | Opus | **Adopted.** Not decoded |
| `BINDING_EXISTS` as a refusal: the refresh already shows the other chat | Opus | **Adopted.** Maps to `.skipped`; `otherChatLinked` removed |
| Two `linkFailures` clearing rules | Opus | **Adopted.** One rule: clears on `connected`, close, or retry |
| Reload reimplements process retirement | Opus | **Adopted.** Reuses `shutdown()` |
| `attemptIndex`, `UnlinkReason` enum | Opus | **Adopted** (moot after 1; reason is a `String`) |
| Fold unlink into `link` with a nil tab | Opus | **Rejected.** Two named operations read more clearly |
| Drop the app-wide operation actor | Codex (considered) | **Rejected.** Decision A depends on it |
| Drop the idle reload | Codex (considered) | **Rejected.** A running chat never loads the hook or answer tool |

## Open questions

- None open. Phase 4 settled the earlier two (see decision log).

## Design deliverables

- Screens: [screens.md](./screens.md) — all three screens approved (Chat console, Ask panel,
  Question thread).
- Endpoints: [endpoints.md](./endpoints.md) — two daemon behaviors change (the Claude version
  check, and unlink keeping unanswered questions); the rest are existing daemon interfaces the
  app starts calling. Approved 2026-10-24; corrected in Phase 5; revised in Phase 7.
- Models: [models.md](./models.md) — client types plus one daemon event field; nothing new on
  disk. Approved 2026-10-24; revised in Phase 5 and Phase 7.
- Implementation plan: [implementation-plan.md](./implementation-plan.md) — four PRs (two daemon,
  two client).

## Existing contracts (Phase 2, surveyed 2026-10-24 at the base commits)

### Client

- **Chat tabs.** `ChatTabRecord {id, folder, model, effort, isWaiting}`
  (`SlipstreamViewer/Models/ChatTabRecord.swift:5`).
  - The tab `id` is the Claude session id: `--session-id` for a new tab, `--resume` once a
    transcript exists (`ChatTabModel.swift:330`).
  - Records persist in one global `@Shared(.chatTabs)` file and are filtered by `folder`.
  - The "first tab" is the first record for that folder in array order. Nothing on the record
    stores a binding.
- **Launch.** `claude --print … --permission-mode=bypassPermissions
  --setting-sources=user,project,local` (`Sources/SlipstreamCore/ClaudeInvocation.swift:9-23`).
  - It runs in `record.folder` with the login-shell environment.
  - Because `local` is a setting source, a hook in `.claude/settings.local.json` loads at launch.
  - `tryAgain` (`ChatTabModel.swift:243`) relaunches with `--resume`.
- **Tab strip.** `ChatPageView.swift:34` (`tabStrip`) and `ChatTabView` (`:147`). There is no
  context menu today.
- **Tab ↔ capture.** Matched by folder equality: tab `record.folder` == capture `root`
  (`ChangeStreamPageModel.swift:635,819`).
- **Binding model.** `CaptureBinding` decodes `binding_generation`, `state` and `reason` only
  (`Sources/SlipstreamCore/Captures.swift`).
  - It drops `harness` and `harness_session_id`, so the client can tell *that* a chat is
    linked but not *which*.
  - States: `setup_pending`, `connected`, `unavailable`, `unlinked`.
  - `agent.binding.v1` and `agent.unlinked.v1` events decode to `.unsupported`
    (`Events.swift:238-241`).
- **Ask notices.** `CaptureStatus.askNotice` (`SlipstreamViewer/Models/CaptureStatus.swift:132-152`)
  tells the user to "Run `slipstream attach` inside the agent chat". `chatText` says "No chat
  linked". Both need app-linked wording.
- **Daemon calls.**
  - Control socket: `ask` is the only verb sent (`ControlTransport.swift`; `exchange` is private
    and typed to questions).
  - Readers: `GET /v1/captures`.
  - `WorkspaceClient` already shells out to the `slipstream` CLI (`WorkspaceClient.swift:76`).

### Daemon (`playola-radio/slipstream` @ 89eed57)

- **`attach`** (`src/daemon.ts:2038-2051`).
  - Request: `{v:1, verb:"attach", worktree, harness, harness_session_id, root_transcript}`.
  - Reply: `{session_id, state, binding_generation, agent_connection, created}`.
  - `BINDING_EXISTS` when the capture already holds a different chat. There is no in-place
    swap: the caller unlinks, then attaches.
- **Hook and answer-tool install is CLI-only** (`src/attach-workflow.ts`, `planAgentConfig` /
  `applyAgentConfig`).
  - The hook is a PostToolUse entry in `<worktree>/.claude/settings.local.json`.
  - The answer tool is installed with `claude mcp add --scope local slipstream …`.
  - The no-flag `slipstream attach` detects the chat from `CLAUDE_CODE_SESSION_ID`, finds its
    transcript, installs config, then attaches.
  - The identity-flag form (`--harness … --harness-session-id … --root-transcript`) attaches
    without installing config (`src/cli.ts:882`).
- **`unlink {session_id}`** (`src/daemon.ts:1536-1582`) revokes the binding and appends
  `agent.unlinked.v1`.
  - Queued, unclaimed questions are cleared silently (`src/session.ts:361-365`). No event is
    written.
  - Questions are never redelivered after a relink.
- **Reader binding.** `GET /v1/captures` row `binding` = `null | {harness, harness_session_id,
  binding_generation, state, reason}` (`src/daemon.ts:597-632`).
  - A connected binding with a stale owner heartbeat reads `setup_pending`.
- **Setup check.** After attach the binding is `setup_pending`.
  - The chat's next tool call fires the hook, which returns a `setup_check`.
  - The agent answers it with `slipstream_answer_question(check_id, "connected")`. Only then
    is the binding `connected`.
  - Connection state is memory-only, so a daemon restart returns every link to `setup_pending`.
  - A newly linked tab that makes no tool call stays `setup_pending`.
- **Question lifecycle.** The events are `question.queued.v1` (30-minute `expires_at_ms`),
  `question.dispatch_attempted.v1` and `question.answered.v1`.
  - There is no dropped, undelivered or expired fact (`docs/ask-agent/contract.md:286`).
  - "Not delivered" must be derived by the client: the question was queued under a binding
    generation that is no longer current, or its expiry passed with no dispatch attempt.
- **Claude version check.** `RUNTIMES` (`src/claude-root-transcript.ts:8-13`) pins exactly
  `2.1.280`/`2.1.284`/`2.1.300` with `sdk-ts`, and `2.1.283` with `sdk-cli`.
  - It is also checked pre-flight in `src/attach-workflow.ts:~178`.
  - Tests pin it in `claude-root-transcript.test.ts`, `daemon.test.ts:102-104`,
    `test/daemon-harness.ts:90`, `attach-workflow.test.ts`, `cli.test.ts:356` and
    `autocapture-acceptance.test.ts:716`.
  - Docs list it in `docs/ask-agent/contract.md:230-235`, `docs/connect-agent-chat.md:62`,
    `README.md:154` and `IMPLEMENTATION_PLAN.md:1084-1103`.
  - The app's own minimum is Claude 2.1.293 (`AgentEnvironmentClient.swift:38`). Tabs on
    2.1.300 (`sdk-ts`) pass today; every other version the app accepts is refused. (Corrected in
    Phase 5; this said "every app-run tab is refused".)

### Consequences for the design

- The simplest link path reuses the CLI: the app runs `slipstream attach <folder>` with
  `CLAUDE_CODE_SESSION_ID=<tab id>`. That one call installs the hook and answer tool and
  attaches. Phase 4 confirms whether the env-detection path works outside a chat.
- A relink is `unlink` then `attach`. The app needs an unlink call: CLI `slipstream unlink`,
  or a control verb.
- A newly linked tab sits at "waiting to confirm" until its next tool call. The Ask notice
  must say so plainly. Whether the app sends a nudge is a Phase 3/4 question.
