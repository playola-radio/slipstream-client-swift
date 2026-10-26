import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import IssueReporting
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct TerminalPageTests {
  let fake = TerminalFake()
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

    await expectReportsIssue {
      await model.workspaceChanged(folder: a)
    } matching: { issue in
      issue.description.contains("Caught error")
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

    expectNoDifference(model.shownTabs.map(model.tabStatusIcon), [.running, .finished, .failed, .failed, nil])
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
