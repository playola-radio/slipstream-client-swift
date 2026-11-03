# Recording controls — Model changes

There is no database. The daemon's one durable model is its intent record,
`<store>/control/intent.json` (`docs/autocapture/contracts.md` §8; types in
`src/capture-intent.ts`, load/validate/save in `src/intent-store.ts`, both in
`playola-radio/slipstream`). The client stores nothing new; it reads captures through
`GET /v1/captures`.

| Change | Model | Stored in | Summary |
|---|---|---|---|
| Changed | `CaptureIntent` | `intent.json` → `captures[]` | Drops the `waiting` intent value; at most 32 `running` (was 16) |

`BindingIntent` (`bindings[]`) is unchanged: Pause revokes the link exactly as detach does today,
and the limit stays at 10 linked chats.

## CaptureIntent (`captures[]`) — Changed

| Field | Type | Null | Default | Change | Notes |
|---|---|---|---|---|---|
| `intent` | `"running" \| "withdrawn"` (was `"running" \| "waiting" \| "withdrawn"`) | NOT NULL | — | Changed | `waiting` removed: a full attach writes nothing |

- **Indexes / constraints:** the slot rule becomes "at most **32** entries with
  `intent: "running"`, plus admissions in flight". `MAX_CAPTURES` in `src/capture-intent.ts`
  is the one constant. The rule that the first `waiting` entry becomes `running` when a slot
  frees is deleted, along with its code in `withdrawCapture` and the daemon's start of the
  promoted entry in `detach`.
- **Associations:** unchanged
- **Enums:** `intent` loses `waiting`. `NotRecordingReason` loses `capture-limit-reached`; the
  client's wording for it in `CaptureStatus.swift` goes too.
- **Migration:** read-time only. `loadIntent` rewrites every `waiting` entry it parses as
  `intent: "withdrawn", withdrawn_reason: "detached"`, `last_failure: null`, before validating;
  the next normal intent write (temp-file + rename, as today) saves the new form. No startup save
  and no new failure path. The offline readers (`withdrawOffline`, `slipstream status` with no
  daemon) load through the same function, so they see paused entries too. Nothing starts
  recording that wasn't recording. Upgrade → rollback → upgrade is safe: an unsaved `waiting`
  entry is still the old daemon's own value, and the next upgrade reads it as paused again. The
  record stays `version: 1`. (The live store has no `waiting` entries today; this covers an old
  daemon having written some.)
- **Deploy compatibility:** an older daemon reads a migrated record (it knows every value in
  it). Rolling back restores the 16 cap and the queue: while 16 or more are `running`, a new
  attach waits as before, and no running capture is evicted.
- **Source of truth:** `intent.json` says which workspaces should record and which chats are
  linked. Session logs record what happened (`capture.stopped`, `agent.unlinked`). Runtime and
  ownership heartbeats say what is live now. `GET /v1/captures` folds all three. The client keeps
  no copy: "paused" and "N recording" are derived from each refresh.
