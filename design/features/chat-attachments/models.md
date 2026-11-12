# Chat attachments — Model changes

Nothing new is persisted. There are no daemon, store or schema changes. Attachments are files
under the existing attachments folder, and the message text is the only record of which files a
message carries. The "Lives in" column says where each type is.

| Change | Model | Lives in | Summary |
|---|---|---|---|
| Changed | `AttachmentMarker` | `SlipstreamCore` | Splits any text into text and attachment segments, instead of parsing one marker at the end |
| Changed | `AttachmentClient` | `SlipstreamViewer/Dependencies` | Adds copying a file (async, off the main actor); `write` takes `Data` |
| New | `IncomingAttachment` | `SlipstreamViewer/Models` | One dropped or pasted thing, read off the pasteboard by the editor |
| New | `TokenTextView` | `SlipstreamViewer/Views/Reusable Components` | The AppKit text view that draws markers as tokens: editable in the message box, read-only in the sent bubble |
| Changed | `ChatTabModel` | `SlipstreamViewer/Views/Pages/ChatPage` | Attaches incoming items into the draft; renders segments; attach error |
| Changed | `ChatPageModel` | `SlipstreamViewer/Views/Pages/ChatPage` | Owns the message box's drop highlight; forwards attaching to the selected tab |
| Changed | `PRStatusBarModel` | `SlipstreamViewer/Views/Pages/ChangeStreamPage` | Passes `Data` to `AttachmentClient.write` |

## AttachmentMarker — Changed

The marker grammar is unchanged: `@⟦name⟧(path)`, where `name` has no `⟦`, `⟧` or newline, and
`path` is the percent-encoded absolute path (allowed set unchanged), with no parentheses or
whitespace, that decodes to a string starting with `/`.

| Member | Change | Notes |
|---|---|---|
| `format(name:path:) -> String` | Unchanged | Callers guarantee `name` has no `⟦`, `⟧` or newline (see `AttachmentClient.copy`). |
| `segments(_ text: String) -> [Segment]` | Added | Scans the marker pattern's matches left to right. Every well-formed marker anywhere in `text` becomes `.attachment`; the text between them becomes `.text`, kept verbatim, with empty runs dropped. A marker is well-formed only if its path decodes to an absolute path and re-formatting its name and decoded path reproduces it exactly; anything else stays inside the surrounding `.text`. |
| `text(_ segments: [Segment]) -> String` | Added | The inverse: `.text` verbatim, `.attachment` as `format(name:path:)`. `text(segments(s)) == s` for every `s`. |
| `Segment` | Added | `enum Segment: Equatable, Sendable { case text(String); case attachment(name: String, path: String) }` |
| `Segment.isImage: Bool` | Added | True for an `.attachment` whose path extension's `UTType` conforms to `.image`; picks the token's icon. |
| `parse(_:) -> Parsed?`, `Parsed` | Removed | Its only callers (`ChatTabModel.attachment(for:)` and its test) move to `segments`. A message with one marker at the end segments to `[.text(body + " "), .attachment]`, so PR bar messages still render. |

- **Source of truth:** the message text. Draft, sent message, and reloaded transcript all carry the
  same marker string, so tokens survive relaunch and history reload with no extra state.

## AttachmentClient — Changed

| Member | Change | Notes |
|---|---|---|
| `write(_ name: String, _ data: Data) throws -> URL` | Changed (was `String` contents) | Writes `data` to `<base>/<new UUID>/<name>`. The PR bar passes `Data(contents.utf8)`; pasted images pass PNG bytes. |
| `copy(_ file: URL) async throws -> URL` | Added | Copies a regular file to `<base>/<new UUID>/<name>` and returns the copy, where `name` is the file's last path component with any `⟦`, `⟧` or newline replaced by `_`. A folder (or package; `isDirectoryKey` covers both) throws `AttachmentError.folder(path)` before anything is created. On any failure the new UUID folder is removed and the underlying error is rethrown, full text shown to the user. |
| `open(_:)` | Unchanged | |

`base` stays `~/Library/Application Support/Slipstream/attachments/`. A fresh UUID folder per file
means two `image.png`s never collide and each keeps its original name. Nothing is ever deleted
(same as today): old transcripts point at these files, so deleting them would break reopened chats.
The live `copy` is `nonisolated` and does its file work off the main actor; a same-volume copy is
an APFS clone, so it is near-instant whatever the size. `write` stays synchronous: its bytes are
already in memory, so it takes milliseconds. The app is not sandboxed, so dropped URLs
need no security-scoped access.

## IncomingAttachment — New

What the editor hands the model after reading a drop or paste. The editor only reads the
pasteboard; the model decides what to do with each item.

| Case | Payload | Comes from |
|---|---|---|
| `file(URL)` | a local file URL | Finder drag, Finder ⌘C then ⌘V, or a file promise (Messages, Photos): the editor receives promises with `NSFilePromiseReceiver` into a fresh temporary folder and hands over the received URLs |
| `image(Data)` | PNG bytes | an image on the pasteboard with no file behind it (screenshot to clipboard, Safari "Copy Image") |
| `unavailable(name: String, detail: String)` | the promised file's name and the full error | a file promise its source app failed to deliver; the model shows it as an attach error and attaches nothing for it |

Pasteboard precedence, in the editor: file URLs or file promises → `file`; otherwise image data with
no plain string → `image`; otherwise the normal text paste/drop. Only the first two highlight the box
and show the copy cursor. Items keep pasteboard order.

A dropped folder arrives as `file(URL)`; the model refuses it with an attach error naming the
path (folders aren't attachments).

## ChatTabModel — Changed

| Member | Change | Notes |
|---|---|---|
| `draft: String` | Unchanged type | Now may contain markers. The editor shows each marker as a token and edits around it. |
| `AttachError` | Added | `struct AttachError: Equatable { var name: String; var detail: String }`: the item's file name (`image.png` for a pasted image) and its full error text. |
| `attachError: AttachError?` | Added | The first failure of the last attach, shown above the draft. |
| `attachmentsArrived(_ items: [IncomingAttachment], at offset: Int) async` | Added | Copies/writes each item in order through `AttachmentClient` (images are named `image.png`, as in Conductor), then inserts the successes' markers, space-separated, into `draft` at `offset`. `offset` is a UTF-16 offset into `draft` (not into the editor's storage): the editor computes it as `AttachmentMarker.text(segments before the caret).utf16.count`. The model clamps it to `draft`'s length, to a character boundary and out of any marker it lands inside, since the user may have typed while copying. `attachError` is set to the first failure; the other items still attach. |
| `attachErrorDismissed()` | Added | Clears `attachError`. |
| `attachmentSegments(for item: TranscriptItem) -> [AttachmentMarker.Segment]?` | Replaces `attachment(for:)` | `AttachmentMarker.segments(rowText(for: item))` for a user message containing at least one marker; `nil` otherwise, so the bubble keeps today's plain text. Old one-end-marker messages keep their text, plus the space before the token. |
| `attachmentTapped(path: String)` | Replaces `attachmentTapped(_ item:)` | Opens that token's file; failures keep today's alert. |
| `send()` | Unchanged | A draft of markers only is non-empty after trimming, so it already sends. |

## ChatPageModel — Changed

| Member | Change | Notes |
|---|---|---|
| `isDropTargeted: Bool` | Added | Drives the message box's drop-target look. It lives on the page because the window has one message box; a tab switch mid-drag can't strand it. |
| `dropTargetChanged(_ isTargeted: Bool)` | Added | User action from the editor. |
| `placeholderText` | Now computed | `"Drop to attach"` while `isDropTargeted`, otherwise today's text. |
| `attachErrorTitle: String?`, `attachErrorDetail: String?` | Added | From the selected tab's `attachError`: `"Couldn't attach <name>"` and the full error text (`Hvvd6`). |
| `attachErrorDismissed()` | Added | Pass-through to the selected tab, like `draft`. |
| `attachmentsArrived(_:at:tabID:) async` | Added | Passes through to the tab the items were dropped in (`tabID`, captured by the view at drop time), so a file promise that arrives after a tab switch still lands in its own chat. |
| `attachErrorDismissText` | Added | `"Dismiss"`, the × accessibility label. |

## TokenTextView — New

An `NSViewRepresentable` around an `NSTextView`, built from the existing `QuestionEditor` in
`AskAgentPageView`. Each `.attachment` segment is one character holding an `NSTextAttachment` subclass
that stores its segment, drawn by one attachment cell as the two-cell token (`DesignTokens.Chat.Attachment`; long
names truncate in the middle, and the tooltip shows the full path). It has no logic of its own: it
turns segments into storage, turns storage back into segments (each token character yields its
attachment's segment), and forwards edits, drops, pastes and token clicks to the model.

- **Editable (message box):** `textDidChange` sends `AttachmentMarker.text(storage segments)` as
  the draft. `updateNSView` rebuilds storage only when the draft differs from that text (send,
  attach), as `QuestionEditor` does today. Backspace and undo treat a token as one character.
  Copy, cut and dragging write the selection as marker text (the attachment subclass doesn't survive
  the rich-text pasteboard), and pasting or dropping text that contains markers inserts them as
  tokens, so cut-then-paste and dragging a token within the box keep it whole.
- **Read-only (sent bubble):** selectable, sized to its text, replacing today's `Text` plus chip.
  Copy writes the canonical marker text.

## PRStatusBarModel — Changed

Only the call site: `try attachments.write(name, Data(contents.utf8))`. Messages still end in one
marker, which now renders as an inline token.
