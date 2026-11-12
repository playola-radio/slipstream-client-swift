# PR status bar — Screens

Pen file: `design/slipstream.pen`. The frames are in zone "Zone · PR status bar" (`Mhzm1`): screen A
(`t68du`) holds the status states (drawn as the original 40pt row; the content is unchanged), screen B
(`V3XP4`) the chat messages, and screen C (`PVSLw`, 2026-11-12) the toolbar placement that replaced the
row (spec D16). Measurements and colours
are in [`exports/pr-status-bar.json`](exports/pr-status-bar.json); the HTML exports are next to it.

## Navigation map
| Screen | Surface | Address | Reached from |
|---|---|---|---|
| Workspace window, toolbar PR section | client | n/a (native): a tinted pill at the trailing end of the window toolbar of `Window("Slipstream", id: "main")`, just before the right-panel toggle | Selecting a workspace in the sidebar |
| Workspace window, chat transcript | client | n/a (native): the chat column | Selecting a workspace; a PR bar button that hands work to the agent |

## Workspace window, toolbar PR section (the PR status bar)
- **Status:** Changed
- **Surface:** client
- **Address:** n/a (native). A tinted rounded pill at the trailing end of the window toolbar, just
  before the right-panel toggle. Open In sits 12pt left of the right panel's divider (spec D17). Until 2026-11-12 this
  was a 40pt row at the top of the right column; it moved so it shows while the right panel is
  hidden (spec D16).
- **Access:** anyone using the app on this Mac. It shows only when a workspace is selected.
- **Navigated to from:**
  - Sidebar → choosing a workspace row. The bar shows that workspace's PR.
- **Navigates to:**
  - PR number chip `#61 ↗` → opens the PR on GitHub in the default browser.
  - **Create PR** (⌘⇧P) → sends the agent "Create a PR" with `PR instructions.md` attached. The chat
    shows the message (screen B).
  - **Commit and push** → sends the agent "Commit and push all changes".
  - **Resolve conflicts** → sends the agent "Rebase your branch onto the remote branch (`<target>`)
    and resolve conflicts. Stage the resolved files and run `git rebase --continue`, then push
    --force-with-lease."
  - **Fix errors** (⌘⇧X) → sends the agent "Fix the failing CI actions. I've attached the failure
    logs." with `Fix errors instructions.md` attached.
  - **Merge** (⌘⇧M) → merges the PR on GitHub directly (no agent), with the repository's default
    merge method, only if the PR head is still the one shown.
  - **Continue** → starts a new branch in the same workspace from the latest target branch (no
    agent). The chats stay.
  - **Archive** → archives the workspace, as the sidebar's Archive does today.
  - **Details** → a popover with the failed command, its exit status and its full output, with Copy.
- **Changed from today:** the PR row leaves the right column and becomes a pill in the toolbar. It
  shows, left to right: the PR number chip (when a PR exists), where things stand (icon, label,
  muted detail), and the next-step buttons. The pill's fill follows the state's tone (purple when
  merged). It stays visible when the right panel is hidden. Only one situation shows at a time. Which one is decided by the rules in
  spec.md ("How the status is derived"); the table lists the states, not their precedence.
  While an agent button's message is being sent and its agent turn runs, that button is dimmed, as
  Merge is in Merging.

  Current screen (the reference preview from `conductor-top-bar`):
  ![Right header — today's reserved slot](exports/existing/window--pr-actions-preview.png)

  Conductor, for reference: ![Conductor — Create PR](exports/existing/conductor--create-pr.png)
  ![Conductor — merged](exports/existing/conductor--merged.png)

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Checking | The selected workspace has no status result yet (later checks keep the last state). Muted spinner and "Checking for a pull request…" | `JiBez` | ![PR status bar — checking](exports/pr-status-bar--checking.png) |
| Couldn't check | `git` or `gh` failed (gh missing, signed out, no network, timeout). Red title and **Details**. The title names the operation: "Couldn't check the pull request", "Merge failed", "Couldn't start a new branch", "Couldn't send Create PR"… | `chZSM` | ![PR status bar — error](exports/pr-status-bar--error.png) |
| Couldn't check, Details open | **Details** clicked: the operation, folder, command, how it ended (exit status, timeout, launch failure) and full output, selectable, with Copy | `VYTJt` | ![PR status bar — error details](exports/pr-status-bar--error-details.png) |
| Merging | **Merge** clicked and GitHub hasn't answered. "Merging…", the Merge button dimmed | `dLmoG` | ![PR status bar — merging](exports/pr-status-bar--merging.png) |
| Merged | The branch's PR is merged, its head is still this branch's HEAD, and nothing is uncommitted. The strip is tinted purple; **Continue** and **Archive** | `AyH6f` | ![PR status bar — merged](exports/pr-status-bar--merged.png) |
| Closed | The branch's PR was closed without merging, with the same head-and-clean rule as Merged. Muted "Closed"; **Create PR** opens a new one | `c7Bvm` | ![PR status bar — closed](exports/pr-status-bar--closed.png) |
| PR open, uncommitted or unpushed | A PR is open and the worktree has uncommitted changes, or local HEAD is ahead of the PR's head. **Commit and push** | `D7cwis` | ![PR status bar — open, uncommitted](exports/pr-status-bar--open-uncommitted.png) |
| PR open, merge conflicts | GitHub reports the PR conflicts with its base. Amber "Merge conflicts with develop"; **Resolve conflicts** | `T2halZ` | ![PR status bar — open, conflicts](exports/pr-status-bar--open-conflicts.png) |
| PR open, checks failed | At least one check failed. Red "Checks failed · 2 of 9 failed"; **Fix errors** | `ub22i` | ![PR status bar — open, checks failed](exports/pr-status-bar--open-checks-failed.png) |
| PR open, checks running | Checks are still running and none has failed. Muted "Checks running · 6 of 9 done"; no button | `KCeFx` | ![PR status bar — open, checks running](exports/pr-status-bar--open-checks-running.png) |
| PR open, ready | Not a draft, nothing failed or running, and GitHub says it can merge (`MERGEABLE` and `CLEAN`). Green "Ready to merge"; **Merge** | `uNssU` | ![PR status bar — open, ready](exports/pr-status-bar--open-ready.png) |
| PR open, draft | Would be "ready", but the PR is a draft (gh won't merge drafts). Muted "Draft · all checks passed"; no button (spec D6) | `Egghy` | ![PR status bar — open, draft](exports/pr-status-bar--open-draft.png) |
| PR open, waiting | Nothing to fix, but GitHub won't merge yet: still computing, review required, changes requested, behind the target, blocked by branch rules, or the branch is out of sync with the PR. Muted hourglass, "Waiting on GitHub · <reason>"; no button (spec D12) | `Diimy` | ![PR status bar — open, waiting](exports/pr-status-bar--open-waiting.png) |
| No PR, uncommitted | No PR for the branch, and the worktree has uncommitted changes. **Create PR** | `SKZEl` | ![PR status bar — no PR, uncommitted](exports/pr-status-bar--no-pr-uncommitted.png) |
| No PR, committed | No PR, clean worktree, branch has commits its target doesn't. "Ready for a pull request · 3 commits ahead of develop"; **Create PR** | `gapRS` | ![PR status bar — no PR, committed](exports/pr-status-bar--no-pr-committed.png) |
| Nothing to submit | No PR, clean worktree, nothing ahead of the target. The strip is empty | `ik1F7` | ![PR status bar — nothing to submit](exports/pr-status-bar--nothing-to-submit.png) |

The table above shows each state's content as drawn in the original row; the toolbar pill carries
the same content.

### Toolbar placement and narrow windows (screen C, 2026-11-12)

The content above sits in a pill in the toolbar. Open In ends 12pt left of the right panel's
divider, or 12pt left of the pill when the pill reaches further left or the right panel is hidden
(spec D17). As the
window narrows the pill gives up room so the breadcrumb and Open In never go into the toolbar's
"»" overflow menu: first the grey detail goes, then the buttons hide their titles and displayed shortcut
indicators (the shortcuts, tooltips, and VoiceOver labels stay). The PR number chip and the status label always stay. With no
workspace selected, or when the feature doesn't apply (Nothing to submit, not a repo, fork), the
pill is not shown. The pill looks the same with the right panel open or hidden.

| State | Wide | Narrower: detail dropped | Narrowest: icon-only buttons |
|---|---|---|---|
| No PR yet (`YUDuk`) | ![Toolbar — no PR, wide](exports/pr-status-toolbar--no-pr--wide.png) | ![Toolbar — no PR, medium](exports/pr-status-toolbar--no-pr--medium.png) | ![Toolbar — no PR, narrow](exports/pr-status-toolbar--no-pr--narrow.png) |
| Checks failed (`rathA`) | ![Toolbar — checks failed, wide](exports/pr-status-toolbar--checks-failed--wide.png) | ![Toolbar — checks failed, medium](exports/pr-status-toolbar--checks-failed--medium.png) | ![Toolbar — checks failed, narrow](exports/pr-status-toolbar--checks-failed--narrow.png) |
| Ready to merge (`JT6cS`) | ![Toolbar — ready, wide](exports/pr-status-toolbar--ready--wide.png) | ![Toolbar — ready, medium](exports/pr-status-toolbar--ready--medium.png) | ![Toolbar — ready, narrow](exports/pr-status-toolbar--ready--narrow.png) |
| Merged (`zseT4`) | ![Toolbar — merged, wide](exports/pr-status-toolbar--merged--wide.png) | ![Toolbar — merged, medium](exports/pr-status-toolbar--merged--medium.png) | ![Toolbar — merged, narrow](exports/pr-status-toolbar--merged--narrow.png) |

Ready to merge and Merged have no grey detail, so their middle column only differs in width. The
exact widths at which each step happens depend on the measured text, not on fixed breakpoints.

## Workspace window, chat transcript
- **Status:** Changed
- **Surface:** client
- **Address:** n/a (native). The chat column's transcript.
- **Access:** anyone using the app on this Mac.
- **Navigated to from:**
  - A toolbar PR button that hands work to the agent. The message appears in the workspace's chat; if no
    chat is open for the workspace, one is opened first.
- **Navigates to:**
  - Attachment chip → opens the attached file in its default app.
- **Changed from today:** a user message ending in a well-formed `@⟦name⟧(path)` marker (grammar in
  spec.md) shows the text before the marker, then a file chip labelled with `name`, instead of the
  raw marker. Other messages are unchanged. If the file is gone, clicking the chip shows an alert
  naming the path.

| State | When it shows | Node | Mockup |
|---|---|---|---|
| Create PR sent | **Create PR** was clicked | `f00glz` | ![Chat message — Create PR](exports/chat-message--create-pr.png) |
| Fix errors sent | **Fix errors** was clicked; the failure logs are inside the attached file | `X6l6V` | ![Chat message — Fix errors](exports/chat-message--fix-errors.png) |
| Plain message sent | **Commit and push** or **Resolve conflicts** was clicked (no file) | `iQKtW` | ![Chat message — Commit and push](exports/chat-message--commit-and-push.png) |
