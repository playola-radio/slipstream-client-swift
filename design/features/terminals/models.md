# Terminals — Model changes

Client-only. The daemon's data (`~/.slipstream`, sessions, events) doesn't change. Everything
here lives in the app's `Application Support/<bundle id>/` folder, beside `chatTabs.json`.

| Change | Model | Storage | Summary |
|---|---|---|---|
| New | `TerminalState` | `terminals.json` via `@Shared(.terminalState)` | Every terminal tab, plus each workspace's selected tab |
| New | `TerminalTabRecord` | inside `TerminalState.tabs` | One Setup or terminal tab |
| New | `SetupStatus` (enum) | inside `TerminalTabRecord.kind` | How a Setup tab's command is going or ended |
| New | Tab history log | `terminals/<tab id>.log` | The raw output of one tab, for replay after relaunch |

## TerminalState (`terminals.json`) — New

```swift
struct TerminalState: Codable, Equatable, Sendable {
  var tabs: IdentifiedArrayOf<TerminalTabRecord> = []
  var selectedTabIDs: [String: TerminalTabRecord.ID] = [:]
}
```

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `tabs` | `IdentifiedArrayOf<TerminalTabRecord>` | no | `[]` | Strip order within a folder is array order. Read by the pane's tab strip |
| `selectedTabIDs` | `[folder path: tab id]` | no | `[:]` | Each workspace's last selected tab (scope item 6). Read when a workspace is shown |

- **Indexes / constraints:**
  - Tab ids are unique (`IdentifiedArray`).
  - At most one Setup tab with `folder == nil` (scope item 3). Starting New Workspace replaces it.
  - A Setup tab whose `folder` is nil shows at the front of every workspace's strip, and alone
    in the pane when no workspace is selected (spec R-13). Its selection when no workspace is
    selected isn't stored; it's simply shown. Any other tab shows only in its own `folder`.
  - A `selectedTabIDs` value names a tab that is shown in that folder: one whose `folder` is that
    key, or the folderless Setup tab. Moving the Setup tab to its folder removes every other key
    pointing at it. A dangling id falls back to the workspace's own first tab, then the first tab
    in the strip, and it's never an error (spec R-29, decision log 2026-11-09).
  - "Always one terminal tab" (scope item 4) applies to a shown workspace that isn't being
    archived. No Terminal 1 is created during archive or quit.
- **Why one file:** moving the Setup tab to its workspace and selecting it there are one write,
  so a crash can't leave the tab moved but the selection pointing elsewhere (Codex consult).
  It follows the `chatTabs` pattern (`Models/ChatTabRecord.swift`): a `SharedKey` extension with
  `.fileStorage(...)` and `default: TerminalState()`.
- **Associations:** `TerminalTabRecord.folder` holds the same path string as
  `ChatTabRecord.folder` and the workspace list (the resolved worktree path), so filtering by the
  selected workspace's folder works the same way.
- **Migration:** new file. Missing means empty. A workspace shown with no terminal tab gets
  **Terminal 1** then (scope item 4), so existing workspaces need no backfill.
- **Deploy compatibility:** an older app build ignores `terminals.json` and the `terminals/`
  folder. If a workspace is archived from an older build, its records survive the upgrade back;
  those tabs show "This folder no longer exists" and close normally (spec R-30). Nothing is
  deleted just because the workspace list is unavailable.

## TerminalTabRecord — New

```swift
struct TerminalTabRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var folder: String?
  var kind: Kind

  enum Kind: Codable, Equatable, Sendable {
    case setup(SetupStatus)
    case terminal(number: Int)
  }
}
```

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `UUID` | no | `uuid()` dependency | Names the history log file, so moving a Setup tab moves nothing on disk |
| `folder` | `String` | yes | | The workspace folder. `nil` only for a Setup tab that hasn't seen a valid `workspace_path:` line. Every terminal tab has one |
| `kind` | `Kind` | no | | `.setup` or `.terminal(number:)`. The number gives the title "Terminal N" and survives other tabs closing; **+** uses the folder's highest open number + 1 |

- **Read by:** the pane's tab strip (title, status icon, ×), the Setup footer, the close check
  (a running Setup tab is busy), launch (marks a running Setup interrupted), archive.
- **Not stored:** whether a terminal is busy (asked of the live pty), the terminal's process
  ids, and the shell's environment. All are rebuilt each launch.
- **Deletion:** closing a tab removes its record and its log. A successful archive removes all the
  folder's records, logs and its `selectedTabIDs` entry. A failed archive keeps them.
- **Write order** (spec R-7): a new tab's record is saved, awaiting the `@Shared` save, before
  its process starts or its log is written. Closing stops the tab, deletes the log, then saves
  the record's removal, so a log never outlives its record (Brian, D1). Orderly quit awaits
  pending saves.

## SetupStatus — New (enum)

```swift
enum SetupStatus: Codable, Equatable, Sendable {
  case running
  case finished(seconds: Int)
  case failed(exitStatus: Int32?)
  case interrupted
}
```

| Case | Set when | Shows (screens.md) |
|---|---|---|
| `running` | The Setup tab opens | Spinner, "Setting up <workspace>…" (or "Setting up…" before the folder is known) |
| `finished(seconds:)` | The command exits 0 | Check, "Setup finished · <seconds>s" |
| `failed(exitStatus:)` | The command exits non-zero, or it couldn't be started (`nil`: `slipstream` not found, the login environment failed; the reason is written into the tab's log as text) | Alert. "…exit N. The workspace was created." when `folder != nil`; "…no workspace was created. Close this tab to dismiss." when `folder == nil` |
| `interrupted` | Launch finds a tab still `running`: the app quit during setup | Alert, "Setup was interrupted" |

- No start time is stored (spec R-28): the live session times the run with the continuous
  clock and stores only the final `seconds`. Every `running` found at launch becomes
  `interrupted`.
- Whether a workspace was created isn't stored. For `finished` and `failed` it's
  `folder != nil`, because the CLI prints the path right after the folder is made and recorded.
  For `interrupted` a nil folder means the path is unknown, and the footer makes no claim
  (spec R-12).
- The final status is saved only after the tab's last output is flushed to its log (spec R-3).

## Tab history log (`terminals/<tab id>.log`) — New

| Property | Value |
|---|---|
| Location | `Application Support/<bundle id>/terminals/<TerminalTabRecord.id>.log` |
| Content | The exact bytes the pty sent, ANSI codes included, in order |
| Cap | When the file reaches 5,000 lines or 4 MiB, it's rewritten to at most its last 4,000 lines and 3 MiB; a single line longer than that keeps only its end. The check runs on append, so an oversized log is compacted by its first append after launch (spec R-5, S-8) |
| Written by | One serial writer per tab, off the main actor, before the bytes reach the view. It also owns compaction, reopening and deletion. A write error stops saving for that tab; the terminal keeps running |
| Read by | Replay at launch, before the tab's new shell starts, with input off; then the terminal leaves the alternate screen and resets its modes without clearing scrollback, and the "Restored" divider is drawn. Replay is never read for `workspace_path:` lines |

- **Source of truth:** the log is the only copy of a tab's past output; nothing else stores it.
  The record is authoritative for whether the tab exists. A record with no log replays nothing,
  which is what a crash mid-close leaves. Launch never deletes logs.
- **Data at risk:** history is lost on purpose when a tab closes or its workspace is archived.
  The cap drops the oldest lines. A cap rewrite that crashes midway must not leave a half file:
  write to a temporary file and replace it (implementation plan).
- **Privacy:** the log holds whatever the terminal showed, which can include secrets a script
  printed. It stays in the user's own Application Support folder, the same as the daemon's
  stored events. Nothing is uploaded. The app never writes the daemon bearer token to a terminal
  or a log.
