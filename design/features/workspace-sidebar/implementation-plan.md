# Workspace sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. It is a single PR in `playola-radio/slipstream-client-swift`. Steps use
> checkbox (`- [ ]`) syntax for tracking. Before writing any Swift, invoke the `pfw-*` skills the
> repo's `CLAUDE.md` lists: `pfw-observable-models`, `pfw-dependencies`, `pfw-sharing`,
> `pfw-testing`, `pfw-custom-dump`, `pfw-identified-collections` and `pfw-modern-swiftui`.
> Subagents must invoke them too.

**Goal:** Replace the toolbar session picker with a Conductor-style workspace sidebar. Put the
chat in the middle and a Change stream | Terminals switch on the right.

**Architecture:**
- The sidebar is derived.
- `ChangeStreamPageModel` already owns sessions, selection and the workspace commands. It gains:
  - repo grouping, through a pure helper in `Models/`;
  - an explicit archive target;
  - the right-side pane.
- The only stored value is `@Shared(.isSidebarHidden)`.
- Each task lands its model change together with its final view code, so every commit compiles
  without throwaway UI.

**Tech Stack:**
- Swift 6 in strict mode, SwiftUI on macOS.
- swift-dependencies, swift-sharing and IdentifiedCollections.
- Swift Testing with CustomDump.
- XcodeGen.

**Spec:** `design/features/workspace-sidebar/spec.md`. The contracts are:
- `screens.md`: states, strings and navigation;
- `models.md`: the one new key, plus what is derived;
- endpoints: none.

Base commits:
- client `a419eab` (`develop`, after the terminals engine PR #48);
- daemon `b736f77c1c9728354767e708f067a8427f172567`, read only.

## Global Constraints

- **Rows.** Rows are exactly today's `pickerSessions` with the inactive toggle permanently off.
  Auto-selection, preferred-root selection and reload reconciliation do not change (spec
  Decision 4).
- **Grouping.**
  - A row groups under `<repo>` only when its normalized root is exactly
    `<root>/<repo>/<name>`, matched by path components. `<root>` is the managed workspaces root
    or `$HOME/conductor/workspaces`.
  - Same-name groups merge.
  - Every other folder is its own group.
  - A nil root shows the session's `label` (Decision 3).
- **Status.** Bold = `chat.isWaiting(folder:)`. Spinner = `chat.hasWorkingTab(in:)`. There is no
  dot and no capture-state suffix.
- **Widths.**
  - sidebar `260`;
  - stream at least `680` (`DesignTokens.FeedPane.width`);
  - chat `720`, shrinking to `420`;
  - window minimum = the sum of the shown columns' minimums: `1360` with the sidebar, `1100`
    without.
- **Copy.** Strings are copied verbatim from `screens.md` → "Strings":
  - "Workspaces", "Add repository…", "Change stream", "Terminals";
  - "Terminals are coming in a later update";
  - `"<repo>  ›  <workspace>"` with two spaces each side of `›`, or "Slipstream";
  - "New workspace", "Archive workspace", "Hide sidebar" and "Show sidebar".
- **Design values.**
  - Colours, fonts and spacing come only from new `DesignTokens` enums. Their values are copied
    from `design/features/workspace-sidebar/exports/`:
    - `ws-sidebar-component.json` for the sidebar;
    - `workspace-window--row-hover.json` for the hover row;
    - `workspace-window--terminals-placeholder.json` for the switch and the placeholder.
  - The `.html` exports give the same values as CSS.
  - Views never hardcode one.
  - The archive glyph is lucide `archive`. Add it as an asset beside the existing lucide icons
    in `DesignTokens.Icons`.
- **Daemon.** No daemon change. No new workspace command.
- **Safety.** Never point the app at the real `~/.slipstream`. Run against `npm run qa:daemon`
  with `SLIPSTREAM_STORE`.
- **Build gates.** Warnings are errors. Run `xcodegen generate` after adding files.

Verification command (from the repo root):

```
xcodegen generate && xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS'
```

Add `-only-testing:SlipstreamViewerTests/<Suite>` or `…/<Suite>/<test>` to narrow it.

## Review Focus

1. **The reply popover after the stream moves right.**
   - `ReplyPlacement` opens the popover to the right of the question bar
     (`ReplyPlacement.swift:12`). With the stream as the rightmost column, it would pin to the
     window edge, over its own bar.
   - Expected: it opens to the left, over the chat, with its connector. That is the mirror of
     today. Task 4 pins it.
2. **Narrow windows and screens.** The chat must never go under 420pt or the stream under 680pt.
   Hiding the sidebar keeps the chat's width, and the stream takes the space. Showing the sidebar
   in a narrow window widens the window, capped at the screen. Task 5 tests the width rule; the
   cap is a manual check.
3. **Workspace roots not loaded yet.** Rows still show, each in its own group, and regroup when
   the roots arrive. The selection does not change. Tasks 1 and 2 pin it.
4. **Archiving a row other than the selected one, or while a reload runs.**
   - The target is the row clicked. The selection survives.
   - A refused archive gives back that row's tabs and drafts, even though they were never on
     screen. Task 3 pins it.
5. **Switching to Terminals mid-follow and back.** Watching continues, returning lands on the
   latest change, and connectors don't draw over the placeholder. Task 4 pins it.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `SlipstreamViewer/Models/WorkspaceSidebar.swift` | Create | `WorkspaceRoots`, `SidebarGroup` with its grouping function, and the `.isSidebarHidden` key |
| `SlipstreamViewerTests/Models/WorkspaceSidebarTests.swift` | Create | Path and grouping rules |
| `SlipstreamViewer/Dependencies/WorkspaceClient.swift` | Modify | `managedRoot` becomes `roots`, both roots from one login environment |
| `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift` | Modify | Sidebar state and actions, archive target, right pane, widths; picker, toggle and Hide feed removed |
| `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift` | Modify | Three columns, toolbar, right-pane switch, placeholder |
| `SlipstreamViewer/Views/Pages/ChangeStreamPage/WorkspaceSidebarView.swift` | Create | The sidebar column, visuals only |
| `SlipstreamViewer/Views/Pages/ChatPage/ChatPageModel.swift` | Modify | `restoreTabs` recreates tab models that `stopTabs` removed |
| `SlipstreamViewer/Views/Pages/ChatPage/ChatPageView.swift` | Modify | Drop the `leading` slot (Show feed was its only user); un-`private` `SpinnerView` |
| `SlipstreamViewer/Views/Pages/QuestionThreadPage/ReplyPlacement.swift` | Modify | Open the popover to the left of the bar |
| `SlipstreamViewer/Models/CaptureStatus.swift` | Modify | Delete `pickerSuffix`; the menu was its only reader |
| `SlipstreamViewer/DesignTokens.swift` | Modify | Add `Sidebar`, `RightPane` and `Workspace`; delete the Hide/Show-feed and `StreamPicker` tokens |
| `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift` | Modify | New tests; rewrite or remove the picker, toggle and Hide-feed tests |
| `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift` | Modify | `restoreTabs` regression |
| `SlipstreamViewerTests/Models/CaptureStatusTests.swift` | Modify | Remove the `pickerSuffix` tests (lines 77 and 125–135) |

---

### Task 1: Workspace roots and repo grouping

**Files:**
- Create: `SlipstreamViewer/Models/WorkspaceSidebar.swift`
- Create: `SlipstreamViewerTests/Models/WorkspaceSidebarTests.swift`
- Modify: `SlipstreamViewer/Dependencies/WorkspaceClient.swift`
- Modify: `ChangeStreamPageModel.swift`, `ChangeStreamPageTests.swift` (the client rename only)

**Interfaces:**
- Produces:

  ```swift
  /// Where `slipstream workspace create` and Conductor put workspaces, as normalized path components.
  struct WorkspaceRoots: Equatable, Sendable {
    var managed: String
    var conductor: String
    init(managed: URL, conductor: URL)               // normalizes once, with ChangeStreamPageModel.normalizedFolder
    func repository(of folder: String) -> String?    // "<repo>" iff folder is exactly <root>/<repo>/<name> under either root
    func isArchivable(_ folder: String) -> Bool       // ManagedWorkspacePath.contains(folder, root: managed)
  }

  struct SidebarGroup: Identifiable, Equatable, Sendable {
    var repository: String?                // nil: a folder or session on its own
    var rows: [SessionOption]
    var id: String { repository ?? rows[0].id }
    var newWorkspaceFolder: String? { rows.first?.root }   // spec Decision 8

    static func groups(_ sessions: some Sequence<SessionOption>, roots: WorkspaceRoots?) -> [SidebarGroup]
    static func rowName(_ session: SessionOption) -> String   // last component of root, else label
    var name: String { repository ?? Self.rowName(rows[0]) }
  }

  extension SharedKey where Self == AppStorageKey<Bool>.Default {
    static var isSidebarHidden: Self   // verbatim from models.md
  }
  ```

- The client's `managedRoot: @Sendable () async -> URL` is replaced by
  `roots: @Sendable () async -> WorkspaceRoots`.
  - **Live:** one `AgentEnvironmentClient.loginEnvironment()` call. It builds `managedRoot(environment:)`
    and `HOME/conductor/workspaces`.
  - **`testValue`:** `/tmp/slipstream-test/workspaces` and `/tmp/conductor-test/workspaces`.
- Ordering:
  - groups appear in the order of their first row;
  - rows keep input order inside a group.
- With `roots == nil`, every session is its own group.

- [ ] **Step 1: Write the failing tests** in `WorkspaceSidebarTests`.
  - Use `WorkspaceRoots(managed: URL(filePath: "/u/slipstream/workspaces"), conductor: URL(filePath: "/u/conductor/workspaces"))`.
  - Use `expectNoDifference` on `groups(…).map { [$0.name] + $0.rows.map(SidebarGroup.rowName) }`.
  - The tests:
    - **`sameRepoUnderBothRootsSharesOneGroup`**
      - Roots `/u/slipstream/workspaces/playola/workspace-9` and
        `/u/conductor/workspaces/playola/lisbon-v2`.
      - Expect `[["playola", "workspace-9", "lisbon-v2"]]`.
      - The group's `newWorkspaceFolder` is the first root.
    - **`aFolderOutsideTheRootsIsItsOwnGroup`**: `/a/b/c` → `[["c", "c"]]`, with
      `repository == nil`.
    - **`onlyExactlyRepoSlashNameGroups`**
      - `/u/slipstream/workspaces/r`, `/u/conductor/workspaces/r/w/deeper` and
        `/u/slipstream/workspaces-old/r/w` → three standalone groups.
      - The last shows the match is by component, not by string prefix.
    - **`aSessionWithoutARootShowsItsLabel`**
      - `SessionOption(id: "s1", label: "Today 10:02")` → `[["Today 10:02", "Today 10:02"]]`.
      - `newWorkspaceFolder == nil`.
    - **`withoutRootsEverySessionIsItsOwnGroup`**: the two `playola` roots with `roots: nil` give
      two groups.
    - **`onlyManagedWorkspacesAreArchivable`**
      - True for `/u/slipstream/workspaces/r/w`.
      - False for `/u/conductor/workspaces/r/w`, `/u/slipstream/workspaces/r` and
        `/u/slipstream/workspaces-old/r/w`.

- [ ] **Step 2: Run them to verify they fail**

  Run: the verification command with `-only-testing:SlipstreamViewerTests/WorkspaceSidebarTests`.
  Expected: compile failure, because `WorkspaceRoots` is undefined.

- [ ] **Step 3: Implement.**
  - **Matching:** reuse `ManagedWorkspacePath.contains(_:root:)` (`Sources/SlipstreamCore/WorkspacePathStreamParser.swift`,
    from PR #48). It is the exact-depth component match. `repository(of:)` returns the folder's
    path component just after whichever root contains it. Folder roots arrive normalized, so there
    is no filesystem access per call.
  - **Swap the page model to the new client field:**
    - `managedWorkspaceRoot: URL?` → `private(set) var workspaceRoots: WorkspaceRoots?`;
    - `loadManagedWorkspaceRoot()` → `loadWorkspaceRoots()`, with the same task and generation
      check;
    - `isArchiveWorkspaceShown` → `selectedFolder.map { workspaceRoots?.isArchivable($0) ?? false } ?? false`.
  - **Terminals plan overlap:** its later tasks pass `managedWorkspaceRoot` or
    `await workspace.managedRoot()` to `newWorkspaceStarted(repository:store:managedRoot:)`
    (`design/features/terminals/implementation-plan.md`, around line 746). Whichever feature lands
    second passes `URL(filePath: workspaceRoots.managed)` instead.
  - **Update the test helper:** `workspaceClient(…)` passes
    `roots: { WorkspaceRoots(managed: Self.managedRoot, conductor: URL(filePath: "/work/conductor/workspaces")) }`.

- [ ] **Step 4: Run the new suite and the whole `ChangeStreamPageTests` suite.** Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add SlipstreamViewer/Models/WorkspaceSidebar.swift SlipstreamViewerTests/Models/WorkspaceSidebarTests.swift SlipstreamViewer/Dependencies/WorkspaceClient.swift SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift
  git commit -m "feature: group workspaces by repo for the sidebar"
  ```

### Task 2: The sidebar replaces the session picker

**Files:**
- Modify: `ChangeStreamPageModel.swift`, `ChangeStreamPageView.swift`, `ChatPageView.swift`
  (un-`private` `SpinnerView`) and `DesignTokens.swift`
- Modify: `CaptureStatus.swift` and `CaptureStatusTests.swift`
- Create: `WorkspaceSidebarView.swift`
- Test: `ChangeStreamPageTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces, on `ChangeStreamPageModel`:
  - **Properties:** `var sidebarGroups: [SidebarGroup]`, defined as
    `SidebarGroup.groups(pickerSessions, roots: workspaceRoots)`.
  - **Display text**
    - `let sidebarTitleText = "Workspaces"`
    - `let addRepositoryText = "Add repository…"`
    - `var toolbarTitleText: String`:
      - `"<repo>  ›  <row name>"` when `workspaceRoots?.repository(of:)` names the selected
        folder;
      - otherwise the row name;
      - `"Slipstream"` with nothing selected.
  - **View helpers:** `func rowName(_ session: SessionOption) -> String` (forwards to
    `SidebarGroup.rowName`), `func isSelected(_ session: SessionOption) -> Bool`, and
    `func isWorking(_ session: SessionOption) -> Bool`. The existing `isBold(_:)` is kept.
- **`emptyStateText` (Decision 12):** `sessions.isEmpty` becomes `pickerSessions.isEmpty`.
- **Deletions**
  - Delete:
    - `isShowingInactiveSessions`, `inactiveSessionsToggleText`, `inactiveSessionsToggleTapped()`;
    - `hiddenInactiveSessionCount`, `sessionPickerTitle`, `sessionMenuText(for:)`;
    - `isSessionPickerDisabled`, `newWorkspaceText`, `CaptureStatus.pickerSuffix`;
    - the toolbar `Menu` and `menuTitle(_:isBold:)`;
    - `DesignTokens.StreamPicker`.
  - `pickerSessions` becomes `sessions.filter { !isHideable($0) }`.
  - The toolbar's archive item and `archiveWorkspaceText` stay until Task 3.

- [ ] **Step 1: Write the failing tests**
  - **Rewrite `thePickerHidesInactiveWorkspacesBehindAToggle` → `theSidebarHidesInactiveWorkspaces`.**
    `sidebarGroups.flatMap(\.rows).map(\.id) == [Fixture.session]`.
  - **Rewrite `theWatchedWorkspaceStaysInThePickerWhenItStops` → `theSelectedWorkspaceStaysInTheSidebarWhenItStops`.**
    - Select `Fixture.otherSession` while it is recording.
    - Refresh with it stopped.
    - It is still listed.
  - **Rewrite `thePickerHidesNothingWhenCaptureStateIsUnknown`** against the sidebar rows.
  - **Delete:**
    - `thePickerHasNoToggleWhenEveryWorkspaceIsActive`;
    - `theMenuNamesEachWorkspacesCaptureState`;
    - the `pickerSuffix` tests in `CaptureStatusTests`.
  - **`rowsGroupByRepoOnceTheRootsLoad`**
    - Sessions at `/work/slipstream/workspaces/r/workspace-1` and
      `/work/conductor/workspaces/r/lisbon`.
    - After `viewAppeared()`, one group named `r` with both rows.
    - `selectedSession` is unchanged from before the roots arrived.
  - **`toolbarTitleNamesRepoAndWorkspace`**
    - `"r  ›  workspace-1"` for `Self.workspaceRoot` selected.
    - `"project"` for `/tmp/project`.
    - `"Slipstream"` with no sessions.
  - **`aWorkspaceWithoutChatsIsNeitherBoldNorWorking`.** Bold for a restored but unshown waiting
    tab is already pinned by `pickerRowBoldWhenFolderWaiting` (line 413). Keep that test.
  - **`allInactiveSessionsReadNoCaptureSessionsYet`**
    - Every session stopped and nothing selected.
    - `emptyStateText == "No capture sessions yet"` (Decision 12).

- [ ] **Step 2: Run them to verify they fail.** Use the `ChangeStreamPageTests` filter.

- [ ] **Step 3: Implement the model.** Follow the MARK order in the repo `CLAUDE.md`.

- [ ] **Step 4: Implement the view.**
  - **Tokens:** add `DesignTokens.Sidebar` (fill, stroke, title, group header, row and selected
    fills, row name fonts regular and bold, spinner, footer) and
    `DesignTokens.Workspace.sidebarWidth = 260`. Copy the values from the JSON named in Global
    Constraints.
  - **`WorkspaceSidebarView(model:)`**
    - the title;
    - for each group: the group name, then each row as a `Button` calling
      `sessionSelected(session.id)`;
    - each row's name weight comes from `isBold`, its spinner (`SpinnerView`) from `isWorking`,
      and its fill from `isSelected`;
    - the footer button `addRepositoryText` calls `newWorkspaceTapped()`;
    - the column is `.disabled(model.isWorkspaceBusy)`.
  - **`ChangeStreamPageView`**
    - Put the sidebar at the leading edge, `.frame(width: sidebarWidth)`, before today's
      feed/detail columns. The columns are rearranged in Task 4.
    - The toolbar's `Menu` becomes `Text(model.toolbarTitleText)`. Keep a plain toolbar button
      for `archiveWorkspaceTapped()` while `isArchiveWorkspaceShown`, until Task 3.

- [ ] **Step 5: Run the full verification command.** Expected: PASS, zero warnings.

- [ ] **Step 6: Commit**

  ```bash
  git commit -am "feature: list workspaces grouped by repo in a sidebar instead of the toolbar menu"
  ```

### Task 3: + per repo and archive from the row

**Files:**
- Modify: `ChangeStreamPageModel.swift`, `ChatPageModel.swift`, `WorkspaceSidebarView.swift`,
  `ChangeStreamPageView.swift` and `DesignTokens.swift`
- Asset: lucide `archive`
- Test: `ChangeStreamPageTests.swift` and `ChatPageTests.swift`

**Interfaces:**
- Consumes: `SidebarGroup.newWorkspaceFolder`, `WorkspaceRoots.isArchivable`.
- Produces, on `ChangeStreamPageModel`:
  - **`let newWorkspaceHelpText = "New workspace"`** and
    **`let archiveWorkspaceHelpText = "Archive workspace"`**.
  - **`func newWorkspaceTapped(in group: SidebarGroup) async`**
    - Guards `!isWorkspaceBusy` and a non-nil `newWorkspaceFolder`.
    - Calls `workspace.create(URL(filePath: folder), daemon.storeID)` without the chooser.
    - It shares today's busy, select and failure tail with `newWorkspaceTapped()` through one
      private helper. `newWorkspaceTapped()` keeps the chooser and backs **Add repository…**.
  - **Hover and focus state,** following `ChatPageModel.tabHovered` (`ChatPageModel.swift:217`):
    - `private var hoveredRowID: String?` and `private var focusedRowID: String?`;
    - `func rowHoverChanged(_ session: SessionOption, isHovering: Bool)` and
      `func rowFocusChanged(_ session: SessionOption, isFocused: Bool)`. Each clears only when
      the id still matches.
  - **Row helpers**
    - `func isArchivable(_ session: SessionOption) -> Bool`
    - `func isHighlighted(_ session: SessionOption) -> Bool`: hovered or focused.
    - `func isArchiveIconShown(for session: SessionOption) -> Bool`: archivable and highlighted.
  - **Archive target:** `private(set) var archiveTarget: SessionOption?`.
    `func archiveTapped(_ session: SessionOption)` sets it and presents the confirmation.
  - **`archiveConfirmationText`** reads `archiveTarget?.root`.
  - **`archiveConfirmed()`** is one body.
    - It captures `target` and `folder` into locals at the top, plus
      `let isSelected = target.id == selectedSession?.id`.
    - Only when `isSelected`:
      - it hides the chat (`chat.workspaceChanged(folder: nil, …)`) before stopping;
      - on failure, it gives the folder back to the chat;
      - on success, it clears the selection, then `resetFeed()` and `startWatching()`.
    - Always: `stopTabs`, `archive`, then on failure `restoreTabs` and the alert; on success
      `forgetTabs`, `archivedSessionIDs.insert`, `loadSessions()`.
  - **Deletions:** `archiveWorkspaceTapped()`, `archiveWorkspaceText`, `isArchiveWorkspaceShown`
    and the temporary toolbar archive button.
- On `ChatPageModel`, `restoreTabs(in:drafts:)` first re-adds a tab model
  (`addModel(for:needsHistory: true)`) for each of the folder's records that has none, then
  restores drafts.
  - This matters because `stopTabs` removes the models (`ChatPageModel.swift:347`).
  - Today the selected path re-adds them via `workspaceChanged`.
  - An unselected row has no such path.

- [ ] **Step 1: Write the failing tests**
  - **`plusCreatesInTheGroupsFirstFolderWithoutTheChooser`**
    - `workspaceClient(choose: nil, create:)` records its path.
    - `calls == [[Self.workspaceRoot, "store-a"]]`.
    - The new path is selected, as in `newWorkspaceCreatesThenSelectsIt`.
  - **`plusFailureShowsTheExistingAlert`**: the title is "Couldn't finish creating the workspace".
  - **`archiveIconShowsOnHoverOrFocusForManagedRowsOnly`**
    - A managed row shows the icon when hovered and when focused.
    - It is hidden once both clear.
    - The icon stays while focused after the hover leaves.
    - A `/work/conductor/workspaces/r/lisbon` row never shows it.
    - This replaces `archiveIsOnlyOfferedUnderTheManagedRoot`; delete that test.
  - **`archivingAnotherRowKeepsTheSelection`**
    - Two managed sessions; the first is selected and the second has a working tab.
    - After `archiveTapped(second)`, `archiveConfirmationText` ends "…will be stopped.".
    - After `archiveConfirmed()`:
      - the archive call got the second folder;
      - `selectedSession?.id` and `chat.folder` are unchanged;
      - the second folder's records are gone.
  - **`refusedArchiveOfAnotherRowRestoresItsTabsAndDrafts`**
    - Give the unselected row's record a draft and refuse the archive.
    - `chat.tabs` again has a model for that record, with its draft.
  - **`archiveTargetSurvivesAReloadDuringTheCommand`**
    - Gate `archive` on an `AsyncStream`, as `newWorkspaceCreatesThenSelectsIt` does.
    - Call `refreshTapped()` while it is gated.
    - The recorded path is the clicked row's.
  - **`archiveWhileBusyDoesNothing`**: with a create gated, `archiveConfirmed()` makes no call.
  - **Adapt the existing archive tests** to set the target with `archiveTapped(selected)`:
    - `archiveStopsChatsBeforeRunningTheCommand`;
    - `archiveHidesTheChatWhileTheCommandRuns`;
    - `refusedArchive…`;
    - `archiveConfirmationWarnsWhenClaudeIsWorking`.

    They pin "archive the selected row behaves as today".
  - **In `ChatPageTests`, add `restoringTabsRecreatesStoppedModels`**: after `stopTabs` then
    `restoreTabs`, the models exist again with their drafts.

- [ ] **Step 2: Run them to verify they fail.**

- [ ] **Step 3: Implement the model changes.**

- [ ] **Step 4: Implement the view.**
  - **Group header:** a **+** shown when `group.newWorkspaceFolder != nil`, with
    `.help(newWorkspaceHelpText)`, calling `newWorkspaceTapped(in:)`.
  - **Row**
    - `.onHover` → `rowHoverChanged`; a `@FocusState` change → `rowFocusChanged`;
    - the highlight fill from `isHighlighted`;
    - the archive icon when `isArchiveIconShown(for:)`, with `.help(archiveWorkspaceHelpText)`,
      calling `archiveTapped`;
    - `.accessibilityAction(named: archiveWorkspaceHelpText)` when `isArchivable`.
  - Add the icon and highlight tokens to `DesignTokens.Sidebar`.

- [ ] **Step 5: Run the full verification command.** That includes `ChatPageTests`, which is
  the touched-area rule for `restoreTabs`. Expected: PASS.

- [ ] **Step 6: Commit**

  ```bash
  git commit -am "feature: make and archive workspaces from their sidebar rows"
  ```

### Task 4: Chat in the middle; Change stream | Terminals on the right

**Files:**
- Modify: `ChangeStreamPageModel.swift`, `ChangeStreamPageView.swift`, `ChatPageView.swift`,
  `ReplyPlacement.swift` and `DesignTokens.swift`
- Test: `ChangeStreamPageTests.swift`

**Interfaces:**
- Produces, on `ChangeStreamPageModel`:

  ```swift
  enum RightPane: Equatable, CaseIterable { case stream, terminals }
  private(set) var rightPane: RightPane = .stream
  var isStreamShown: Bool { rightPane == .stream }
  func rightPaneSelected(_ pane: RightPane)   // no-op if unchanged; .terminals → replyCollapsed(); .stream → follow.jumpToLatest()
  func rightPaneText(_ pane: RightPane) -> String   // "Change stream" / "Terminals"
  func isSelected(_ pane: RightPane) -> Bool
  let terminalsPlaceholderText = "Terminals are coming in a later update"
  ```

- `showsReplyConnector` and `showsSelectionConnector` read `isStreamShown` instead of
  `!isFeedHidden`.
- **Deletions**
  - `isFeedHidden`, `hideFeedTapped()`, `showFeedTapped()`, `hideFeedText` and `showFeedText`;
  - `ChatPageView`'s `Leading` generic and slot;
  - the tokens `HideFeedButton`, `Fonts.hideFeed`, `Fonts.restoreFeed`, `Colors.hideFeed`,
    `Colors.restoreFeed`, `Icons.hideFeed` and `Chat.TabStrip.showFeedFont`/`showFeedColor`.
- **`ReplyPlacement`**
  - The popover sits to the left of the bar:

    ```
    x = min(viewport.maxX - inset - width, max(viewport.minX + inset, bar.minX - connectorLength - width))
    ```

  - `barAnchor` becomes `(bar.minX, bar.midY)`, and `popoverAnchor.x` becomes `popover.maxX`.
  - `showsConnector` becomes `popoverAnchor.x < barAnchor.x`.

- [ ] **Step 1: Write the failing tests**
  - **Rewrite `hidingTheFeedCollapsesTheReply` → `switchingToTerminalsCollapsesTheReply`.**
  - **Rewrite `showingAHiddenFeedReturnsToTheLatestChange` → `switchingBackToTheStreamReturnsToTheLatestChange`.**
  - **`switchingPanesKeepsWatching`**
    - Switch to Terminals.
    - `model.watchTask` is the same and not cancelled.
    - `send(Fixture.edited(1))` still adds a row.
  - **`connectorsHideWhileTerminalsShows`**: with a reply open, switch to Terminals.
    `showsReplyConnector == false`.
  - **`switchingWorkspaceKeepsTheRightPane`**: after Terminals, `sessionSelected(other)` leaves
    `rightPane == .terminals`.
  - **Rewrite `replyOpensBesideItsBarWithAConnector`** (`ChangeStreamPageTests.swift:2135`) to
    the mirrored geometry. The popover's `maxX` is `bar.minX - connectorLength` and the connector
    shows. Add the left-edge clamp case to it.

- [ ] **Step 2: Run them to verify they fail.**

- [ ] **Step 3: Implement the model and `ReplyPlacement`.**

- [ ] **Step 4: Implement the view.**
  - **Body:** `HStack(spacing: 0)` with:
    - sidebar;
    - middle column: today's `detailPane`, which is the fixture, the live comparison, or
      `ChatPageView` with no slot (Decision 11);
    - right column.
  - **Right column**
    - A tab strip: `ForEach(RightPane.allCases)` buttons labelled `rightPaneText`, calling
      `rightPaneSelected` and styled by `isSelected`. It is the underline strip in frame `gwLQ8`,
      not a system segmented `Picker`.
    - Then `if model.isStreamShown { feedPane } else { placeholder }`. This tears the feed down
      as Hide feed does today; the model owns watching.
  - **Feed:** move its stroke to the leading edge. Delete the Hide feed button and both Show feed
    buttons. Keep `fileViewer`'s top spacing so the comparison does not shift.
  - Add `DesignTokens.RightPane` (strip, selected underline, placeholder).

- [ ] **Step 5: Run the full verification command.** Expected: PASS.

- [ ] **Step 6: Commit**

  ```bash
  git commit -am "feature: move the chat to the middle and switch the right side between stream and terminals"
  ```

### Task 5: Sidebar toggle and column widths

**Files:**
- Modify: `ChangeStreamPageModel.swift`, `ChangeStreamPageView.swift` and `DesignTokens.swift`
- Test: `ChangeStreamPageTests.swift`

**Interfaces:**
- **Tokens:** `DesignTokens.Workspace` adds `chatWidth = 720` and `chatMinWidth = 420`.
- **Model**
  - **Shared state:** `@ObservationIgnored @Shared(.isSidebarHidden) var isSidebarHidden`, like
    `fontSizeStep` at line 24.
  - **Display text:** `var sidebarToggleHelpText: String` is "Hide sidebar" or "Show sidebar".
  - **Properties**
    - `var isSidebarShown: Bool`
    - `var chatColumnWidth: CGFloat`:

      ```
      min(chatWidth, max(chatMinWidth, viewport.width - sidebarWidth - FeedPane.width))
      ```

      It always subtracts the sidebar, so hiding the sidebar leaves the chat's width alone and
      the stream takes the space (`screens.md` "Sidebar hidden").
    - `var windowMinWidth: CGFloat`:

      ```
      chatMinWidth + FeedPane.width + (isSidebarShown ? sidebarWidth : 0)
      ```

  - **User actions:** `func sidebarToggleTapped()` toggles the value with `$isSidebarHidden.withLock`.

- [ ] **Step 1: Write the failing tests**
  - **`sidebarHiddenIsRemembered`**
    - Toggle once.
    - A second `makeModel(storage:)` sees `isSidebarShown == false`, and the help text reads
      "Show sidebar".
  - **`chatShrinksBeforeTheStream`**
    - Call `viewportChanged` with widths 2040, 1600, 1360 and 1200. Expect 720, 660, 420 and 420.
    - Hide the sidebar at 1360: the width is still 420.
  - **`windowMinimumFollowsTheSidebar`**: 1360, then 1100 after the toggle.

- [ ] **Step 2: Run them to verify they fail.**

- [ ] **Step 3: Implement the model.**

- [ ] **Step 4: Implement the view.**
  - The sidebar shows only `if model.isSidebarShown`.
  - The middle column gets `.frame(width: model.chatColumnWidth)`.
  - The right column gets `.frame(minWidth: FeedPane.width, maxWidth: .infinity)`.
  - The frame minimum becomes `model.windowMinWidth`. The fixture path keeps
    `FunctionMap.demoWorkspaceMinWidth`.
  - The toolbar gets a leading button with the `sidebar.left` system image,
    `.help(sidebarToggleHelpText)`, calling `sidebarToggleTapped()`. Place it before
    `Text(toolbarTitleText)`.

- [ ] **Step 5: Run the full verification command.** Expected: PASS.

- [ ] **Step 6: Manual check against a disposable daemon.**

  Start `npm run qa:daemon` in `~/playola/slipstream`, then run the app with `SLIPSTREAM_STORE`
  set to its store. Check:
  - the five states match frames `Gmszm`, `OEccY`, `gm8O5`, `gwLQ8` and `zaPgO` (`screens.md`);
  - with macOS keyboard navigation on, Tab focuses a row and reveals its archive icon;
  - at 1,360pt with the sidebar, the chat is 420pt and the stream at least 680pt;
  - hiding the sidebar keeps the chat's width;
  - showing the sidebar in a 1,100pt window widens the window, or stops at the screen edge;
  - a reply popover opens left of its bar, over the chat, with its connector;
  - Compare functions replaces the chat column, and closing it restores the chat.

  Note any deviation in the PR description.

- [ ] **Step 7: Commit**

  ```bash
  git commit -am "feature: hide or show the sidebar and keep the stream at least as wide as today"
  ```

## Unresolved questions

- **For Brian:** approved by Brian on 2026-10-26. Decisions 8–12 and the Hide feed removal
  were made while resolving the review; Brian approved them, the 1,360pt minimum with the
  sidebar, the reply popover opening to the left, and the stream view being torn down while
  Terminals shows.
- **Reply popover direction:** Review Focus 1 and Task 4 mirror it to the left. No approved
  frame shows a popover, so this is a design call.
- **Accepted:** two sessions with the same folder show two rows with the same name. Inactive
  duplicates are hidden, so this needs two live sessions on one folder.
