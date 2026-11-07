# Conductor-style top bar: thin per-column headers, with a slot ready for PR actions

**Status:** Visuals approved and adversarially reviewed (2026-11-07). Implementation plan:
[implementation-plan.md](./implementation-plan.md), awaiting review.

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `adc8fd756bca0df534d7cf985e2388c8ace20414` (develop).
- Daemon (`playola-radio/slipstream`): `903ef29b75499eadfffe71edd6d20af890926e2b` (develop). Read only;
  no daemon change is expected.

## Target surfaces

- `client`: the macOS app's one window (`Window("Slipstream", id: "main")`).

## Why

Brian wants the top of the window to look like Conductor's, and wants it ready for the PR
actions Conductor has (PR number, change status, Commit and push). Today's unified toolbar
(`ChangeStreamPageView.swift:396-422`) is "extra fat and bubbly": macOS draws each item as a
large glass capsule.

Brian's specific complaints, from the side-by-side screenshots:
- The pill on the left (sidebar toggle grouped with "repo › workspace") is not right, and the
  sidebar already lists the workspaces.
- Refresh isn't needed.
- The Open in (Finder) button is too bubbly and too big, and belongs above the chat, not at the
  far right.

## Scope

1. **One thin header row per column, flat, in the titlebar area**, replacing the system toolbar's
   glass items. No capsules or bubbles; small flat controls, as Conductor draws them.
2. **Sidebar column header:** the window buttons and the sidebar toggle.
3. **Chat column header:** a flat "repo › workspace" breadcrumb in Conductor's style, and a small
   flat Open in button (app icon + chevron) beside it.
4. **Right column header:** a strip reserved for the PR actions that come later. This feature
   only lays out the strip; it adds no PR behaviour.
5. **Refresh goes away.** The workspace list reloads when the app comes back to the front, and
   ⌘R in the menu reloads it on demand. (Today Refresh is the only way to see a workspace or
   recording started outside the app, e.g. from the CLI or Conductor.)
6. **The "Slipstream" window title goes away.**
7. **Compare functions moves** out of the top bar into the right column's tab row, beside
   Change stream | Terminals, the way Conductor puts Review in its tab row.

## Non-goals

- Any PR behaviour: no PR number, change counts, Commit and push, or GitHub calls. The right
  header is only laid out for them.
- Conductor's back/forward buttons, Home, Create, Search.
- Any daemon change.

## Existing contracts

None touched. The header reads state the window already has (selected workspace, its repository,
the Open in model); no daemon request or event changes.

## Resolved questions

- What the right column header shows before PR actions exist: nothing. It is an empty strip with
  the column's background and borders (approved mockup `XIjZj`).

## Adversarial review (Codex consult, 2026-11-07)

| # | Finding | Disposition |
|---|---|---|
| 1 | Traffic lights are drawn by macOS, not by the header row; toolbar-hiding tricks keep system layout and glass | Accepted. The plan starts with a spike on `.windowStyle(.hiddenTitleBar)` plus a content header. If that fails, use an AppKit titlebar accessory, not toolbar styling |
| 2 | Dragging, double-click-to-zoom and full screen are not guaranteed by a content header | Accepted. `WindowDragGesture` only on the header's empty areas; never `isMovableByWindowBackground` |
| 3 | The spike has no pass/fail criteria | Accepted. The plan's spike lists them: lights centred in 40pt on macOS 15 and 26, leading room with the sidebar shown and hidden, drag on empty header space only, double-click follows the system setting, full-screen inset, inactive-window look, keyboard and VoiceOver reach the header controls |
| 4 | Activation reload can overlap the first load and pile up when switching apps | Accepted. One reload runs at a time; a request during a reload runs once more after it. Activation and ⌘R go through the same path |
| 5 | A failed reload empties the sidebar but keeps the selection | Accepted (reloads now happen on every activation). A failed reload keeps the list and selection already shown; the error replaces the list only if no load has succeeded |
| 6 | ⌘R can't reach the page model, which the view creates privately | Accepted. The plan picks the wiring (a focused value or app-owned model); ⌘R is disabled when the window isn't focused |
| 7 | The "no workspace" mockup still showed a selected row and a full chat | Fixed. `E5HiR4` re-exported with nothing selected; screens.md says the columns below are unchanged |
| 8 | Messages still say "Refresh", and the toolbar's busy spinner has no new home | Accepted. The copy becomes "Press ⌘R to check again"; the spinner sits after the sidebar toggle |
| 9 | The breadcrumb and Open in have states before the repository and folder are known | Accepted. Workspace name alone until the repository is known; Open in dimmed until the folder is known (today's behaviour, now written down) |
| 10 | Compare functions has no disabled look or "open" state | Partly accepted. Dimmed with explanatory help text when unusable. No open state: the comparison visibly replaces the chat column and has its own Close |
| 11 | No rule for a narrow right pane | Accepted. The Change stream subtitle truncates first; the Compare functions label never truncates |
| 12 | The PR slot is speculative | Accepted. Only the empty right header area is built; no PR models, placeholder controls or reserved sizes |
| 13 | `endpoints.md` and `models.md` are missing | Rejected. `deliverables.md` allows a `none — <reason>` line in spec.md instead of the file; both lines are below |

## Simplicity gate (2026-11-07)

Codex and Claude both audited the plan for excess. The plan dropped:
- a stored "has listed" flag (worked out from `hasLoadedSessions` and `sessionsError`);
- the closed-window activation guard and its test (closing the window quits the app);
- three single-use header view types (now private builders);
- duplicate fill and border tokens, a second app-icon size, and a disabled-opacity token;
- the right header's padding token;
- the demo-only help text.

It kept:
- the Review Focus section (the plan format requires it);
- the right part's padding in `window-header.json` (the export mirrors the pen frame).

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: none — no daemon or network change
- Models: none — no new or changed data; the header reads state the window already has

## Approvals

- 2026-11-06: scope above agreed in chat (breadcrumb kept above the chat in Conductor's flat
  style; Refresh removed; Open in moved above the chat).
- 2026-11-06: Compare functions moves to the right column's tab row.
- 2026-11-07: mockups approved in chat: default `XIjZj`, sidebar hidden `SoZho`, no workspace
  `E5HiR4`, and the reference-only PR actions preview `mmNKj`.
- 2026-11-07: review dispositions approved in chat (failed reload keeps the list, one reload at a
  time, "Press ⌘R" copy, busy spinner after the sidebar toggle, Compare functions dimmed rule).
