# Terminals — a terminals pane with the setup output and shells per workspace

> **Amended by [workspace-sidebar](../workspace-sidebar/spec.md) (2026-10-26).** The Terminals
> pane is no longer a third 440pt column. It is the **Terminals** segment of the right side's
> **Change stream | Terminals** switch, which workspace-sidebar builds with a placeholder. This
> feature fills that segment.
>
> These parts of this design are superseded:
> - **Hide terminals** / **Show terminals**, `isTerminalPaneHidden`, and the "Hidden" state;
> - the ~1,440pt window minimum. Widths are set by workspace-sidebar Decision 10.
>
> New Workspace (sidebar **+** or **Add repository…**) switches the segment to Terminals so the
> Setup tab shows. Everything else stands: tabs, Setup, restore, models and the engine (PR #48).
> Re-check this plan's UI tasks against workspace-sidebar's spec before implementing them.

**Status:** Phase 1 (scope) agreed with Brian 2026-10-24. Architecture consulted with Codex
2026-10-24. Spec reviewed by Brian 2026-10-25 (switch timing chosen). Screens approved 2026-10-25
([screens.md](./screens.md)). Models and endpoints approved 2026-10-25. Phase 5 (Codex adversarial review) ran
2026-10-25: every finding has a disposition below and none is blocking.

## Base commits

- Client (`playola-radio/slipstream-client-swift`): `fad72167eb0e5431489c71187d90fcffe343feae` (develop)
- Daemon (`playola-radio/slipstream`): `feffc30c678b45fe890dcbde7ae2b63d17d9a53e` (develop). One
  CLI output line changes (scope item 3).

## Target surfaces

- `client`: the macOS app. A new right-hand pane, and New Workspace runs in it.
- `slipstream` CLI (daemon repo): `workspace create` also prints `workspace_path: <path>` before
  it runs the setup script. Nothing else in the daemon changes.

## Why

Brian moved from Conductor to Slipstream and lost Conductor's bottom panel (Setup / Terminal / +).
The setup script's output matters: it prints the web addresses and ports for that workspace
(Brian). Today the app runs `slipstream workspace create` headless and shows output only when it
fails, as an alert of the last 12 lines (`WorkspaceClient.swift:29-40`). There is also no way to
open a shell in a workspace from the app.

## Scope

1. **Terminals pane.** A new pane on the right of the window, beside the feed and the chat.
   About 440pt wide. Its tab strip uses the chat tabs' style: **Setup** (only for workspaces this
   app created), **Terminal 1**, **Terminal 2**, … and **+** to add a terminal (Brian: "We'll have
   to add a right pane, too").
2. **Hide the pane** (Claude's call, recommended by Codex): a **Hide terminals** button at the
   right end of the pane's tab strip hides the pane, and **Show terminals** at the right end of
   the chat tab strip brings it back, the way the feed can be hidden (`ChangeStreamPageModel.swift:584-592`). It shows by default, and
   hiding it isn't remembered across restarts, the same as the feed. When it shows, the window's
   minimum width grows from 1000 to about 1440. When it's hidden, the minimum stays 1000. A
   window narrower than that grows when the pane shows. The minimum never exceeds the screen's
   visible width, so on a small screen the chat gets narrower and the hide button stays on
   screen (Claude's call after review R-17). Hiding the feed doesn't lower the minimum, as today.
   - **New Workspace shows the pane** if it was hidden, so the Setup tab is visible (R-14).
   - Terminal colours, font and spacing come from the approved Phase 3 frames and are added to
     `DesignTokens`. The 16 ANSI colours use SwiftTerm's default palette unless the frames say
     otherwise.
3. **New Workspace runs in a Setup tab** (Brian: "just run it in a terminal, save the active
   terminal window, and have the terminal do the storage part").
   - After the user picks a repository, a **Setup** tab opens and is selected. It runs
     `slipstream workspace create <repo> --store <id>` in a real terminal. The CLI passes the
     terminal on to the setup script (`stdio: inherit`, daemon `src/cli.ts:723-727`), so the
     script's colours and progress output appear as they would in Conductor.
   - **The window switches to the new workspace as soon as its folder exists** (Brian,
     2026-10-25, option A), so the user watches setup inside the new workspace, as in Conductor.
     - The CLI changes to print `workspace_path: <path>` once the folder is created and recorded
       with the daemon, before the setup script runs. It keeps the final `workspace_path:` line
       too, so the output still ends with the path ([endpoints.md](./endpoints.md)).
     - The app acts on the first `workspace_path:` line whose path is an absolute folder
       exactly two levels below the managed workspaces root (`<root>/<repo>/<name>`) that
       exists (R-11; the same check archive already uses). It records that folder on the Setup tab,
       then refreshes the workspace list as today (`loadSessions(preferring:)`). Later
       `workspace_path:` lines are ignored.
     - It switches the window to the new workspace only if the user hasn't picked another
       workspace since starting New Workspace (R-4). The Setup tab moves either way: the move
       is by tab id and never depends on which workspace is showing.
     - **A Setup tab with no folder yet** shows at the front of every workspace's strip, and in
       the pane when no workspace is selected, until it's closed or gets its folder (R-13). Once
       it has a folder it shows only in that workspace's strip (2026-11-09).
     - An older CLI prints only the final line, so the app switches when setup finishes. A setup
       script that prints its own `workspace_path:` line for a folder that isn't a managed
       workspace is ignored by the check above. (The app can't check the repo name: the user may
       pick a subfolder or a linked worktree, and the CLI names the folder after the main
       checkout.)
   - Until the workspace exists (the fetch and worktree steps, normally seconds), the Setup tab
     is at the front of the strip whichever workspace is selected. New Workspace is disabled
     until then (Claude's call). Today it stays disabled for the whole create
     (`isWorkspaceBusy`). Once the Setup tab has moved to its workspace, another New Workspace
     can start.
   - When setup finishes, the tab keeps its output, shows how it ended ("Setup finished" or
     "Setup failed — exit N") and runs nothing else. Its × closes it.
   - **Failures show in the Setup tab.** The "Couldn't finish creating the workspace" alert
     goes away (Claude's guess, Brian accepted). The path is printed before the script runs, so
     a failed script still leaves its tab in the new workspace. Failures before the workspace
     exists (no `origin`, fetch failed, the CLI isn't installed) leave the failed tab at the front
     of the strip until the user closes it.
   - When the command can't start at all (`slipstream` not found, the login environment failed),
     the app writes the reason, such as "Couldn't find slipstream…", into the tab's terminal as
     text, so it's in the history too (R-21).
   - At most one Setup tab without a workspace can exist at a time (Claude's call). Running New
     Workspace again replaces a failed one.
   - The setup script gets no keyboard input: the CLI ignores its stdin (`cli.ts:723-727`), so
     interactive setup prompts aren't supported (Claude's note from the review).
4. **Terminal tabs.** Each one runs the user's login shell (`-l`) with the login environment
   and PATH, started in the workspace folder, so their normal prompt works.
   - **+** adds the next number, one more than the highest open one, so names don't change when a
     tab closes (Codex).
   - Every workspace always has at least one terminal tab (Claude's call, matching how chat
     tabs work, `ChatPageModel.swift:160-171`):
     - A workspace with no terminal tab gets **Terminal 1** when it's shown. That covers new
       workspaces (Setup plus Terminal 1, like Conductor), Conductor-made ones and ones made
       before this feature.
     - Closing the last terminal opens a fresh Terminal 1.
     - Conductor-made workspaces never get a Setup tab (Claude's guess, Brian accepted).
   - If the workspace folder no longer exists, a terminal tab shows "This folder no longer
     exists" and starts no shell (Claude's call). A Setup tab still shows its saved output (R-15).
   - **When a shell exits** (the user types `exit`, or the shell can't start), the tab stays with
     its output and the app writes "Process exited (exit N)" or the launch error into it. It
     isn't restarted; × closes it at once. After a relaunch it gets a fresh shell like any other
     tab (Claude's call after R-15; closing it automatically could loop with "always at least one
     terminal").
   - With no workspace selected, the pane shows "Choose a workspace" (Claude's call), unless a
     Setup tab is waiting for its workspace; then that tab shows (R-13).
   - Keys: SwiftTerm's standard copy, paste and selection (Claude's call). Clicking a tab focuses
     its terminal. There are no new shortcuts in v1, but **⌘W closes the focused terminal's tab**
     (with the busy check) when a terminal has keyboard focus, instead of the chat tab it closes
     today (R-18).
5. **History.** Every tab saves its own output to a file, up to about 4,000 lines or a few MiB,
   whichever is smaller (Brian; the numbers are Codex's, the byte bound from R-5).
   - On relaunch each tab replays its history, then shows a thin divider "Restored — earlier
     processes ended" (Claude's call). A terminal tab then starts a fresh login shell in the
     workspace folder. A Setup tab only replays.
   - Running processes don't survive a restart (accepted).
   - Full-screen programs (vim, top) can't be restored. After replay the terminal resets to
     normal output.
6. **Last tab remembered.** Each workspace remembers which tab was last selected (Setup or a
   terminal) across restarts (Brian: "It should show the last open tab — either the setup or a
   terminal if one had been used").
7. **Per workspace.** Each workspace has its own tabs. Switching workspaces switches the pane.
   Terminals in other workspaces keep running.
8. **Closing a busy tab** (Brian: "in the tab"). If something is still running when the user
   closes a tab, the tab itself shows "Still running — Close / Keep", not an alert.
   - "Something running" means a program in the foreground of that terminal (the terminal's
     foreground process group isn't the shell's). An idle prompt closes at once. Background jobs
     (`cmd &`) aren't detected (Codex; accepted for v1).
   - A Setup tab is busy while its command is still running.
   - Closing a busy tab that isn't selected selects it and asks there.
   - Closing a tab stops what runs in it and deletes its saved history.
9. **Archive stops terminals.** Archiving a workspace stops its terminals first, the way it
   already stops its chats (`archiveConfirmed()`, `ChangeStreamPageModel.swift:524`): the
   command removes the folder they run in.
   - A Setup tab still running is stopped and marked "Setup was interrupted" (R-9).
   - If archiving succeeds, the workspace's tabs and history files are deleted.
   - If it fails, the tabs come back with their history. Terminal tabs get fresh shells; a Setup
     tab stays interrupted and never re-runs.
10. **Quitting** stops every terminal. History is already on disk.

## Non-goals

- No Run tab (Brian).
- Processes don't survive a restart. There is no tmux-style detach or reattach.
- The setup command isn't re-run, and setup can't be retried from the tab. Run New Workspace
  again.
- The app doesn't detect background jobs. No process-tree checks.
- The pane can't be resized and doesn't remember being hidden.
- The app adds no link detection of its own and doesn't offer to open addresses or ports.
  SwiftTerm's built-in ⌘-click on a URL is left as it is (Claude's call after R-18: it costs no
  code and helps with the setup output's addresses).
- No terminal settings (font, colours, scrollback size); it uses `DesignTokens`.
- No daemon change beyond the extra `workspace_path:` line.

## Architecture (Codex consult, 2026-10-24)

Codex (`gpt-5.6-sol`, read-only, session `01a16f64-…`) read the files this touches and proposed
the following. Claude agrees except where noted. The implementation plan (Phase 6) turns it into
tasks.

- **Emulator: SwiftTerm**, pinned `exactVersion: 1.19.0` (stable, not the 2.0 preview). It is
  the one new package dependency (Claude's call, stated to Brian).
- **Ownership.**
  - One app-lifetime `TerminalPageModel`, created in `SlipstreamViewerApp` beside `chat` and
    passed to `ChangeStreamPageModel`.
  - Each `TerminalTabModel` holds a live process handle and a retained SwiftTerm
    `TerminalView` (the display only). The app owns the pty itself: it starts the child with
    SwiftTerm's `PseudoTerminalHelpers.fork` (forkpty) and reads, reaps and stops it the way
    `AgentProcess` does, instead of using `LocalProcessTerminalView` (Claude's call while
    planning: R-2, R-19 and R-20 need control of the read loop, `waitpid` and stop, which
    `LocalProcess` keeps private).
  - `TerminalHostView: NSViewRepresentable` only moves that retained view into its container.
    It never creates, starts or stops one. So workspace switches and SwiftUI re-renders keep
    every terminal alive.
- **Testing seam.** A `TerminalRuntimeClient` dependency makes sessions. Tests use a fake
  session that sends `.output` / `.workspacePath` / `.exited` events by hand, so model tests never
  open a real pty.
- **History.**
  - Exact pty bytes, with their ANSI codes, go to `Application Support/<bundle id>/terminals/<tab
    id>.log`. Each chunk read from the pty is queued for the file, then fed to the view.
  - Writes are done in order off the main actor, one serial writer per tab.
  - When the file reaches 5,000 lines or 4 MiB, it is rewritten to at most the last 4,000 lines
    and 3 MiB (R-5). The check runs on append only; a log over the trigger at launch is
    compacted by its first append (S-8).
  - Replay feeds the bytes in before the shell starts, then resets the terminal to its main
    screen (exact sequence under Requirements, R-16).
  - The file name comes from the tab id, so when the Setup tab moves to its workspace nothing
    on disk moves.
- **Setup path detection.** A pure `WorkspacePathStreamParser` reads the stream incrementally.
  It splits on LF, drops a trailing CR, handles reads that split a line or a character, discards
  lines over 4,096 bytes and reports each `workspace_path: ` at the start of a line. It doesn't
  parse escape codes: the CLI prints the path as plain text after an empty line, always ending
  in a newline (S-2).
- **Busy check.** `tcgetpgrp(master fd) != getpgid(shell pid)`, comparing process groups rather
  than pids.
- **Stopping.** SwiftTerm's `terminate()` only signals the leader. The app signals the foreground
  and shell process groups, waits for the exit callback and escalates after a short timeout.
  (Claude: check this against SwiftTerm 1.19 when implementing; the plan carries a test.)
- **Environment.** Reuse `AgentEnvironmentClient.loginEnvironment()` and `loginShell(...)`
  behind an injectable closure, not `resolve()`, which needs Claude installed. The app sets
  `TERM=xterm-256color` and `COLORTERM=truecolor`, sets `PWD`, and keeps `LANG`/`LC_*`, falling
  back to `en_US.UTF-8`. Setup launches the absolute `slipstream` path directly, with no
  `sh -c`.
- **Workspace client.** `WorkspaceClient.create` (headless) gives way to a call that returns the
  launch description for the Setup tab. `outcome(output:status:)` becomes
  `failureText(output:status:)` for `archive`, which prints no path (S-4).
- **Persistence.** One `@Shared(.fileStorage)` file holds tabs and the per-workspace selection
  together, so moving the Setup tab and selecting it change at once. Its shape is in
  [models.md](./models.md) (Phase 4).
- **Launch.** At launch the app marks a Setup tab that was still running as interrupted ("Setup
  was interrupted"). There is no log cleanup: a closed tab's log is deleted before its record
  (S-1).

Claude disagrees with one Codex suggestion: Codex offered a resizable pane (`HSplitView`, minimum
340). Brian didn't ask for resizing, so v1 uses a fixed width (non-goals).

PR order (Codex's, with archive and quit folded into the pane PR after R-8 so no build ships
terminals that archive or quit leave running; the CLI line doesn't depend on any client PR):
1. Daemon repo: `feature:` print the workspace path before running the setup script.
2. `chore:` the terminal engine (SwiftTerm, history files, the setup-line reader).
3. `feature:` the pane with terminal tabs, stopped by archive and quit.
4. `feature:` New Workspace in a Setup tab.

### Requirements from the adversarial review (for the implementation plan)

These come from the Phase 5 review below; the plan turns each into tasks and tests.

- **Stopping (R-2, R-6).** One stop operation per session, owned by the runtime adapter, with
  bounded completion. It doesn't call SwiftTerm's `terminate()` and then wait for the exit
  callback (that can hang: `terminate()` cancels its own monitor). It signals the foreground and
  shell process groups (positive ids only), escalates to `SIGKILL` after a timeout, reaps the
  child itself, and ignores late escalations once the session is gone. Leader exit alone isn't
  completion. Model it on `AgentProcess.shutdown()` (`AgentProcessClient.swift:129`).
- **Exit status (R-19).** The adapter turns SwiftTerm's raw `waitpid` status into exited(code)
  or signalled(signal); "exit 256" must never show.
- **Completion after drain (R-20).** The adapter sends its finished event only after the
  output is drained and the path reader has seen end of input, so a fast exit can't drop the
  final `workspace_path:` line. Same split as `AgentProcessClient` (exit vs finished).
- **Status after output (R-3).** A Setup tab's final status is saved only after its last output
  is flushed to the log.
- **Saving order (R-7).** Save a tab's record (awaiting the `@Shared` save) before starting its
  process or writing its log. On close, stop the process, delete the log, then persist the
  record removal, so a log never outlives its record (S-1). A crash between the two brings the
  tab back with no history. Orderly quit awaits pending saves.
- **History writer (R-5, R-10).** One serial writer per tab owns append, compaction, reopening
  and deletion. Compaction keeps at most 4,000 lines and 3 MiB, writes a temporary file and
  replaces the log, then reopens its handle; a single line longer than the byte cap is cut. A
  write error (disk full) stops saving for that tab and the terminal keeps running.
- **Replay (R-16).** An exact, tested sequence: feed the saved bytes with input and replies to
  the terminal's queries switched off, leave the alternate screen, reset modes and the parser
  without clearing the scrollback, then draw the divider and start the shell.
- **Path reader (R-11, R-22).** Live Setup output only, never replay. It treats LF and CRLF as
  line ends, discards a line longer than 4,096 bytes until its next line end, and accepts only
  an absolute path that passes the folder check in scope item 3. It doesn't strip escape codes
  (S-2).
- **Environment (R-23).** An injectable login-environment closure that fails when `PATH` is
  missing or the output is malformed, so "Couldn't find slipstream" only shows when it really
  isn't on `PATH`.
- **Concurrency (R-4).** New Workspace, archive and workspace selection each have one owner. A
  Setup tab's events carry its tab id and a generation; the auto-switch is skipped once the user
  has picked a workspace since starting. Archive and New Workspace stay mutually exclusive, as
  `isWorkspaceBusy` makes them today.
- **Quit (R-24).** `AppDelegate`'s termination handshake awaits both `chat.quitConfirmed()` and
  the terminals' stop-and-save, and no new terminal starts once quitting has begun.
- **Close confirmation (R-25).** "Still running" is bound to the tab id, survives the Setup tab
  moving, and goes away if the process ends while it's showing.
- **Tests (R-26, R-27).** Model tests use a fake runtime whose closures cover launch, events,
  busy check, stop and history, so they never touch a pty or the disk. A small real-pty
  integration suite in disposable folders covers exit 0 and 1, a signal, an immediate exit, a
  launch failure, an idle close, a busy close and bounded stop. The acceptance matrix is in the
  implementation plan.

## Decision log

- 2026-10-24 Brian: add a terminals pane with the setup output and multiple terminals, styled like
  Conductor's bottom panel; it needs a new right-hand pane.
- 2026-10-24 Brian: run setup in a terminal and let each terminal save its own output, instead
  of capturing setup output separately.
- 2026-10-24 Brian: each workspace shows its last open tab, Setup or terminal.
- 2026-10-24 Brian: confirm closing a busy tab inside the tab, not with an alert.
- 2026-10-24 Brian accepted the scope playback ("yeah sounds good"): tabs per workspace that keep
  running in the background, no Setup tab for Conductor workspaces, setup failures in the tab
  instead of the alert, login shell and PATH, SwiftTerm, no Run tab.
- 2026-10-24 Claude's calls, pending Brian's review of this spec: the pane can be hidden (item 2),
  the "Restored" divider (item 5), and 4,000 lines of history (item 5). After the builder check
  (a fresh subagent planning from this spec), Claude also chose:
  - every workspace always has a terminal tab;
  - a missing folder shows a message instead of a shell;
  - "Choose a workspace" when none is selected;
  - only one Setup tab without a workspace at a time;
  - no new shortcuts.
- 2026-10-25 Brian chose **A** for the open question: switch to the new workspace as soon as its
  folder exists, via the CLI printing `workspace_path:` before the setup script (scope item 3).
  Brian raised no objection to Claude's calls listed above; they stand.
- 2026-10-25 Claude's call that follows: New Workspace is disabled only until the Setup tab has
  its workspace, not for the whole setup run.
- 2026-10-25 Brian approved the screen "Workspace window — Terminals pane" with all eleven states
  (`design/slipstream.pen` zone "14 · Terminals", frames `y46ro` `hEY8y` `NTKN7` `q45pa` `QPmYb`
  `M7WFX` `Vuydd` `itKKe` `D8Kx1` `mouwC` `Eotfj` as of that date; PNGs in `exports/`). The hide
  button sits in the pane's tab strip and Show terminals in the chat strip (scope item 2 updated
  to match).
- 2026-10-25 Brian approved models.md and endpoints.md as first written that day, including
  Claude's calls: "Setting up…" before the folder is known, `failed(exitStatus: nil)` when the
  command can't start, a blank line before the early path line, and the "Setup was interrupted"
  footer (Setup failed look, no separate frame).
- 2026-10-25 Claude's calls after the Phase 5 review, pending Brian's review: an orphaned Setup
  tab shows at the front of every strip; the auto-switch is skipped if the user picked another
  workspace; New Workspace shows a hidden pane; the minimum width is capped at the screen
  width; a shell that exits leaves its tab open with a note; ⌘W closes the focused terminal;
  SwiftTerm's ⌘-click on a URL is kept; archive marks a running Setup interrupted; archive and
  quit move into the pane PR.
  One of them changes the approved models.md: `SetupStatus.running` no longer stores
  `startedAt` (R-28).
- 2026-11-09 Brian approved reversing the orphaned-Setup call and S-7 after the terminals pane
  showed one workspace's Setup tab while the chat showed another. A Setup tab that has a folder
  shows only in that workspace, whether or not the workspace list has loaded; moving it clears
  every other workspace's selection of it; and a dangling selection falls back to the
  workspace's own first tab before a folderless Setup. Cost: a Setup whose workspace never
  appears in the list (R-1) can no longer be reached from another workspace.
- 2026-10-25 Brian chose **A** for D1 (simplicity gate S-1): a closed tab's log is deleted before
  its record, and launch no longer cleans up logs. This changes the write order in the approved
  models.md and R-7.

## Adversarial review (Codex, 2026-10-25)

Codex reviewed spec.md, screens.md, models.md and endpoints.md against the client and daemon
code (12 blocking, 17 should-fix, 2 minor; raw report kept out of the repo). Every finding is
**resolved** (a doc changed) or **accepted** (with the reason). None is blocking now.

| # | Finding (severity) | Disposition |
|---|---|---|
| R-1 | Recording fails: the folder exists but the daemon never lists it, so a Setup moved there can't be reached (blocking) | Resolved: a Setup tab whose folder isn't in the workspace list shows at the front of every strip (scope 3, models.md). Reversed 2026-11-09: a workspace could show another workspace's terminal (decision log) |
| R-2 | `terminate()` then waiting for SwiftTerm's exit callback can hang (blocking) | Resolved: adapter-owned bounded stop (Architecture → Requirements) |
| R-3 | Final status can be saved before the last output reaches the log (should-fix) | Resolved: status saved only after the writer flushes (Requirements) |
| R-4 | Releasing the busy gate lets a late refresh select the wrong workspace (blocking) | Resolved: auto-switch only if the user hasn't picked a workspace since; move by tab id; archive and New Workspace stay exclusive (scope 3, Requirements) |
| R-5 | A newline-free flood is never byte-bounded (blocking) | Resolved: line and byte caps, oversized lines cut, checked on append (scope 5, models.md, Requirements; S-8) |
| R-6 | Shell exit doesn't prove the foreground program stopped (blocking) | Resolved: stop signals both process groups and escalates, modelled on `AgentProcess.shutdown()`; background jobs stay out of scope (Requirements, Non-goals) |
| R-7 | JSON saves and log files aren't one transaction; cached saves coalesce (blocking) | Resolved: saving order; the log goes before its record, so nothing needs cleaning up (models.md, Requirements; S-1) |
| R-8 | PR 3 ships terminals that archive and quit don't stop (should-fix) | Resolved: archive and quit fold into the pane PR (PR order) |
| R-9 | A failed archive can't bring back a running Setup (should-fix) | Resolved: archive marks it interrupted; it never re-runs (scope 9) |
| R-10 | Compaction can leave appends going to an unlinked file (should-fix) | Resolved: one serial writer owns append, compaction, reopen and delete; a write error stops saving for that tab only (Requirements) |
| R-11 | A setup script printing `workspace_path:` fools the first-marker rule under an older CLI (blocking) | Resolved: the first marker counts only if it's an existing folder two levels below the managed workspaces root (scope 3, endpoints.md; S-3) |
| R-12 | `folder == nil` means "path not learned", not "no workspace made" (should-fix) | Accepted: the CLI prints the path right after `record`, so only a quit can stop it in between, and a quit shows "Setup was interrupted", which claims nothing. models.md says what nil means per status |
| R-13 | First-ever New Workspace: "Choose a workspace" hides the running Setup (blocking) | Resolved: a folderless Setup takes the empty pane's place (scope 3, screens.md) |
| R-14 | New Workspace with the pane hidden shows nothing (blocking, with R-13) | Resolved: New Workspace shows the pane (scope 2) |
| R-15 | Shell exit, shell launch failure and missing-folder Setup tabs are undefined (should-fix) | Resolved: the tab stays with a "Process exited" note; a Setup tab always replays (scope 4, screens.md) |
| R-16 | "Replay, then reset" isn't precise enough (should-fix) | Resolved: exact replay sequence with input off (Requirements) |
| R-17 | Hiding the feed doesn't lower the 1440pt minimum on a small screen (should-fix) | Resolved: minimum capped at the screen's visible width; the hide button stays reachable (scope 2) |
| R-18 | ⌘W closes a chat while typing in a terminal; SwiftTerm opens links (should-fix) | Resolved: focus-aware ⌘W; SwiftTerm's ⌘-click kept and the non-goal reworded (scope 4, Non-goals) |
| R-19 | SwiftTerm reports raw `waitpid` status ("exit 256") (blocking) | Resolved: adapter normalizes exit vs signal (Requirements) |
| R-20 | Exit can arrive before the final output, dropping the last path line (blocking) | Resolved: finished event only after drain and parser end (Requirements) |
| R-21 | `failed(nil)` carries no reason after relaunch (should-fix) | Resolved: the app writes the reason into the tab and its log (scope 3) |
| R-22 | Path reader rules are loose (split escapes, overflow, CR) (should-fix) | Resolved: exact rules, live output only (Requirements). Escape and bare-CR handling later cut as unreachable (S-2) |
| R-23 | Malformed login environment reads as "slipstream not found" (should-fix) | Resolved: injectable, validated environment closure (Requirements) |
| R-24 | Quit only waits for chats (should-fix) | Resolved: one termination handshake awaits chats and terminals (Requirements) |
| R-25 | A close confirmation can target the wrong tab after Setup moves (should-fix) | Resolved: bound to the tab id (Requirements) |
| R-26 | A fake session factory leaks real side effects into model tests (should-fix) | Resolved: closure-based runtime covering launch, events, busy, stop and history (Requirements) |
| R-27 | Fakes can't prove SwiftTerm's real ordering (should-fix) | Resolved: small real-pty integration suite (Requirements) |
| R-28 | Persisted `startedAt` serves nothing after relaunch (minor, twice) | Resolved: `running` has no payload; the live session times it with the continuous clock (models.md). Changes approved models.md, flagged to Brian |
| R-29 | A folderless Setup selected under several workspaces leaves stale selections (should-fix) | Resolved: a stale selection falls back to the first tab, so nothing is pruned (S-7); no new Terminal 1 during archive or quit (models.md). Since 2026-11-09 moving the Setup clears the stale selections |
| R-30 | Downgrade, archive, upgrade leaves orphan records (should-fix) | Accepted: those tabs show "This folder no longer exists" and close normally; a missing workspace list never deletes anything (models.md) |
| R-31 | No acceptance matrix (blocking) | Resolved: the implementation plan carries Codex's matrix as its acceptance gates |

No finding on: the app-lifetime page model, the retained terminal view, storing terminal numbers
or the final duration, or the Node TTY ordering claim.

## Simplicity gate (Codex and Opus, 2026-10-25)

Both reviewers read the plan against the client and daemon code. Both found the overall
approach about as small as the approved scope allows: no whole subsystem or PR can go without
reversing a decision or an approved frame. Numbering follows the Opus report; the plan cites
these ids.

| # | Cut (who) | Disposition |
|---|---|---|
| S-1 | Delete a closed tab's log before its record; drop launch cleanup of orphan logs and its decode-failure guard (Opus) | Adopted by Brian (D1, 2026-10-25). Reverses R-7's close order and approved models.md; a crash mid-close brings the tab back empty |
| S-2 | Path reader only splits on LF; no escape, bare-CR or final-line handling (Opus) | Adopted. The CLI prints the path plain, after an empty line, ending in a newline |
| S-3 | Reuse archive's two-level folder check; drop the `workspace-<N>` name and control-character checks; resolve the managed root once (Opus, Codex 3) | Adopted |
| S-4 | `WorkspaceOutcome.workspacePath` is dead once create moves to the tab; keep only failure text (Opus, Codex 1) | Adopted |
| S-5 | `isInputEnabled` derived: input goes to the process handle, which doesn't exist during replay (Opus) | Adopted |
| S-6 | "Saved before shown" test and its surface spy prove nothing, since append only queues (Opus) | Adopted |
| S-7 | Don't prune selections when the Setup tab moves or closes; the first-tab fallback gives the same result (Opus) | Adopted; R-29's behaviour is unchanged. Reversed for moves 2026-11-09: the fallback didn't give the same result (decision log) |
| S-8 | No compaction on read; append compacts (Opus) | Adopted |
| S-9 | Drop duplicate and literal tests (`finishedComesAfterTheLastOutput`, `terminalValues`, per-string display tests) (Opus, Codex 6) | Adopted |
| S-10 | `isFolderMissing` computed from `missingFolderPath` (Opus, Codex 4) | Adopted |
| S-11 | Share `OneShot` from `AgentProcessClient` instead of copying it (Opus) | Adopted |
| S-12 | Set SwiftTerm scrollback to 4,000; its default of 500 would defeat the history cap (Opus; a gap, not a cut) | Adopted |
| S-13 | `start(restoring:)` loses its flag; `start` already reads the log (Codex 2) | Adopted |
| S-14 | Parser line limit is a fixed constant, not an init parameter (Codex 5) | Adopted |

Considered and kept (Opus): SwiftTerm's `LocalProcess` (no end-of-output signal, so R-20 can't be
met), a text snapshot instead of a byte log (loses the colours in the approved Restored frame),
comparing session ids instead of `selectionCount` (auto-selects would cancel the switch),
deriving `interrupted`, dropping old-CLI support, and dropping "always one terminal tab".

## Open questions

- None open. Brian chose the switch timing and D1 on 2026-10-25 (decision log).

## Design deliverables

- Screens: [screens.md](./screens.md). The window gains the Terminals pane (approved 2026-10-25).
- Endpoints: [endpoints.md](./endpoints.md) — approved by Brian 2026-10-25. There's no HTTP or socket change. The
  `slipstream workspace create` output gains an early `workspace_path:` line, and the app runs
  the command in a terminal instead of headless.
- Models: [models.md](./models.md) — approved by Brian 2026-10-25. New client types and files on disk: terminal
  tab records, per-workspace selected tab, history logs.
- Implementation plan: [implementation-plan.md](./implementation-plan.md).

## Existing contracts (Phase 2, surveyed 2026-10-24 at the base commits)

### Client

- **Window.** One `Window("Slipstream", id: "main")` holds `ChangeStreamPageView(chat:)`
  (`SlipstreamViewerApp.swift`). Its body is `HStack { feedPane (hideable); detailPane }`, with
  `minWidth: 1000` (`ChangeStreamPageView.swift`). Current screen:
  ![Window today](../linked-chat/exports/chat-console--linked.png)
- **New Workspace.** `newWorkspaceTapped()` (`ChangeStreamPageModel.swift:507`):
  - `chooseRepository()` → `workspace.create(repo, storeID)` → `loadSessions(preferring: path)`.
  - On failure it calls `workspaceFailed(title:text:)` (the alert).
  - `isWorkspaceBusy` blocks a second create meanwhile.
- **WorkspaceClient** (`WorkspaceClient.swift`). `{managedRoot, chooseRepository, create,
  archive}`.
  - `runSlipstream` uses `AgentEnvironmentClient.loginEnvironment()` and finds `slipstream` on
    the login PATH.
  - It merges stdout and stderr through a pipe, so it's not a terminal. Colours and progress
    bars are lost.
  - `outcome(output:status:)` takes the last `workspace_path: ` line and, on failure, the last 12
    other lines.
- **Archive.** `archiveConfirmed()` (`:524`):
  - It hides and stops the folder's chats, then runs `archive`.
  - On failure it restores the chats. On success it forgets them.
- **Login environment.** `AgentEnvironmentClient.loginEnvironment()` runs
  `$SHELL -ilc 'printf marker; env -0'`. `loginShell(environment:passwordDatabaseShell:)` picks
  the shell.
- **Saved tabs pattern.** `ChatTabRecord {id, folder, model, effort, isWaiting}` in one global
  `@Shared(.chatTabs)` file (`Application Support/<bundle id>/chatTabs.json`), filtered by
  `folder` (`Models/ChatTabRecord.swift`).
- **App-lifetime models.** The chat model is created once in the app and keeps every
  workspace's tabs (and their processes) alive across switches (`ChatPageModel`). Terminals
  follow the same ownership.

### `slipstream workspace create` (daemon @ feffc30, `src/workspace.ts:36-75`, `src/cli.ts:709-731`)

1. Checks for an `origin` remote and fetches it.
2. Picks the base (`origin/develop`, else origin's default branch).
3. Adds the worktree `~/slipstream/workspaces/<repo>/workspace-N` on a new branch.
4. Prints `created <path> on <branch> from <base>`.
5. Records the folder with the daemon.
6. Runs the repo's committed `setup` script with `/bin/sh -c`. stdin is ignored; stdout and
   stderr are inherited, so they reach the terminal. It sets `CONDUCTOR_ROOT_PATH` and
   `CONDUCTOR_WORKSPACE_PATH`.
7. Prints an empty line, then `workspace_path: <path>`, whether or not the script succeeded.
8. Exits 0 only if recording and setup both succeeded.

Failures before step 4 print `slipstream: …` to stderr and no path.
