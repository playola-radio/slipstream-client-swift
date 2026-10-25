# Terminals — Endpoint changes

There is no HTTP or socket change: the daemon's API is untouched. The one contract that changes
is the output of the `slipstream workspace create` command (daemon repo `playola-radio/slipstream`
@ `feffc30`), which the app now runs in a terminal and reads as it streams.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| Changed | CLI | `slipstream workspace create <repo> --store <id>` | local user (no token) | Print the workspace path as soon as the folder exists, before the setup script runs |

## CLI slipstream workspace create <repo> --store <id>
- **Change:** Changed (output only)
- **Auth:** none; runs as the user. The app launches the absolute `slipstream` path found on the
  login `PATH`, in a pty, with the login environment (spec, Architecture → Environment).
- **Arguments:** unchanged — `<repo>` (any folder inside a git repository), `--store <id>`.
- **Request body:** none
- **Output delta** (`src/workspace.ts` `runWorkspaceCreate`):
  - **Added:** right after the record attempt (step 5 in spec "Existing contracts") and before
    `runRepoScript('setup', …)`, it prints `workspace_path: <path>` on its own line. It is
    printed whether or not recording succeeded, matching the final line's rule ("printed whenever
    the folder was made").
  - **Kept:** after setup it still prints an empty line, then `workspace_path: <path>`, as the
    last line. Exit status is unchanged: 0 only if recording and setup both succeeded.
  - **Unchanged:** failures before the worktree exists print `slipstream: …` to stderr and no
    `workspace_path:` line at all.
- **Output `0` (setup ran):**
  ```text
  created /Users/brian/slipstream/workspaces/playola/workspace-3 on slipstream/workspace-3 from origin/develop

  workspace_path: /Users/brian/slipstream/workspaces/playola/workspace-3
  …setup script output (inherited stdout/stderr)…

  workspace_path: /Users/brian/slipstream/workspaces/playola/workspace-3
  ```
  The early line is preceded by an empty line too, so it is easy to spot in the scrollback; the
  mockups show it that way.
- **Errors:**

  | Exit | When | `workspace_path:` lines |
  |---|---|---|
  | 1 | Not a git repo, no `origin`, fetch failed, no base branch, `worktree add` failed | none |
  | 1 | Recording failed or the setup script failed | both (early and final) |

- **Compatibility:**
  - The app acts on the **first** `workspace_path:` line it sees whose path is absolute and,
    normalized, names a folder exactly two levels below the managed workspaces root that exists
    (spec R-11, R-22, S-3). Later lines are ignored, and output replayed from history is never read. With an
    older CLI that prints only the final line, the app switches when setup ends. A setup script
    that prints its own `workspace_path:` line for a folder that isn't a managed workspace is
    ignored by the folder check.
  - `WorkspaceClient.outcome(output:status:)` is replaced by `failureText(output:status:)`,
    used by `archive` only. Archive output has no `workspace_path:` line, so the path reading
    goes (spec S-4).
  - The daemon's own tests (`src/workspace.test.ts:83` asserts the last two lines;
    `src/workspace.os.test.ts:51` asserts the last line) still pass; the change adds a test that
    the early line comes after `record` and before the setup script runs, and none on the
    pre-worktree failure paths (`:119`, `:130` already assert that).
  - README "Workspaces without Conductor" gains one sentence: the path is also printed before
    setup runs.
  - Ordering: in a pty, Node's `console.log` to a TTY is synchronous, so the early line reaches
    the terminal before the setup script's first byte.
- **Input:** the setup script still gets no stdin (`cli.ts:723-727`), even in a pty, so setup
  prompts can't be answered from the tab.
- **Consumers:** the Terminals pane's Setup tab (screens.md, states Setup running / finished /
  failed). People running the command by hand see one extra line.
