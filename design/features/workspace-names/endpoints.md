# Workspace names — Endpoint changes

The daemon has three wire surfaces here:
- **Control socket** — `<store>/control.sock`, owner-only, NDJSON `v:1` envelopes, the only
  write path. Success is `{v:1, ok:true, ...fields}`; failure is `{v:1, ok:false, code, message}`.
- **HTTP reader** — GET-only, Bearer auth.
- **MCP forwarder** — the stdio tool server agents call; it forwards to the control socket with
  the chat's verified identity triple.

The daemon PR copies these contracts into `docs/ask-agent/contract.md` under a new "Workspace
names" section.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| New | MCP TOOL | `slipstream_name_workspace` | the linked agent chat | Let the agent name its workspace |
| New | CONTROL | `name_workspace` | control socket owner + identity triple | Back the tool: set the agent's name |
| New | CONTROL | `rename_session` | control socket owner | Set or clear your name |
| Changed | GET | `/v1/sessions` | Bearer token | Report each session's names |
| Changed | MCP TOOL | `slipstream_begin_task` | the linked agent chat | Description tells the agent when to name the workspace |

`ControlErrorCode` (`src/control-protocol.ts`) gains one value, `INVALID_NAME`. No new
`attach_features` value: the forwarder's exact build-match gate covers the tool, and the app
reads `naming`'s presence on `/v1/sessions`.

## MCP TOOL slipstream_name_workspace
- **Change:** New
- **Auth:** the calling chat must be linked to a connected capture, exactly as for
  `slipstream_begin_task`.
- **Tool definition:**
  ```json
  {
    "name": "slipstream_name_workspace",
    "description": "Give this workspace a short name (2-5 words) that says what the work is about, so the person watching can tell workspaces apart. Call it once, on your first task, when the work is clear. Call it again with replace_existing: true only if the work changes direction. You cannot override a name the person chose.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": { "type": "string", "description": "2-5 words, e.g. \"Workspace rename menu\"." },
        "replace_existing": { "type": "boolean", "description": "Replace your earlier name. Default false." }
      },
      "required": ["name"],
      "additionalProperties": false
    }
  }
  ```
- **Behaviour:** the forwarder builds a `name_workspace` envelope with the identity triple and
  the raw arguments — `name` as-is, and `replace_existing` as-is whenever the key is present,
  so the daemon (not the forwarder) rejects a non-boolean. It sends it through the existing
  `versionGate` and returns:
  - success: `{ text: "Agent name saved.", isError: false, structured: { changed } }`,
    or `"An agent name was already set; kept it."` when `changed` is `false`. The text never
    says the visible name changed, because a user name may override it.
  - failure: `{ text: "<CODE>: <message>", isError: true, structured: { code } }`, as
    `answer-forwarder.ts` does.
- **Acknowledgment check:** success means `ok: true` with a boolean `changed`. Any other
  `ok: true` shape is treated like a lost reply.
- **No automatic resend.** A lost or malformed reply returns `OUTCOME_UNKNOWN` ("the name was
  sent but whether it was saved could not be confirmed"). A resend could overwrite a newer
  replacement or land on a relinked session, so retrying is the agent's deliberate choice.
- **Dispatch:** `callTool` routes `slipstream_name_workspace` to a new `forwardNameWorkspace`
  (`src/name-forwarder.ts`).
- **Consumers:** agents (Claude Code, Codex) via the forwarder; guidance in `SKILL.md`.

## CONTROL name_workspace
- **Change:** New
- **Auth:** control socket owner; the request carries the identity triple.
- **Request body:**
  ```json
  { "v": 1, "verb": "name_workspace", "harness": "claude-code", "harness_session_id": "8d1e…", "worktree": "/Users/me/conductor/workspaces/slipstream-client-swift/tacoma-v2", "name": "Workspace rename menu", "replace_existing": false }
  ```
  `replace_existing` is optional (default `false`).
- **Response `ok`:**
  ```json
  { "v": 1, "ok": true, "changed": true }
  ```
- **Checks, in order** (the outer envelope, compromise and readiness guards run first, unchanged):
  1. `harness`, `harness_session_id`, `worktree` are non-empty strings → else `IDENTITY_UNRESOLVED`.
  2. `replace_existing` is absent or a boolean → else `PROTOCOL`.
  3. `name` is a valid name ([models.md](./models.md#session-name-file-sessionsidnamejson--new)) → else `INVALID_NAME`.
  4. The same chat-to-capture resolution as `beginTask` (`src/daemon.ts:1651`), shared with it
     as one synchronous helper, including capturing `bindingAtEntry(req)` before any await: realpath the worktree; linked capture
     at that root, else `AGENT_NOT_CONNECTED` (watch-only) or `SESSION_NOT_SELECTED`; lost
     activation → `STORAGE_UNAVAILABLE`; not recording → `CAPTURE_NOT_READY`; binding changed
     since entry → `SESSION_NOT_SELECTED`; `staleBinding`; binding not `connected` →
     `AGENT_NOT_CONNECTED`.
  5. **Admission.** The write is registered in the capture's existing in-flight set (`track`,
     as `beginTask` does), so unlink and maintenance drain it, and is then queued on the
     metadata lock.
  6. Under the lock, read `name.json`. If `agent_name` is set and `replace_existing` is not
     `true`, or it already equals the trimmed name, reply `changed: false` without writing.
  7. Write and fsync the temp file.
  8. **Publication check, immediately before the atomic rename, with no await between:**
     store ownership held, daemon not tearing down and activation not lost → else
     `STORAGE_UNAVAILABLE`, and the temp file is removed. There is no binding re-check: the
     target is the session the chat was linked to at entry, so a name that lands after an
     unlink still names the session the agent worked in. (No tombstone check either:
     `delete_session` refuses a session whose capture isn't stopped.)
  9. Rename over `name.json`, fsync the directory, reply `changed: true`. `user_name` is never
     touched. A failure after the rename → `STORAGE_UNAVAILABLE` (the name may have landed).
- **No event.** The app picks the name up on its next `/v1/sessions` poll.
- **Errors:**

  | Code | When |
  |---|---|
  | `IDENTITY_UNRESOLVED` | Identity triple missing |
  | `PROTOCOL` | `replace_existing` not a boolean |
  | `INVALID_NAME` | Name fails validation; the message names the first failing rule |
  | `SESSION_NOT_SELECTED` | Chat not linked to a capture of this worktree |
  | `AGENT_NOT_CONNECTED` | Watch-only capture, or setup not finished |
  | `CAPTURE_NOT_READY` | Linked capture not recording yet |
  | `STALE_BINDING` | `session_id` or `binding_generation` in the request is stale (`staleBinding`, as for `begin_task`) |
  | `STORAGE_UNAVAILABLE` | Shutting down, store lock lost, or a failed write |

- **Consumers:** `slipstream_name_workspace` (forwarder).

## CONTROL rename_session
- **Change:** New
- **Auth:** control socket owner (the app holds no extra credential).
- **Request body:**
  ```json
  { "v": 1, "verb": "rename_session", "session_id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90", "name": "Sidebar polling backoff" }
  ```
  `name: null` clears your name ("Use agent's name"). The `name` key is required.
- **Response `ok`:**
  ```json
  { "v": 1, "ok": true }
  ```
  No names in the reply; the app re-reads `/v1/sessions` right after a success.
- **Checks, in order** (outer guards first, unchanged):
  1. `session_id` is a lowercase UUIDv4 → else `PROTOCOL`.
  2. `name` is present and a string or `null` → else `PROTOCOL`.
  3. A string `name` is valid → else `INVALID_NAME`.
  4. Queue on the metadata lock.
  5. Session directory exists with no tombstone → else `SESSION_NOT_FOUND` ("session was
     deleted" when tombstoned).
  6. Read `name.json`, set `user_name`, write and fsync the temp file.
  7. **Publication check, immediately before the atomic rename, with no await between:** store
     ownership held and daemon not tearing down → else `STORAGE_UNAVAILABLE`. Then rename and
     fsync the directory. A rename that races a `delete_session` can leave `name.json` in a
     tombstoned directory; that is harmless (the list never reads it for a removed session, and
     `gc` removes it), so there is no delete re-check.
- **Admission:** refused only when the daemon is compromised (store lock lost) or tearing down
  (`STORAGE_UNAVAILABLE`). Any capture lifecycle state is fine, including the recording
  session, a stopped capture and archived sessions. Not routed through `runMaintenance`.
- **Outcome:** a write can land even when the reply is lost or the final directory fsync
  fails. The app treats any failure after sending as "may have saved" and refreshes the list.
  It does not resend automatically; "Try again" is the user's choice.
- **Errors:**

  | Code | When |
  |---|---|
  | `PROTOCOL` | Bad `session_id`, or `name` missing or not string/null |
  | `INVALID_NAME` | Name fails validation |
  | `SESSION_NOT_FOUND` | No such session, or deleted |
  | `STORAGE_UNAVAILABLE` | Shutting down, store lock lost, failed write |
  | `CAPTURE_NOT_READY` | Daemon still starting (existing connection-level guard) |

- **Request encoding:** the client encodes `name` explicitly, writing JSON `null` for a clear;
  it never omits the key.
- **Acknowledgment check:** the existing `ControlReply.check`, as `record` and `pause` use.
  Each request opens its own socket, so a reply can't belong to another request.
- **Client mapping** (Rename workspace dialog, [screens.md](./screens.md#rename-workspace-dialog)):
  `SESSION_NOT_FOUND` → Workspace gone; `INVALID_NAME` → the invalid-name message; anything
  else, a timeout, a malformed reply or `DAEMON_UNAVAILABLE` → Save failed. Every write, success
  or failure, also triggers a list refresh, so a write that did land shows up.
- **Consumers:** client Rename workspace dialog (Rename) and row context menu ("Use agent's
  name", sends `null`), via a new `ControlTransport.renameSession(sessionID:name:)` exposed on
  a dependency client.

## GET /v1/sessions
- **Change:** Changed
- **Response delta:** every item gains `naming`.
  ```json
  [{ "id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90", "durable_seq": "1842", "removed": false, "agent_connection": { "state": "connected" }, "naming": { "agent_name": "Workspace rename menu", "user_name": null } }]
  ```
  - No `name.json` → both `null`.
  - Removed items always report both `null` without reading the file, as `durable_seq` does.
  - On a daemon with this feature the key is always present and always an object with both
    keys. An absent key means an older daemon.
- **Freshness:** the app polls this endpoint every 2 s while the window is visible and the app
  is active (spec D8), plus its existing refresh moments and right after a rename.
- **Errors delta:** none. A malformed `name.json` reports both names `null` for that session
  and logs one daemon warning; the rest of the list is unaffected (see
  [models.md](./models.md)).
- **Compatibility:** the current client ignores unknown keys. A new client against an older
  daemon sees no `naming`: folder-name labels, Rename disabled.
- **Consumers:** client sidebar rows, breadcrumb, row context menu, rename dialog, and every
  label surface in [spec.md](./spec.md#label-surfaces).

## MCP TOOL slipstream_begin_task
- **Change:** Changed (description only; schema and behaviour unchanged)
- **Description delta:** appends: "Once you know what this workspace's work is about, also call
  slipstream_name_workspace with a 2-5 word name — usually on your first task."
- **Docs:** `SKILL.md` and `README.md` ("Connect an agent chat") gain the same rule: name the workspace once, on the first task,
  in 2-5 words; replace it only if the work changes direction; don't rename per task.
- **Consumers:** agents.
