# S1 validation and integration status

This slice selects visible source lines and queues a question. It does not display
answers or establish delivery support. The daemon owns agent identity and routing.

## Authority

- Client base: `facdb953fd9b0b5aa7f822b9a2adf9c724b63adb` (`origin/develop`).
- Shipped D1 contract: daemon `1434899ad21e8f471da65fbe034c9a25ffc18b4b`
  (PRs #33/#34), including the request byte-cap fix.
- All five files in `design/features/ask-agent/` match the owner export byte for
  byte, including all four PNGs and `pen-nodes.json`.
- `pen-nodes.json` SHA-256:
  `e496ba623baa91f6c8b83168d220af84557bf4d1581d8f788a88c041a7883a91`.

## Contract trace

The viewer resolves its question socket through `DescriptorDiscovery.storeURL`,
using the same `SLIPSTREAM_STORE` and home resolution as reader discovery. It
sends one bounded NDJSON `v:1, verb:"ask"` request to `<store>/control.sock`.
There is no fallback to a second store or HTTP write endpoint.

A rendered block's original line IDs and its file event produce `session_id`,
`change_seq`, `path`, `snapshot_sha256`, `line_start`, and `line_end`. The app
never sends display-normalized source or a guessed harness identity. D1
`normalizeAsk` / `readQuestionContext` / `selectSource` validate the historical
snapshot and derive source text, including BOM, tabs, CRLF and trailing-LF rules.

`QuestionAcknowledgment.decode` requires the shipped success envelope and matching
capture/request IDs before closing. Request IDs are lowercase UUIDs. Unchanged
retries reuse the frozen request. Text edits create a separate intent; the model
retains uncertainty about earlier attempts. Transport failures before sending are
unavailable; after sending they are unknown. `STORAGE_UNAVAILABLE` is also treated
as potentially committed, matching the daemon CLI. Capture-connection state is
never repurposed for composer failures. A native accessible alert presents the
failure while retaining the draft and context.

The two question event names decode as `recordedWithoutRow`; the existing event
follower still advances replay state. No speculative dispatch payload is decoded.

## Local evidence

- `swift test`: 119 tests passed, including in-process Unix sockets, split frames
  and UTF-8, caps, malformed replies, response deadline, cancellation, unavailable
  socket, socket permissions, exact acknowledgment matching, and existing core suites.
- `xcodegen generate`, then `xcodebuild test -scheme SlipstreamViewer
  -destination 'platform=macOS' -derivedDataPath .context/DerivedData`: 73 app tests passed, including existing feed tests. Build uses warnings as errors.
- Model coverage includes presets/append/inline Add, persistence failures and load
  ordering, retry identity, duplicate activation, late callbacks, frozen context
  through eviction/session switches, rowless sequence advancement, reverse drag,
  excluded/disjoint source, placement at viewport edges, scrolling and resizing.
- A disposable copy of D1 ran through `npm run qa:daemon`, with its QA attach set
  to a synthetic Codex identity for queue testing. Only the QA harness was adapted:
  its token print/persistence fields were redacted. Production daemon code remained
  at the shipped commit. No real agent was claimed by this fixture.
- The Swift transport submitted a real `user.ts` change, then retried the same ID.
  D1 returned the same question ID/timestamps with `duplicate:true`. Public events
  confirmed that selected tabs and CRLF were preserved.
- A separate AppKit QA harness loaded the real stream, invoked the native source
  drag adapter on lines 7–9, rendered the composer, and sent through the live
  QuestionClient. Exact D1 acknowledgment closed the composer. The harness is an
  opt-in local artifact, not an external-service unit fixture.
- AppKit captures are under `.context/qa/`: `modal-closed.png`, `modal-open.png`,
  `live-closed.png`, `live-open.png`, `live-inline-add.png`, `live-resized.png`,
  `live-scrolled.png`, and `live-queued.png`. In-app caching avoids screen-recording
  permission. OS-wide event injection is unavailable on this host; native adapter
  events were exercised directly inside the isolated QA window.

## Visual comparison

The closed/open panels measure 640 × 397 and 640 × 534 logical points. The modal,
editor, controls, menu, selection and connector use literal node colors, dimensions,
strokes, padding and font weights. The new title and saved-question label use 550;
the send label uses 600; normal text uses 400. The previous feed-title weight
exception was not reused. The editor uses 20-point Geist with a 30-point line
height. At constrained heights the composer scrolls within the viewport.

The AppKit bitmap text appears heavier than the supplied Pen PNGs despite these
font settings. This remains a visual review item; pixel-identical typography is
not claimed. The supplied full-screen backdrop includes an unimplemented file
viewer; this slice implements the approved stream-selection entry point only.
No disappearance of a feed card was observed during these checks; the separately
reported intermittent bug is not claimed fixed.

## Cross-model review

Claude Opus completed a retrospective architecture consultation, correctness review
(PASS for a draft), then separate concurrent challenge and Excess Audit passes.
The combined fixes add explicit uncertain-dismissal confirmation, queue feedback,
visible-source connector handling and accurate errors, and remove redundant state
and validation. Five additional model regressions pass. See
[review-disposition.md](review-disposition.md) for every audit disposition.
Final review of the committed fix wave is pending.

## Required before merge

- D2 must merge first. Trace its actual attach readiness/errors and dispatch event
  through the client; then verify real Codex terminal and Conductor delivery and
  cumulative daemon QA. At the last check, daemon `origin/develop` was still D1.
- Review the noted typography difference and repeat the native UI interaction check
  with ordinary mouse/keyboard input on an authorized desktop.
- Brian owns merging and release. Claude terminal/Conductor routing is a separately
  blocked follow-up. Four-path delivery and an ask-and-answer UI are not complete.
