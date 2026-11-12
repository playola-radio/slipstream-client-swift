# Commit chapters — Endpoint changes

No route, parameter or control verb changes. The daemon's HTTP reader is GET-only with Bearer
auth; both new event types travel on the existing session event route, in `seq` order like every
other event. Event shapes live in [models.md](./models.md) and are not repeated here.

The daemon PR registers both types in `src/public-events.ts` (`PUBLIC_EVENT_TYPES`,
`LIFECYCLE_TYPES`, the lifecycle branch of `buildPublicEnvelope`), as `slipstream.capture.scope.v1`
is — not in `EVENT_TYPES`, which feeds the frozen `display-fold.v1` contract. Recovery then
validates them with no further change (it checks every `PUBLIC_EVENT_TYPES` entry against
`loadAllSchemas()`). Both are added to the event list in the README / `docs/` that documents the
log.

| Change | Method | Path | Auth | Purpose |
|---|---|---|---|---|
| Changed | GET | `/v1/sessions/:sessionId/events` | Bearer token | Also carries `slipstream.git.head_observed.v1` and `slipstream.git.chapters.v1` |

## GET /v1/sessions/:sessionId/events
- **Change:** Changed — two new event types in the stream; nothing else differs.
- **Auth:** Bearer token (unchanged)
- **Path params:** `sessionId` (unchanged)
- **Query params:** unchanged (`after`, `follow`)
- **Request body:** none
- **Response `200`:** unchanged framing (NDJSON, or SSE with `follow=true`). New lines look like:
  ```json
  {"specversion":"1.0","id":"3","source":"urn:slipstream:session:7c0e","type":"slipstream.git.chapters.v1","datacontenttype":"application/json","seq":"3","time":"2026-11-11T16:30:00.004Z","data":{"session_id":"7c0e","state":"active"}}
  ```
  ```json
  {"specversion":"1.0","id":"412","source":"urn:slipstream:session:7c0e","type":"slipstream.git.head_observed.v1","datacontenttype":"application/json","seq":"412","time":"2026-11-11T16:42:03.118Z","data":{"session_id":"7c0e","kind":"commit","sha":"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678","subject":"Add retry to the upload client","observed_at_ms":1794501723118}}
  ```
- **Ordering guarantee (new):** a `file.changed` produced from a filesystem observation the daemon
  admitted before a reflog notification has a lower `seq` than that notification's
  `head_observed` events; one admitted after has a higher `seq` (spec D2). This is admission
  order at the daemon, not Git's commit instant: the file and reflog watches are separate, and a
  file read just before the boundary can capture bytes written just after the commit.
- **Errors:** unchanged
- **Compatibility:**
  - Older apps ignore unknown event types and still advance their cursor (the log's forward
    compatibility rule). Today's app shows them as an "Unsupported event" divider; the client PR
    ships after the daemon PR and decodes both.
  - A new app on an older daemon gets no `git.chapters` event, so chapters stay off: no
    chapters and no "Not committed yet" heading — the stream looks as it does today minus task
    headings.
  - `slipstream.task.started.v1` is unchanged on the wire; the new app simply stops drawing it.
- **Consumers:** Change stream screen ([screens.md](./screens.md)) via
  `DaemonTransport.follow` and `firstEvent`.
