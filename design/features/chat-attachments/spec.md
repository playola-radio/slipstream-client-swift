# Chat attachments

Drag files in from Finder, or paste or drag in images from anywhere (Messages, Safari, the
clipboard), and they ride along with the chat message as small badges the agent can open.

## Why

From Brian, 2026-11-12: "I wanted to drag in an image for it to analyze -- a screenshot of
something I wanted." Then: "I'd like that for all files dragged in from finder and I'd like to be
able to copy an image to the clipboard and paste it in or drag it in from texts, etc and have it
show a similar little badge." The badge is the existing file chip from the PR status bar
(`design/features/pr-status-bar`).

## Base commits

| Repo | Branch | SHA |
|---|---|---|
| Client `playola-radio/slipstream-client-swift` | `develop` | `17583f1` (17583f152cd09196f6c49cced438520e59fd2fc6) |
| Daemon `playola-radio/slipstream` | not touched | — |

## Target surfaces

- `client`: the macOS app (`SlipstreamViewer`) and `SlipstreamCore`. No daemon change.

## What Conductor does (evidence)

From Conductor's local database (`conductor.db`, table `attachments`), 2026-11-12:

- Dropped and pasted files are **copied** into an attachments folder (`.context/attachments/…`)
  and keep their original name (`Screenshot 2026-05-18 at 11.41.21 AM.png`, `IMG_5870.PNG`).
- The message text carries one `@⟦name⟧(…)` marker per file, several per message, wherever the
  user put them, e.g. `…pops up from the bottom: @⟦IMG_5862 2.PNG⟧(…) @⟦IMG_5863 2.PNG⟧(…)`.

## Scope

1. **Ways to attach.** Drag files from Finder onto the message box; paste (⌘V) an image or a copied
   Finder file; drag an image in from another app (Messages, Safari, Preview). Plain text pastes
   stay text.
2. **Drop target.** The message box only (as in Conductor). While a drag is over it the box
   highlights and reads "Drop to attach"; the pointer shows macOS's green + copy badge, which the
   system draws for a copy drop.
3. **Inline tokens** (Brian, 2026-11-12, from Conductor screenshots): an attachment lands in the
   draft at the caret as a two-cell token (kind icon | file name) that flows with the text. It
   has no ×; backspacing over it deletes it like a character. Any number per message.
4. **Copies, not references** (Claude's call, matching Conductor): every attachment is copied into
   the existing attachments folder (`~/Library/Application Support/Slipstream/attachments/<uuid>/`)
   under its original name; images with no file behind them are saved as `image.png`. The agent and the
   badge always see the file as it was when attached.
5. **Sending.** Each attachment becomes an `@⟦name⟧(path)` marker in the message text, so the
   agent opens it with its normal file reading (which sees images) and a reloaded transcript still
   shows the badges. A message may be attachments only, with no text.
6. **Sent bubble.** The message as written, with each attachment as the same two-cell token at
   the place it was in the text; clicking a token opens the file (today's end-of-message chip
   becomes an inline token, and PR-bar messages render the same way).
7. **Errors.** If a file can't be copied or an image can't be saved, the message box shows the
   full error text above the draft, with an × to dismiss it.

## Acceptance criteria

Model and core tests (Swift Testing, no real files except in `AttachmentClient`'s own tests):

1. `AttachmentMarker.segments` handles no markers, one at the end (today's PR-bar shape), several
   (including adjacent ones), a marker mid-text, markers only, and malformed or truncated markers
   (which stay text). `text(segments(s)) == s` for all of them, plus emoji and multi-line text.
   Names and paths with spaces, `%`, `#`, `(`, `)` and Unicode round-trip through `format` and
   `segments`.
2. `attachmentsArrived` inserts markers in item order at the given offset, clamps an offset past
   the end or inside a character, and keeps the rest of the draft byte-for-byte. A failed item sets
   `attachError` to its name and the error's full text (shown as "Couldn't attach <name>" over the
   full text), the other items still attach, and `attachErrorDismissed`
   clears it. A pasted image is written as `image.png`.
3. `AttachmentClient.copy` refuses a folder without creating anything, replaces `⟦`, `⟧` and
   newlines in the name, and removes its UUID folder when the copy fails.
4. A draft that is only markers sends, and the user message written to the agent carries the
   markers unchanged.
5. `attachmentSegments(for:)` returns segments for user messages with markers (including old
   one-end-marker messages) and `nil` for every other row. `attachmentTapped(path:)` opens that path, and a missing file
   sets today's alert.
6. The PR status bar's existing tests pass with `write` taking `Data`, and its messages still end
   in one marker.
7. The full existing ChatPage, PRStatusBar and SlipstreamCore suites pass (shared behavior
   changes).

Manual gate, recorded in the PR (AppKit drag and paste can't be faked in model tests):

8. Each way to attach puts a token at the caret: Finder drag, Finder ⌘C then ⌘V, a clipboard
   screenshot (⌘⌃⇧4), a Safari image drag, and a Messages image drag. A plain-text paste or drag
   stays text and doesn't highlight the box.
9. Backspace deletes a token whole; typing, undo, and dragging a token within the box keep the
   draft's markers intact.
10. Sent with Claude: the agent reads a dropped screenshot and a dropped file whose name has
    spaces and parentheses. Reopening the tab shows the same tokens.

## Non-goals

- Inline image previews or thumbnails in the chat.
- Sending images to Claude as inline image blocks.
- An attach button / file picker (drag and paste only).
- Any daemon change.

## Open questions

- None.

## Design deliverables
- Screens: [screens.md](./screens.md)
- Endpoints: none — client-only; the daemon's wire contract is unchanged
- Models: [models.md](./models.md)

## Adversarial review (Codex, 2026-11-12)

Codex (`gpt-5.6-sol`, read-only, grounded in the code) reviewed spec, screens and models. It said
"implementation should not start" until five contracts were settled. All five are settled below.
Dispositions:

**Blocking items Codex named, all resolved:**
- **Editor ↔ draft sync** (an `NSTextAttachment` is one character, a marker is many; copying
  `QuestionEditor` as is would replace markers with `U+FFFC`). *Resolved:* `TokenTextView` in
  models.md. Each token character carries its segment, and the draft is always
  `AttachmentMarker.text(storage segments)`. The drop offset is computed in draft coordinates and
  clamped by the model. Round-trip criteria 1 and 2.
- **Does Claude read percent-encoded paths?** *Resolved by experiment:* `claude -p --model haiku`
  got a marker pointing at `…/Application%20Support/x/my%20note%20%281%29.txt` and read the file
  correctly 3 times out of 3. The PR status bar has shipped the same encoding. It is kept as a
  manual gate (criterion 10).
- **File promises** (Messages, Photos). *Resolved:* the editor receives them with
  `NSFilePromiseReceiver` into a fresh temporary folder, then they go through `copy` like any file.
- **Size limits and cleanup.** *Accepted with rationale:*
  - Same-volume copies are APFS clones, so they are near-instant at any size.
  - Clipboard images are already in memory.
  - Deleting attachments would break reopened chats whose transcripts point at them, the same as
    the PR bar today. No limit and no cleanup in v1.
- **Literal marker text becomes a token** (typed, or pasted from a sent bubble). *Accepted:*
  - It is a local, single-user app, and the user wrote the text.
  - Pasting a sent message's markers re-attaches the same files, which is useful.

**Other findings:**

Resolved in the design:
- **Copying on the main actor.** `copy` is async and off the main actor. (`write` stays
  synchronous after the simplicity gate: its bytes are already in memory.)
- **A failed copy leaves a half-written file.** The UUID folder is removed on failure.
- **A folder copy creates its folder first.** A folder is refused before anything is created.
- **Names containing `⟦ ⟧` or newlines break the marker.** Those characters are replaced in the
  copy's name.
- **`attachError` contradiction.** It was described as both "first" and "last" failure; it is now
  the first.
- **Pasteboard precedence was unspecified.** It is now stated in models.md, and plain text never
  highlights the box.
- **Long token names.** They truncate in the middle, with the full path in the tooltip.
- **A parser that scans "on every render" needs a defined cost.** It is a single left-to-right
  scan.
- **`rowText` trims newlines, so segments aren't verbatim.** Accepted: the bubble already shows
  trimmed text.
- **SwiftUI `Text` can't flow inline tokens.** The sent bubble uses `TokenTextView` read-only, so
  the composer and bubble draw the same token.
- **Image naming from date and time zone.** Dropped: pasted images are `image.png`, as in
  Conductor, so attaching adds no new use of `date` or `timeZone`.

Accepted with rationale:
- **Typed `AttachmentImportError` instead of the raw error text.** Brian's standing rule is to
  show full errors, never generic text.
- **Pasteboard reading belongs in a dependency.** `NSDraggingInfo` and promise receipt can't be
  faked meaningfully, so the AppKit adapter only reads and forwards; all policy is in the
  model. Covered by manual criterion 8.
- **Keep `AttachmentMarker.parse` deprecated.** It is internal to this app's package and has one
  caller, so it is removed.
- **Separate `writeText`/`writeData`.** There is one text caller and it passes
  `Data(contents.utf8)`.
- **No "importing" state, and sending during a slow copy.**
  - Copies are near-instant (APFS clone).
  - A slow cross-volume copy finishing after send lands in the next draft, visible, not lost.
- **Undo across a model-driven storage rebuild.** It only happens on send and attach, as in
  `QuestionEditor` today.
- **Old messages with marker-like text become tokens.** This is the intended migration: old
  attachment-only and multi-marker messages now render.
- **`dropTargetChanged` is ceremony.** It is kept: CLAUDE.md requires user actions as named model
  methods.
- **`attachmentTapped(path:)` takes raw data.** The path comes from the parser's segment, the
  same as today's chip.
- **Security-scoped URLs and quarantine.** The app is not sandboxed (no app entitlements).
- **Acceptance criteria were missing.** Added above.

Deferred (non-goals stay non-goals):
- Thumbnails.
- Progress UI.
- Showing missing-file tokens before they are clicked.
- VoiceOver polish beyond the token's label (its full name).

## Simplicity gate (Codex and Claude Opus, 2026-11-12)

Two independent reviewers looked at the plan for excess. Both found the overall design the right
size. Applied in one wave to the plan and models.md:

- `write` stays synchronous (it only takes `Data` now), so the PR status bar keeps its sync helper.
- The drop highlight moved from each tab to `ChatPageModel`: the window has one message box, and a
  tab switch mid-drag could have stranded the flag. `placeholderText` becomes computed instead of
  adding a second placeholder property.
- `attachmentSegments(for:)` returns `nil` for rows without markers, so the view's choice between
  plain text and tokens mirrors today's `if let attachment`.
- The image-or-file icon choice moved out of the view into `Segment.isImage` (Core).
- Tokens are an `NSTextAttachment` subclass that stores its segment, drawn by one cell; no parallel
  custom attribute and no view-provider alternative. Copy, cut and drag write marker text, which is
  what keeps cut-then-paste and in-box drags whole.
- Simpler parser (scan the regex matches, keep the canonical check); one parameterized test asserts
  both segmentation and round-trip; `isPackageKey` dropped (`isDirectoryKey` covers packages).
- Test cuts: shared `makeModel` stubs, the tab-switch test (correct by construction), the
  multi-marker pass-through test, the flag-setter test (folded into a placeholder test). The
  clamped-offset test now really types during a suspended copy.
- The `dropText` token and the Task 4 manual launch are gone (folded into the final manual gate).

Defended:
- **Read-only `TokenTextView` in the sent bubble** (vs SwiftUI `Text` with inline images): SwiftUI
  can't draw the bordered two-cell token Brian approved (`t6JCze`).
- **Attach-error banner** (vs reusing the open-file alert): approved state `Hvvd6`, spec item 7.
- **Refusing folders:** Brian asked for files; a dropped project folder would otherwise be copied
  whole without a word.

## Approvals

- 2026-11-12 — Brian approved models.md ("yes").
- 2026-11-12 — Brian approved the Chat message screen ("yes looks great"): states with-attachments
  `t6JCze`, attachment-only `u79AU6`.
- 2026-11-12 — Brian approved the Message box screen ("yes looks great"): states with-attachments
  `y7HVvN`, drop-target `WZyfo`, attach-failed `Hvvd6`.
- 2026-11-12 — Brian redirected the composer to Conductor's look: inline two-cell tokens at the
  caret, message box as the only drop zone with the green + copy cursor.
- 2026-11-12 — Brian approved the behavior playback in chat ("yes sounds good"). Copy-vs-reference
  was left open; Claude chose copies (scope item 4), flagged to Brian for override.
