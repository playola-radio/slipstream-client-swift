# Claude review disposition

Claude returned after the owner-authorized implementation pause. Opus reviewed
commit `3c72d32` against `origin/develop`: retrospective architecture consultation,
correctness (PASS for a draft), then separate concurrent challenge and Excess
Audit passes. All four reports are preserved in `.context/reviews/` locally.
The combined fix wave is summarized below; final re-review is recorded in
`validation.md`.

## Correctness, architecture and challenge

- Dismissal during or after an uncertain send now requires explicit confirmation.
  The warning explains that dismissal does not withdraw a queued question and
  discards its retry identity. Keeping the composer retains draft/context/request
  ID. This resolves the silent-discard issue while preserving A2's Close/Cancel/
  Escape actions and the brief's exclusion of persistent chat.
- A matching acknowledgment closes the composer and reports “Question queued
  (delivery not confirmed)” in the existing footer. Capture health is unchanged.
- Saved-question failures have their own alert titles. Corrupt data remains intact;
  defaults still work and Add is disabled with an accurate explanation. A6 excludes
  editing/deleting saved questions; automatic reset would silently delete data.
- Unavailable-service text now calls for attaching through the shared daemon;
  it no longer suggests that a running standalone reader can accept questions.
  Generic rejection wording does not falsely attribute local validation to a server.
- Invalid-context guidance includes both D1 limits: 200 lines and 16 KiB. A drag
  beyond 200 lines still produces no selection, as required by the brief's invalid-
  range guard; a dedicated over-limit feedback state remains a minor UX limitation.
- The connector uses the visible feed rectangle and hides when its source block
  disappears, without discarding the draft. Nonobservable geometry storage avoids
  rebuilding every code block on scroll; unchanged drag selections are deduplicated.
  Pinned-heading occlusion and actual desktop input remain part of native UI QA.
- Single-row pointer selection is retained for A2's “one or more lines.” Keyboard
  selection, text-copy menus and future input features are outside this slice.
- UUID acknowledgment validation follows the shipped D1 schema, verified directly
  by Claude against `questions.ts`; the brief makes shipped implementation authoritative.
- Partial-write errors remain outcome-unknown, matching the brief's required
  `control-client.ts` semantics rather than inventing a second retry policy.

## Excess Audit: each finding

- C1: Removed the stored active flag; activity derives from the operation generation
  explicitly required by the brief's child-model lifecycle contract.
- C2: Removed duplicate acknowledgment identity checks from the model; transport owns them.
- C3: Retained the encoded-byte cap required by the bounded-transport brief. Validation
  bounds trimmed text, while encoding preserves raw whitespace, so this branch is
  reachable. The byte-limit regression now covers that case.
- C4: Removed the unreachable `DAEMON_UNAVAILABLE` wire-code branch.
- C5: Removed the UserDefaults read-back check; it cannot prove durable persistence.
- C6: Retained `canSubmit` context validation to enforce “empty or invalid ranges never
  submit,” including injected clients and programmatic model construction.
- C7: Retained local range/text/identity preflight for the same invalid-input requirement
  and D1 byte limits. Display wording no longer claims every rejection came from a daemon.
- C8: Retained the typed D1 acknowledgment and checks for the brief's “exact successful
  queue acknowledgment” and malformed-response requirement; live retry QA consumes IDs,
  timestamps and duplicate state. JS-safe line endpoints remain necessary: a 200-line
  span does not constrain its absolute line numbers.
- C9: Removed the one-caller `selectedLines` helper and inlined the identity guard.
- C10: Removed configurable connect timeout and public store access; response timeout
  remains configurable for the required bounded-deadline transport test.
- C11: Retained blank-line handling to match the explicitly required D1 control-client
  framing behavior.
- C12: Retained the pre-await composer identity guard: the view's queued Task can begin
  after the composer was replaced. A3/A4 require stale actions not to send a new question.
- S1: Retained the reserved dispatch event name because the owner brief explicitly
  requires rowless recognition without inventing a D2 payload.
- S2: Retained side placements for the brief's explicit both-sides/edges viewport checks.
- T1: Retained eviction coverage: A3 requires the parent to preserve the composer through
  cache eviction, not merely preserve an immutable field on a retained local reference.
- T2: Retained core decoding and model replay coverage: the brief separately requires
  rowless decoding and durable sequence advancement without feed rows.
- T3: Retained the specified error matrix: the brief explicitly names unavailable,
  inactive session, invalid context, queue full, storage failure, conflict and unknown
  outcomes as draft-preservation requirements.
- T4: Reduced generic rejection decoding to one representative wire code.
