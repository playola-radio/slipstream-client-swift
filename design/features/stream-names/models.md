# Stream names — Model changes

The daemon has no database. Its "models" are files in the store. The client's are Swift value
types. Both are listed here.

| Change | Model | Where | Summary |
|---|---|---|---|
| New | Session name file | daemon `<store>/sessions/<id>/name.json` | Stores the agent's name and your name for one stream |
| Changed | Session directory inventory | daemon `src/maintenance.ts` `HISTORY_FILES` | Deleting a stream also removes `name.json` |
| Changed | `SessionSummary` | client `Sources/SlipstreamCore/DaemonTransport.swift` | Decodes `naming` from `GET /v1/sessions` |
| New | `SessionNaming` | client `Sources/SlipstreamCore/DaemonTransport.swift` | The two stored names |
| Changed | `SessionOption` | client `SlipstreamViewer/Models/FeedContent.swift` | Carries `naming` so the picker and the rename sheet can read it |

## Session name file (`sessions/<id>/name.json`): New

```json
{ "version": 1, "agent_name": "Invoice totals refactor", "user_name": "Billing cleanup" }
```

| Field | Type | Null | Default | Notes |
|---|---|---|---|---|
| `version` | integer, exactly `1` | no | | Any other value is a storage error |
| `agent_name` | string, valid name | yes | `null` | Written only by `attach` with a name. Read by `GET /v1/sessions`, `rename_session` (to keep it) |
| `user_name` | string, valid name | yes | `null` | Written or cleared only by `rename_session`. Read by `GET /v1/sessions`, `attach` (to keep it) |

- **Valid name:** checked in this order, with the reason reported by the first failure:
  1. It is a string.
  2. It is well-formed UTF-16: no unpaired surrogates (JS `isWellFormed`).
  3. It contains none of U+0000–U+001F, U+007F–U+009F, U+2028 or U+2029. This is checked
     before trimming, so tabs and line breaks are rejected rather than trimmed.
  4. Trim with ECMAScript `String.prototype.trim`, matching the contract's existing title
     rule (`contract.md:75`). After step 3, the only code points it can remove are U+0020,
     U+00A0, U+1680, U+2000–U+200A, U+202F, U+205F, U+3000 and U+FEFF. The Swift mirror
     rejects step 3's code points first and then reuses the app's existing
     `QuestionRequest.trim`; the extra code points in its set were already rejected, so it
     removes exactly this list.
  5. It is not empty.
  6. It is at most 64 UTF-8 bytes.

  There is no Unicode normalization. The stored value is the trimmed string. One daemon
  function does this, used by both writers and by the CLI. The 2–5 word guidance is advice for
  agents, not a rule.
- **Missing file:** both names are `null`. That is the state of every stream created before
  this feature, and of new streams attached without `--name`. No backfill.
- **Malformed file:** any of these counts as malformed:
  - unparseable JSON
  - a `version` other than `1`
  - a missing `agent_name` or `user_name` key
  - a value that is neither `null` nor a valid name, as above (the stored string must
    already be trimmed)

  A malformed file is a storage error, never "unnamed".
  - `GET /v1/sessions` fails with the reader's existing `500`.
  - `rename_session` and a named `attach` fail with `STORAGE_UNAVAILABLE`.
  - Crash-safe publishing makes this state very unlikely to arise.
- **Write:** every write is a full read-modify-write of both fields.
  - It is published with the same crash-safe pattern as `removed.json` (`publishTombstone`,
    `src/maintenance.ts:49-79`): a unique temp file opened with `wx` and mode 0600, a full
    write, fsync, an atomic rename over `name.json`, then fsync of the session directory.
  - The temp file is created inside the existing session directory. A write never creates
    the directory, so it cannot bring back a missing session.
  - If both names end up `null`, the file is still written with `null`s. No delete path is
    needed.
- **Serialization:** one in-process metadata lock, a promise chain in the daemon, is taken by:
  - `rename_session`'s read-modify-write
  - `attach`'s name write

  Operations run in the order they acquire the lock, so a user rename and an agent attach
  preserve each other's field. The lock is separate from `runMaintenance`, which refuses work
  while a capture is active. Renaming the recording stream has to work.

  `delete_session` and `gc` do not take the lock. A rename that races a delete can leave a
  `name.json` in a tombstoned session directory. That is harmless: the list reports null names
  for a removed stream without reading the file (`EMPTY_NAMING`), and `gc` re-runs
  `removeSessionHistory`, which unlinks `name.json`.
- **Lock lifetime:**
  - Teardown awaits the lock's chain tail, which settles only after every admitted operation,
    after it has drained attach and maintenance (`src/daemon.ts:262-285`). Shutdown drains
    admitted name writes by construction.
  - Once teardown starts, a queued operation finds the daemon closed and replies
    `STORAGE_UNAVAILABLE` without writing.
  - When an operation reaches the front of the lock, it re-checks store ownership and daemon
    state, and only then publishes.
  - Teardown finishes this wait before it releases the store lock.
  - A failed operation releases the lock without breaking the chain for later operations.
- **Readers:** only the HTTP session list reads `name.json`, by adding names to its items
  after `listSessions`. `listSessions`, which gc and blob reclamation use, does not read
  names. A malformed file therefore cannot block gc.
- **Not a log record:** resume picks the workspace's session by the time of its last event
  (`src/store-reader.ts:168-204`). Writing a name as an event would change which session
  resumes. Names also don't belong in the change history.
- **Source of truth:** this file is the only store of names. The fallback label (folder ·
  start time) is derived by the client from `session.started` and never stored.
- **Migration:** none. The file is created on first write.
- **Deploy compatibility:**
  - A newer store opened by an older daemon: the old daemon ignores `name.json`, and its
    delete leaves the file behind. It sits in a tombstoned directory, which the list reports
    as removed with no names, so nothing reads it.
  - An older store opened by a newer daemon: no file, so no names.

## Session directory inventory (`HISTORY_FILES`): Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `HISTORY_FILES` | `readonly string[]` | `['events.jsonl']` → `['events.jsonl', 'name.json']` | `removeSessionHistory` unlinks each, ignoring `ENOENT`. Used by `delete_session` and by `gc` when it finishes an interrupted delete |

- `removed.json`, `owner.lock` and the session directory itself are still kept.

## `SessionSummary` (client): Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `naming` | `SessionNaming?` | Added | Decoded from the item's `naming` key. `nil` when the key is absent, which means a daemon without `workspace-names-v1`: rename is disabled and labels use the fallback |

- The decoder has a hand-written `init(from:)`. It does not use synthesized optional
  decoding, because that can't tell an absent key from `null`.
  - An absent `naming` key decodes as `nil`.
  - A present `naming` must be an object that has both the `agent_name` and `user_name`
    keys, each a string or `null`.
  - `naming: null`, a missing inner key, or a wrong type fails the decode of the list, in
    the same way as other malformed required fields.
- The client does not re-validate name strings it receives. The daemon is the authority.

## `SessionNaming` (client): New

| Field | Type | Null | Notes |
|---|---|---|---|
| `agentName` | `String?` | yes | Wire `agent_name` |
| `userName` | `String?` | yes | Wire `user_name` |

- `Equatable`, `Sendable`, `Decodable`. It has no logic.
- The effective name is `userName ?? agentName`. Label building in `ChangeStreamPageModel`
  owns it.

## `SessionOption` (client): Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `naming` | `SessionNaming?` | Added | Copied from `SessionSummary`. Read by the rename sheet to open the field with the current name and to decide whether to show "Use agent's name" |
| `label` | `String` | Changed meaning | The effective name, or the fallback `<folder> · started MMM d HH:mm`, with the collision rule in [screens.md](./screens.md#stream-picker). Previously `<root> · started MMM d HH:mm:ss` |

- `sessionLabels(_:)` (`ChangeStreamPageModel.swift:840-855`) takes the session options (which
  carry `naming`) along with the `SessionStarted` map. The folder is the last path component of `SessionStarted.root`.
- It labels every listed session, not only those whose start record loaded:
  - A named session keeps its name even when its start record failed to load.
  - An unnamed session whose start record failed to load is labelled by its id.
- Order of disambiguation:
  1. Duplicate names get ` · started MMM d HH:mm` appended. A fallback label already
     contains its start time, so it never gets a second one.
  2. A final pass over all resulting labels appends ` · <id>` to any that still collide.
     That covers the case where a name matches another stream's fallback label.
