# Workspace sidebar — repos and workspaces on the left, stream or terminals on the right

**Status:** Design complete: screens approved, data contracts written, adversarial review and
simplicity gate done. Ready to implement from [implementation-plan.md](./implementation-plan.md).

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `607f90f7addcf6aabeeb803c14679c8625f5fa9c` (develop). The plan was checked again against `a419eab`, after PR #48 added `ManagedWorkspacePath`
- Daemon (`playola-radio/slipstream`): `b736f77c1c9728354767e708f067a8427f172567` (develop). Read
  only; no daemon change is expected (see Existing contracts).

## Target surfaces

- `client`: the macOS app's one window (`Window("Slipstream", id: "main")`).

## Why

Brian moved from Conductor to Slipstream and misses Conductor's left pane. They said what they miss
most: being able to make a new workspace from one place, and secondly switching between open
workspaces and keeping track of them. Today all of this sits in the toolbar session picker menu
(`ChangeStreamPageView.swift:391-426`). The menu has no grouping, and the only status it shows is a
bold row.

Two constraints from Brian shape the layout:
- They will keep fewer workspaces open than they do in Conductor. Switching matters, but less there.
- The change stream is the most important thing in the window. Even the chat comes second to it.

## Scope

1. **Workspace sidebar on the left, open by default.** It is a column, not an overlay; it never
   covers the chat or the stream. A single toolbar button hides and shows it.
2. **Grouped by repo.** Each repo header has a **+** that makes a new workspace in that repo, using
   the existing New Workspace flow. At the bottom, **Add repository…** runs New Workspace with the
   folder chooser, as the menu item does today.
3. **One row per session the picker lists today with inactive sessions hidden.** Clicking a row
   switches the whole window to that workspace, just as choosing it in the picker does today:
   the stream, the chat tabs and the terminals.
4. **Each row shows status at a glance:**
   - a blue spinner while an agent turn is running in that workspace;
   - a bold name while a chat in that workspace is waiting for your response.

   Both come from this app's own chat tabs. Agents running elsewhere (Conductor, a terminal) are
   not tracked.
5. **Archive moves onto the row** as an icon shown on hover or keyboard focus, with the existing
   confirmation. It archives the row it is on, which need not be the selected one.
6. **Chat in the middle, stream on the right.** The right side is a **Change stream | Terminals**
   switch. The stream is the default and is the widest column. Terminals is a placeholder until
   the terminals feature fills it.
7. **The toolbar picker goes away.** Its place shows a plain "repo › workspace" label.
8. **Hide feed goes away.** The stream is never hidden in favour of the chat. The right-side
   switch replaces it.

## Non-goals

- Home, Search, an account switcher, renaming workspaces, PR titles or diff counts on rows, and
  Conductor's right-hand files/changes pane.
- Showing the stream and a terminal at the same time. Brian accepted this trade-off when choosing
  layout F over C.
- Any daemon change.
- The Terminals UI itself. It belongs to `design/features/terminals/`.
- Showing inactive, stopped or archived sessions.
- Status for agents this app didn't start.

## Decisions

Brian confirmed or changed items 1–7 and 13 on 2026-10-26. Items 8–12 are design calls made
while resolving the adversarial review (below); Brian has not yet reviewed them.

1. **Row name:** the folder name, e.g. `workspace-3` or `belo-horizonte-v6`.
2. **Needs you:** the row is **bold**, as the picker row is today. The flag is the persisted
   `isWaiting` (`ChatPageModel.isWaiting(folder:)`). It is set when a turn ends while its tab
   isn't on screen, and cleared when you send. Viewing the tab does not clear it. No amber dot. A blue spinner shows while an
   agent turn runs (`hasWorkingTab(in:)`).
3. **Grouping:** by repo name taken from the folder path. Roots are already standardized and
   symlink-resolved (`normalizedFolder`). Matching compares path components with the same
   normalization as today's `isArchiveWorkspaceShown`, against two roots:
   - `WorkspaceClient.managedRoot` (`$HOME/slipstream/workspaces`);
   - `$HOME/conductor/workspaces`.

   A root exactly two components below one of them, `<repo>/<name>`, goes under `<repo>`. Any
   other folder is its own group, and its toolbar label shows the folder name once.

   Groups with the same name merge, so Conductor's and Slipstream's `playola` workspaces sit
   together. Two different repos sharing a basename would merge as well; that is accepted for a
   single user's machine. A session whose root hasn't arrived yet shows under its existing
   `label` in its own group until `sessionStart` returns. Conductor workspaces appear.
4. **Inactive sessions:** the toggle is removed, not moved (Brian: "left over from a previous
   thing"). The rows are exactly today's `pickerSessions` with `isShowingInactiveSessions`
   permanently false, which means:
   - inactive sessions are hidden, except the selected one;
   - auto-selection, preferred-root selection and reload reconciliation are unchanged.
5. **Terminals:** this feature does not build the Terminals UI. The right-side switch has a
   **Terminals** segment whose content is a placeholder. Switching to Terminals after New
   workspace waits for the terminals feature; switching to a placeholder would only hide the
   stream.
6. **Sidebar hidden state:** remembered across launches.
7. **Archive:** an archive icon appears on the row on hover and on keyboard focus. The row also
   has a named accessibility action, "Archive workspace". There is no right-click menu.
   - Clicking the icon records that row's folder and session as the archive target. The
     confirmation, the chat stop/restore and the command all use that target, not
     `selectedFolder`.
   - Archiving a row that isn't selected leaves the selection, chat and stream alone.
   - Archiving the selected row clears the selection, as today.
   - Busy gating (`isWorkspaceBusy`) and the failure alert are unchanged.
8. **New workspace in a repo (+):** the command target is the folder of the group's first row, in
   sidebar order. It is never the group directory or the repo name.
   - `slipstream workspace create` resolves a linked worktree to its main checkout
     (`src/workspace.ts` `runWorkspaceCreate`, daemon @ `b736f77`: `root = gitDir === commonDir ?
     top : dirname(commonDir)`). This covers Conductor worktrees and plain checkouts alike.
   - A non-git or vanished folder fails in the CLI and shows today's "Couldn't finish creating
     the workspace" alert.
9. **Right side.** The page model owns which segment is shown (`.stream` or `.terminals`). It is
    in memory and starts on the stream at launch.
    - Switching to Terminals does what Hide feed does today: it collapses the reply.
    - Switching back does what Show feed does: it jumps to latest.
    - Connector visibility reads the segment instead of `isFeedHidden`.
    - Switching segments never stops watching. Watching keeps its page-lifetime owner in the
      model. The stream view itself is removed while Terminals shows, as Hide feed removes it
      today, and switching back jumps to latest (simplicity gate, item 8).
    - Switching workspace keeps the current segment.
10. **Widths.**
    - The sidebar is a fixed 260pt.
    - The stream keeps at least 680pt, today's feed width.
    - The chat is 720pt and shrinks first, down to 420pt, when the window narrows.
    - Window minimum: 1,360pt with the sidebar, 1,100pt without (today: 1,000pt).
    - If the sidebar is shown in a window narrower than that, the window widens, capped at the
      screen's visible width.
11. **Compare functions** keeps its place: it replaces the chat column (the middle) while open,
    as it replaces the detail pane today. Closing it restores the chat. The fixture/demo path is
    unchanged.
12. **Empty text.** `emptyStateText` decides "No capture sessions yet" from the visible rows, not
    from all sessions. An all-inactive list therefore reads "No capture sessions yet" instead of
    "Choose a capture session…". A failed refresh keeps today's behaviour: the selection and its
    row stay, and the error shows only when nothing is selected. Refresh stays in the toolbar.
13. **Terminals sequencing:** this design amends `design/features/terminals/`. The terminals
   feature fills the right-side switch's Terminals segment, not a third column with Hide/Show.
   Engine PR #48 is unaffected.

## Acceptance criteria

Each is a model test unless marked.

- **Rows**
  - The rows equal today's `pickerSessions` with inactive sessions hidden.
  - The selected inactive session still shows.
  - Archived sessions never show.
- **Grouping**
  - A managed root and a Conductor root with the same `<repo>` share one group.
  - `/a/b/c` is its own group.
  - A path deeper or shallower than `<repo>/<name>` under a workspace root is its own group.
  - A row whose root is nil shows its `label`.
- **Status**
  - Bold follows `isWaiting(folder:)`, and the spinner follows `hasWorkingTab(in:)`, for a folder
    whose tabs were restored from `chatTabs.json` but never shown this launch.
  - A folder with no chat records is neither bold nor spinning.
- **+**
  - It calls `workspace.create` with the group's first row's folder, without opening the chooser.
  - On success it selects the new path.
  - On failure it shows the existing alert.
- **Archive a row that isn't selected**
  - The confirmation, `stopTabs`, `archive` and `forgetTabs` all use that row's folder.
  - The selection and the selected chat folder are unchanged.
  - On failure, that row's tabs are restored.
- **Archive the selected row** behaves as today.
- **Archive is gated**
  - While `isWorkspaceBusy`, it does nothing.
  - A reload that finishes during the archive doesn't change the archive target.
- **Segments**
  - Switching to Terminals collapses the reply.
  - Switching back jumps to latest.
  - Watching continues throughout; no `stopWatching` is called.
  - Connectors are hidden while Terminals shows.
- **Sidebar hidden** persists through `@Shared(.isSidebarHidden)`.
- **Empty text**
  - All sessions inactive and nothing selected → "No capture sessions yet".
- **Removed behaviour**
  - Tests for the inactive toggle, Hide/Show feed and the picker title are removed or rewritten
    against the rules above.
- **Manual (run the app against `npm run qa:daemon`)**
  - The five approved states match their frames.
  - The archive icon appears when a row is focused with the keyboard.
  - At 1,360pt with the sidebar, the stream is at least 680pt and the chat at least 420pt.

## Adversarial review (Codex `gpt-6-astra`, 2026-10-26)

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Archive confirmation and actions read `selectedFolder`, but the mockup archives an unselected row | blocking | **Resolved**: Decision 7 (explicit archive target) and acceptance criteria |
| 2 | "Only active" vs "plus selected", and no rule for when the selection disappears | blocking | **Resolved**: Decision 4 reuses `pickerSessions` with the toggle off. Selection, auto-select and reload rules are unchanged from today |
| 3 | "Newer session per folder" isn't derivable: there is no timestamp | blocking | **Resolved**: dropped. One row per session, as the picker lists today |
| 4 | Path grouping vs repository identity; tilde, depth and same-name groups | blocking | **Resolved**: Decision 3. Normalized component matching at exact depth 2. Same-name merge is accepted |
| 5 | Status covers only this app's chat tabs | should-fix | **Resolved**: Scope 4 and Non-goals state it |
| 6 | `isWaiting` isn't "unseen" | should-fix | **Resolved**: worded as "waiting for your response" (Scope 4, Decision 2) |
| 7 | **+** target and failure contract | should-fix | **Resolved**: Decision 8 |
| 8 | Unresolved roots; all-inactive and failed-refresh states | should-fix | **Resolved**: Decisions 3 and 12 |
| 9 | Terminals docs still describe a third column; segment lifecycle | should-fix | **Resolved**: Decision 9. An amendment notice is added to the top of `design/features/terminals/spec.md` and `implementation-plan.md` |
| 10 | Removing Hide feed loses its reply and follow guarantees | should-fix | **Resolved**: Decision 9 moves them onto the segment switch |
| 11 | Fixed widths break the 1,000pt minimum; Compare functions placement | should-fix | **Resolved**: Decisions 10 and 11. Compact width is a layout rule, not a separate mockup state (accepted) |
| 12 | Hover-only archive loses keyboard access | should-fix | **Resolved**: Decision 7 (focus reveal and accessibility action) |
| 13 | State ownership | should-fix | **Resolved**: the page model owns the selection, segment and archive target; rows are derived (models.md) |
| 14 | Acceptance criteria miss transitions | should-fix | **Resolved**: Acceptance criteria section |
| 15 | Cheap derivation; standalone label | nit | **Resolved**: rows are derived when sessions change, not per render. A standalone folder's label shows once (Decision 3) |

Blocking findings remaining: none.

## Simplicity gate (Codex `gpt-6-astra` and Claude Opus, 2026-10-26)

Both read the plan against the client code at `607f90f`. One wave of changes went into
[implementation-plan.md](./implementation-plan.md) and [models.md](./models.md).

| # | Finding | Raised by | Disposition |
|---|---|---|---|
| 1 | Two root closures start two login shells | both | **Adopted**: one `WorkspaceClient.roots` closure returns both roots |
| 2 | `SidebarRow` copies `SessionOption` | both | **Adopted**: groups hold `[SessionOption]`; `rowName` derives the name |
| 3 | String-prefixed group ids | Opus | **Adopted**: `repository: String?`; the toolbar title reuses `repository(of:)` |
| 4 | `WorkspaceSidebar` namespace with one function | Codex | **Adopted**: `SidebarGroup.groups` |
| 5 | `isSidebarDisabled` duplicates `isWorkspaceBusy`; `isNewWorkspaceShown` duplicates `newWorkspaceFolder != nil` | Codex, Opus | **Adopted**: both deleted |
| 6 | Two archive bodies for selected and unselected rows | both | **Adopted**: one body; only the selected-row effects branch |
| 7 | Separate window-minimum constants | both | **Adopted**: derived from the column minimums |
| 8 | Keeping the stream alive behind Terminals | Opus (Codex: keep) | **Adopted, Decision 9 amended**: the model owns watching, and Hide feed already tears the view down today, so a keep-alive adds a hidden-view mode for nothing |
| 9 | Segmented `Picker` with a `Binding(get:set:)` | Opus | **Adopted**: underline tab buttons, as in frame `gwLQ8` |
| 10 | Throwaway toolbar UI between tasks | Codex | **Adopted**: each task ships its model change with its final view code (five tasks, not six) |
| 11 | Overlapping tests (new bold test, archive-eligibility test, first-row test) | both | **Adopted**: merged into existing or neighbouring tests |
| 12 | Moving `SpinnerView` | Opus | **Adopted**: un-`private` it in place |
| 13 | Replace `chatColumnWidth` with `layoutPriority` | Opus | **Rejected**: a priority layout lets the chat grow when the sidebar hides, which breaks the approved Sidebar hidden state. The width formula was also fixed so hiding keeps the chat's width (Codex) |
| 14 | `NavigationSplitView` / `List(selection:)` | Codex | **Rejected**: selection runs through `sessionSelected(_:)`, and the custom headers, status and focus-revealed archive stay either way |
| 15 | A refused archive of an unselected row loses its tabs: `restoreTabs` only updates existing models | Codex | **Gap fixed**: Task 3 recreates the models, with a ChatPage regression |
| 16 | Decision 12 had no task | Opus | **Gap fixed**: Task 2 |
| 17 | Two live sessions on one folder show two rows with the same name | Opus | **Accepted**: one row per session, as the picker does today |

Kept as load-bearing by both: hover and focus state, the archive target, `RightPane`, the
placeholder, `isSidebarHidden`, `WorkspaceRoots`, removing `ChatPageView`'s leading slot,
deleting `pickerSuffix`, and mirroring `ReplyPlacement`.

## Existing contracts

Client @ `607f90f`, daemon @ `b736f77`. Only what this feature touches is listed.

**Window today.** Two columns:
- left: the change stream, 680pt, with a **Hide feed** button;
- right: the chat.

Every workspace action sits in the toolbar's session picker menu
(`ChangeStreamPageView.swift:391-426`):
- the session rows;
- "Show N inactive sessions";
- "New workspace…";
- "Archive workspace…".

![Workspace window — today](exports/existing/window--today.png)

**Session list** (`ChangeStreamPageModel.loadSessions(preferring:)`):
1. `daemon.discover` finds the daemon.
2. `listCaptures` and `sessions` load the session list.
3. `sessionStart` runs once per session to get its `root` folder.

The result is a list of `SessionOption`:
```swift
struct SessionOption { id, label, agentConnection, readinessSeq, root: String?, capture: CaptureSummary?, hasHistory }
```
`CaptureSummary` has `sessionID`, `root`, `state`, `reason`, `retryAtMs` and `binding`.

There is no repo name, branch or display name anywhere. A session is archived when
`capture.state == .stopped && capture.reason == "archived"`.

**Per-folder chat status** (`ChatPageModel`):
- `isWaiting(folder:)` reads the persisted `ChatTabRecord.isWaiting`. It is set when a turn
  finishes while its tab isn't on screen, and cleared when the user sends.
- `hasWorkingTab(in:)` is true while any tab in that folder has an active turn. Tabs in other
  folders keep running, so both values are live for every folder that has chat tabs.

**New / archive workspace** (`WorkspaceClient`):
- `chooseRepository()` opens an NSOpenPanel.
- `create(repo)` runs `slipstream workspace create <repo> --store <id>`, which resolves a linked
  worktree to its main checkout. Any folder inside the repo is therefore enough to make a new
  workspace in it.
- `archive(folder)` runs `slipstream workspace archive`.
- `managedRoot` is `$HOME/slipstream/workspaces`. Archive is offered only for folders under it.

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: none — the daemon's API and the `slipstream workspace create` / `archive` commands are
  used unchanged
- Models: [models.md](./models.md)
- Implementation plan: [implementation-plan.md](./implementation-plan.md)

## Approvals

| Date | What | Covers |
|---|---|---|
| 2026-10-26 | Workspace window, all five states: Open, Row hover, Sidebar hidden, Terminals placeholder, Unavailable. Includes one toolbar sidebar toggle with no header hide button, bold for "needs you" with no dot, folder names on rows, and no inactive toggle | `design/slipstream.pen` frames `Gmszm`, `OEccY`, `gm8O5`, `gwLQ8`, `zaPgO`; component `BkqdP`. Exports in [screens.md](./screens.md) |
| 2026-10-26 | Layout direction F: sidebar open by default as a column; chat in the middle; right side switches between Change stream and Terminals | `design/slipstream.pen` frame `Gmszm` (`sidebar--F-open-column-stream-switch`), component `BkqdP` (`WS · Sidebar`). Directions A, B, C and E were explored and rejected (frames `ywJ3X`, `GjKJz`, `v6eeam`, `J17wx`, `VLNYX`) |
| 2026-10-26 | The plan's unresolved questions: Decisions 8–12, removing Hide feed, the 1,360pt window minimum with the sidebar, the reply popover opening to the left, and the stream view being torn down while Terminals shows | Decisions 8–12 above; [implementation-plan.md](./implementation-plan.md) "Unresolved questions" |
