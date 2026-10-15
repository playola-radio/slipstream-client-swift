# Stream names — Endpoint changes

The daemon has two wire surfaces:
- **Control socket.** `<store>/control.sock` is owner-only and uses NDJSON `v:1` envelopes. It is
  the only write path.
  - Success replies are `{v:1, ok:true, ...fields}`.
  - Failures are `{v:1, ok:false, code, message}`.
- **HTTP reader.** It is GET-only, with Bearer auth.

The CLI is listed too, because agents use it to name their stream. The daemon PR copies these
contracts into `docs/ask-agent/contract.md` under a new "Stream names" section.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| New | CONTROL | `rename_session` | control socket owner | Set or clear your name for a stream |
| Changed | CONTROL | `attach` | control socket owner | Accept an optional agent name |
| Changed | CONTROL | `status` | control socket owner | Advertise `workspace-names-v1` |
| Changed | GET | `/v1/sessions` | Bearer token | Report each stream's names |
| Changed | CLI | `slipstream attach` | local user | `--name "<2-5 words>"` |

`ControlErrorCode` (`src/control-protocol.ts:24-42`) gains one value, `INVALID_NAME`.

## CONTROL rename_session
- **Change:** New
- **Auth:** owner of the control socket (the app holds no extra credential)
- **Request body:**
  ```json
  { "v": 1, "verb": "rename_session", "session_id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90", "name": "Billing cleanup" }
  ```
  `name: null` clears your name, so the agent's name (or the fallback) shows again. The `name`
  key is required.
- **Response `ok`:**
  ```json
  { "v": 1, "ok": true, "session_id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90" }
  ```
  The reply carries no names. The stored `user_name` is the trimmed value, and the app reads it
  back with its list reload right after a successful rename.
- **Checks, in order.** The existing outer guards run first, unchanged: envelope parsing,
  store compromise, startup readiness (`src/daemon.ts:969,1019-1029`). Then:
  1. `session_id` is a valid session id (lowercase UUIDv4) → else `PROTOCOL`.
  2. `name` is present and is a string or `null` → else `PROTOCOL`.
  3. A string `name` is a valid name (see [models.md](./models.md#session-name-file-sessionsidnamejson-new)) → else `INVALID_NAME`.
  4. The operation is queued on the metadata lock. When it runs, store ownership and daemon
     state are checked (not wedged, not tearing down, store lock held) → else
     `STORAGE_UNAVAILABLE`. Teardown waits for queued operations.
  5. Under the lock: the session directory exists and has no tombstone → else
     `SESSION_NOT_FOUND`. The message is "session was deleted" for a tombstoned session.
  6. Read `name.json`, set `user_name`, and publish. Any read or write failure, including a
     malformed file → `STORAGE_UNAVAILABLE`.
- **Ordering:** same-field writes are last-writer-wins in lock order. A retried rename can
  overwrite a rename made in between from another window. That is accepted, since only the
  local user writes `user_name`.
- **Outcome:** a write can be published even when its reply is lost, or when the final
  directory fsync fails and the reply is `STORAGE_UNAVAILABLE`. Callers must treat any failure
  after sending as "may have applied" and refresh the list. Resending the same `name` is
  harmless.
- **Delete is outside the lock:** `delete_session` and `gc` do not take the metadata lock. A
  rename that races a delete can leave a `name.json` in a tombstoned session directory. That
  is harmless: the list reports null names for a removed stream without reading the file, and
  `gc` re-runs history removal, which unlinks it.
- **Admission:** allowed in every capture state except wedged. That covers renaming the stream
  being recorded and any detached stream. It does not use `runMaintenance`.
- **Errors:**

  | Code | When |
  |---|---|
  | `PROTOCOL` | Bad `session_id`, `name` missing or not a string/null, or an older daemon (`unknown verb: rename_session`) |
  | `INVALID_NAME` | Unpaired surrogate; a control character, line break, or U+2028/U+2029; empty after trimming; or over 64 UTF-8 bytes. Checked in that order, and the message names the first failure |
  | `SESSION_NOT_FOUND` | No such session, or it was deleted |
  | `STORAGE_UNAVAILABLE` | Wedged or tearing-down daemon, lost store lock, malformed `name.json`, or a failed write (which may still have been published) |
  | `CAPTURE_NOT_READY` | The daemon is still starting (existing connection-level guard) |

- **Consumers:** client Rename sheet (Save and "Use agent's name").

## CONTROL attach
- **Change:** Changed
- **Request delta:** adds an optional `name` (string).
  ```json
  { "v": 1, "verb": "attach", "worktree": "/Users/me/code/louisville-v1", "harness": "claude-code", "harness_session_id": "…", "name": "Invoice totals refactor" }
  ```
- **Response:** unchanged. It is still `{session_id, agent_connection}`, or
  `{session_id, already_active: true, agent_connection}`.
- **Behaviour:**
  - `name` is validated before the daemon enters `attaching`, next to the `root_transcript`
    check. A non-string or invalid name → `INVALID_NAME`, and nothing changes.
  - For a new or resumed attach, the name is written as `agent_name` after the capture starts
    and before it is activated. It sits next to `recordAgentConnection`
    (`src/daemon.ts:481`), so the list refresh the app runs on `session.resumed` already sees
    it.
  - If that write fails, the attach takes the existing failure branch after the capture
    starts, the same one as a failed `recordAgentConnection`:
    - the capture is stopped and frozen at its durable boundary
    - a new session replies `STORAGE_UNAVAILABLE`
    - a resumed session replies `SESSION_RESUME_FAILED` ("could not record the stream name",
      with the existing retry remedy)
  - Nothing is rolled back. The session's start or resume record, and possibly the name
    itself, stay on disk. Running the same attach again is the retry.
  - For an attach that is already active (`already_active: true`), the name is written as
    `agent_name` under the metadata lock if it differs from the stored one. The binding is
    otherwise unchanged. This is how an agent renames its stream.
    - After acquiring the lock, the daemon re-checks that the same binding is still active.
      If it isn't, nothing is written and the reply is the existing `CAPTURE_NOT_READY` "the
      active capture changed; retry attach".
    - The re-attach does not emit an event. The app picks up the new name at its next
      refresh (see `GET /v1/sessions`).
  - Without `name`, `name.json` is not read or written.
  - `attach` never touches `user_name`.
- **Errors delta:**
  - Adds `INVALID_NAME`.
  - A failed name write gives `STORAGE_UNAVAILABLE` for a new session and
    `SESSION_RESUME_FAILED` for a resumed one.
  - A named re-attach whose binding changed while it waited gives `CAPTURE_NOT_READY`.
- **Compatibility:**
  - An older daemon ignores an unknown `name` silently. That is why the CLI checks
    `attach_features` before it sends one.
  - Clients that don't send `name` see no change.
- **Consumers:** `slipstream attach` (both paths).

## CONTROL status
- **Change:** Changed
- **Response delta:** `attach_features` becomes `["agent-connection-v1", "workspace-names-v1"]`.
  `workspace-names-v1` covers three things:
  - `attach` accepts `name`
  - `rename_session` exists
  - `GET /v1/sessions` items carry `naming`
- **Compatibility:** additive. `src/attach-workflow.test.ts:64` and `:347` pin the old array and
  must be updated.
- **Consumers:** `slipstream attach` before sending `name`.

## GET /v1/sessions
- **Change:** Changed
- **Response delta:** every item gains `naming`.
  ```json
  [{ "id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90", "durable_seq": "1842", "removed": false, "agent_connection": { "state": "connected" }, "naming": { "agent_name": "Invoice totals refactor", "user_name": "Billing cleanup" } }]
  ```
  - With no `name.json`, both values are `null`.
  - Removed items always report both as `null`, and the file is not read, as is done for
    `durable_seq`.
  - The key is always present on a daemon with `workspace-names-v1`. Its value is always an
    object with both keys, and never `null`. The app treats an absent key as an older daemon.
  - Names are added to each item after `listSessions` (see models.md, Readers).
- **Freshness:** there is no live delivery of names. A rename from another window, or an
  agent's re-attach with a new name, shows up at the app's next refresh. The refresh moments
  are:
  - the window appears
  - Refresh is pressed
  - a stream is selected
  - the watched stream resumes
  - a rename from this window succeeds
  - the window becomes key
- **Errors delta:** a malformed `name.json` fails the request with the reader's existing `500`.
- **Compatibility:**
  - The current client ignores unknown keys (`SessionSummary` decoder), so it keeps working.
  - The new client against an older daemon sees no `naming`. It disables rename and uses
    fallback labels.
- **Consumers:**
  - the client Stream picker (labels, title, rename availability)
  - the client Rename sheet (current names)
  - the queued-question notice label

## CLI slipstream attach
- **Change:** Changed
- **Usage delta:**
  ```
  slipstream attach [dir] [--store <dir>] [--name <name>]
  slipstream attach [dir] [--store <dir>] --harness <name> --harness-session-id <id> [--root-transcript <path>] [--name <name>]
  ```
- **Behaviour:**
  - `--name` alone still routes to the one-command attach.
  - Before anything is installed or attached, the CLI checks the name with the daemon's own
    validation function. An invalid name prints the reason and exits 1, and nothing changes.
  - With `--name`, both paths require `workspace-names-v1` in `status.attach_features`.
    Otherwise the CLI refuses with: `the running daemon does not support stream names. Restart
    the Slipstream daemon with this version, then run slipstream attach --name … again. Nothing
    was installed or recorded.` It exits 1.
  - On an already-active connected attach with `--name`, the line ending "; nothing changed."
    ends "; agent name updated." instead.
  - Without `--name`, the one-command path prints:
    `Name this stream once, in 2-5 words: slipstream attach --name "<name>"`.
  - The manual path keeps printing every reply field.
- **Docs:**
  - `README.md` ("Connect an agent chat" and the command reference) shows
    `slipstream attach --name "<2-5 words describing this workspace's work>"`.
  - `docs/connect-agent-chat.md` gets the same.
  - `SKILL.md` gets a short rule: when you attach, pass `--name` with a 2-5 word name for the
    workspace's overall work, and don't rename it for each task.
- **Consumers:** agents (Claude Code, Codex) and people at a terminal.
