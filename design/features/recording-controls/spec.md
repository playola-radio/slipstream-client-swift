# Recording controls — choose which workspaces the daemon records, from the sidebar

**Status:** Design complete. Screens, endpoints and models approved; adversarial review and simplicity gate done (no blocking findings); implementation plan at [implementation-plan.md](./implementation-plan.md).

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `7749fcce5f33250ac3b8f8e85df8de9eee96dcf7` (develop).
- Daemon (`playola-radio/slipstream`): `b736f77c1c9728354767e708f067a8427f172567` (develop). This
  feature changes the daemon (capture cap and the waiting queue).

## Target surfaces

- `client`: the workspace sidebar in the macOS app's one window.
- Daemon: the capture limit and the attach control request.

## Why

Before this feature the daemon attached itself to every Conductor workspace: `conductor setup`
hooks ran `slipstream attach` on every new workspace, and `conductor enroll` captured all existing
ones. It filled its 16 slots, queued the rest, and auto-admitted queued workspaces whenever a slot
freed. Brian could not tell from the app what was recording, and could not stop or start one
without the CLI.

Brian's rule: **nothing records automatically. A workspace records only because Brian asked, from
the app.** The Conductor setup hooks were removed by hand on 2026-11-02 (backups in
`.context/conductor-settings-backup/`), and the old auto-captures were detached.

## Scope

1. **The sidebar shows recording state.** A recording workspace looks as it does today. A
   workspace the daemon knows but is not recording (detached, not archived) shows as a dimmed row
   instead of being hidden.
2. **Pause / Record on each row.** Pause detaches the workspace (the daemon's existing withdraw).
   Record attaches it watch-only. Re-recording the same folder resumes the same session; the
   paused time shows in the stream as a gap.
3. **Record a folder…** at the bottom of the sidebar records any folder chosen in a folder picker.
4. **The app's New Workspace still records** the workspace it creates, as today. If the daemon is
   full, the workspace is still created but isn't recorded; the Setup tab shows the daemon's
   refusal, and **Record a folder…** records it once a slot is free.
5. **Daemon cap 16 → 32.** When all 32 slots are in use, Record is refused with a plain message
   ("All recording slots are in use. Pause a workspace first."). The waiting queue and its
   auto-admit go away.
6. **Pause unlinks the chat**, as detach does today. A chat can't link to a paused workspace,
   and only Record resumes one; opening or using a chat never restarts recording.

## Non-goals

- Any automatic attach: no Conductor hook, no enroll, no "record everything open".
- A separate paused state in the daemon. Pause is detach.
- Recording-rule settings, schedules, or per-repo defaults.
- Changing how archive works.

## Open questions

1. ~~A paused workspace with a linked chat~~ — decided 2026-11-02 to keep the link; **reversed
   2026-11-03: Pause unlinks**, as detach does today. Keeping the link needed new daemon rules for
   unlink, archive, rollback and chat slots (adversarial review findings 2–5); unlinking needs
   none.
2. ~~Should a paused row offer "Remove from sidebar"?~~ — not in this feature. A paused row goes
   away when its folder is deleted or archived.
3. ~~Are archived workspaces hidden entirely?~~ — yes, as today (unless selected).
4. ~~Rerun the real-use resource check at 32?~~ — yes; it is a ship gate for the daemon PR (see
   Acceptance criteria).
5. ~~Chat-link limit~~ — decided 2026-11-03 to raise it to 32; **reverted 2026-11-03**: paused
   workspaces hold no links, so it stays at 10.

## Existing contracts

Daemon control socket (`docs/autocapture/contracts.md` §5, newline-delimited JSON):

| Verb | Request | Result today |
|---|---|---|
| attach (watch-only) | `{v:1, verb:"attach", mode:"watch-only", worktree}` | `{session_id, state, created}`. Same root resumes its existing session with a gap. With 16 running intents: writes a `waiting` intent and returns `CAPTURE_LIMIT_REACHED` ("…It starts automatically when another workspace is archived or detached."). `ROOT_OVERLAP` for ancestor/descendant roots. |
| detach | `{v:1, verb:"detach", target}` | Withdraws capture and binding intent, stops the capture (`capture.stopped{detached}`). Stopped target: `already_stopped: true`. |
| status | `{v:1, verb:"status"}` | Every capture with state, reason, retry and binding. The same rows are served over HTTP as `GET /v1/captures`, which the client reads as `CaptureList` (`Sources/SlipstreamCore/Captures.swift`). |

Client today: `ControlTransport` sends `ask`, `recordExchange`, `updateRelay`; it has no attach or
detach. The sidebar lists `pickerSessions`, which hides any session whose capture is inactive
(`CaptureStatus.isInactive`) unless it is selected.

Live store on 2026-11-02: 147 captures — 6 recording, 101 archived, 40 detached. Of the 40
detached, 13 folders still exist; 27 are gone. Showing every detached capture would add 27 dead
rows, so the sidebar shows a paused row only when its folder exists.

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: [endpoints.md](./endpoints.md)
- Models: [models.md](./models.md)

## Decisions

- Sidebar states: default + hover, working, full, record failed. (Brian, 2026-11-02) Pause
  failed and record-a-folder failed added from the review. (Brian, 2026-11-03)
- A refused Record shows its message under the row, cleared on the next click. A refused
  **Record a folder…** shows under the sidebar footer. (Brian, 2026-11-02 and 2026-11-03)
- Pause has no confirmation; Record undoes it and the paused time shows as a gap. (Brian, 2026-11-02)
- Pause unlinks the chat; chat attach refuses a paused folder. (Brian, 2026-11-03)
- Simplicity gate (Brian, 2026-11-03): a New Workspace refused when full is not shown as a
  paused row; a chat tab refused as paused shows the daemon's own message; app error wording uses
  one overlap line and the daemon's message for rare refusals, and the Full line has no number.

## Acceptance criteria

Daemon PR:
- Attach (watch-only or from a chat) for a new folder while 32 slots are held returns
  `CAPTURE_LIMIT_REACHED` and changes nothing in `intent.json`; a paused entry stays paused.
- Two concurrent attaches of different new folders at 31 slots admit exactly one. An attach of a
  folder already starting or recording succeeds while full.
- Watch-only attach of a paused folder resumes its session (same `session_id`, `capture.gap`).
  A paused folder that was deleted and recreated gets a new session.
- Chat attach of a paused or archived folder returns `CAPTURE_PAUSED` and changes nothing; of a
  never-recorded folder it admits and links as today.
- Pause (detach) then Record, across a daemon restart, leaves the workspace recording and its
  chat unlinked; the next chat attach links with a fresh check.
- A `waiting` entry in `intent.json` loads as `withdrawn{detached}` with `last_failure: null`
  (daemon and offline readers alike), and the next normal intent write saves it that way.
- Archive, `gc` and session deletion racing Record never restart a withdrawn or deleted capture
  (existing fences kept; tests extended to the refusal path).
- `conductor enroll` and `workspace create` print a full refusal through their ordinary failure
  output, which carries the daemon's "NOT recording" message, and exit non-zero.
- The real-use resource check (`docs/autocapture/real-use-check.md`) passes at 32 captures
  before the cap ships. If it fails, the cap ships at the highest passing value and the app's
  wording uses that number.

Client PR:
- Sidebar shows one row per folder; paused rows appear only when the folder exists;
  not-recording (failed, retrying) rows show with Pause; archived and other stopped rows stay
  hidden unless selected.
- "N recording" counts recording rows only.
- Pause and Record each show working, success (row follows the next refresh) and every error in
  [endpoints.md](./endpoints.md); a send-without-reply shows "not confirmed" and reconciles from
  a refresh.
- Sidebar and Ask share one operation per folder: both disabled while it runs; a reply arriving
  after the selection changed updates the row and never moves the selection.
- Ask on a paused workspace shows the paused notice and Record; after Record, Ask enables only
  under today's rules.
- Auto-link never sends an attach for a folder the last refresh showed as paused. A
  `CAPTURE_PAUSED` refusal (a race, or a manual Connect to Stream) shows the daemon's message.
- **Record a folder…**: cancel does nothing; an already-recording folder selects its row; a
  refusal shows under the footer.
- No `capture-limit-reached` wording remains.

## Adversarial review

Codex (`gpt-6-astra`, read-only, against both base commits), 2026-11-03. 16 findings, 5 blocking.
After the reversal of open question 1, none is blocking.

| # | Finding | Disposition |
|---|---|---|
| 1 | Blocking: a paused chat auto-link silently restarts recording (chat attach admits the folder) | **Resolved.** The daemon refuses chat attach for a paused folder with `CAPTURE_PAUSED`; the app's auto-link skips paused folders. ([endpoints.md](./endpoints.md)) |
| 2 | Blocking: unlink can't handle kept links on paused captures | **Resolved** by the reversal: Pause unlinks, so no paused link exists. |
| 3 | Blocking: archiving an already-paused workspace keeps its link | **Resolved** by the reversal. Archive of a paused workspace removes its folder, so the row disappears. |
| 4 | Blocking: rolling back with kept links is unsafe | **Resolved** by the reversal: rollback restores only the 16 cap and the queue. ([models.md](./models.md)) |
| 5 | Blocking: paused links can fill all chat slots | **Resolved** by the reversal: the chat-link limit stays 10 and paused workspaces hold none. |
| 6 | "N recording" and slots in use are different facts | **Resolved.** N counts recording rows; Full wording is "All recording slots are in use. Pause a workspace first."; the header isn't recoloured. Failed and retrying captures, hidden today, now show with **Pause**. ([screens.md](./screens.md)) |
| 7 | An accepted attach isn't recording yet; Ask readiness; stale completions | **Resolved.** After acceptance the row follows the refresh; Ask enables only under today's rules; one operation per folder shared by sidebar and Ask; replies never move the selection. ([screens.md](./screens.md)) |
| 8 | Error contracts incomplete; timeout wording claims too much | **Resolved.** Full error tables for attach and detach (`TARGET_NOT_FOUND`, `PROTOCOL`, connect vs no-reply); **Pause failed** state `W3IjdQ` added. ([endpoints.md](./endpoints.md)) |
| 9 | Rows: folders or sessions? Which capture wins? | **Resolved.** Rows are folders, using `current(in:)`; Pause and Record target the folder, and the row follows the next refresh. With no paused links, a paused capture can't outrank a recording one. |
| 10 | Admission and archive race rules | **Resolved.** The capacity check and intent write stay in one synchronous turn counting in-flight admissions; refusal before any allocation; existing `gc`/delete fences kept; app disables conflicting actions per folder. Acceptance criteria added. |
| 11 | Migration rules | **Resolved**, then simplified by the simplicity gate: `loadIntent` reads a `waiting` entry as paused and the next normal write saves it; no startup save. ([models.md](./models.md)) |
| 12 | Folder-picker and New Workspace failures have nowhere to show | **Resolved.** Footer error, state `G8j5Wn` (Brian, 2026-11-03); cancel and already-recording behavior defined. A New Workspace that couldn't record shows the refusal in its Setup tab; the "appears paused" row was dropped by the simplicity gate (no capture exists to show). |
| 13 | The client reads HTTP `/v1/captures`, not `status`; store path wrong | **Resolved.** Both surfaces named; path is `<store>/control/intent.json`. Unavailable-binding precedence is untouched because Pause unlinks. |
| 14 | Visibility policy and folder checks | **Resolved.** Policy per stop reason in [screens.md](./screens.md); folder check is an injected dependency, once per refresh, unreadable counts as missing; "Remove from sidebar" excluded. |
| 15 | Acceptance gates missing | **Resolved.** See Acceptance criteria, including the real-use check at 32. |
| 16 | `created` meaning | **Resolved.** Documented as today's meaning; the client doesn't read it. |

## Simplicity gate

Codex (`gpt-6-astra`, read-only) and a Claude Opus reviewer in parallel, against both base commits,
2026-11-03. Both agreed no simpler overall design meets the intent.

| Finding | Source | Disposition |
|---|---|---|
| New Workspace refused when full can't "appear paused": nothing is written, so nothing lists it | both | **Adopted** (Brian). Setup tab shows the refusal; **Record a folder…** after pausing one |
| `withdrawCapture` boolean only served promotion | both | **Adopted.** Returns nothing |
| Enroll's special full-refusal branch | both | **Adopted.** The generic failure branch prints the daemon's message |
| Record/Pause replies unused (`state`, `session_id`) | both | **Adopted.** Both return nothing; rows follow the refresh |
| Forced startup migration save | Opus (Codex: shrink the count) | **Adopted.** `loadIntent` rewrites `waiting` in memory; the next write saves it |
| Pause by session id | Opus | **Adopted.** Detach targets the folder; the daemon pauses every capture there |
| New folder-exists and folder-picker clients | Opus | **Adopted.** Reuse `TerminalRuntimeClient.folderExists` and a parameterised `chooseRepository` |
| Record a folder… pre-check for already recording | Opus | **Adopted.** Record joins; `loadSessions(preferring:)` selects the row |
| `LinkRefusal.paused` and its custom text | Opus | **Adopted** (Brian). Auto-link skip stays; the daemon's message shows through `.other` |
| Bespoke wording per refusal; "inside"/"contains" parse (daemon message can't tell them apart) | Opus | **Adopted** (Brian). One overlap line, daemon message for the rest, Full line without the number |
| Four-case row state, `hasFreeSlot`, `messageDismissed`, `recordText`, `workspace.ts` edit, ~8 duplicate tests | Opus | **Adopted** |
| Drop Ask's **Record** button | Opus | **Rejected.** Approved frames `PHH8d`/`blDch`; small |
| Drop the auto-link right after Record | Opus | **Rejected.** Without it Ask stays disabled until the next chat turn |
| Drop the folder-exists check | Opus (self-rejected) | **Rejected.** Pausing then deleting a folder would leave dead rows |

## Approvals

- 2026-11-02 — Brian picked layout **A · Dim in place** (canvas zone "recording-controls — layout exploration", node `gOF3X`) over B (paused shelf) and C (always-on switch).
- 2026-11-02 — Brian approved the **Workspace sidebar** states (default + hover, working, full, record failed), frames `qrTx8`, `OPNrE`, `pkqIf`, `T9EHei` in zone `ZcE7b`. Exported to `exports/sidebar--*.png`.
- 2026-11-02 — Brian approved the **Ask the agent** paused states (paused, recording…), frames `PHH8d`, `blDch` in zone `KNAm8`, with the capture line reading "Paused". Exported to `exports/ask-agent--*.png`.
- 2026-11-03 — Brian approved [endpoints.md](./endpoints.md) and [models.md](./models.md), including raising the chat-link limit from 10 to 32 (superseded below).
- 2026-11-03 — After the adversarial review, Brian approved **Pause unlinks the chat** (reversing "keep link" and the 32 chat-link limit) and the footer placement for **Record a folder…** errors, and accepted the recommended dispositions for every other finding. This covers the rewritten [endpoints.md](./endpoints.md) and [models.md](./models.md), the revised Full wording (`pkqIf`), the new states **Pause failed** (`W3IjdQ`) and **Record a folder failed** (`G8j5Wn`), and the Ask chat line "No chat linked" (`PHH8d`, `blDch`).
- 2026-11-03 — Brian approved the simplicity-gate reversals: no paused row for a New Workspace refused when full, the daemon's message for a chat tab refused as paused, and the simplified error wording ("Couldn't record <name>: it overlaps a folder that's already recording."; "All recording slots are in use. Pause a workspace first."). Frames `pkqIf` and `G8j5Wn` updated to match.
