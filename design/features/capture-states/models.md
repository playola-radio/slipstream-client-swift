# Capture states — Model changes

The daemon has no database and this feature changes nothing on it. The client's models are Swift
value types. Core types carry wire values only (no display strings, no Observation); wording lives
beside the app's shared models so the future chat console can reuse it.

| Change | Model | Where | Summary |
|---|---|---|---|
| New | `CaptureList` | client `Sources/SlipstreamCore/Captures.swift` | Decoded `GET /v1/captures` body |
| New | `CaptureSummary` | client `Sources/SlipstreamCore/Captures.swift` | One workspace's capture state, reason, retry and binding |
| New | `CaptureBinding` | client `Sources/SlipstreamCore/Captures.swift` | The workspace's chat link |
| New | `CaptureState` | client `Sources/SlipstreamCore/Captures.swift` | Wire `state`, tolerating unknown values |
| New | `BindingState` | client `Sources/SlipstreamCore/Captures.swift` | Wire `binding.state`, tolerating unknown values |
| Changed | `DaemonClient` | client `SlipstreamViewer/Dependencies/DaemonClient.swift` | Adds `listCaptures`, distinguishing 404 |
| Changed | `QuestionRequest` | client `Sources/SlipstreamCore/Questions.swift` | Sends `binding_generation` |
| New | `CaptureAvailability` | client `SlipstreamViewer/Models/CaptureStatus.swift` | Whether the snapshot loaded, per refresh |
| New | `CaptureStatus` wording | client `SlipstreamViewer/Models/CaptureStatus.swift` | Readable capture and chat-link text, suffix, dot colour, Ask gate |
| Changed | `SessionOption` | client `SlipstreamViewer/Models/FeedContent.swift` | Carries the workspace's capture, and may exist without a session |

## `CaptureList` (client): New

| Field | Type | Null | Notes |
|---|---|---|---|
| `captures` | `[CaptureSummary]` | no | Wire `captures`. Order is not relied on |

- `Decodable`, `Equatable`, `Sendable`. `as_of_ms` and `binding_slots` are not decoded: nothing
  reads them (`binding_slots` UI is out of scope).

## `CaptureSummary` (client): New

| Field | Type | Null | Notes |
|---|---|---|---|
| `sessionID` | `String` | no | Wire `session_id`. The join key with `/v1/sessions` |
| `root` | `String` | no | Wire `root`. Labels a capture-only picker row (its folder name) |
| `state` | `CaptureState` | no | Wire `state` |
| `reason` | `String?` | yes | Wire `reason`, kept raw. Wording maps known codes and shows unknown ones verbatim |
| `retryAtMs` | `Int64?` | yes | Wire `retry.next_attempt_at_ms`; `retry: null` → `nil` |
| `binding` | `CaptureBinding?` | yes | Wire `binding`; `null` means no chat linked |

- `capture_mode`, `heartbeat_ms` and `message` are not decoded. The daemon already folds the
  heartbeat into `state`.

## `CaptureBinding` (client): New

| Field | Type | Null | Notes |
|---|---|---|---|
| `generation` | `String` | no | Wire `binding_generation`, a decimal string. Sent back on `ask` |
| `state` | `BindingState` | no | Wire `state` |
| `reason` | `String?` | yes | Wire `reason`, kept raw |

- `harness` and `harness_session_id` are not decoded: nothing in the app displays or routes on
  them; the daemon routes by session.

## `CaptureState` / `BindingState` (client): New

```swift
public enum CaptureState: Equatable, Sendable {
  case queued, baselining, recording, stopped, notRecording
  case unknown(String)
}

public enum BindingState: Equatable, Sendable {
  case setupPending, connected, unavailable, unlinked
  case unknown(String)
}
```

- Decoded from a string; any other value becomes `.unknown(raw)`. A non-string is a decode error.

## `DaemonClient` (client): Changed

| Member | Type | Change | Notes |
|---|---|---|---|
| `listCaptures` | `@Sendable () async throws -> CaptureList?` | Added | `nil` for HTTP 404 (reader has no capture table). Other statuses, transport errors and decode failures throw, as `listSessions` does |

## `QuestionRequest` (client): Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `bindingGeneration` | `String` | Added | Wire `binding_generation`. Taken from the selected workspace's `CaptureBinding` when the composer opens. Always sent, because Ask is only enabled with a connected binding |

## `CaptureAvailability` (client): New

```swift
enum CaptureAvailability: Equatable, Sendable {
  case loading
  case available(checkedAt: Date)
  case unavailableFromReader   // 404
  case failed                  // transport, other status, unreadable body
}
```

- Held once per page by `ChangeStreamPageModel`, updated by each refresh under the existing
  refresh generation guard. A failed refresh replaces `available`; it never leaves an old
  "Recording" showing.
- A successful response without the selected workspace's session is a per-row condition
  ("Not captured"), not a failure.

## `CaptureStatus` wording (client): New

Pure functions over `(CaptureAvailability, CaptureSummary?)`, unit-tested with every state and
reason. They own every string in [screens.md](./screens.md): capture text, detail line, picker
suffix, chat text, dot colour token, and the Ask gate with its notice.

- Retry detail formats `retryAtMs` in the injected time zone ("Retry scheduled Oct 18 16:45:00").
  A retry time in the past is still shown as scheduled; the app never infers that it ran.
- `stop-unconfirmed` is never worded as "Stopped".
- The Ask gate is: availability `available`, capture `recording`, binding `connected`, and the
  existing runtime `agentConnection == .connected`.

## `SessionOption` (client): Changed

| Field | Type | Change | Notes |
|---|---|---|---|
| `capture` | `CaptureSummary?` | Added | The matching capture from the latest snapshot; `nil` when the snapshot has none or didn't load |
| `hasHistory` | `Bool` | Added | `false` for a capture-only row (no `/v1/sessions` entry). Such a row opens no follower, offers no compare or rename, and shows the "No change history is available yet" empty state |
| `label` | `String` | Changed | A capture-only row uses its root's folder name, with the existing collision rules. The state suffix is added at display time, not stored |

- The existing `agentConnection` and `readinessSeq` stay: they are the live runtime readiness
  from events. Live events never overwrite `capture`.
- Selection remains by id, so a capture-only row that later gains a session keeps its selection
  and starts its follower once.

## Removed

- `ChangeStreamPageModel.RecordingState` and `recordingState(of:)`, which guessed "Recording"
  from events. Every caller now reads `CaptureStatus`.
