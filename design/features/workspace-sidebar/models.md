# Workspace sidebar — Model changes

Client only. The daemon's data (`~/.slipstream`, sessions, captures) doesn't change, and neither
does `chatTabs.json`. The sidebar is derived from data the app already loads. The only new stored
value is whether the sidebar is hidden.

| Change | Model | Storage | Summary |
|---|---|---|---|
| New | `isSidebarHidden` | `UserDefaults` via `@Shared(.isSidebarHidden)` | Whether the sidebar is hidden; remembered across launches |

## isSidebarHidden (`UserDefaults` key `isSidebarHidden`) — New

```swift
extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var isSidebarHidden: Self {
    Self[.appStorage("isSidebarHidden"), default: false]
  }
}
```

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `isSidebarHidden` | `Bool` | no | `false` | Read by the window to show or hide the sidebar column. Written by the toolbar sidebar button (spec Decision 6) |

- **Indexes / constraints:** none
- **Associations:** none
- **Enums:** none
- **Source of truth:** this key is the only record of the setting. It follows the
  `.fontSizeStep` pattern (`Models/FontSize.swift`).
- **Migration:** new key. A missing key means the sidebar shows, which is the default the spec
  approved.
- **Deploy compatibility:** older builds ignore the key.

## Derived, not stored

These are computed from data the app already holds. None of them is persisted.

| Value | Derived from | Notes |
|---|---|---|
| A row's repo group | the session's normalized `root` | `<repo>` when the root is exactly `<repo>/<name>` under the managed root or `$HOME/conductor/workspaces`, both from `WorkspaceClient.roots` (component match, as `isArchiveWorkspaceShown` does today). Otherwise its own group. Same-name groups merge (spec Decision 3) |
| A row's name | the last component of `root`, or the session's `label` while `root` is nil | e.g. `workspace-3`, `belo-horizonte-v6` |
| Row is bold | `ChatPageModel.isWaiting(folder:)` | Unchanged persisted `ChatTabRecord.isWaiting` |
| Row spinner | `ChatPageModel.hasWorkingTab(in:)` | In-memory turn state |
| Row has archive icon | today's `isArchiveWorkspaceShown` rule, applied to that row's root | Only folders exactly `<repo>/<name>` under the managed root |
| Which rows show | today's `pickerSessions` with inactive sessions hidden: every session except inactive ones that aren't selected | One row per session, as the picker lists today. Replaces the inactive toggle |

Rows, groups and names are computed from in-memory paths: the two workspace roots are normalized
once when they load, so rendering never touches the filesystem. Bold and spinner are read per row from `ChatPageModel`; each scans the chat records, which is cheap at a
handful of workspaces.

## In-memory page state (not persisted)

Owned by `ChangeStreamPageModel`. The page model already owns selection.

| Value | Type | Notes |
|---|---|---|
| Right-side segment | `.stream` / `.terminals` | Starts on `.stream` every launch. Replaces `isFeedHidden` |
| Archive target | the `SessionOption` of the row whose archive icon was clicked | Set by the icon; read by the confirmation and `archiveConfirmed()`. Replaces reading `selectedFolder` |
