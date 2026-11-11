# Commit chapters — Model changes

The daemon has no database. Its models here are two new event types in the session log
(`events.jsonl`), each with a self-contained JSON schema in `schemas/`, plus in-memory reader
state. The client's models are Swift value types. Nothing is backfilled: sessions recorded before
this feature have no chapters.

| Change | Model | Where | Summary |
|---|---|---|---|
| New | `slipstream.git.chapters.v1` | daemon `src/public-events.ts`, `schemas/` | Whether chapter detection is running for this capture run, and why not |
| New | `slipstream.git.head_observed.v1` | daemon `src/public-events.ts`, `schemas/` | The worktree's HEAD moved: a commit, an amend, or another kind of move |
| New | Reflog reader state | daemon, in memory in the capture session | Where the reader is in the worktree's HEAD reflog |
| New | `HeadObserved`, `GitChapters` | client `Sources/SlipstreamCore/Events.swift` | Decoded payloads of the two new events |
| Changed | `EventPayload` | client `Sources/SlipstreamCore/Events.swift` | Adds `.headObserved`, `.gitChapters`; removes `.taskStarted` |
| Removed | `TaskStarted` | client `Sources/SlipstreamCore/Events.swift` | Nothing reads a task title once task headings are gone |
| Changed | `FeedSection` | client `SlipstreamViewer/Models/FeedContent.swift` | `heading: TaskHeading?` becomes `chapter: Chapter` |
| New | `Chapter` | client `SlipstreamViewer/Models/FeedContent.swift` | What a section's heading shows |
| Removed | `TaskHeading` | client `SlipstreamViewer/Models/FeedContent.swift` | Replaced by `Chapter` |

Both daemon events are registered the way `slipstream.capture.scope.v1` is: in
`PUBLIC_EVENT_TYPES` and `LIFECYCLE_TYPES` in `src/public-events.ts`, built by
`buildPublicEnvelope`'s lifecycle branch. They are **not** added to `EVENT_TYPES` in
`src/event.ts`, whose list feeds the frozen `display-fold.v1` contract. The envelope `subject` is
absent on both. Recovery validates both automatically: it checks every `PUBLIC_EVENT_TYPES`
entry against `loadAllSchemas()` (`src/recovery.ts`). Only `head_observed` carries
`data.observed_at_ms` (the producer passes the same instant as `occurred_at_ms`), because the
client displays it and doesn't decode the envelope `time`; `git.chapters` has only the envelope
`time`, like the other lifecycle events.

**Schema encoding.** The daemon's validator (`src/schema.ts`) supports `type`, `required`,
`properties`, `const`, `enum`, `pattern`, `minimum`, `minLength`, `maxLength`, `oneOf`, `items` and
`$ref`; it never enforces `additionalProperties` and has no `null` type. So optional fields are
**absent, never `null`**, and `kind` and `state` are plain strings in the schema, not
`enum`s: recovery must accept a log written by a newer daemon with a value this daemon doesn't
know (`src/recovery.ts` rejects recognized types that fail their schema). The daemon's own
producer types are closed unions; consumers map unknown values to a fallback.

## `slipstream.git.chapters.v1` — New

```json
{
  "specversion": "1.0",
  "id": "3",
  "source": "urn:slipstream:session:7c0e",
  "type": "slipstream.git.chapters.v1",
  "datacontenttype": "application/json",
  "seq": "3",
  "time": "2026-11-11T16:30:00.004Z",
  "data": {
    "session_id": "7c0e",
    "state": "unavailable",
    "detail": "this worktree's reflog is turned off (core.logAllRefUpdates=false and .git/logs/HEAD does not exist)"
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `session_id` | string | yes | |
| `state` | string: `active` \| `unavailable` | yes | Client: chapters on or off; unknown → off |
| `detail` | string, `minLength` 1 | when `unavailable` | One full sentence, including the underlying error text or config value. The client shows it verbatim after `No commit chapters — ` |

- **When:** once per activation of a git-policy capture (start, resume, and after storage
  recovery), when setup finishes: `active` if detection is running, else `unavailable`. Also
  `unavailable` mid-activation if detection stops (watch error, lost reflog continuity). Never for
  filesystem-policy captures.
- **Why unavailable, and the `detail` the daemon writes** (the daemon owns this copy; there is
  no machine-readable reason, since display is its only consumer):
  - Reflog turned off — `logs/HEAD` doesn't exist **and** `git config --bool
    core.logAllRefUpdates` prints `false`: `this worktree's reflog is turned off
    (core.logAllRefUpdates=false and <logPath> does not exist)`. (Git still appends to an
    existing log when the setting is false, so an existing log is `active`. A missing log with the
    setting unset or true is `active`: Git creates it on the first ref update.)
  - Unsupported ref format — `git rev-parse --show-ref-format` prints anything but `files` (e.g.
    `reftable`; if the command fails, Git is older than 2.45 and the format is `files`): `this
    repository's ref format isn't supported yet (<format>)`.
  - Reflog unreadable — reading failed for any reason other than the log not existing yet: `this
    worktree's reflog can't be read (<error text>)`; continuity lost (see reader state): `this
    worktree's reflog can't be read (the reflog was rewritten and its last seen entry is gone)`.
  - Watch failed — the metadata `Platform.watch` subscription failed to start or errored:
    `watching this worktree's reflog failed (<error text>)`.
- After `unavailable`, detection stays off until the next activation. File capture is unaffected.

## `slipstream.git.head_observed.v1` — New

```json
{
  "specversion": "1.0",
  "id": "412",
  "source": "urn:slipstream:session:7c0e",
  "type": "slipstream.git.head_observed.v1",
  "datacontenttype": "application/json",
  "seq": "412",
  "time": "2026-11-11T16:42:03.118Z",
  "data": {
    "session_id": "7c0e",
    "kind": "commit",
    "sha": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
    "subject": "Add retry to the upload client",
    "observed_at_ms": 1794501723118
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `session_id` | string | yes | |
| `kind` | string, see table | yes | Daemon's classification of the reflog record. Client: chapter vs divider and copy; unknown → `other` |
| `sha` | string, pattern `^([0-9a-f]{40}\|[0-9a-f]{64})$` | yes | HEAD after the move (the record's new value). Client shows the first 7 |
| `subject` | string, `minLength` 1 | no | Only on `commit`/`amend`, taken from the reflog message (rule below). Absent when empty. Client title |
| `target` | string, `minLength` 1 | no | Only on `checkout`: the text after `to ` in `moving from X to Y`, as Git wrote it. Descriptive only — it does not say whether HEAD is attached to a branch. Client divider copy |
| `observed_at_ms` | integer epoch ms | yes | When the daemon received the reflog notification. Display only, never ordering |

**`kind` classification.** The *action* is the reflog message up to the first `: `. Reflog
messages are a Git convention (and `GIT_REFLOG_ACTION` can override them), not a typed API; the
supported set is fixed by fixture tests recorded from real Git runs.

| Rule, first match wins | `kind` |
|---|---|
| action contains `rebase` and ends `(finish)` | `rebase` |
| action contains `rebase` and ends `(abort)` | `rebase_abort` |
| action contains `rebase` (any other step: start, pick, reset, merge, label, continue, …) | skipped |
| action is `commit (amend)` | `amend` |
| action is `commit`, `commit (initial)`, `commit (merge)`, `cherry-pick`, `revert` | `commit` |
| action starts `merge ` or `pull`, message contains `Fast-forward` | `fast_forward` |
| action starts `merge ` or `pull` | `commit` |
| action is `checkout` or `switch` | `checkout` |
| action is `reset` and old SHA = new SHA | skipped |
| action is `reset` | `reset` |
| anything else | `other` |

A rebase that ends without a `(finish)` or `(abort)` record (`--quit`, a crash) produces no
divider.

**`subject`.** Git writes the commit's subject into the reflog message after the action
(`commit (amend): Fix café`), so no `git log` runs. For `commit*`, `cherry-pick` and `revert`,
`subject` is the text after the first `: `. For a non-fast-forward `merge`/`pull`, whose message
is Git's merge strategy note rather than the commit subject, `subject` is the action with its
first letter capitalised (`merge feat` → `Merge feat`). Git collapses runs of whitespace in the
subject; that is accepted.

- **Source of truth:** the worktree's HEAD reflog is authoritative for what moved; this event is
  the daemon's observation of it. Its position in `seq` places the chapter boundary (spec D2). It
  is never rewritten if history is later rewritten.

## Reflog reader state — New (daemon, in memory only)

| Field | Type | Notes |
|---|---|---|
| `logPath` | string | `git rev-parse --path-format=absolute --git-path logs/HEAD`, resolved at activation |
| `identity` | `{dev, ino}` | From `fstat` of the open file at the last read |
| `offset` | integer bytes | Bytes consumed |
| `tail` | `Buffer` | Bytes after the last `\n`, held until complete (bytes, so a UTF-8 character can span reads) |
| `lastRecord` | `Buffer` | The last complete record consumed, for re-finding our place after a rewrite |

- **Baseline** (activation): `offset` = file size (0 if absent). Existing history makes no
  events. A partial line at the baseline is a fragment that doesn't parse, so the malformed-record
  rule below skips it.
- **Read** (at a barrier, see spec D2): open, `fstat`, read `[offset, extent)` from the same
  descriptor. Each complete record is parsed as `<old> <new> <ident> <tz>\t<message>`; a complete
  record that doesn't parse is skipped with a console warning.
- **Continuity:** if `identity` changed or the size is below `offset` (e.g. `git reflog expire`
  rewrote it), the reader searches the new file for `lastRecord` and continues after it. If it
  isn't there, the reader returns `{ lost }` with the rewritten sentence above; the session emits
  `git.chapters` `unavailable` with it and stops detection. A truncate-and-regrow in place to at
  least the old size is not detectable; that limitation is accepted.
- Not persisted. Each activation (start, resume) builds a new reader and re-baselines; commits
  made while stopped make no chapters. Storage recovery keeps the reader: barriers queued during
  the outage are read once capture is live again (spec D2).

## `HeadObserved`, `GitChapters` — New (client)

```swift
public struct HeadObserved: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case commit, amend, checkout, reset, fastForward, rebase, rebaseAbort, other
  }
  public var kind: Kind          // unknown strings decode as .other
  public var sha: String
  public var subject: String?
  public var target: String?
  public var observedAtMs: Int64
}

public enum GitChapters: Equatable, Sendable {
  case active
  case unavailable(detail: String)   // unknown state strings decode as unavailable; absent detail → ""
}
```

A known event type missing a required field still fails decoding, as every other type does.

## `EventPayload` — Changed (client)

| Case | Change | Notes |
|---|---|---|
| `.headObserved(HeadObserved)` | Added | |
| `.gitChapters(GitChapters)` | Added | |
| `.taskStarted(TaskStarted)` | Removed | `slipstream.task.started.v1` joins `rowlessTypes` |

## `FeedSection` — Changed, `Chapter` — New (client)

```swift
enum Chapter: Equatable, Sendable {
  case open
  case commit(number: String, title: String, detail: String)
}

struct FeedSection: Identifiable, Equatable, Sendable {
  var id: Seq          // .zero for the first section; the head_observed seq for each later one
  var chapter: Chapter
  var items: IdentifiedArrayOf<FeedItem> = []
}
```

| Field | Change | Notes |
|---|---|---|
| `heading: TaskHeading?` | Removed | |
| `chapter: Chapter` | Added | Read by the model's heading properties and pinned-heading logic |

The fold rules (in-place retitle, lazy first section, numbering, visibility, the chapters-on flag)
are spec D7.
