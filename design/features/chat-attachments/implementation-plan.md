# Chat attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (single PR) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Before writing Swift, invoke the `pfw-*` skills CLAUDE.md lists (`pfw-observable-models`, `pfw-dependencies`, `pfw-testing`, `pfw-custom-dump`, `pfw-modern-swiftui`); subagents must too.

**Goal:** Let the user drag files and images into the chat message box, or paste them there, as inline tokens that go to the agent as `@⟦name⟧(path)` markers and show as tokens in the sent bubble.

**Architecture:** The draft stays a `String`. Markers in that string are the only record of attachments. `AttachmentMarker` gains a segment parser and its inverse. `AttachmentClient` copies dropped files off the main actor and writes pasted image bytes. `ChatTabModel` owns all attach policy. One AppKit `TokenTextView` draws markers as two-cell tokens: editable in the message box, read-only in the sent bubble. It only converts between storage and segments and forwards events.

**Tech Stack:** Swift 6 (strict concurrency, warnings as errors), SwiftUI + AppKit (`NSTextView`, `NSTextAttachment`, `NSFilePromiseReceiver`), Point-Free Dependencies, Swift Testing + CustomDump.

**Spec:** `design/features/chat-attachments/spec.md`. Contracts: [models.md](./models.md) (types and members; implement exactly these) and [screens.md](./screens.md) (states and mockups; pen nodes `y7HVvN`, `WZyfo`, `Hvvd6`, `t6JCze`, `u79AU6`). Base: client `develop` @ `17583f1`. No daemon change.

## Global Constraints

- Views contain zero logic. Every string, show/hide decision and colour is a model property or a `DesignTokens` value (CLAUDE.md).
- Visual values come from `design/features/chat-attachments/exports/json/<screen>--<state>.json` (resolved pen nodes; the file's `design-tokens.json` variables aren't used by these screens), added to `SlipstreamViewer/DesignTokens.swift`. Never hardcode a colour, font or spacing. Reuse the existing `Chat.Attachment` values wherever the export agrees.
- Copying a dropped file never runs on the main actor (`copy` is `async`, with a `nonisolated` live body). Writing pasted image bytes stays synchronous: they are already in memory.
- Errors are shown in full (`localizedDescription`, which names the path), never generic text.
- Attachments live at `~/Library/Application Support/Slipstream/attachments/<UUID>/<name>`. Nothing is deleted except a failed copy's own UUID folder.
- Pasted images are written as `image.png`.
- Tests: Swift Testing, `expectNoDifference`; model tests never touch real files or real time. Stub `attachments` per test, only in the tests that attach.
- Core: `swift test --filter <Suite>`. App: `xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:SlipstreamViewerTests/<Suite>` (run `xcodegen generate` first if files were added). The full CI command (without `-only-testing`) is the pre-commit gate for the last task.
- No `Co-Authored-By` trailers. Never edit `CHANGELOG.md`.

## Review Focus

1. **The user types while a slow copy is running.** The tokens land at a sensible spot and no typed character is lost. Test in Task 3 (`attachKeepsTypingDoneDuringCopy`).
2. **A drop's offset falls inside a multi-scalar character** (emoji or a composed accent before the caret). The insert must not split it. Test in Task 3 (`attachClampsOffsetToCharacterBoundary`).
3. **A pasted sent message contains markers.** It must turn back into tokens and keep its text unchanged. Covered by the Task 1 round-trip (`text(segments(s)) == s`) and manual check 9.
4. **A folder or app bundle is dropped.** It shows the full error and creates nothing on disk. Test in Task 2 (`copyRefusesAFolder`).
5. **Old transcripts with one end marker** (PR status bar messages) still render as text plus a token. Test in Task 4 (`oldEndMarkerSegments`).

---

### Task 1: Segment parser and its inverse

**Files:**
- Modify: `Sources/SlipstreamCore/AttachmentMarker.swift`
- Test: `Tests/SlipstreamCoreTests/AttachmentMarkerTests.swift`

**Interfaces:**
- Produces:
  - `AttachmentMarker.Segment` (`enum Segment: Equatable, Sendable { case text(String); case attachment(name: String, path: String) }`, where `path` is decoded)
  - `Segment.isImage: Bool`: true for an `.attachment` whose path extension's `UTType` conforms to `.image`
  - `static func segments(_ text: String) -> [Segment]`
  - `static func text(_ segments: [Segment]) -> String`
  - `parse`/`Parsed` stay until Task 4.

- [ ] **Step 1: Write failing tests.** One parameterized `segmentsSplitAndRoundTrip` asserts, for each `(input, expected)`, both `segments(input) == expected` and `text(segments(input)) == input`:
  - `"hi"` → `[.text("hi")]`
  - `"😀 é\nline"` → `[.text("😀 é\nline")]`
  - `"Create a PR @⟦a.md⟧(/tmp/a.md)"` → `[.text("Create a PR "), .attachment(name: "a.md", path: "/tmp/a.md")]`
  - `"@⟦a.png⟧(/tmp/a.png)"` → `[.attachment(…)]`
  - `"see @⟦a.md⟧(/tmp/a.md) and @⟦b.md⟧(/tmp/b.md)!"` → `[.text("see "), .attachment(a), .text(" and "), .attachment(b), .text("!")]`
  - `"@⟦a.md⟧(/tmp/a.md)@⟦b.md⟧(/tmp/b.md)"` → two attachments, no text
  - `"go @⟦a.md⟧(tmp/a.md)"`, `"go @⟦a.md⟧(/tmp/%zz.md)"`, `"go @⟦a.md⟧(/tmp/a.md"` and `"go @⟦a.md⟧(/tmp%2Fa.md)"` → a single `.text` of the whole input
  - `"x @⟦bad @⟦a.md⟧(/tmp/a.md)"` → `[.text("x @⟦bad "), .attachment(a)]`

  Convert `roundTripsAwkwardPaths` to assert `segments("go " + marker) == [.text("go "), .attachment(name: "f.md", path: path)]`. Add `isImageFollowsTheExtension`: `a.png` and `b.HEIC` are images; `c.md` and `.text` are not.
- [ ] **Step 2:** Run `swift test --filter AttachmentMarkerTests`. Expect a FAIL (no `segments`).
- [ ] **Step 3: Implement `segments` and `text`.** Scan the matches of `@⟦([^⟦⟧\n]+)⟧\(([^()\s]+)\)` (the same character classes as `parse`). Keep a match only if its path decodes to a string starting with `/` and `format(name:decodedPath)` reproduces the matched text exactly; that makes `text` (which maps `.attachment` through `format`) an exact inverse. Text between kept matches is emitted verbatim; empty runs are dropped.
- [ ] **Step 4:** Run `swift test --filter AttachmentMarkerTests`. Expect a PASS.
- [ ] **Step 5:** Commit `Split chat text into text and attachment segments`.

### Task 2: AttachmentClient copies files and writes bytes

**Files:**
- Modify: `SlipstreamViewer/Dependencies/AttachmentClient.swift`, `SlipstreamViewer/Views/Pages/ChangeStreamPage/PRStatusBarModel.swift:424`
- Test: `SlipstreamViewerTests/Dependencies/AttachmentClientTests.swift`, `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/PRStatusBarTests.swift:421`

**Interfaces:**
- Produces:
  - `var write: @Sendable (_ name: String, _ data: Data) throws -> URL` (was `String` contents)
  - `var copy: @Sendable (_ file: URL) async throws -> URL`
  - `AttachmentError.folder(String)`, with the message `"\(path) is a folder; only files can be attached"`
  - `testValue` stays `unimplemented` for each closure.

- [ ] **Step 1: Write failing tests** in `AttachmentClientTests`, using real temp folders as the existing tests do:
  - `writeCreatesFileUnderAFreshFolder`: now passes `Data("Do the thing".utf8)`, with the same assertions.
  - `copyKeepsTheNameUnderAFreshFolder`: the copy's bytes equal the source's, the name equals the source's last path component, and the parent is a UUID folder under `base`.
  - `copyReplacesMarkerBreakingCharacters`: a source named `"a⟦b⟧\nc.txt"` yields a copy named `"a_b__c.txt"`.
  - `copyRefusesAFolder`: throws `AttachmentError.folder(source.path)`, and `base` has no children afterwards.
  - `copyOfMissingFileCleansUp`: throws, and `base` has no children afterwards.
- [ ] **Step 2:** Run `-only-testing:SlipstreamViewerTests/AttachmentClientTests`. Expect a FAIL (no compile).
- [ ] **Step 3: Implement.**
  - `copy` checks `isDirectoryKey` (true for packages too) before creating the UUID folder, then copies with `FileManager.copyItem`, which clones on APFS. On any thrown error, remove the UUID folder and rethrow. The live closure is a `nonisolated` async function (it must not inherit `@MainActor`).
  - In `PRStatusBarModel.attach`, pass `Data(contents.utf8)`. Nothing else in the PR bar changes.
  - Update the `PRStatusBarTests` stub to decode `String(decoding: data, as: UTF8.self)` into `written`.
- [ ] **Step 4:** Run the `AttachmentClientTests` and `PRStatusBarTests` suites. Expect a PASS.
- [ ] **Step 5:** Commit `Copy dropped files into the attachments folder`.

### Task 3: Attaching into the draft (model)

**Files:**
- Create: `SlipstreamViewer/Models/IncomingAttachment.swift`
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift`, `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift`
- Test: `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift` (new `// MARK: - Attaching` extension; each test overrides `$0.attachments.copy` / `.write` itself, returning `/att/<name>`; `makeModel` is unchanged)

**Interfaces:**
- Consumes:
  - `AttachmentMarker.format` (Task 1)
  - `AttachmentClient.copy` / `write`, `AttachmentError.folder` (Task 2)
- Produces:
  - `enum IncomingAttachment: Equatable, Sendable { case file(URL); case image(Data) }`
  - On `ChatTabModel` (`@MainActor`):
    - `struct AttachError: Equatable { var name: String; var detail: String }` (nested in `ChatTabModel`)
    - `var attachError: AttachError?`
    - `func attachmentsArrived(_ items: [IncomingAttachment], at offset: Int) async`
    - `func attachErrorDismissed()`
  - On `ChatPageModel`:
    - `var isDropTargeted = false` and `func dropTargetChanged(_ isTargeted: Bool)`: the window has one message box, so the highlight lives here, not on a tab.
    - `placeholderText` becomes computed: `"Drop to attach"` while `isDropTargeted`, otherwise today's text.
    - Display text from the selected tab's `attachError`: `attachErrorTitle` (`"Couldn't attach \(name)"`) and `attachErrorDetail` (the full error), both `nil` when there is none.
    - Pass-throughs mirroring `draft`: `attachErrorDismissed()` and `attachmentsArrived(_:at:) async` forward to `selectedTab` (the optional chain fixes the receiving tab before the await).
    - `attachErrorDismissText = "Dismiss"` is the × accessibility label.

- [ ] **Step 1: Write failing tests:**
  - `attachFileInsertsMarkerAtOffset`: with draft `"look  here"`, attaching `[.file(/src/a.png)]` at offset 5 gives `"look " + format("a.png", "/att/a.png") + " here"`.
  - `attachSeveralKeepsOrderSpaceSeparated`: two files plus one image give three markers joined by `" "` in item order. The image is written as `"image.png"`.
  - `attachFailureSetsFullErrorAndKeepsOthers`: the first item (`.file(/src/dir)`) throws `AttachmentError.folder("/src/dir")`. Then `attachErrorTitle == "Couldn't attach dir"`, `attachErrorDetail == "/src/dir is a folder; only files can be attached"`, the second item's marker is inserted, and `attachErrorDismissed()` makes both `nil`.
  - `attachKeepsTypingDoneDuringCopy`: the copy stub suspends on a continuation held in `LockIsolated`; while suspended, set `draft` to `"ab"` (shorter than the offset of 5); resume. The draft is `"ab" + marker`.
  - `attachClampsOffsetToCharacterBoundary`: with draft `"é😀x"` and an offset that lands inside the emoji's UTF-16 pair, the insert goes before the emoji (round down to a `Character` boundary), and the draft's other characters are unchanged.
  - `placeholderReadsDropToAttachWhileTargeted`: `dropTargetChanged(true)` makes `placeholderText == "Drop to attach"`; `dropTargetChanged(false)` restores it.
  - `markerOnlyDraftSends`: with a draft that is just one marker, `send()` writes a user message whose text equals the marker (assert with the existing `agent.writes` / `firstMessage` helpers).
- [ ] **Step 2:** Run `-only-testing:SlipstreamViewerTests/ChatPageTests`. Expect the new tests to FAIL.
- [ ] **Step 3: Implement.**
  - For each item in order: `.file(url)` → `try await attachments.copy(url)`; `.image(data)` → `try attachments.write("image.png", data)`.
  - Format each success with the copy's `lastPathComponent` and `path`.
  - Record the first failure as `AttachError(name:detail:)`: the name is the dropped URL's `lastPathComponent` (or `"image.png"`), the detail its error's `localizedDescription` (an `AttachmentError`'s text, or a `CocoaError`'s, which names the path).
  - Then clamp `offset` to `draft.utf16.count`, convert with `String.Index(utf16Offset:in:)`, round down via `draft.rangeOfComposedCharacterSequence`, and insert the markers joined by `" "`.
- [ ] **Step 4:** Run `ChatPageTests`. Expect a PASS.
- [ ] **Step 5:** Commit `Attach dropped and pasted files into the chat draft`.

### Task 4: Tokens in the sent bubble

**Files:**
- Create: `SlipstreamViewer/Views/Reusable Components/TokenTextView.swift`
- Modify:
  - `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift:144-147,517-524`
  - `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift:321-360`
  - `SlipstreamViewer/DesignTokens.swift:1211` (`Chat.Attachment`)
  - `Sources/SlipstreamCore/AttachmentMarker.swift` (remove `parse` and `Parsed`)
- Test: `ChatPageTests.swift:3151-3178`, `AttachmentMarkerTests.swift` (drop the remaining `parse` cases; their inputs are already covered in Task 1)

**Interfaces:**
- Consumes: `AttachmentMarker.segments` / `text`, `Segment.isImage`.
- Produces:
  - `ChatTabModel`: `func attachmentSegments(for item: TranscriptItem) -> [AttachmentMarker.Segment]?` (nil unless the item is a user message containing at least one marker) and `func attachmentTapped(path: String)`. `attachment(for:)` and `attachmentTapped(_ item:)` are removed.
  - `struct TokenTextView: NSViewRepresentable`, with:
    - `init(segments: [AttachmentMarker.Segment], isEditable: Bool, onTokenTap: @escaping (String) -> Void)`
    - the editable-only inputs added in Task 5, defaulted here.
  - `DesignTokens.Chat.Attachment`: `imageIcon` (an `Icons.Icon`, like `icon`, from `y7HVvN`), `divider` colour, `maxNameWidth`.

- [ ] **Step 1: Rewrite the tests at 3151-3178:**
  - `markerRendersAsAttachment` → `oldEndMarkerSegments`: `attachmentSegments(for: markedRow())` equals `[.text("Create a PR "), .attachment(name: "PR instructions.md", path: "/tmp/x/PR instructions.md")]`.
  - `plainOrReplyRowHasNoAttachmentSegments`: a user row with no marker, and a reply row with one, both give `nil`.
  - `attachmentTapOpensFile` / `attachmentTapMissingFileShowsAlert` now call `attachmentTapped(path: "/tmp/x/PR instructions.md")`, with the same expectations.
- [ ] **Step 2:** Run `ChatPageTests`. Expect a FAIL.
- [ ] **Step 3: Implement the model members.** Remove `parse`/`Parsed`. Build `TokenTextView`:
  - Storage is built from segments. Each `.attachment` becomes one character holding a `TokenAttachment: NSTextAttachment` subclass that stores its `Segment`; storage turns back into segments by reading `.attachment` attributes.
  - One `NSTextAttachmentCell` subclass draws the token: kind icon (`imageIcon` when `segment.isImage`, else `icon`) | divider | name. The name middle-truncates at `maxNameWidth`; the tooltip is the path; the accessibility label is the name.
  - Copy (and, in Task 5, cut and drag) writes `AttachmentMarker.text(selected segments)` as plain text, because the attachment subclass doesn't survive the rich-text pasteboard.
  - Read-only mode: not editable, selectable, no scroller, sized to its text (`intrinsicContentSize` from the layout manager's used rect at the proposed width).
  - Clicking a token calls `onTokenTap(path)`.
  - In `userBubble`, replace the `attachment`/`attachmentChip` branch with `if let segments = tab.attachmentSegments(for: item)` → `TokenTextView(segments:isEditable: false, onTokenTap: tab.attachmentTapped(path:))`; otherwise today's `bubbleText`.
- [ ] **Step 4:** Run `ChatPageTests` and `swift test --filter AttachmentMarkerTests`. Expect a PASS.
- [ ] **Step 5:** Commit `Show attachments as inline tokens in sent messages`.

### Task 5: The token message box (drop, paste, errors)

**Files:**
- Modify:
  - `SlipstreamViewer/Views/Reusable Components/TokenTextView.swift`
  - `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift:83-99` (replace the `TextField`)
  - `SlipstreamViewer/DesignTokens.swift` (`Chat.MessageBox` drop-target stroke/fill; the attach-error banner, from `WZyfo` and `Hvvd6`)
- Create: `changelog.d/chat-attachments.md`
- Test: manual gate below (AppKit drag and paste can't be faked in model tests; all policy was tested in Task 3)

**Interfaces:**
- Consumes: the Task 3 `ChatPageModel` members and Task 4's `TokenTextView`.
- Produces: `TokenTextView` editable inputs:
  - `onTextChange: (String) -> Void`
  - `onSubmit: () -> Void`
  - `onDropTargetChange: (Bool) -> Void`
  - `onAttach: ([IncomingAttachment], Int) -> Void`
  - `placeholder: String`, `isEnabled: Bool`

- [ ] **Step 1: Editable mode.** Base it on `QuestionEditor`:
  - `textDidChange` sends `AttachmentMarker.text(storage segments)`. `updateNSView` rebuilds storage only when `model.draft` differs from that text.
  - Return calls `onSubmit`, and Shift-Return inserts a newline (today's behavior).
  - The placeholder (`model.placeholderText`) is drawn when the storage is empty.
- [ ] **Step 2: Drop and paste.**
  - Register file URLs, `NSFilePromiseReceiver.readableDraggedTypes`, PNG and TIFF.
  - Apply models.md's precedence once, in a helper shared by `draggingEntered`/`draggingUpdated`, `readSelection(from:type:)` and paste:
    1. File URLs → `.file`.
    2. Promises are received into `FileManager.default.temporaryDirectory/<UUID>` via `receivePromisedFiles(atDestination:options:operationQueue:)`, then become `.file`.
    3. Image data with no `.string` → `.image(PNG data)`; convert TIFF with `NSBitmapImageRep`.
    4. Anything else → `super` (a normal text drop or paste).
  - Only cases 1–3 call `onDropTargetChange(true)` and return `.copy`; exiting or ending the drag calls `onDropTargetChange(false)`.
  - Plain text whose string contains markers is inserted via `segments`, so the markers become tokens. This is also what keeps cut-then-paste and dragging a token within the box intact.
  - The offset passed to `onAttach` is `AttachmentMarker.text(segments of storage before the drop/caret point).utf16.count`.
  - The view creates `Task { await model.attachmentsArrived(items, at: offset) }`.
- [ ] **Step 3: Message box chrome.** While `model.isDropTargeted`, show the drop-target stroke and fill. When `model.attachErrorTitle` is set, show the error banner above the editor (title, then `attachErrorDetail`) with its × (`model.attachErrorDismissed()`). Match `Hvvd6`, including selectable full text.
- [ ] **Step 4: Add `changelog.d/chat-attachments.md`:**

  ```markdown
  ### Changes

  - Drag files from Finder into the chat message box, or paste or drag in images (screenshots,
    Messages, Safari). Each one shows as a small badge in your message, and the agent can open it.
  ```
- [ ] **Step 5: Manual gate.** Use a disposable daemon (`SLIPSTREAM_STORE`, `npm run qa:daemon` in the daemon repo) and record the results in the PR body (spec acceptance criteria 8–10):
  - Each way to attach puts a token at the caret: Finder drag, Finder ⌘C then ⌘V, ⌘⌃⇧4 then ⌘V, a Safari image drag, and a Messages image drag.
  - A plain-text paste or drag stays text and doesn't highlight the box.
  - Dropping a folder shows the full error, and × clears it.
  - Backspace deletes a token whole. Typing, undo, cut-then-paste, and dragging a token within the box keep the draft's markers.
  - Paste a copied sent bubble: its tokens come back.
  - A PR-bar "fix errors" message shows text plus an inline token, and clicking it opens the file.
  - Send a screenshot plus a file named `my note (1).txt`: the agent describes both. Reopen the tab: the tokens are still there.
- [ ] **Step 6:** Run `swift test`, then the full CI `xcodebuild test` command. All must pass.
- [ ] **Step 7:** Commit `Drop and paste files and images into the chat message box`.

## Unresolved questions

- None. Codex's review and the simplicity gate's dispositions are recorded in spec.md.
