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
