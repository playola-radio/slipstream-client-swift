# Conductor-style top bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Before writing Swift, invoke the `pfw-*` skills the repo's `CLAUDE.md` lists: `pfw-observable-models` (Tasks 2–3), `pfw-testing` + `pfw-custom-dump` (every test step), `pfw-modern-swiftui` (Tasks 1, 4, 5).

**Goal:** Replace the window's glass unified toolbar with one thin, flat 40pt header row split per column (sidebar, chat, right), move Compare functions into the right pane's tab row, and swap the Refresh button for reload-on-activation plus ⌘R.

**Architecture:** The window drops its title bar (`.windowStyle(.hiddenTitleBar)`) and each column draws its own header part at its top, so the parts line up with the columns by construction. All header text and show/hide decisions are new `ChangeStreamPageModel` properties. Reloads from appearing, activation and ⌘R go through one single-flight path in the model; ⌘R reaches the model through a focused scene value read by a new `Commands` struct.

**Tech Stack:** Swift 6 (strict concurrency, warnings are errors), SwiftUI on macOS 15+, Observation, swift-dependencies, Swift Testing + CustomDump, XcodeGen.

**Spec:** `design/features/conductor-top-bar/spec.md` and `screens.md`; all measurements and colours are in `exports/window-header.json`; mockups are `exports/window--default.png`, `window--sidebar-hidden.png`, `window--no-workspace.png`.

## Global Constraints

- One PR against `develop`. No daemon change, no PR behaviour, no placeholder PR controls (spec non-goals, review #12).
- Views contain zero logic: every string and show/hide decision is a model property; views pick colours through `DesignTokens` functions given model booleans (the existing `RightPane.Tab.color(isSelected:)` pattern).
- Every visual value comes from `window-header.json`, copied into a new `DesignTokens.WindowHeader`; no hardcoded colours, fonts or sizes in views.
- Header height 40pt; every part has its column's fill and a 1pt `#2A3640` bottom border.
- Never `isMovableByWindowBackground`. Window dragging only via `WindowDragGesture` on empty header space.
- Copy: "Refresh to check again" → "Press ⌘R to check again"; the menu item is "Reload Workspaces" with ⌘R in the View menu.
- Tests never touch a daemon, the network or real time; never point anything at the real `~/.slipstream`.

## Review Focus

1. The app becoming active while the first load is still running (it does at every launch) → exactly one more load, not a pile-up. Test: Task 3 `aReloadAskedForDuringAReloadRunsOnceAfterIt`.
2. A reload that fails while a workspace is selected and its stream is live → sidebar, selection and feed stay; capture state reads unknown. Test: Task 3 `aFailedReloadKeepsTheListAndSelection`.
3. ⌘R pressed while typing in the chat composer or with a terminal focused → it still reloads, and types nothing. Check: Task 4 Step 4.
4. A narrow right pane with a long question summary ("12 questions · 3 new replies") → the summary truncates, the Compare functions label stays whole. Check: Task 5 Step 6.

---

### Task 1: Window chrome spike (not committed)

Proves that a content header can replace the title bar before anything depends on it. Spike code is thrown away; only the findings are kept.

**Files (scratch only):** `SlipstreamViewer/App/SlipstreamViewerApp.swift`, `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift`

**Interfaces:**
- Produces: the exact scene/view modifiers that pass, and the measured leading width the window buttons need (`trafficLightsWidth`), recorded in the task's findings for Task 5.

- [ ] **Step 1: Candidate A.** On the `Window` scene replace `.windowToolbarStyle(.unified)` with `.windowStyle(.hiddenTitleBar)`; remove `.toolbar { toolbar }`; wrap the body's `HStack` in a `VStack(spacing: 0)` whose first child is a 40pt `HStack` of three coloured placeholders (260pt sidebar fill `#0E1318`, chat-width `#12171D`, the rest `#191F27`, 1pt bottom border); let the root ignore the top safe area if the header doesn't reach the window's top edge. Put `WindowDragGesture()` on the placeholders' empty space.

- [ ] **Step 2: Run the app against a disposable daemon** (`SLIPSTREAM_STORE` + `npm run qa:daemon` in the daemon repo) and check every criterion:
  1. The window buttons are vertically centred in the 40pt header (compare `exports/window--default.png`).
  2. Their leading room: measure the width from the window edge to the end of the third button + 18pt gap; with the sidebar hidden the chat part must start with the same room.
  3. Dragging empty header space moves the window; dragging or clicking a control (use a temporary `Button`) does not.
  4. Double-clicking empty header space does what System Settings › Desktop & Dock › "Double-click a window's title bar to" says (try Zoom and Minimise).
  5. Full screen: when the menu bar slides down nothing in the header is covered or clipped. The leading room may stay empty.
  6. Inactive window: the header keeps its colours; the window buttons grey out as usual.
  7. Keyboard (Full Keyboard Access on) and VoiceOver reach the temporary header button.
  Check on macOS 26 (this machine). Check on macOS 15 if one is available; otherwise list macOS 15 as unverified in the PR body.

- [ ] **Step 3: If A fails a criterion, try candidate B:** keep `.hiddenTitleBar` and host the header in an AppKit `NSTitlebarAccessoryViewController` (via a small `NSViewRepresentable` window accessor) instead of the content `VStack`. Re-run Step 2.

- [ ] **Step 4: If neither passes, STOP** and report to Brian: which criteria failed, how, with screenshots. Do not try toolbar styling or a third approach.

- [ ] **Step 5: Record the findings** (passing candidate, exact modifiers, measured `trafficLightsWidth`, per-criterion result, macOS versions checked) in a scratch note for Task 5 and the PR body, then discard the spike: `git restore SlipstreamViewer/App/SlipstreamViewerApp.swift SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift`.

---

### Task 2: Header text and visibility in the model

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift` (`toolbarTitleText` at :215; `compareFunctionsText` area at :177)
- Test: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift` (`toolbarTitleNamesRepoAndWorkspace` at :3871, the `toolbarTitleText` line at :2782, `compareFunctionsFreezesRecordedBaselineAndCurrentFeedHead` at :462)

**Interfaces:**
- Produces (all in `// MARK: - Display Text` / `View Helpers`):
  - `var breadcrumbRepositoryText: String?`: the repository name, or nil while unknown or with nothing selected
  - `var breadcrumbWorkspaceText: String?`: `rowName(selectedSession)`, or nil with nothing selected
  - `var isOpenInShown: Bool`: `selectedSession != nil`
  - `var compareFunctionsHelpText: String`
- Removes: `toolbarTitleText`.

- [ ] **Step 1: Write the failing tests.** Rename `toolbarTitleNamesRepoAndWorkspace` to `breadcrumbNamesRepoAndWorkspace` and assert at its three existing points:

```swift
expectNoDifference(project.breadcrumbRepositoryText, nil)
expectNoDifference(project.breadcrumbWorkspaceText, "project")
#expect(project.isOpenInShown)
// after listWorkspace()
expectNoDifference(model.breadcrumbRepositoryText, "r")
expectNoDifference(model.breadcrumbWorkspaceText, "workspace-1")
// no sessions
expectNoDifference(empty.breadcrumbRepositoryText, nil)
expectNoDifference(empty.breadcrumbWorkspaceText, nil)
#expect(!empty.isOpenInShown)
```

At :2782 replace `toolbarTitleText` with `breadcrumbWorkspaceText` (still `"seventeenth"`). In `compareFunctionsFreezesRecordedBaselineAndCurrentFeedHead` add, beside each `canCompareFunctions` check:

```swift
// before the baseline event
expectNoDifference(model.compareFunctionsHelpText, "Available once Slipstream has recorded where this workspace started")
// after the baseline event
expectNoDifference(model.compareFunctionsHelpText, "Compare each function before and after this session's changes")
```

In `breadcrumbNamesRepoAndWorkspace`'s no-sessions part also assert:

```swift
expectNoDifference(empty.compareFunctionsHelpText, "Choose a workspace to compare its functions")
```

- [ ] **Step 2: Run and see them fail to compile.** `xcodegen generate && xcodebuild test -scheme SlipstreamViewer -only-testing:SlipstreamViewerTests/ChangeStreamPageTests` → FAIL: no member `breadcrumbRepositoryText`.

- [ ] **Step 3: Implement.** Split `toolbarTitleText`'s logic into the two breadcrumb properties and delete it. `compareFunctionsHelpText` checks in this order: nothing selected → no baseline → usable, returning the three strings above. The demo launch flag gets no text of its own; the button is disabled there anyway.

- [ ] **Step 4: Run the whole `SlipstreamViewerTests` target** → PASS.

- [ ] **Step 5: Commit.** `git commit -m "chore: give the page model the header's breadcrumb, Open in and Compare functions text"`

---

### Task 3: One reload path, and failed reloads keep the list

**Files:**
- Modify: `ChangeStreamPageModel.swift` (`viewAppeared` :608, `refreshTapped` :619, `refreshButtonText` :177, `loadSessions` catch :1064–1075)
- Modify: `ChangeStreamPageView.swift` (the `didBecomeActive` `onReceive`, the toolbar's Refresh item)
- Test: `ChangeStreamPageTests.swift`

**Interfaces:**
- Produces:
  - `func reloadShortcutPressed() async`: replaces `refreshTapped()`
  - `func appBecameActive() async`: does what the view's `didBecomeActive` handler does today (`chat.appActivityChanged(isActive: true)`, `openIn.viewAppeared()`), then reloads. No shown-window guard: closing the window quits the app (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), so the handler only fires while the view exists
- Removes: `refreshTapped()`, `refreshButtonText`.

- [ ] **Step 1: Rename the calls.** Replace all 26 `model.refreshTapped()` calls in `ChangeStreamPageTests.swift` with `model.reloadShortcutPressed()`. No assertions change yet. `appBecameActive()` lists installed apps, and `OpenInClient.testValue.installedApps` is `unimplemented`, so stub it to return `[]` in `makeModel`'s `withDependencies` block.

- [ ] **Step 2: Write the failing tests:**

```swift
@Test func aFailedReloadKeepsTheListAndSelection() async {
  let model = await liveModel()
  defer { model.viewDisappeared() }
  fake.setSessionsError(URLError(.cannotConnectToHost))
  await model.reloadShortcutPressed()
  expectNoDifference(model.sessions.ids, [Fixture.session])
  expectNoDifference(model.selectedSession?.id, Fixture.session)
  expectNoDifference(model.sessionsError, nil)
  expectNoDifference(model.captureText, "Capture state unknown — couldn't reach Slipstream")
}

@Test func aReloadAskedForDuringAReloadRunsOnceAfterIt() async {
  let (gate, open) = AsyncStream<Void>.makeStream()
  let daemon = DaemonFake(sessionsGate: gate)
  daemon.setSessions(
    [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
    starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
  daemon.setCaptures([Fixture.capture()])
  let model = makeModel(daemon: daemon)
  defer { model.viewDisappeared() }
  let appeared = Task { await model.viewAppeared() }
  await Task.megaYield()
  await model.appBecameActive()
  await model.reloadShortcutPressed()
  open.yield()
  await Task.megaYield()
  open.yield()
  await appeared.value
  expectNoDifference(daemon.sessionsCallCount, 2)
}
```

`missingDaemonIsExplained` stays as it is: a first load that fails still shows the error.

- [ ] **Step 3: Run and see them fail.** Same command as Task 2 → FAIL to compile: no member `reloadShortcutPressed` / `appBecameActive`.

- [ ] **Step 4: Implement.**
  - Add `@ObservationIgnored private var isReloading = false` and `isReloadQueued = false`.
  - In the `loadSessions` catch, after the stale-generation guard: if `hasLoadedSessions && sessionsError == nil` (a load has succeeded), call `captureRefreshFailed()` and return, leaving `sessions`, the selection and `sessionsError` as they are.
  - Add the single-flight helper. `viewAppeared`, `appBecameActive` and `reloadShortcutPressed` call it. Other `loadSessions()` callers (selection, chat link, recording, events) are untouched.

```swift
private func reloadSessions() async {
  guard !isReloading else { isReloadQueued = true; return }
  isReloading = true
  defer { isReloading = false }
  repeat {
    isReloadQueued = false
    await loadSessions()
  } while isReloadQueued
}
```

  - Implement `appBecameActive()`. In the view, make the `didBecomeActive` handler `Task { await model.appBecameActive() }`. Delete the toolbar's Refresh `ToolbarItem` and `refreshButtonText`.

- [ ] **Step 5: Run the whole `SlipstreamViewerTests` target** → PASS. This is the touched-area regression run. `loadSessions` is shared, so every existing ChangeStreamPage test must stay green.

- [ ] **Step 6: Commit.** `git commit -m "bugfix: reload workspaces one at a time, and keep the list when a reload fails"`

---

### Task 4: "Press ⌘R" copy and the Reload Workspaces command

**Files:**
- Modify: `SlipstreamViewer/Models/CaptureStatus.swift:56,58,166`; `SlipstreamViewer/Models/QuestionFailure.swift:28`; `ChangeStreamPageModel.swift:264`
- Create: `SlipstreamViewer/App/ReloadCommands.swift`
- Modify: `SlipstreamViewer/App/SlipstreamViewerApp.swift` (`.commands`); `ChangeStreamPageView.swift` (add `.focusedSceneValue(model)`)
- Test: `SlipstreamViewerTests/Models/CaptureStatusTests.swift:86,89,223`; `SlipstreamViewerTests/Views/Pages/AskAgentPage/AskAgentPageTests.swift:474`; `ChangeStreamPageTests.swift:2786,2941`

**Interfaces:**
- Consumes: `ChangeStreamPageModel.reloadShortcutPressed()` (Task 3).
- Produces: `struct ReloadCommands: Commands`, which reads `@FocusedValue(ChangeStreamPageModel.self) private var model`.

- [ ] **Step 1: Update the expected strings in the tests listed above.** Replace "Refresh to check again." with "Press ⌘R to check again.", and "Refresh to see which chat is linked now" with "Press ⌘R to see which chat is linked now". Then run `grep -rn "Refresh to" SlipstreamViewer SlipstreamViewerTests`; the only matches left should be the five source strings.

- [ ] **Step 2: Run the tests** → FAIL on those assertions. Then change the five source strings. Run the tests again → PASS.

- [ ] **Step 3: Add the command.** `ReloadCommands` puts a `CommandGroup(after: .toolbar)` in the View menu containing `Button("Reload Workspaces") { Task { await model?.reloadShortcutPressed() } }.keyboardShortcut("r").disabled(model == nil)`. Register it in `.commands` before `FontSizeCommands`. Add `.focusedSceneValue(model)` to `ChangeStreamPageView`'s body. Build.

- [ ] **Step 4: Check by hand** against a disposable daemon:
  - View › Reload Workspaces shows ⌘R and sits above the text-size group.
  - Start a workspace from the CLI, press ⌘R, and it appears in the sidebar.
  - ⌘R works with the chat composer focused and types nothing.
  - ⌘R works with a terminal focused and types nothing.

- [ ] **Step 5: Commit.** `git commit -m "feature: reload the workspace list with ⌘R and say so in place of Refresh"`

---

### Task 5: The header row, flat Open in, and Compare functions in the tab row

**Files:**
- Create: `SlipstreamViewer/Assets.xcassets/GitCompare.imageset/` (lucide `git-compare`, ISC; same `Contents.json` as `GitBranch.imageset`, template rendering)
- Modify: `SlipstreamViewer/DesignTokens.swift`: add `enum WindowHeader`; change `OpenInButton.iconSize` from 16 to 14 (`OpenInClient` sizes the app icons with it)
- Modify: `ChangeStreamPageView.swift`. The headers are private builders beside `rightPaneStrip`/`detailPane`: `sidebarHeader`, `chatHeader`, and `sidebarToggle`, which both use. `OpenInButton` stays where it is (:425) and is restyled. Delete `toolbar` (:397–423)
- Modify: `SlipstreamViewerApp.swift` (the window modifiers recorded in Task 1)

**Interfaces:**
- Consumes: Task 1's passing window modifiers and `trafficLightsWidth`.
- Produces: `DesignTokens.WindowHeader`. Its values come from `window-header.json`:
  - `height` 40, `trafficLightsWidth` (measured in Task 1). Fills and borders reuse `Sidebar.fill`, `Chat.fill`, `FeedPane.fill` and `Sidebar.stroke` / `Chat.stroke` (#2A3640).
  - `Sidebar`: `horizontalPadding` 14, `gap` 18, `toggleSize` 15, `toggleColor` `#8B9AA6`.
  - `Chat`: `leadingPadding` 16 (14 when the sidebar is hidden), `trailingPadding` 12, `gap` 8, `toggleHorizontalPadding` 10.
  - `Breadcrumb`: `gap` 7, icons `FolderGit2`/`GitBranch` 13 `#8B9AA6`, `ChevronRight` 12 `#5C6B77`, `repositoryFont` Geist 12.5/400 `#8B9AA6`, `workspaceFont` Geist 12.5/500 `#E6EDF3`.
  - `OpenIn`: `height` 24, `radius` 5, `appIconPadding` 6, `ChevronDown` 12 `#8B9AA6` with `chevronPadding` 5. The app icon uses `OpenInButton.iconSize`.
  - `Compare`: `gap` 6, `horizontalPadding` 8, `icon(isEnabled:)` (`GitCompare` 14), `font` Geist 12, `color(isEnabled:)` `#8B9AA6` / `#5C6B77`.

- [ ] **Step 1: Window and layout.**
  - Apply Task 1's window modifiers.
  - Put a header at the top of each column:
    - the sidebar: a `VStack(spacing: 0)` of `sidebarHeader` over `WorkspaceSidebarView`;
    - the detail column: a `VStack(spacing: 0)` of `chatHeader` over `detailPane`;
    - the right column: a 40pt draggable clear strip with a bottom border, added as the first child of `rightPane`'s existing `VStack`, which already draws the fill and left border.
  - Keep `.coordinateSpace(name: "question-workspace")` and the question overlay on the same outer `HStack`, as today.
  - Delete `.toolbar { toolbar }` and the `toolbar` builder.

- [ ] **Step 2: `sidebarToggle` and `sidebarHeader`.**
  - `sidebarToggle`, used by both headers, is:
    - a clear `trafficLightsWidth` spacer;
    - the `sidebar.left` toggle button (plain, 15pt, `.help` and `.accessibilityLabel(sidebarToggleHelpText)`);
    - a small `ProgressView` right after the toggle, if `isWorkspaceBusy`.
  - `sidebarHeader` is `sidebarToggle` plus `WindowDragGesture` on the trailing empty space.

- [ ] **Step 3: `chatHeader`.**
  - When `!isSidebarShown`, it starts with `sidebarToggle`, laid out as in `window--sidebar-hidden.png`.
  - Then the breadcrumb (combined into one VoiceOver element):
    - the repository icon, repository name and chevron only `if let breadcrumbRepositoryText`;
    - the branch icon and workspace name `if let breadcrumbWorkspaceText`.
  - A draggable spacer.
  - `OpenInButton` if `isOpenInShown`. It is a flat `Menu` with `.menuStyle(.button)` and `.buttonStyle(.plain)`, and contains:
    - the app icon;
    - a 1pt divider;
    - the chevron.
  - The button keeps today's `primaryAction`, help, accessibility label and `.disabled(isOpenDisabled)`, which also dims it. It has a 24pt-high bordered rectangle. Check that no system bezel or capsule is drawn; if `Menu` insists on one, make it a `Button` for the icon plus a `Menu` for the chevron.

- [ ] **Step 4: Compare functions in the tab row.**
  - In `rightPaneStrip`, after the existing `Spacer(minLength: 0)`, add a plain button calling `compareFunctionsTapped()`:
    - icon plus `compareFunctionsText`;
    - colours from `Compare.color(isEnabled: canCompareFunctions)`;
    - `.disabled(!canCompareFunctions)` and `.help(compareFunctionsHelpText)`;
    - its `HStack` is `.fixedSize()` and `.layoutPriority(1)`.
  - Give the Change stream subtitle `Text` `.truncationMode(.tail)`, so the subtitle gives way first.

- [ ] **Step 5: Build and run the whole test target.** Run `xcodegen generate`, then `xcodebuild test -scheme SlipstreamViewer`, then `swift test`. Expect: PASS, no warnings.

- [ ] **Step 6: Check by hand** against a disposable daemon:
  - The three states match `window--default.png`, `window--sidebar-hidden.png` and `window--no-workspace.png`.
  - All seven criteria from Task 1 Step 2 pass again with the real controls: drag on the breadcrumb text and on Open in must not move the window.
  - Open in is dimmed while a just-selected workspace's folder is unknown.
  - The spinner shows while creating a workspace.
  - Narrow the window to its minimum width with several questions open: the subtitle truncates and "Compare functions" stays whole.
  - Compare functions is dimmed with its help text before the baseline.

- [ ] **Step 7: Commit.** `git commit -m "feature: thin flat header per column in place of the toolbar, with Compare functions in the tab row"`
