# Capture states

Show, for every workspace, whether it is really recording, why not when it isn't, and whether its
agent chat is linked. Ask Agent follows the selected workspace's own chat link.

## Base commits

| Repo | Branch | SHA |
|---|---|---|
| Client `playola-radio/slipstream-client-swift` | `develop` | `317788b` |
| Daemon `briankeane/slipstream` (owns the wire contract) | `origin/develop` | `ae50202` |

## Target surfaces

- `client` only: `SlipstreamCore` (decoding) and `SlipstreamViewer` (picker, status strip, Ask).
- Daemon: none. It already serves `GET /v1/captures` and fences `ask` by `binding_generation`
  (`docs/autocapture/contracts.md` §6, §9).

## Scope

- Decode `GET /v1/captures`, tolerating unknown states and reasons (keeping the raw code). A 404
  means "capture state unavailable from this reader".
- Replace every event-guessed "Recording" with the snapshot: nothing reads "Recording" unless
  `state == recording`. Show readable reasons and the retry time.
- Show each workspace's chat-link state.
- Ask Agent is gated on the selected workspace's own capture and binding, and sends its
  `binding_generation`, so two workspaces' questions reach only their own chats.
- Refresh on the existing triggers only.

## Non-goals

- The chat console.
- Any daemon change.
- `binding_slots` UI (chat slots used / limit).
- Polling, or a faster refresh.
- Benchmarks.

## Decisions

- **Snapshot, not inference.** Capture state comes only from `/v1/captures`. Events still drive the
  feed and live runtime readiness, but never set capture state. The footer stops saying "Live" and
  "Recording ended"; the resume marker becomes "Capture restarting".
- **Refresh-driven freshness.** With no polling, a waiting workspace flips to "Recording" on the next
  existing refresh trigger, not by itself. The CAPTURE row shows "Checked HH:mm:ss" so a snapshot is
  never presented as continuous observation. This is how the brief's "waiting 17th workspace then
  flips to recording" criterion is met and tested.
- **Picker is the union** of sessions and captures, joined by session id, so a waiting or queued
  workspace with no history yet is visible and selectable.
- **One status strip** under the feed header, two rows (CAPTURE, CHAT). Picker rows get a short
  suffix; full reasons appear after selecting.
- **Ask gate:** capture `recording` + binding `connected` + live runtime readiness. The composer is
  pinned to its workspace and binding generation.

## Design deliverables

- Screens: [screens.md](./screens.md)
- Endpoints: [endpoints.md](./endpoints.md)
- Models: [models.md](./models.md)
