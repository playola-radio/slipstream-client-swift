import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct TerminalPageTests {
  let fake = TerminalFake()
  let clock = TestClock()
  let a = "/tmp/workspace-a"
  let b = "/tmp/workspace-b"

  func makeModel(
    _ records: [TerminalTabRecord] = [],
    selected: [String: UUID] = [:],
    state: Shared<TerminalState>? = nil
  ) -> TerminalPageModel {
    withDependencies {
      $0.defaultFileStorage = fake.fileStorage
      $0.terminalRuntime = fake.runtimeClient
      $0.terminalHistory = fake.historyClient
      $0.uuid = .incrementing
      $0.continuousClock = clock
    } operation: {
      if let state { return TerminalPageModel(state: state) }
      @Shared(.terminalState) var state
      $state.withLock { $0 = TerminalState(tabs: IdentifiedArray(uniqueElements: records), selectedTabIDs: selected) }
      return TerminalPageModel()
    }
  }

  func terminal(_ id: Int, in folder: String, number: Int) -> TerminalTabRecord {
    TerminalTabRecord(id: UUID(id), folder: folder, kind: .terminal(number: number))
  }

  @Test func firstShowAddsTerminalOne() async {
    let model = makeModel()

    await model.workspaceChanged(folder: a)

    expectNoDifference(fake.saved?.tabs.elements, [terminal(0, in: a, number: 1)])
    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1"])
    #expect(model.selectedTab?.id == UUID(0))
    expectNoDifference(fake.launches.map(\.directory), [a])
  }

  @Test func plusUsesHighestNumberPlusOne() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: a, number: 3)])
    await model.workspaceChanged(folder: a)

    await model.newTabTapped()

    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1", "Terminal 3", "Terminal 4"])
    #expect(model.selectedTab?.title == "Terminal 4")
  }

  @Test func selectionIsRememberedPerWorkspace() async {
    let model = makeModel([
      terminal(100, in: a, number: 1), terminal(101, in: a, number: 2), terminal(102, in: b, number: 1),
    ])
    await model.workspaceChanged(folder: a)
    model.tabSelected(UUID(101))

    await model.workspaceChanged(folder: b)
    await model.workspaceChanged(folder: a)

    #expect(model.selectedTab?.id == UUID(101))
    expectNoDifference(fake.saved?.selectedTabIDs, [a: UUID(101)])
  }

  @Test func danglingSelectionFallsBackToFirstTab() async {
    let model = makeModel(
      [terminal(100, in: a, number: 1), terminal(101, in: a, number: 2)], selected: [a: UUID(999)])

    await model.workspaceChanged(folder: a)

    #expect(model.selectedTab?.id == UUID(100))
  }

  @Test func recordIsSavedBeforeLaunch() async {
    let model = makeModel()

    await model.workspaceChanged(folder: a)

    #expect(fake.savedState(at: .read(UUID(0)))?.tabs[id: UUID(0)] != nil)
    #expect(fake.savedState(at: .launch(directory: a))?.tabs[id: UUID(0)] != nil)
  }

  @Test func failedNewTerminalSaveDoesNotLaunchOrShowNewTab() async {
    @Shared(wrappedValue: TerminalState(), FailingTerminalStateKey()) var state
    let model = makeModel(state: $state)

    await withKnownIssue {
      await model.workspaceChanged(folder: a)
    }

    expectNoDifference(model.shownTabs, [])
    #expect(model.selectedTab == nil)
    expectNoDifference(fake.launches, [])
  }

  @Test func closeDeletesLogThenRecord() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: a, number: 2)])
    await model.workspaceChanged(folder: a)

    await model.closeTabTapped(UUID(101))

    let closing = fake.calls.drop { $0 != .stop(launch: 1) }
    expectNoDifference(Array(closing), [.stop(launch: 1), .flush(UUID(101)), .delete(UUID(101))])
    #expect(fake.savedState(at: .delete(UUID(101)))?.tabs[id: UUID(101)] != nil)
    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100)])
    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1"])
  }

  @Test func closingLastTerminalOpensTerminalOne() async {
    let model = makeModel([terminal(100, in: a, number: 2)])
    await model.workspaceChanged(folder: a)

    await model.closeTabTapped(UUID(100))

    expectNoDifference(fake.saved?.tabs.elements, [terminal(0, in: a, number: 1)])
    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1"])
    #expect(fake.launches.count == 2)
  }

  @Test func closingUnselectedBusyTabSelectsItAndAsks() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: a, number: 2)])
    await model.workspaceChanged(folder: a)
    fake.setBusy(true, launch: 1)

    await model.closeTabTapped(UUID(101))

    #expect(model.selectedTab?.id == UUID(101))
    #expect(model.selectedTab?.isCloseConfirmationVisible == true)
    #expect(fake.saved?.tabs[id: UUID(101)] != nil)

    await model.closeConfirmed(UUID(101))

    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100)])
  }

  @Test func closeShortcutClosesSelectedTab() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: a, number: 2)])
    await model.workspaceChanged(folder: a)
    model.tabSelected(UUID(101))

    await model.closeShortcutPressed()

    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100)])
    #expect(model.selectedTab?.id == UUID(100))
  }

  @Test func closeShortcutAsksWhenBusy() async {
    let model = makeModel([terminal(100, in: a, number: 1)])
    await model.workspaceChanged(folder: a)
    fake.setBusy(true)

    await model.closeShortcutPressed()

    #expect(model.selectedTab?.isCloseConfirmationVisible == true)
    #expect(fake.saved?.tabs[id: UUID(100)] != nil)
  }

  @Test func tabsInOtherWorkspacesKeepRunning() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: b, number: 1)])
    await model.workspaceChanged(folder: a)

    await model.workspaceChanged(folder: b)
    fake.send("still here\r\n", launch: 0)
    await Task.megaYield()

    #expect(!fake.calls.contains { if case .stop = $0 { true } else { false } })
    expectNoDifference(fake.log(UUID(100)), "still here\r\n")
    expectNoDifference(model.shownTabs.map(\.id), [UUID(101)])
  }

  @Test func noWorkspaceShowsEmptyState() async {
    let model = makeModel([terminal(100, in: a, number: 1)])

    await model.workspaceChanged(folder: nil)

    #expect(model.isEmptyStateVisible)
    #expect(model.emptyTitle == "Choose a workspace")
    #expect(model.emptyText == "Its terminals appear here.")
    expectNoDifference(model.shownTabs, [])
    expectNoDifference(fake.launches, [])
  }

  @Test func workspaceHidesEmptyState() async {
    let model = makeModel()

    await model.workspaceChanged(folder: a)

    #expect(!model.isEmptyStateVisible)
  }

  @Test func launchMarksRunningSetupInterrupted() async {
    let setup = TerminalTabRecord(id: UUID(100), folder: a, kind: .setup(.running))
    let finished = TerminalTabRecord(id: UUID(101), folder: a, kind: .setup(.finished(seconds: 3)))
    let model = makeModel([setup, finished])

    await model.launched()

    expectNoDifference(fake.saved?.tabs[id: UUID(100)]?.kind, .setup(.interrupted))
    expectNoDifference(fake.saved?.tabs[id: UUID(101)]?.kind, .setup(.finished(seconds: 3)))
  }

  @Test func restoredTabReplaysThenStartsShell() async {
    fake.setLog(UUID(100), "earlier\r\n")
    let model = makeModel([terminal(100, in: a, number: 1)])

    await model.workspaceChanged(folder: a)

    expectNoDifference(fake.calls, [.read(UUID(100)), .append(UUID(100)), .launch(directory: a)])
    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100)])
  }

  @Test func stopTabsStopsOnlyThatFolder() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: b, number: 1)])
    await model.workspaceChanged(folder: b)
    await model.workspaceChanged(folder: a)

    await model.stopTabs(in: a)

    let stops = fake.calls.filter { if case .stop = $0 { true } else { false } }
    expectNoDifference(stops, [.stop(launch: 1)])
    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100), UUID(101)])
  }

  @Test func noTerminalOneDuringArchive() async {
    let model = makeModel([terminal(100, in: a, number: 1)])
    await model.workspaceChanged(folder: a)
    await model.stopTabs(in: a)

    await model.workspaceChanged(folder: a)
    await model.closeTabTapped(UUID(100))

    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100)])
    #expect(fake.launches.count == 1)
  }

  @Test func restoreTabsStartsFreshShells() async {
    let model = makeModel([terminal(100, in: a, number: 1)])
    await model.workspaceChanged(folder: a)
    await model.workspaceChanged(folder: nil)
    await model.stopTabs(in: a)

    model.restoreTabs(in: a)
    await model.workspaceChanged(folder: a)

    expectNoDifference(fake.launches.map(\.directory), [a, a])
    expectNoDifference(model.shownTabs.map(\.id), [UUID(100)])
  }

  @Test func restoredWorkspaceWhoseLastTabClosedGetsTerminalOne() async {
    let model = makeModel([terminal(100, in: a, number: 1)])
    await model.workspaceChanged(folder: a)
    await model.workspaceChanged(folder: nil)
    await model.closeConfirmed(UUID(100))
    await model.stopTabs(in: a)

    model.restoreTabs(in: a)
    await model.workspaceChanged(folder: a)

    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1"])
    #expect(fake.launches.count == 2)
  }

  @Test func forgetTabsDeletesRecordsLogsAndSelection() async {
    let model = makeModel(
      [terminal(100, in: a, number: 1), terminal(101, in: b, number: 1)], selected: [a: UUID(100), b: UUID(101)])
    fake.setLog(UUID(100), "a\r\n")
    fake.setLog(UUID(101), "b\r\n")
    await model.workspaceChanged(folder: a)
    await model.stopTabs(in: a)

    await model.forgetTabs(in: a)

    #expect(!fake.hasLog(UUID(100)))
    #expect(fake.hasLog(UUID(101)))
    expectNoDifference(
      fake.saved, TerminalState(tabs: [terminal(101, in: b, number: 1)], selectedTabIDs: [b: UUID(101)]))
  }

  @Test func quitStopsAllAndBlocksNewTabs() async {
    let model = makeModel([terminal(100, in: a, number: 1), terminal(101, in: b, number: 1)])
    await model.workspaceChanged(folder: a)
    await model.workspaceChanged(folder: b)

    await model.quitConfirmed()
    await model.newTabTapped()
    await model.workspaceChanged(folder: "/tmp/workspace-c")

    let stops = Set(fake.calls.filter { if case .stop = $0 { true } else { false } })
    expectNoDifference(stops, [.stop(launch: 0), .stop(launch: 1)])
    #expect(fake.calls.contains(.flush(UUID(100))))
    #expect(fake.calls.contains(.flush(UUID(101))))
    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(100), UUID(101)])
    #expect(fake.launches.count == 2)
  }

  @Test func tabStatusIconFollowsKindAndStatus() async {
    let model = makeModel([
      TerminalTabRecord(id: UUID(100), folder: a, kind: .setup(.running)),
      TerminalTabRecord(id: UUID(101), folder: a, kind: .setup(.finished(seconds: 14))),
      TerminalTabRecord(id: UUID(102), folder: a, kind: .setup(.failed(exitStatus: 1))),
      TerminalTabRecord(id: UUID(103), folder: a, kind: .setup(.interrupted)),
      terminal(104, in: a, number: 1),
    ])

    await model.workspaceChanged(folder: a)

    expectNoDifference(model.shownTabs.map(\.statusIcon), [.running, .finished, .failed, .failed, nil])
  }

  @Test func closeButtonShowsOnSelectedOrHoveredTab() async {
    let model = makeModel([
      terminal(100, in: a, number: 1), terminal(101, in: a, number: 2), terminal(102, in: a, number: 3),
    ])
    await model.workspaceChanged(folder: a)

    model.tabHovered(UUID(101), isHovering: true)

    expectNoDifference(model.shownTabs.map(model.showsCloseButton), [true, true, false])
    expectNoDifference(model.shownTabs.map(model.isSelected), [true, false, false])
    expectNoDifference(model.shownTabs.map(model.isHovered), [false, true, false])

    model.tabHovered(UUID(101), isHovering: false)

    expectNoDifference(model.shownTabs.map(model.showsCloseButton), [true, false, false])
  }

  @Test func newTabButtonNeedsAWorkspace() async {
    let model = makeModel()

    await model.workspaceChanged(folder: nil)
    #expect(!model.showsNewTabButton)

    await model.workspaceChanged(folder: a)
    #expect(model.showsNewTabButton)
  }

  @Test func focusFollowsTheTerminal() async {
    let model = makeModel([terminal(100, in: a, number: 1)])
    await model.workspaceChanged(folder: a)

    model.terminalFocusChanged(UUID(100), isFocused: true)
    #expect(model.hasKeyboardFocus)

    model.terminalFocusChanged(UUID(100), isFocused: false)
    #expect(!model.hasKeyboardFocus)
  }
}

// MARK: - Setup tabs

extension TerminalPageTests {
  var repository: URL { URL(filePath: "/work/r") }
  var managedRoot: URL { URL(filePath: "/work/slipstream/workspaces") }
  var created: String { "/work/slipstream/workspaces/r/workspace-1" }

  func newWorkspace(_ model: TerminalPageModel) -> Task<String?, Never> {
    Task { await model.newWorkspaceStarted(repository: repository, store: "store-1", managedRoot: managedRoot) }
  }

  /// Shows `a` (Terminal 1 is UUID(0), launch 0), then starts New Workspace (Setup is UUID(1), launch 1).
  func startedSetup() async -> (TerminalPageModel, Task<String?, Never>) {
    let model = makeModel()
    await model.workspaceChanged(folder: a)
    let setup = newWorkspace(model)
    await Task.megaYield()
    return (model, setup)
  }

  func setupTab(_ model: TerminalPageModel) -> TerminalTabModel? {
    model.shownTabs.first { $0.id == UUID(1) }
  }

  @Test func setupLaunchesCreateCommand() async {
    let (model, setup) = await startedSetup()

    expectNoDifference(
      fake.launches.last,
      TerminalLaunch(
        executable: "/opt/slipstream/bin/slipstream",
        arguments: ["workspace", "create", "/work/r", "--store", "store-1"],
        environment: TerminalFake.environment.variables, directory: "/work/r",
        size: setupTab(model)?.surface.size ?? TerminalSize(columns: 0, rows: 0)))
    expectNoDifference(
      fake.savedState(at: .launch(directory: "/work/r"))?.tabs[id: UUID(1)],
      TerminalTabRecord(id: UUID(1), folder: nil, kind: .setup(.running)))
    #expect(model.selectedTab?.id == UUID(1))
    #expect(model.selectedTab?.footerText == "Setting up…")
    #expect(model.selectedTab?.statusIcon == .running)

    fake.finish(.exited(1))
    _ = await setup.value
  }

  @Test func environmentFailureWritesItsText() async {
    fake.setEnvironmentError(TerminalLaunchError(text: "Couldn't read PATH from your login shell"))
    let model = makeModel()

    let path = await model.newWorkspaceStarted(repository: repository, store: "store-1", managedRoot: managedRoot)

    #expect(path == nil)
    #expect(fake.log(UUID(0)).contains("Couldn't read PATH from your login shell"))
    expectNoDifference(fake.saved?.tabs[id: UUID(0)]?.kind, .setup(.failed(exitStatus: nil)))
    expectNoDifference(fake.launches, [])
  }

  @Test func firstValidPathMovesSetupTab() async {
    let (model, setup) = await startedSetup()

    fake.send("created \(created)\r\nworkspace_path: \(created)\r\n")
    let path = await setup.value

    #expect(path == created)
    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.folder, created)
    #expect(fake.saved?.selectedTabIDs[created] == UUID(1))
    await model.workspaceChanged(folder: created)
    #expect(setupTab(model)?.footerText == "Setting up workspace-1…")
  }

  @Test func invalidPathIsIgnored() async {
    let (_, setup) = await startedSetup()
    fake.setMissing("/work/slipstream/workspaces/r/gone")

    fake.send("workspace_path: /elsewhere/r/workspace-1\r\n")
    fake.send("workspace_path: /work/slipstream/workspaces/r\r\n")
    fake.send("workspace_path: /work/slipstream/workspaces/r/gone\r\n")
    fake.finish(.exited(0))
    let path = await setup.value

    #expect(path == nil)
    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.folder, nil)
  }

  @Test func laterPathsAreIgnored() async {
    let (_, setup) = await startedSetup()

    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    fake.send("workspace_path: /work/slipstream/workspaces/r/workspace-2\r\n")
    await Task.megaYield()

    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.folder, created)
  }

  @Test func oldCliFinalLineMovesSetupTab() async {
    let (model, setup) = await startedSetup()

    fake.send("SETUP-DONE\r\n")
    fake.send("workspace_path: \(created)\n")
    fake.finish(.exited(0))
    let path = await setup.value
    await Task.megaYield()

    #expect(path == created)
    expectNoDifference(
      model.state.tabs[id: UUID(1)],
      TerminalTabRecord(id: UUID(1), folder: created, kind: .setup(.finished(seconds: 0))))
  }

  @Test func finishedAfterFourteenSeconds() async {
    let (model, setup) = await startedSetup()
    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    await model.workspaceChanged(folder: created)

    await clock.advance(by: .milliseconds(14_900))
    fake.finish(.exited(0), launch: 1)
    await Task.megaYield()

    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.finished(seconds: 14)))
    #expect(setupTab(model)?.footerText == "Setup finished · 14s")
    #expect(setupTab(model)?.statusIcon == .finished)
  }

  @Test func setupInAFolderEndsWhenItsCommandFinishes() async {
    let (model, setup) = await startedSetup()
    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    #expect(model.isSettingUp(folder: created))
    #expect(!model.isSettingUp(folder: a))

    let ended = Task { await model.setupEnded(in: created) }
    fake.finish(.exited(0), launch: 1)
    await ended.value

    #expect(!model.isSettingUp(folder: created))
  }

  @Test func failureWithFolder() async {
    let (model, setup) = await startedSetup()
    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    await model.workspaceChanged(folder: created)

    fake.finish(.exited(1), launch: 1)
    await Task.megaYield()

    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.failed(exitStatus: 1)))
    #expect(setupTab(model)?.footerText == "Setup failed — exit 1. The workspace was created.")
    #expect(setupTab(model)?.statusIcon == .failed)
  }

  @Test func failureWithoutFolder() async {
    let (model, setup) = await startedSetup()

    fake.finish(.exited(1))
    let path = await setup.value

    #expect(path == nil)
    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.failed(exitStatus: 1)))
    #expect(
      setupTab(model)?.footerText == "Setup failed — no workspace was created. Close this tab to dismiss.")
  }

  @Test func signalMapsToExitCode() async {
    let (_, setup) = await startedSetup()

    fake.finish(.signalled(15))
    _ = await setup.value

    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.failed(exitStatus: 143)))
  }

  @Test func statusSavedAfterFlush() async {
    let (_, setup) = await startedSetup()

    fake.send("last line\r\n")
    fake.finish(.exited(0))
    _ = await setup.value

    expectNoDifference(fake.savedState(at: .flush(UUID(1)))?.tabs[id: UUID(1)]?.kind, .setup(.running))
    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.finished(seconds: 0)))
  }

  @Test func secondNewWorkspaceReplacesFolderlessSetup() async {
    let (model, first) = await startedSetup()
    fake.send("fatal: no origin\r\n")
    fake.finish(.exited(1))
    _ = await first.value

    let second = newWorkspace(model)
    await Task.megaYield()

    #expect(!fake.hasLog(UUID(1)))
    expectNoDifference(fake.saved?.tabs.ids.elements, [UUID(0), UUID(2)])
    expectNoDifference(model.shownTabs.map(\.id), [UUID(2), UUID(0)])
    #expect(model.selectedTab?.id == UUID(2))

    fake.finish(.exited(1))
    _ = await second.value
  }

  @Test func movedSetupLeavesOtherWorkspaces() async {
    let (model, setup) = await startedSetup()

    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value

    expectNoDifference(model.shownTabs.map(\.id), [UUID(0)])
    #expect(model.selectedTab?.id == UUID(0))
    expectNoDifference(fake.saved?.selectedTabIDs, [created: UUID(1)])
  }

  @Test func movedSetupShowsOnlyInItsWorkspace() async {
    let (model, setup) = await startedSetup()
    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value

    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1"])
    await model.workspaceChanged(folder: b)
    expectNoDifference(model.shownTabs.map(\.title), ["Terminal 1"])
    await model.workspaceChanged(folder: created)
    expectNoDifference(model.shownTabs.map(\.title), ["Setup", "Terminal 1"])
  }

  @Test func anotherWorkspacesSetupNeverShowsEvenWhenSelected() async {
    let model = makeModel(
      [
        terminal(100, in: a, number: 1),
        TerminalTabRecord(id: UUID(101), folder: b, kind: .setup(.finished(seconds: 3))),
      ],
      selected: [a: UUID(101)]
    )

    await model.workspaceChanged(folder: a)

    expectNoDifference(model.shownTabs.map(\.id), [UUID(100)])
    #expect(model.selectedTab?.id == UUID(100))
  }

  @Test func danglingSelectionPrefersTheWorkspacesOwnTab() async {
    let model = makeModel(
      [
        TerminalTabRecord(id: UUID(101), folder: nil, kind: .setup(.failed(exitStatus: 1))),
        terminal(100, in: a, number: 1),
      ],
      selected: [a: UUID(999)]
    )

    await model.workspaceChanged(folder: a)

    expectNoDifference(model.shownTabs.map(\.id), [UUID(101), UUID(100)])
    #expect(model.selectedTab?.id == UUID(100))
  }

  @Test func closeConfirmationSurvivesMove() async {
    let (model, setup) = await startedSetup()
    await model.closeTabTapped(UUID(1))
    #expect(setupTab(model)?.isCloseConfirmationVisible == true)

    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    await model.workspaceChanged(folder: created)

    #expect(model.selectedTab?.id == UUID(1))
    #expect(model.selectedTab?.isCloseConfirmationVisible == true)
    await model.closeConfirmed(UUID(1))
    #expect(fake.saved?.tabs[id: UUID(1)] == nil)
  }

  @Test func archiveMarksRunningSetupInterrupted() async {
    let (model, setup) = await startedSetup()
    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    await model.workspaceChanged(folder: created)

    await model.stopTabs(in: created)

    expectNoDifference(fake.savedState(at: .stop(launch: 1))?.tabs[id: UUID(1)]?.kind, .setup(.interrupted))
    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.interrupted))
  }

  @Test func archiveWhileFinishedSetupFlushesStaysInterrupted() async {
    let (model, setup) = await startedSetup()
    fake.send("workspace_path: \(created)\r\n")
    _ = await setup.value
    await model.workspaceChanged(folder: created)
    fake.hold(.flush)
    fake.finish(.exited(0), launch: 1)
    await Task.megaYield()

    let stopping = Task { await model.stopTabs(in: created) }
    await Task.megaYield()
    fake.release(.flush)
    await stopping.value

    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.interrupted))
  }

  @Test func quitWhileUnstartableSetupFlushesStaysInterrupted() async {
    fake.setLaunchError(TerminalLaunchError(text: "Couldn't start the setup shell"))
    let model = makeModel()
    await model.workspaceChanged(folder: a)
    fake.hold(.flush)
    let setup = newWorkspace(model)
    await Task.megaYield()

    let quitting = Task { await model.quitConfirmed() }
    await Task.megaYield()
    fake.release(.flush)
    await quitting.value
    _ = await setup.value

    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.interrupted))
  }

  @Test func closedSetupDoesNotReturnABufferedPath() async {
    let (model, setup) = await startedSetup()

    fake.send("workspace_path: \(created)\r\n")
    await model.closeConfirmed(UUID(1))

    #expect(await setup.value == nil)
  }

  @Test func quitWhileReplacingAFailedSetupLaunchesNothing() async {
    let (model, first) = await startedSetup()
    fake.finish(.exited(1))
    _ = await first.value
    fake.hold(.flush)

    let second = newWorkspace(model)
    await Task.megaYield()
    let quitting = Task { await model.quitConfirmed() }
    await Task.megaYield()
    fake.release(.flush)
    await quitting.value
    await Task.megaYield()

    #expect(fake.launches.count == 2)
    if fake.launches.count > 2 { fake.finish(.exited(1)) }
    #expect(await second.value == nil)
  }

  @Test func newWorkspaceAfterQuitKeepsTheFailedSetup() async {
    let (model, first) = await startedSetup()
    fake.send("fatal: no origin\r\n")
    fake.finish(.exited(1))
    _ = await first.value
    await model.quitConfirmed()

    #expect(await newWorkspace(model).value == nil)

    #expect(fake.hasLog(UUID(1)))
    #expect(fake.saved?.tabs[id: UUID(1)] != nil)
  }

  @Test func quitMarksRunningSetupInterrupted() async {
    let (model, setup) = await startedSetup()

    await model.quitConfirmed()
    _ = await setup.value

    expectNoDifference(fake.savedState(at: .stop(launch: 1))?.tabs[id: UUID(1)]?.kind, .setup(.interrupted))
    expectNoDifference(fake.saved?.tabs[id: UUID(1)]?.kind, .setup(.interrupted))
  }

  @Test func replayedSetupRunsNothing() async {
    let replayed = "/work/slipstream/workspaces/r/workspace-2"
    fake.setLog(UUID(100), "workspace_path: \(replayed)\r\n")
    let model = makeModel([TerminalTabRecord(id: UUID(100), folder: a, kind: .setup(.finished(seconds: 3)))])

    await model.workspaceChanged(folder: a)

    expectNoDifference(fake.launches.map(\.directory), [a])
    expectNoDifference(fake.saved?.tabs[id: UUID(100)]?.folder, a)
  }
}

private struct FailingTerminalStateKey: SharedKey {
  struct SaveError: Error {}

  let id = UUID()

  func load(context: LoadContext<TerminalState>, continuation: LoadContinuation<TerminalState>) {
    continuation.resumeReturningInitialValue()
  }

  func subscribe(
    context: LoadContext<TerminalState>, subscriber: SharedSubscriber<TerminalState>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: TerminalState, context: SaveContext, continuation: SaveContinuation) {
    continuation.resume(throwing: SaveError())
  }
}
