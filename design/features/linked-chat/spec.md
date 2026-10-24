# Linked chat — Ask reaches a chat tab in the app

**Status:** Phase 1 (scope) approved by Brian 2026-10-24. Later phases pending.

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

1. **Ask is unchanged.** The Ask button, composer and question thread behave as today. The only
   change is that questions go to a chat tab in the app instead of requiring `slipstream attach`.
2. **Auto-link.** A workspace with nothing linked automatically links its first chat tab.
3. **Indicator.** The linked tab shows a small link icon beside its title in the tab strip.
4. **Moving the link.** Right-click any tab → **Use for Ask** moves the link to that tab.
   (Claude's call, Brian delegated it as "closest to best practice": context menu plus a
   persistent icon on the linked tab; no hover icon on every tab, to avoid clutter.)
5. **Outside chat already linked.** If a Conductor or terminal chat holds the link, the app
   leaves it linked (Brian). A small "Ask: outside chat" label sits at the right end of the tab
   strip, and **Use for Ask** on any tab pulls the link into the app (Brian: "there should be
   some way to pull it here").
6. **Closing the linked tab** (Claude's call): the link moves to the next tab; with no tabs
   left, the workspace becomes unlinked. Questions the agent never picked up are dropped by the
   daemon when a link moves, so the question thread shows them as not delivered rather than
   waiting forever.
7. **Setup behind the scenes** (Claude's call): the app installs the Slipstream hook and answer
   tool into the workspace before starting any chat. A tab already running when it becomes
   linked is restarted with its conversation resumed so it can receive questions.
8. **All Claude versions possible** (Brian, 2026-10-24: "We should support all claude versions
   possible"). The daemon drops its fixed list of tested version/launch-mode pairs
   (`src/claude-root-transcript.ts:8-13`) and accepts any Claude version whose root transcript
   passes the existing structural checks (matching session id, root folder inside the
   workspace, `userType: external`, not a subagent, consistent version/launch mode across
   records). Anything that fails those checks still fails closed.

   Evidence: an app-run chat in `~/slipstream/workspaces/playola/workspace-2` wrote
   `version 2.1.293`, `entrypoint sdk-ts`, which the current list rejects. Local transcripts
   show versions 2.1.237–2.1.300 across launch modes `cli`, `sdk-ts` and `sdk-cli`.

## Non-goals

- No change to the Ask composer, question thread, or answer display.
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

## Open questions

- Exact wording of the Ask notices for app-linked states (Phase 3).
- How the app learns which tab is linked: the client currently drops `harness_session_id` from
  the binding (`Sources/SlipstreamCore/Captures.swift:54-75`) though the daemon sends it
  (Phase 4).
- Whether "consistent launch mode" should also accept any `entrypoint` string or a known set
  (`cli`, `sdk-ts`, `sdk-cli`) (Phase 4/5).

## Design deliverables

- Screens: pending (Phase 3) — chat tab strip (linked icon, outside-chat label, context menu)
  and Ask notices.
- Endpoints: pending (Phase 4) — daemon wire contract (attach/unlink/binding), expected to
  change only the Claude version check.
- Models: pending (Phase 4) — client binding model gains the linked chat's identity.

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
  - The app's own minimum is Claude 2.1.293 (`AgentEnvironmentClient.swift:38`), so every
    app-run tab is refused today.

### Consequences for the design

- The simplest link path reuses the CLI: the app runs `slipstream attach <folder>` with
  `CLAUDE_CODE_SESSION_ID=<tab id>`. That one call installs the hook and answer tool and
  attaches. Phase 4 confirms whether the env-detection path works outside a chat.
- A relink is `unlink` then `attach`. The app needs an unlink call: CLI `slipstream unlink`,
  or a control verb.
- A newly linked tab sits at "waiting to confirm" until its next tool call. The Ask notice
  must say so plainly. Whether the app sends a nudge is a Phase 3/4 question.
