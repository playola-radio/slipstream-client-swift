# Capture states — Endpoint changes

This feature changes no daemon code. The daemon (`briankeane/slipstream` `origin/develop`
`ae50202`) already serves everything below; the client starts consuming it. The contract is
`docs/autocapture/contracts.md` §6 (fold) and §9 (reader projection) in the daemon repo.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| Consumed (new to the client) | GET | `/v1/captures` | Bearer token | Whether each workspace is really recording, and its chat link |
| Consumed differently | CONTROL | `ask` | control socket owner | Now sends the optional `binding_generation` the daemon already accepts |

`GET /v1/sessions` and the event stream are unchanged and keep their current consumers.

## GET /v1/captures
- **Change:** none on the daemon; newly consumed by the client
- **Auth:** `Authorization: Bearer <reader token>` (same as `/v1/sessions`)
- **Request:** no parameters
- **Response `200`:**
  ```json
  {
    "as_of_ms": 1792252567000,
    "binding_slots": { "used": 7, "limit": 10 },
    "captures": [
      {
        "session_id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90",
        "root": "/Users/brian/conductor/workspaces/app/nairobi",
        "state": "recording",
        "reason": null,
        "retry": null,
        "capture_mode": "watch-only",
        "heartbeat_ms": 1792252566120,
        "binding": {
          "harness": "claude-code",
          "harness_session_id": "5c1e9a77-2b0d-4f3a-8e61-9d4c2a7b3f10",
          "binding_generation": "3",
          "state": "connected",
          "reason": null
        }
      },
      {
        "session_id": "7d2b4c19-3e8a-4f56-b1c0-6a9e8d2f4b37",
        "root": "/Users/brian/conductor/workspaces/app/lisbon",
        "state": "not_recording",
        "reason": "capture-limit-reached",
        "retry": null,
        "capture_mode": "watch-only",
        "heartbeat_ms": null,
        "binding": null
      },
      {
        "session_id": "a41f0c6e-9b2d-4e7a-8c35-1f6d2b9e0a84",
        "root": "/Users/brian/conductor/workspaces/app/porto",
        "state": "not_recording",
        "reason": "baseline-failed",
        "retry": { "next_attempt_at_ms": 1792255500000 },
        "capture_mode": "watch-only",
        "heartbeat_ms": null,
        "binding": null
      }
    ]
  }
  ```
- **Fields the client reads:** `captures[].session_id`, `root`, `state`, `reason`,
  `retry.next_attempt_at_ms`, `binding.binding_generation`, `binding.state`, `binding.reason`.
  It ignores `as_of_ms`, `binding_slots`, `capture_mode`, `heartbeat_ms`, `harness`,
  `harness_session_id`, and the undocumented `message`. The daemon already folds the heartbeat
  into `state` (a stale owner reads `not_recording{daemon-unavailable}`).
- **Values:**
  - `state`: `queued` | `baselining` | `recording` | `stopped` | `not_recording`.
  - `reason` for `stopped`: `detached`, `archived`, `maintenance`, `root-missing`,
    `watcher-failed`.
  - `reason` for `not_recording`: `daemon-unavailable`, `root-overlap`, `root-missing`,
    `baseline-failed`, `storage-unavailable`, `watcher-failed`, `resume-failed`,
    `resource-limit`, `stop-unconfirmed`, `capture-limit-reached`.
  - `binding.state`: `setup_pending` (reason `config-missing` or null) | `connected` |
    `unavailable` (`transcript-missing`, `transcript-unreadable`, `identity-changed`,
    `runtime-unsupported`) | `unlinked`.
  - `binding_generation` is a decimal string.
- **Tolerance:** an unknown `state`, `reason` or `binding.state` keeps the row and the raw
  code. A missing required key or a wrong type fails the whole decode (shown as "couldn't
  reach Slipstream"); it is never treated as an empty list.
- **Errors:**

  | Status / failure | When | Client shows |
  |---|---|---|
  | `401` | Wrong or missing bearer token | Existing reader-auth handling; capture state "couldn't reach Slipstream" |
  | `403` | Host header check fails | Same as other failures |
  | `404` | The reader has no capture table (offline `slipstream serve`) | "Capture state unavailable from this reader"; picker rows "· State unknown"; Ask disabled |
  | Transport error, other status, unreadable body | Daemon down, crash, bad JSON | "Capture state unknown — couldn't reach Slipstream"; Ask disabled |

- **Consumers:**
  - Stream picker: rows (union with sessions) and the state suffix.
  - Change stream window: the status strip (CAPTURE and CHAT rows) for the selected workspace.
  - Ask Agent composer: the recording and binding gates, and the `binding_generation` it sends.
- **Fetched when:** together with `GET /v1/sessions` on the existing refresh triggers
  ([screens.md](./screens.md#how-the-app-learns-the-state)). No polling.

## CONTROL ask
- **Change:** the client adds the optional `binding_generation` field. The daemon already
  accepts and enforces it (`src/daemon.ts:1613-1633` on `origin/develop`).
- **Request:**
  ```json
  { "v": 1, "verb": "ask", "session_id": "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90", "request_id": "c7e1d2a9-4b3f-4e8c-9a1d-2f5b6c7d8e90", "binding_generation": "3", "text": "Why did this change?", "context": { "…": "unchanged" } }
  ```
- **Response:** unchanged.
- **Errors the new field adds:**

  | Code | When | Client shows |
  |---|---|---|
  | `STALE_BINDING` | The chat was relinked after the snapshot the composer used | The existing rejected-question banner, then a refresh |

  `AGENT_NOT_CONNECTED` and `CAPTURE_NOT_READY` are unchanged.
