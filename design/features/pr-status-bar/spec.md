# PR status bar

A bar at the top of the right column shows where the selected workspace's pull request stands,
plus the one button for the next step: **Create PR**, **Commit and push**, **Resolve conflicts**,
**Fix errors**, **Merge**, or **Continue** and **Archive** once it has merged. It copies
Conductor's top bar as closely as the evidence allows.

## Why

From Brian, 2026-11-11: "Let's add a PR status bar with buttons (starting with Create PR)…
This is a solved problem — see if you can find exactly what conductor.dev does." The product
goal is spotting LLM mistakes early without interface bloat. One status line and one button per
situation keep the bar small. Most of the work is still handed to the agent in the chat, where
Brian can see it.

## Base commits

| Repo | Branch | SHA |
|---|---|---|
| Client `playola-radio/slipstream-client-swift` | `develop` | `a8fb46b` (a8fb46bfbd3aa420927c35b70fb6d707fe37c72c) |
| Daemon `playola-radio/slipstream` | not touched | — |

## Target surfaces

- `client`: the macOS app (`SlipstreamViewer`) and `SlipstreamCore`. No daemon change.

## What Conductor does (evidence)

Found in Conductor's local database (`session_messages`, `attachments`) and its attachment files,
2026-11-11.

- A button doesn't run git itself. It writes an instructions file and sends the agent a short
  chat message that ends with a marker `@⟦<name>⟧(<url-encoded path>)`. The chat draws the
  marker as a small file chip. The marker is plain message text, so it survives a transcript
  reload.
- Create PR (⌘⇧P): message "Create a PR", file `PR instructions.md`. The template is below, with
  the git facts filled in when the button is clicked.
- Commit and push: message "Commit and push all changes". No file.
- Resolve conflicts: message "Rebase your branch onto the remote branch (develop) and resolve
  conflicts. Stage the resolved files and run `git rebase --continue`, then push
  --force-with-lease." No file.
- Fix errors (⌘⇧X): message "Fix the failing CI actions. I've attached the failure logs.", file
  `Fix errors instructions.md`.
- Merge (⌘⇧M) merges directly. Merged shows `#487 ↗ Merged · Continue · Archive`. Continue is
  "Continue on new branch" (Conductor changelog 0.32.0).
- Screenshots: [`exports/existing/conductor--create-pr.png`](exports/existing/conductor--create-pr.png),
  [`exports/existing/conductor--merged.png`](exports/existing/conductor--merged.png).

## Scope

1. **Where.** In the window toolbar (`ChangeStreamPageView.toolbar`), at the trailing end, just
   before the right-panel toggle. Open In shares the pill's toolbar item and sits just left of
   the chat column's right edge: 12pt left of the right panel's divider, or 12pt left of the pill
   when the pill reaches further left or the right panel is hidden (D17). The section is a tinted rounded pill
   (`DesignTokens.PRStatusBar.fill(tone)` with its stroke), because the toolbar has one
   background. It shows whenever a workspace is selected, whether the right panel is open or
   hidden; it is hidden when the feature doesn't apply (see "How the status is derived", step 1).
   The right column no longer has a PR row. This reverses the 2026-11-11 placement (Q1, "a row at
   the top of the right column, toolbar unchanged"): Brian, 2026-11-12, D16.
   - **Narrow windows.** The pill never pushes the breadcrumb or Open In into the toolbar's "»"
     overflow menu. As room shrinks it first drops the grey status detail, then shows the action
     buttons as icons only (help text and accessibility labels stay). The PR number chip and the
     status label always stay. `PRStatusBarModel` decides the layout and the gap between Open In
     and the pill from the window width, the right panel's divider position, the measured Open In
     width and the measured pill widths; the view only reports widths. Open In and the pill keep
     to the space they had when Open In was centred: half of what's left after Open In, minus the
     trailing chrome (the right-panel toggle and toolbar insets, 52pt measured on macOS 26) and
     the 12pt margin. So in narrow windows Open In can sit left of the divider by more than 12pt.
     This is best-effort: at the smallest window widths even the icon-only pill may not fit.
2. **States.** The states in [`screens.md`](screens.md). Exactly one shows at a time. The status
   is computed as a domain value (models.md `PRStatus`); presentation flags (Details open, an
   operation in flight) sit on top of it, not in the same ordered list.
3. **Agent buttons** (Create PR, Commit and push, Resolve conflicts, Fix errors) send their message
   to the chat tab that was selected for the workspace when the button was clicked. Every selected
   workspace already has a tab (`ChatPageModel.workspaceChanged`). The send uses a new
   `ChatTabModel.enqueueUserMessage(_:)` (contract below). The user's draft text is never touched.
4. **Direct buttons** run without the agent:
   - **Merge** merges the PR on GitHub with the repository's default merge method, only if the PR
     head is still the one shown.
   - **Continue** starts a new branch from the latest target branch in the same folder.
   - **Archive** is the sidebar's existing archive, including its confirmation.
5. **File chip.** A user message ending in a well-formed `@⟦name⟧(path)` marker shows the text
   before the marker, then a chip labelled `name`. Clicking the chip opens the file in its default
   app. Every other message looks the same as today.
6. **Filled in at click time.** The branch, target, change counts and push state in the
   instructions file are read when the button is clicked, not from the last status check.
7. **Shortcuts.**
   - ⌘⇧P runs Create PR.
   - ⌘⇧X runs Fix errors.
   - ⌘⇧M runs Merge.
   - Each is attached to its button (`.keyboardShortcut`), so it works only while that button is
     shown and enabled. These combinations are free today.
8. **Refresh.** The status is checked:
   - on workspace selection;
   - on app activation;
   - on ⌘R;
   - right after Merge, Continue, or a send finishes;
   - when a chat turn in the workspace starts or ends;
   - 30 seconds after the previous check finished, while the window is shown and the app is
     active.
9. **Full errors.** Any failed `git` or `gh` call shows the operation, folder, command line, how it
   ended (exit status, timeout, or launch failure) and complete output in the Details popover, with
   Copy.

## Non-goals

- Conductor's other top-bar items: Update memory, Review, Open PR page tabs, Archive confirmation
  copy changes.
- Creating draft PRs (cut 2026-11-11, Codex finding 15). Existing drafts are shown, with no action.
- Auto-merge, merge queues, choosing a merge method in the UI, and deleting the remote branch on
  merge.
- A PR list, a PR page, review comments, or reviewer status beyond the Waiting reason.
- Showing CI logs in the app. They go into the Fix errors file only.
- Any daemon, store or HTTP change.
- Conductor's `mcp__conductor__GetWorkspaceDiff` step. Our instructions use `git diff` and `gh`
  instead.
- Remembering PR status between launches. It is always derived live.
- Non-GitHub remotes, and workspaces whose `origin` is a fork (PRs from a fork to its upstream).
- Cleaning up old attachment files.

## How the status is derived

Commands run through a new `RepoCommandClient` (models.md): in the workspace folder, with the
user's login environment (resolved once per app run and cached by generalizing the existing
`AgentEnvironmentCache`; not `AgentEnvironmentClient.resolve()`, which fails without `claude`),
with a timeout, and with stdout, stderr and the exit separated. Its live value extends the
existing poll-and-drain loop in `AgentEnvironmentClient.captureOutputBlocking` with a working
directory and a second pipe. `git` and `gh` are found on the login `PATH`. Timeouts: 10 s for
`git`, 20 s for `gh` reads, 60 s for `gh run view`, `gh pr merge` and `git fetch`.

1. **Applies?** `git rev-parse --abbrev-ref HEAD` and `git rev-parse HEAD`. Not a git repository,
   a detached HEAD, or no `origin` remote → **not applicable**: the row is empty, not an error.
2. **Repository.** `gh repo view --json isFork,defaultBranchRef,viewerDefaultMergeMethod`.
   `isFork == true` → not applicable (non-goal). Any failure → **Couldn't check**.
3. **Uncommitted.** `git status --porcelain=v1` — the count of lines.
4. **PR identity.** `gh pr list --head <branch> --state all --limit 20 --json
   number,url,state,isDraft,headRefOid,isCrossRepository,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup`.
   An empty list means no PR; no error-text matching is needed. Only PRs with
   `isCrossRepository == false` count. Then:
   - the open PR with the highest number is **the PR**;
   - otherwise the merged or closed PR with the highest number is the PR **only if** its
     `headRefOid` equals local `HEAD` and nothing is uncommitted;
   - otherwise there is **no PR** (the branch has new work since that PR).
5. **Target branch.** The PR's `baseRefName`, else the repository's `defaultBranchRef.name`. The
   remote is always `origin` (forks are out of scope).
6. **Ahead of target** (no PR and a clean worktree): ensure `origin/<target>` exists, fetching that
   one remote-tracking ref when a single-branch clone does not have it, then run `git rev-list
   --count origin/<target>..HEAD`. An existing ref is not refreshed. A dirty worktree skips both
   operations because uncommitted changes already determine the status.
7. **Push state** (open PR): local `HEAD` against the PR's live `headRefOid`.
   - Equal → in sync.
   - `git merge-base --is-ancestor <headRefOid> HEAD` succeeds → **local ahead** (unpushed).
   - Otherwise (local behind, diverged, or the PR head isn't in the local object store) →
     **out of sync**.
8. **Checks** come from `statusCheckRollup`, decoded by `__typename`:
   - `CheckRun`: name `name`, link `detailsUrl`, `status`, `conclusion`.
   - `StatusContext`: name `context`, link `targetUrl`, `state`.
   - **Failed**: CheckRun conclusion `FAILURE`, `TIMED_OUT`, `ACTION_REQUIRED`, `STARTUP_FAILURE`;
     StatusContext state `FAILURE`, `ERROR`.
   - **Running**: CheckRun status other than `COMPLETED`; StatusContext `PENDING`, `EXPECTED`.
   - **Everything else** (`SUCCESS`, `NEUTRAL`, `SKIPPED`, `CANCELLED`, `STALE`, null, unknown
     values) is **done and not failed**. `CANCELLED` is here on purpose: CodeRabbit leaves a
     cancelled check on every merged PR in this repo (seen on #80). Whether a non-failed check
     actually blocks merging is GitHub's call, read from `mergeStateStatus` below.
   - "N of M" counts rollup entries; "done" is everything not running.
9. **Open PR status**, first match:
   1. uncommitted > 0 or local ahead → **Commit and push**;
   2. out of sync → **Waiting**, reason "branch is out of sync with the PR";
   3. `mergeable == CONFLICTING` → **Merge conflicts**;
   4. any check failed → **Checks failed**;
   5. any check running → **Checks running**;
   6. `isDraft` → **Draft**;
   7. `mergeable == MERGEABLE` and `mergeStateStatus` is `CLEAN`, `HAS_HOOKS` or `UNSTABLE` →
      **Ready to merge**;
   8. otherwise → **Waiting on GitHub**, with the reason:
      - `mergeable`/`mergeStateStatus` `UNKNOWN` → "GitHub is still checking";
      - `reviewDecision == CHANGES_REQUESTED` → "changes requested";
      - `reviewDecision == REVIEW_REQUIRED` → "review required";
      - `mergeStateStatus == BEHIND` → "behind <target>";
      - `mergeStateStatus == BLOCKED` → "blocked by branch rules";
      - anything else → "not mergeable yet".

   `UNKNOWN` never enables Merge. Zero checks don't block Ready; GitHub's `CLEAN` decides.
10. **No PR status**: uncommitted > 0 → **No PR, uncommitted**; ahead > 0 → **No PR,
    committed**; else **Nothing to submit** (empty row).
11. **Merged / Closed**: only reached through step 4's head-and-clean rule.

## Ownership

One `PRStatusBarModel` per window, owned by `ChangeStreamPageModel` (models.md). It follows the
window's existing session poll (`ChangeStreamPageView.swift:86`, `.task(id:
model.isSessionPollRunning)`).

- **One poll, restarted on change.** The view runs `.task(id: model.pollKey) { await
  model.pollTask() }`. `pollKey` is the selected folder, `chat.isAppActive`, a refresh counter,
  whether an operation is in flight, and `chat.hasWorkingTab(in:)`. `pollTask` does nothing while
  no folder is selected, the app is inactive or an operation is in flight; otherwise it loops:
  read, stop if cancelled, publish the result for that folder, sleep 30 s on the injected clock.
- **A superseded read never publishes.** Any key change cancels the task, and the read is checked
  for cancellation before publishing on the main actor. That one rule covers A→B→A selection, a
  workspace archived mid-check, an operation in flight ("Merging…" stays) and the app going
  inactive. ⌘R bumps the refresh counter; an operation finishing or a turn starting or ending
  changes the key. A cancelled read's child process isn't killed; it ends at its own timeout.
- **Last good state** is stored with the folder it belongs to and stays on screen while that
  folder is re-checked. **Checking** shows while there is no result yet for the selected folder
  (D8).

## Actions

### Agent buttons

At click: capture the workspace folder and the selected chat tab (the `ChatTabModel` itself).
The operation is in flight until the send finishes. Agent buttons are disabled (dimmed, as Merge
is while merging) while an operation is in flight or any chat tab in the workspace is working
(`ChatPageModel.hasWorkingTab(in:)`, D15). Then:

1. Read the git facts (Create PR) or fetch the logs (Fix errors).
2. Write the attachment, if any, through `AttachmentClient`. **If writing fails, nothing is sent**
   and the failure shows in Details.
3. `enqueueUserMessage(text + " " + marker)` on the captured tab. A tab closed meanwhile throws
   (its `isClosed` guard), and Details says the chat tab was closed.
4. The status refreshes when the operation ends and again when the started turn ends, through
   `pollKey`.

### `ChatTabModel.enqueueUserMessage(_ text: String) async throws`

- Shares one private write/project/rollback path with `send()`; each keeps its own admission
  rule (`send()` is idle-only and clears the draft; enqueue also writes mid-turn).
- Never reads or clears `draft`.
- Idle tab: starts a turn and the process if needed, exactly as `send()` does.
- Mid-turn tab: writes immediately; the agent reads it after its current step (the same
  transport behaviour `relay(_:)` already relies on).
- Projects the message as a plain user message straight away. No Instant Ask relay mark, label or
  delivery state.
- If the write fails, removes the projected message, ends any turn it started, and throws.
- If the process exits before echoing a mid-turn enqueue, shows a delivery failure even if the
  preceding turn already ended.
- Round-trips through history like any user message (prompt lines and `queued_command`
  attachments, `ClaudeLines.swift:58`).

### Merge

1. `gh pr merge <url> --<method> --match-head-commit <headRefOid>`, where `<method>` maps
   `viewerDefaultMergeMethod` (`MERGE`/`SQUASH`/`REBASE`) to `--merge`/`--squash`/`--rebase`. The
   branch is not deleted. `--match-head-commit` makes GitHub refuse the merge if the PR head
   moved since the bar showed it.
2. Failure (branch protection, review required, head moved) shows in Details. Success refreshes.

### Continue

Shown only in Merged, which already guarantees a clean worktree whose `HEAD` is the merged head.
Disabled, like the agent buttons, while an action runs or a chat in the folder is working (D15).

1. `git fetch origin +refs/heads/<target>:refs/remotes/origin/<target>`. The explicit refspec
   updates `origin/<target>` even in a single-branch clone; `FETCH_HEAD` is not used because any
   other fetch in the repo can rewrite it before the switch.
2. Pick `<name>`: the old branch with `-2`, `-3`… (an existing `-N` suffix is incremented); the
   first name that exists neither locally nor on origin. One `git for-each-ref
   --format=%(refname:short) refs/heads` and one `git ls-remote --heads origin` supply both lists;
   a pure function in Core picks the name.
3. Recheck at click time that the branch, `HEAD` (the PR's `headRefOid`) and a clean
   `git status` still hold, and that no chat in the folder started working during the fetch; if
   not, show the failure and reload instead of switching.
4. `git switch --no-track -c <name> origin/<target>`. No upstream is set; the next Create PR
   pushes it.
5. Any failure shows in Details; success refreshes. The chats stay.

### Archive

Reuses `ChangeStreamPageModel.archiveTapped(_:)` with its confirmation. Shown only when the
workspace is archivable (`isArchivable`); otherwise Merged shows only Continue.

## Errors

`PRBarFailure` (models.md) is a red title plus the Details text, rendered when the failure
happens (the pattern of `ChangeStreamPageModel.workspaceFailed(title:text:detail:)`). For a command
the Details text holds the folder, the command (arguments joined with shell quoting via
`RuntimeInstall.shellQuoted`, never an environment value), how it ended (exit status, "timed out
after N s", or the launch failure) and the complete stdout and stderr.

| Operation | Red title |
|---|---|
| Status check | Couldn't check the pull request |
| Create PR / Commit and push / Resolve conflicts / Fix errors | Couldn't send <button name> |
| Merge | Merge failed |
| Continue | Couldn't start a new branch |

A status-check failure is replaced by the next successful check. An action failure stays until
Details is dismissed with its close button, the action is retried, or the workspace changes.

## Instruction files and the chip

**Location.** `~/Library/Application Support/Slipstream/attachments/<uuid>/<Name>.md`, written
atomically by `AttachmentClient`. They never show up as uncommitted changes, and the agent can't
commit them. The agent runs with `--permission-mode=bypassPermissions`, so it can read them. They
are not cleaned up in v1. (D2)

**Marker grammar.** The message ends with one space, then `@⟦<name>⟧(<path>)`:

- `<name>` is the file name, with no `⟦`, `⟧` or newline.
- `<path>` is the absolute file path, percent-encoded with everything except unreserved characters
  and `/` encoded, so it contains no spaces or parentheses.
- Parsing accepts exactly one marker, at the very end of the text, whose path decodes to an
  absolute path. Anything else renders as plain text, unchanged.

**Chip click.** Opens the file through `AttachmentClient.open`. If the file no longer exists or
won't open, an alert names the path and the reason.

**`PR instructions.md`** (Create PR). This is Conductor's template; the first block is filled in at
click time:

```
The user likes the current state of the code.

There are <N> uncommitted changes.
The current branch is <branch>.
The target branch is origin/<target>.

<There is no upstream branch yet. | The upstream branch is <upstream>. | There are <K> unpushed commits.>
The user requested a PR.

Follow these steps to create a PR:

- If you have any skills related to creating PRs, invoke them now. Instructions there should take precedence over these instructions.
- Run `git diff` to review uncommitted changes
- Commit them. Follow any instructions the user gave you about writing commit messages.
- Push to origin.
- Run `git diff origin/<target>...HEAD` to review the PR diff
- Use `gh pr create --base <target>` to create a PR onto the target branch. Keep the title under 80 characters. Keep the description under five sentences, unless the user instructed you otherwise. Describe not just changes made in this session but ALL changes in the workspace diff.

If any of these steps fail, ask the user for help.
```

The upstream line comes from `git rev-parse --abbrev-ref @{upstream}` and
`git rev-list --count @{upstream}..HEAD` at click time.

**`Fix errors instructions.md`** (Fix errors) holds:

- the PR number, URL and branch;
- each failed check's name and link;
- for each GitHub Actions run behind a failed check, the output of
  `gh run view <run-id> --repo <owner>/<repo> --log-failed`, keeping the last 300 lines.
  - The run is recognized only from a link of the form
    `https://github.com/<owner>/<repo>/actions/runs/<run-id>[/job/<job-id>]`.
  - Runs are fetched once per `(owner/repo, run-id)`, even when several failed checks share one.
- for a check whose link isn't an Actions run, only its name and link.

If fetching a log fails, the file includes the command and its output in place of the log, and
the message is still sent.

## Decisions (my calls, not Brian's unless marked)

- **D1 — agent message text.** We use Conductor's exact sentences, with the real target branch in
  Resolve conflicts.
- **D2 — attachments outside the worktree.** Conductor writes them to `.context/attachments/` in
  the workspace. That works only where `.context/` is git-ignored, which is true on this machine
  through `.git/info/exclude` but not for every Slipstream repo. Writing them inside the worktree
  would show them as uncommitted changes (flipping the bar) and risk the agent committing them.
- **D3 — superseded** by `enqueueUserMessage` (Codex finding 4: `send()` rejects mid-turn).
- **D4 — Continue** as in Actions → Continue.
- **D5 — merge method** from `viewerDefaultMergeMethod`; no branch delete; merge queues out of
  scope.
- **D6 — Brian (2026-11-11).** Existing draft PRs show "Draft · all checks passed" with no button
  (frame `uhPcs`).
- **D7 — Brian (2026-11-11).** Create draft PR and the Create PR chevron menu are cut.
- **D8 — Checking** shows while the selected folder has no result yet; re-checks keep showing
  the last state. (The 0.5 s grace timer was cut in the simplicity gate: real checks make two
  network calls and almost always exceed it.)
- **D9 — Archive** reuses `archiveTapped`, only when archivable.
- **D10 — superseded.** Push state compares with the PR's `headRefOid`, so it no longer depends
  on an upstream.
- **D11 — Brian (2026-11-11).** Clicking a chip opens the file. With no chat open, the button
  opens one and sends. Git facts are filled in at click time. Full scope here, not just Create PR.
- **D12 — Brian (2026-11-11).** A Waiting state (frame `dGTED`) covers "nothing to fix, but GitHub
  won't merge yet", with the reason as muted detail and no button. "Out of sync" uses the same
  frame with its own reason.
- **D13 — CANCELLED checks don't count as failed** (step 8).
- **D14 — Forks unsupported.** A fork `origin` hides the row rather than risk picking the wrong PR.
- **D16 — Brian (2026-11-12). The PR status moves into the window toolbar.** It reverses the
  2026-11-11 placement in scope 1: the row lived in the right column, so it vanished when the
  right panel was hidden. Now it is a pill before the right-panel toggle and Open In is centred
  on the whole window (not over the chat column). Mockups: screen C in screens.md. Open In's
  placement is changed by D17.
- **D17 — Brian (2026-11-12). Open In sits at the chat column's right edge.** After seeing D16
  running: "a small margin to the left of the right-most divider or the pr status bar if the
  divider is too far to the right." Open In moves out of `.principal` into the pill's toolbar
  item, with a model-computed gap so it ends 12pt left of the divider, or of the pill.
- **D15 — Agent buttons wait for the chat.** They are disabled while any chat tab in the
  workspace is working, not only the turn the bar started. This replaces a per-tab turn-end
  observer list; the spec's premise for it was wrong (Instant Ask hooks
  `ChatPageModel.onTabTurnEnded`, not `ChatTabModel.onTurnEnded`).

## Existing contracts

Client only; no daemon contract is touched. Paths are at `a8fb46b`.

- **Window top row.** The system toolbar (`ChangeStreamPageView.toolbar`, line 475) holds:
  - the sidebar toggle;
  - the breadcrumb;
  - the busy spinner;
  - a flexible spacer;
  - Open in;
  - the right-pane toggle.

  Changed by D16 and D17 (2026-11-12): Open in and the PR pill share one toolbar item between
  the flexible spacer and the right-pane toggle, with a model-computed gap between them. The `conductor-top-bar` work
  (#62, #63) restyled this toolbar.
- **Right column.** `rightPane` (`ChangeStreamPageView.swift:180`) is a `VStack` of
  `rightPaneStrip` (line 195, the Change stream / Terminals tabs and Compare functions) and the
  pane. Since D16 it has no PR row; the poll task (`.task(id: pollKey)`) moves to the page root
  so polling runs whether or not the pill or the right panel is shown.
- **Chat send.**
  - `ChatTabModel.send()` (`ChatTabModel.swift:230`) returns early when a turn is active.
  - `ChatTabModel.relay(_:)` (`:266`) writes mid-turn but carries Instant Ask's relay bookkeeping.
  - `onTurnEnded` (`:48`) is set by `ChatPageModel.addModel` (`:468`), which forwards to
    `onTabTurnEnded`, the slot `InstantAskModel` (`:135`) uses.
- **User message render.** `TranscriptProjection.Kind.userMessage(String, relay:)` →
  `ChatPageView.userBubble` (plain `Text`, `ChatPageView.swift:306`). History is rebuilt from the
  transcript JSONL, and user text round-trips verbatim.
- **Archive.** `ChangeStreamPageModel.archiveTapped(_:)` (`:827`) → alert →
  `archiveConfirmed()` → `WorkspaceClient.archive`.
- **Reload and polling.** `reloadShortcutPressed()` (`:734`, ⌘R), `appBecameActive()` (`:719`),
  and the `sessionPollTask()` pattern (`:725`, `.task(id:)`).
- **Processes.** `WorkspaceClient.runInBackground` (`WorkspaceClient.swift:89`) merges stderr into
  stdout and has no working directory, timeout or cancellation, so it is not reused.
  `AgentEnvironmentClient.captureOutputBlocking` (`:167`) already drains a pipe while the
  process runs and kills at a deadline; it is extended rather than rewritten. The login
  environment is cached only inside `AgentEnvironmentCache` (`:84`), behind a `claude` check.
- **Shortcuts.** `Commands` structs use `@FocusedValue(ChangeStreamPageModel.self)`. No ⌘⇧
  shortcuts exist.
- **Open a file.** Only `RecorderServiceClient.openLog` calls `NSWorkspace.shared.open`.
- **Deployment target** macOS 15 (`project.yml`), so the Observation `Observations` sequence
  (macOS 26) isn't available.

## Open questions

None. Q1 (placement) was resolved by Brian on 2026-11-11: a new row above the tabs.

## Adversarial review (Codex, 2026-11-11, session `01a1cc1b-8135-78d2-98a3-c7e843bd75de`)

| # | Finding | Disposition |
|---|---|---|
| 1 | Header slot doesn't exist | **Resolved.** New row above `rightPaneStrip`, approved by Brian (scope 1). |
| 2 | First-match table impossible | **Resolved.** Domain status separate from flags; drafts excluded from Ready; head-SHA rule for merged/closed (steps 4, 9). |
| 3 | `gh pr view` identity ambiguous | **Resolved.** `gh pr list --head` with `headRefOid`, same-repo only, explicit selection; forks out of scope (D14). |
| 4 | D3 false; send rejects mid-turn | **Resolved.** `enqueueUserMessage` contract. |
| 5 | Refresh ownership and process runner | **Resolved.** Ownership section (one restartable poll after the simplicity gate); `RepoCommandClient` with cwd and timeout. |
| 6 | Ready isn't merge readiness | **Resolved.** `mergeStateStatus`, `reviewDecision`; UNKNOWN never Ready; Waiting state approved (D12). |
| 7 | Target rule | **Resolved.** PR base, else the repo's default branch; `develop` preference removed. |
| 8 | Unpushed from wrong source | **Resolved.** Compared with `headRefOid`; behind/diverged → Waiting "out of sync". |
| 9 | Merged/closed hide new work | **Resolved.** Head-and-clean rule; Continue only from that state. |
| 10 | Merge repo and race risks | **Resolved.** Merge by URL with `--match-head-commit` (the separate re-read was cut in the simplicity gate); base repo is origin (no forks); merge queues a non-goal. |
| 11 | Agent action ownership | **Resolved.** Capture at click; disabled while the workspace's chat is working (D15). |
| 12 | Attachment and chip contracts | **Resolved.** Marker grammar, write-failure-means-no-send, open-failure alert, clients. Retention: **accepted** — files are small; cleanup is a non-goal. |
| 13 | Fix-errors run IDs | **Resolved.** `__typename` decoding, Actions URL parsing, `--repo`, dedupe. |
| 14 | Error model | **Resolved.** `PRBarFailure`, per-operation titles, persistence rule. |
| 15 | Cut Create draft PR | **Resolved.** Cut, approved by Brian (D7). |
| 16 | Models: none is false | **Resolved.** [`models.md`](models.md). |
| 17 | 30 s polling constraints | **Accepted with constraints:** cached login env, one restartable poll, timeouts, last good state, local target refs stated (step 6). |
| 18 | Acceptance criteria | **Resolved.** Acceptance criteria below. Accessibility (VoiceOver labels) is included; full-screen/resizing is a manual check. |

Zero blocking findings remain.

## Simplicity gate (Codex `gpt-6-astra` + Opus subagent, 2026-11-11)

Both reviewers read the plan against the real code. No cut reverses D6, D7, D11, D12 or an
Approvals row.

| Finding | Source | Disposition |
|---|---|---|
| Per-tab turn-end observer registry | both | **Adopted.** Derived from `hasWorkingTab(in:)` and `pollKey` (D15). |
| `enqueueUserMessage` as a third send path | both | **Adopted.** One private write path shared with `send()`; capture the tab, not its ID. |
| `status` stored next to `snapshot` | both | **Adopted.** `status` is computed; `PRStatus` cases carry no PR payload. |
| Generation counter, single flight, check-again | Opus | **Adopted.** One restartable `.task(id: pollKey)` loop, like the session poll. Also fixes B's first check queueing behind A's. |
| New process runner, SIGTERM grace, cancellation kill | Opus | **Adopted.** Extend `captureOutputBlocking`'s loop (cwd, second pipe). Superseded reads end at their timeout. |
| New login-environment cache | both | **Adopted.** Generalize `AgentEnvironmentCache`; don't use `resolve()` (needs `claude`). |
| Pre-merge re-read | Opus | **Adopted.** `--match-head-commit` already refuses a moved head. |
| `PRCommands` + three shortcut methods + `canRun` | Opus | **Adopted.** `.keyboardShortcut` on the bar button. |
| 0.5 s Checking timer | Opus (Codex: keep) | **Adopted.** Real checks almost always exceed it; D8 revised. Claude's call. |
| `PRBarFailure` operation and detail enums | Opus | **Adopted.** Title + details strings, like `workspaceFailed`. |
| `prChipTapped()` via `openURL` | Opus | **Adopted.** `Link` to a model URL. |
| Continue name probes per candidate | Opus | **Adopted.** One `for-each-ref` + one `ls-remote`, pure picker in Core. |
| `nameWithOwner`, `PRStatusReader`, configurable tail, `PRStatusIcon` enum | Codex | **Adopted.** Dropped / private helper / fixed 300 / concrete icon value. |
| Duplicate and repetitive tests | both | **Adopted.** Parameterized tables; one history chip test; ownership tests merged into "a cancelled poll never publishes". |
| Fix errors lets the agent fetch logs | Opus | **Rejected.** Attaching the logs is Conductor parity, which Brian asked for. |
| Continue through the agent | Opus | **Rejected.** Direct Continue is in the approved state table (scope 4). |
| Archive rendered by the parent | Opus | **Rejected.** `onArchive` is one closure; splitting the row across two models is worse. |
| One timeout value | Opus | **Rejected.** `gh run view` needs 60 s; reads should fail in 20 s. |

## Acceptance criteria

Model tests (Swift Testing, fake `RepoCommandClient`, `TestClock`) unless marked manual.

**Ownership**
- A cancelled poll never publishes: A→B→A with a slow first read, a workspace archived
  mid-check, and a read that finishes while Merge is in flight ("Merging…" stays).
- `pollKey` changes on selection, app activity, ⌘R, an operation starting or finishing, and a
  chat turn starting or ending in the workspace.
- Polling waits 30 s after a check finishes; it doesn't read while the app is inactive, and
  activation reads once.
- A command that times out shows Details with "timed out after 20 s".
- Checking shows only before the selected folder's first result; later checks keep the last
  state.

**Identity and status**
- No PR (empty list) vs a `gh` auth/network failure (non-zero exit) → No-PR state vs Couldn't
  check.
- Not a repo, detached HEAD, no origin, fork origin → empty row, no error.
- A cross-repository PR with the same branch name is ignored.
- Two open PRs → the higher number wins.
- Merged PR whose head equals HEAD and clean → Merged; HEAD moved or dirty → No-PR state.
- Closed PR, same rule → Closed / No-PR.
- Open PR: dirty → Commit and push; local ahead → Commit and push; behind or diverged → Waiting
  "out of sync".
- Each Waiting reason from its `mergeable`/`mergeStateStatus`/`reviewDecision` input; `UNKNOWN`
  never shows Merge.
- Draft with passing checks → Draft; draft with failing checks → Checks failed.
- Zero checks and `CLEAN` → Ready.
- Check decoding for CheckRun and StatusContext; `CANCELLED` and unknown conclusions don't count
  as failed; "N of M" counts.
- Target is the PR base, else the default branch.

**Agent buttons**
- Idle tab: message sent, turn started, draft untouched.
- Mid-turn tab: message written immediately and projected, draft untouched.
- Write failure: projected message removed, failure in Details.
- Attachment write failure: nothing sent.
- Captured tab closed before sending: nothing sent, Details says so.
- Agent buttons are disabled while an operation is in flight or any chat tab in the workspace is
  working (D15).
- PR instructions filled from click-time git facts (each upstream variant).
- Fix errors: run IDs parsed from Actions job and run URLs, deduped, `--repo` passed, 300-line
  tail, non-Actions checks listed by name and link, log fetch failure embedded.

**Chip**
- Marker parsed at the end of text; percent-decoded path; malformed, mid-text or relative markers
  render as plain text.
- A message with a marker reloaded from history (prompt line and `queued_command`) shows the chip.
- Chip click opens the file; a missing file shows the alert.

**Merge and Continue**
- Merge passes the URL, method flag and `--match-head-commit`; a failed merge shows "Merge
  failed" in Details.
- Continue picks the next free `-N` name against local and remote branches; fetch or switch
  failure shows in Details; success refreshes.
- Archive shown only when archivable.

**Shortcuts**
- Manual: ⌘⇧P / ⌘⇧X / ⌘⇧M fire only while their button is shown and enabled (they are attached
  to the button).

**Toolbar layout (D16)**
- The pill shows everything when the full layout fits; drops the detail when only that fits;
  shows icon-only buttons otherwise, including before anything is measured. Exact boundaries
  count as fitting.
- The section stays shown while the right panel is hidden.
- Open In ends 12pt left of the divider, or 12pt left of the pill when the pill reaches further
  left or the right panel is hidden, but never left of where it sat when centred.

**Manual**
- At several window widths and in full screen, the breadcrumb and Open In never go into the
  "»" overflow menu, Open In follows the divider as it is dragged, and the pill collapses detail
  first, then titles. Check the 12pt margin on macOS 15 too (the trailing chrome was measured on
  macOS 26).
- VoiceOver reads the status and button labels.

## Approvals

| Date | What | Covers |
|---|---|---|
| 2026-11-11 | Scope and state table: "looks great — let's do it." | The state table in screens.md as first drafted |
| 2026-11-11 | Chip, open-on-click, open-a-chat-if-none, fill-in-at-click: "Yes on all 3" | Scope items 3, 5, 6 |
| 2026-11-11 | Full feature here, not just Create PR: "Why not just do it all here?" | Scope |
| 2026-11-11 | Screens A and B mockups: "PERFECT I fucking love it all let's do it." | Pen zone `o1YFJQ` (frames `g4p4Cf`, `N9K28`) as exported then |
| 2026-11-11 | After the Codex review: row above the tabs, cut Create draft PR, add Waiting: "ok love it." | Scope 1, D7, D12; frames `uhPcs` (Draft) and `dGTED` (Waiting); Create PR without chevron |
| 2026-11-12 | Move the PR status out of the right column into the window toolbar, Open In centred on the whole window | Scope 1, D16, screen C |
| 2026-11-12 | Open In just left of the right panel's divider, or of the pill, after seeing it running: "that's it looks good!" | Scope 1, D17, screen C |

## Design deliverables

- **Screens:** [`screens.md`](screens.md)
- **Endpoints:** none — no daemon or HTTP API change. Status comes from local `git` and `gh`.
- **Models:** [`models.md`](models.md) — in-memory only; nothing is persisted.
