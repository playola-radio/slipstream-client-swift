# Recording controls — Endpoint changes

The daemon (`playola-radio/slipstream`) has two public surfaces this feature touches:

- **Control socket verbs:** newline-delimited JSON on the daemon's Unix socket, `{v:1, verb, ...}`
  in and `{v:1, ok, ...}` out (`docs/autocapture/contracts.md` §5). The app calls them through
  `ControlTransport`; the `slipstream` CLI calls them too.
- **Reader HTTP:** `GET /v1/captures` (contracts.md §9), which the app reads through
  `DaemonTransport` as `CaptureList`. It and the `status` verb fold the same rows
  (`statusRows` in `src/daemon.ts`).

The bearer token rules are unchanged.

| Change | Surface | Request | Caller | Purpose |
|---|---|---|---|---|
| Changed | verb `attach` (watch-only) | `{v:1, verb:"attach", mode:"watch-only", worktree}` | client (new), CLI | Record a folder. When full it refuses instead of queuing |
| Changed | verb `attach` (from a chat) | `{v:1, verb:"attach", harness, harness_session_id, worktree, root_transcript}` | client chat tabs, CLI | Refuses on a paused folder; refuses when full |
| Unchanged, newly called | verb `detach` | `{v:1, verb:"detach", target}` (the folder path) | client (new), CLI | Pause a workspace |
| Changed | `GET /v1/captures`, verb `status` | as today | client, CLI | Values only: `capture-limit-reached` is never reported |

## attach (watch-only)
- **Change:** Changed
- **Caller:** the client (sidebar **Record**, **Record a folder…**, Ask **Record**), and
  `slipstream attach --watch-only <root>`, which `slipstream workspace create` (the app's New
  Workspace) runs with `--wait`
- **Request:** unchanged
  ```json
  { "v": 1, "verb": "attach", "mode": "watch-only", "worktree": "/Users/brian/conductor/workspaces/playola/farmerville" }
  ```
- **Response `ok`:** shape unchanged
  ```json
  { "v": 1, "ok": true, "session_id": "6f1c…", "state": "queued", "reason": null, "created": true }
  ```
  - `session_id` is the capture now holding the folder. Re-recording a paused folder resumes its
    session (same id, `session.resumed`, `capture.gap`). A folder that was deleted and recreated
    gets a new id.
  - `created` keeps its current meaning: `true` when this request admitted the capture,
    including resuming a paused session; `false` when it joined a capture already starting or
    recording.
  - `state` is the admission state, usually `queued`. It is not "recording": the first snapshot
    can still fail.
  - The client reads none of these fields: `ok` means accepted, and the row shows whatever the
    next `GET /v1/captures` reports for the folder.
- **Behavior changes:**
  - **The cap is 32** (`MAX_CAPTURES`, was 16). A slot is any `running` capture intent: recording,
    starting, or failing and retrying.
  - **Full is a refusal, not a queue.** A folder with no running capture, while 32 slots are held
    (counting admissions in flight), writes **no** capture intent, allocates no session id, and
    leaves a paused entry paused. The check and the intent write happen in one synchronous turn,
    as today, so two concurrent attaches at 31 slots admit exactly one.
  - Gone: the `waiting` intent and its auto-start when a slot frees.
  - A folder already starting or recording still joins its capture, even when full.
- **Errors**, with the app's wording (shown under the row, or under the footer for **Record a
  folder…**):

  | Code | When | App shows |
  |---|---|---|
  | `CAPTURE_LIMIT_REACHED` | 32 slots held. Message: `32/32 capture slots in use. This workspace is NOT recording. Pause one first.` | "All recording slots are in use. Pause a workspace first." (amber) |
  | `ROOT_OVERLAP` | the folder is inside, or contains, a folder with a capture | "Couldn't record <name>: it overlaps a folder that's already recording." |
  | any other code (`SESSION_RESUME_FAILED`, `CAPTURE_NOT_READY`, `STORAGE_UNAVAILABLE`, `PROTOCOL`, unknown) | rare | "Couldn't record: <daemon message>" |
  | transport: couldn't connect | daemon not running | "Couldn't record: couldn't reach Slipstream." |
  | transport: no reply after send | outcome unknown | "Recording not confirmed. Checking…", then refresh and show the real state |

- **Compatibility:** older CLIs print the new message. `slipstream conductor enroll` and
  `workspace create` print a full refusal through their ordinary failure output, which carries
  the message's "NOT recording" (enroll used to count it as "waiting"). The app's New Workspace
  shows that line in its Setup tab; the folder isn't listed until it records.
- **Consumers:** Workspace sidebar **Record** and **Record a folder…**; Ask **Record**; New
  Workspace (through `slipstream workspace create`).

## attach (from a chat)
- **Change:** Changed
- **Caller:** the app's chat tabs (`ChatLinkClient` runs `slipstream attach <folder>`), and
  `slipstream attach` inside any agent chat
- **Request / response:** unchanged
- **Behavior changes:**
  - **A paused folder is refused.** If the attach would resume a capture whose intent is
    `withdrawn` (paused or archived; the same folder path and the same directory, as resume
    already checks), it writes nothing, admits nothing and links nothing, and returns the new
    code `CAPTURE_PAUSED`:
    `This workspace is paused. Record it in Slipstream first, then attach again.` Only a
    watch-only attach (Record) resumes a paused folder. A folder with no capture, or one deleted
    and recreated, is still admitted, as today. The daemon decides this, not the app, so a Pause
    racing an auto-link can't restart recording.
  - **Full:** a folder with no running capture while 32 slots are held is refused with
    `CAPTURE_LIMIT_REACHED` and writes nothing. Today it writes a `waiting` intent.
- **Errors:** adds `CAPTURE_PAUSED` (new in `src/control-protocol.ts`'s error union).
- **App behavior:**
  - Auto-link (opening a workspace, or a turn ending while nothing is linked) skips a folder the
    last refresh showed as paused, so no error appears.
  - A `CAPTURE_PAUSED` refusal (an auto-link racing a Pause, or a manual **Connect to Stream** on a
    paused folder) shows the tab's existing generic link error with the daemon's message:
    "Slipstream said: CAPTURE_PAUSED: This workspace is paused. Record it in Slipstream first,
    then attach again." The app adds no new refusal type.
  - After a Record succeeds, the app runs its usual auto-link for that folder once, so a chat
    with messages links again.
- **Compatibility:** an older CLI shows the new code and message and exits non-zero.
- **Consumers:** the app's chat tabs (opening, sending, replacing a linked tab); outside chats.

## detach
- **Change:** Unchanged. Listed because the app starts calling it (sidebar **Pause**).
- **Request:**
  ```json
  { "v": 1, "verb": "detach", "target": "/Users/brian/conductor/workspaces/playola/farmerville" }
  ```
- **Response `ok`:**
  ```json
  { "v": 1, "ok": true, "session_id": "6f1c…", "state": "stopped", "reason": "detached" }
  ```
  `already_stopped: true` when the target was already stopped. As today, detach withdraws the
  capture, revokes its chat link (`agent.unlinked{detached}`), and stops it
  (`capture.stopped{detached}`). The app targets the folder path; given a path, the daemon
  withdraws every capture recorded at that folder (`resolveTarget` and detach in `src/daemon.ts`),
  so the app never needs a session id. The client ignores the reply's fields.
- **Errors**, with the app's wording (under the row):

  | Code | When | App shows |
  |---|---|---|
  | `TARGET_NOT_FOUND` | no capture at that folder | "This workspace's recording no longer exists. Refreshing…" |
  | any other code (`STORAGE_UNAVAILABLE`, `PROTOCOL`, unknown) | rare | "Couldn't pause: <daemon message>" |
  | transport: couldn't connect | daemon not running | "Couldn't pause: couldn't reach Slipstream." |
  | transport: no reply after send | outcome unknown | "Couldn't pause: Slipstream didn't confirm it. Checking again…", then refresh |

- **Consumers:** Workspace sidebar **Pause**

## GET /v1/captures and status
- **Change:** Changed (values only)
- **Caller:** the client (`GET /v1/captures` → `CaptureList`), `slipstream status`
- **Request / response shape:** unchanged
- **Behavior changes:** no capture reports `not_recording{capture-limit-reached}` any more. A
  paused workspace is `stopped{detached}` with `binding.state: "unlinked"`, as today.
  ```json
  { "session_id": "6f1c…", "root": "/Users/brian/conductor/workspaces/playola/farmerville",
    "state": "stopped", "reason": "detached", "retry": null, "capture_mode": "watch-only",
    "heartbeat_ms": null,
    "binding": { "harness": "claude-code", "harness_session_id": "…", "binding_generation": "7",
                 "state": "unlinked", "reason": null } }
  ```
- **Consumers:** Workspace sidebar (paused rows, "N recording"), Ask (paused notice), the stream's
  capture line
