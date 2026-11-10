# Workspace names — Model changes

The daemon has no database. Its "models" are files in the store. The client's are Swift value
types. Both are listed here. Storage and validation carry over from
[stream-names](../stream-names/models.md); the writers are new.

| Change | Model | Where | Summary |
|---|---|---|---|
| New | Session name file | daemon `<store>/sessions/<id>/name.json` | Stores the agent's name and your name for one session |
| Changed | Session directory inventory | daemon `src/maintenance.ts` `HISTORY_FILES` | Deleting a session also removes `name.json` |
| Changed | `SessionSummary` | client `Sources/SlipstreamCore/DaemonTransport.swift` | Decodes `naming` from `GET /v1/sessions` |
| New | `SessionNaming` | client `Sources/SlipstreamCore/DaemonTransport.swift` | The two stored names |
| Changed | `SessionOption` | client `SlipstreamViewer/Models/FeedContent.swift` | Carries `naming` for labels, the row menu and the rename dialog |

## Session name file (`sessions/<id>/name.json`) — New

```json
{ "version": 1, "agent_name": "Workspace rename menu", "user_name": null }
```

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `version` | integer, exactly `1` | no | | Any other value is a storage error |
| `agent_name` | string, valid name | yes | `null` | Written only by `name_workspace`. Read by `GET /v1/sessions`, by `name_workspace` (set-if-absent) and by `rename_session` (to keep it) |
| `user_name` | string, valid name | yes | `null` | Written or cleared only by `rename_session`. Read by `GET /v1/sessions` and by `name_workspace` (to keep it) |

- **Valid name.** Checked in this order; the first failure is the reason reported:
  1. It is a string.
  2. It is well-formed UTF-16: no unpaired surrogates (JS `isWellFormed`).
  3. It contains none of U+0000–U+001F, U+007F–U+009F, U+2028 or U+2029. Checked before
     trimming, so tabs and line breaks are rejected rather than trimmed.
  4. Trim with ECMAScript `String.prototype.trim`.
  5. It is not empty.
  6. It is at most 64 UTF-8 bytes.

  No Unicode normalization. The stored value is the trimmed string. One daemon function does
  this for both writers, tested against an inline case table. The app checks only what drives
  the dialog's live states (empty, too long, line breaks or control characters); the daemon
  stays the authority, and its `INVALID_NAME` message covers anything the app's checks miss.
  The 2–5 word target is tool-description guidance, not a rule.
- **Missing file:** both names are `null`. That is every session created before this feature
  and every session the agent hasn't named yet. No backfill.
- **Malformed file** (unparseable JSON, `version` ≠ 1, a missing key, or a value that is neither
  `null` nor a string). Names aren't re-validated on read; the daemon is the only writer. Names are display-only, so one bad file
  must not take down the session list:
  - `GET /v1/sessions` reports both names `null` for that session and logs one daemon
    warning naming the session and the reason. Other sessions are unaffected.
  - The next write to that session treats the malformed file as two `null`s and replaces it,
    logging that it did. That is the repair path; event history is never touched.
  - Crash-safe publishing makes this state very unlikely to arise.
- **Write:** a full read-modify-write of both fields, published like `removed.json`
  (`publishTombstone`, `src/maintenance.ts:55`): a unique temp file opened `wx` mode 0600 in
  the existing session directory, full write, fsync, atomic rename over `name.json`, fsync of
  the directory. A write never creates the directory. A file with two `null`s is still
  written; there is no delete path.
- **Serialization:** one daemon-wide in-process metadata lock (a promise chain) is taken by
  `name_workspace` and `rename_session`. Operations run in lock order, so an agent name and a
  user rename never lose each other's field. The same lock is the authority fence: a
  teardown, activation-loss or store-lock-loss transition waits for the active holder before
  revoking authority, and rejects queued work. Thus an admitted writer either commits while
  authority is still held or observes revocation before submitting its atomic rename. The lock
  is separate from `runMaintenance`, so renaming the recording session works.
  `delete_session` and `gc` don't take it; a write that races a delete can leave `name.json`
  in a tombstoned directory, which is harmless — the list reports `null` names for a removed
  session without reading the file, and `gc`'s `removeSessionHistory` unlinks it.
- **Lock lifetime:** authority revocation is queued through the lock before teardown drains
  its tail and releases the store lock. A queued operation that runs after revocation starts
  replies `STORAGE_UNAVAILABLE` without writing. Each writer checks its authority immediately
  before the atomic rename (see [endpoints.md](./endpoints.md)); the fence keeps that check
  effective through rename submission. `name_workspace` is also registered in the capture's
  in-flight set so unlink and maintenance drain it. A failed operation removes its temp file
  and releases the lock without breaking the chain.
- **Readers:** only the HTTP session list reads `name.json`, adding names after
  `listSessions`. `listSessions` (used by gc and blob reclamation) does not, so a malformed
  file can't block gc.
- **Not a log record:** resume picks a workspace's session by its last event time
  (`src/store-reader.ts`). A name written as an event would change which session resumes.
- **Source of truth:** this file is the only store of names. The folder-name fallback is
  derived by the client from the session's root and never stored.
- **Migration:** none; the file is created on first write.
- **Deploy compatibility:** an older daemon ignores `name.json`, and its delete leaves the file
  in a tombstoned directory that nothing reads. A newer daemon on an older store finds no
  files, so no names.

## Session directory inventory (`HISTORY_FILES`) — Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `HISTORY_FILES` | `readonly string[]` | `['events.jsonl']` → `['events.jsonl', 'name.json']` | `removeSessionHistory` unlinks each, ignoring `ENOENT`. Used by `delete_session` and by `gc` |

## `SessionSummary` (client) — Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `naming` | `SessionNaming?` | Added | Decoded from the item's `naming` key. `nil` when the key is absent (an older daemon) or malformed: labels use the folder name and Rename is disabled |

- The hand-written `init(from:)` decodes it as `try? container.decodeIfPresent(SessionNaming.self,
  forKey: .naming)`, as it already does for `agentConnection`. A malformed `naming` never fails
  the list: losing a label beats losing the list.
- The client does not re-validate received names.

## `SessionNaming` (client) — New

| Field | Type | Null | Notes |
|---|---|---|---|
| `agentName` | `String?` | yes | Wire `agent_name` |
| `userName` | `String?` | yes | Wire `user_name` |

- `Equatable`, `Sendable`, synthesized `Decodable` with snake-case `CodingKeys`. No other logic.

## `SessionOption` (client) — Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `naming` | `SessionNaming?` | Added | Copied from `SessionSummary`. `nil` for capture-only rows (`hasHistory == false`) and for older daemons |

- `SidebarGroup.rowName(_:)` becomes `naming?.userName ?? naming?.agentName ?? <folder>`, with
  the folder being today's value (last path component of `root`, else `label`). Every label
  surface in [spec.md](./spec.md#label-surfaces) goes through it.
- Rename is enabled when `hasHistory && naming != nil`; its disabled tooltip is "Can be named
  once work starts here." for `!hasHistory` and "This version of the Slipstream daemon can't
  rename workspaces." for `naming == nil`. "Use agent's name" is enabled when
  `naming?.userName != nil`.
