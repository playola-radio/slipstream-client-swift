import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
@_spi(Internals) import Sharing
import SlipstreamCore
import SwiftUI
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct ChangeStreamPageTests {
  let fake: DaemonFake
  let clock = TestClock()
  let storage = InMemoryStorage()
  let link = ChatLinkFake()
  let agent = AgentFake()
  let terminal = TerminalFake()
  let recordingFake = RecordingFake()
  let nameFake = WorkspaceNameFake()
  let suggestionFake = WorkspaceNameSuggestionFake()
  let copied = LockIsolated<[String]>([])
  let files = LockIsolated<[URL: Data]>([:])

  init() {
    fake = DaemonFake()
    fake.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)], starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    fake.setCaptures([Fixture.capture()])
  }

  func makeModel(
    daemon: DaemonFake? = nil, storage: InMemoryStorage? = nil, files: LockIsolated<[URL: Data]>? = nil,
    isFunctionDemoVisible: Bool = false, now: (@Sendable () -> Date)? = nil,
    chat: ChatPageModel? = nil, workspace: WorkspaceClient? = nil, instantAsk: InstantAskModel? = nil,
    terminals: TerminalPageModel? = nil, recorder: RecorderModel? = nil, fileStorage: FileStorage? = nil
  ) -> ChangeStreamPageModel {
    let terminals = terminals ?? makeTerminals()
    let workspace = workspace ?? Self.testRootsWorkspace
    return withDependencies {
      $0.workspace = workspace
      $0.defaultInMemoryStorage = storage ?? self.storage
      $0.defaultFileStorage = fileStorage ?? .inMemory(fileSystem: files ?? self.files)
      $0.daemon = (daemon ?? fake).client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(ConstantGenerator())
      $0.timeZone = TimeZone(identifier: "UTC")!
      $0.date = DateGenerator(now ?? { Fixture.checkedAt })
      $0.terminalRuntime = terminal.runtimeClient
      $0.recording = recordingFake.client
      $0.workspaceName = nameFake.client
      $0.workspaceNameSuggestion = suggestionFake.client
      $0.agentEnvironment = agent.environmentClient
      $0.pasteboard = PasteboardClient(copy: { [copied] text in copied.withValue { $0.append(text) } })
      $0.openIn.installedApps = { [] }
    } operation: {
      let chat = chat ?? makeChat()
      return ChangeStreamPageModel(
        chat: chat, instantAsk: instantAsk ?? InstantAskModel(chat: chat), terminals: terminals,
        recorder: recorder ?? RecorderModel(state: .running), isFunctionDemoVisible: isFunctionDemoVisible)
    }
  }

  func makeTerminals(history: TerminalHistoryClient? = nil) -> TerminalPageModel {
    withDependencies {
      $0.defaultFileStorage = terminal.fileStorage
      $0.terminalRuntime = terminal.runtimeClient
      $0.terminalHistory = history ?? terminal.historyClient
      $0.uuid = .incrementing
      $0.continuousClock = clock
    } operation: {
      TerminalPageModel()
    }
  }

  func makeChat(records: [ChatTabRecord] = []) -> ChatPageModel {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.uuid = .incrementing
      $0.chatLink = link.client
      $0.agentEnvironment = agent.environmentClient
      $0.transcripts = agent.transcriptClient
    } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock { $0 = IdentifiedArray(uniqueElements: records) }
      return ChatPageModel()
    }
  }

  func connectedModel(storage: InMemoryStorage? = nil) async -> ChangeStreamPageModel {
    let model = makeModel(storage: storage)
    await model.viewAppeared()
    await Task.megaYield()
    return model
  }

  func send(_ items: StreamItem...) async {
    for item in items { fake.send(item) }
    await Task.megaYield()
  }

  func send(to index: Int, _ items: StreamItem...) async {
    for item in items { fake.send(to: index, item) }
    await Task.megaYield()
  }

  func fileRow(_ model: ChangeStreamPageModel, _ id: Int) -> FileChangeRow? {
    for section in model.sections {
      if case .file(let row) = section.items[id: Fixture.seq(id)] { return row }
    }
    return nil
  }

  // MARK: - Chat link

  @Test func capturesReachChatAfterEveryRefresh() async {
    let model = await connectedModel()
    expectNoDifference(model.chat.outsideChatText, "Stream: outside chat")

    fake.setCaptures([Fixture.capture(binding: nil)])
    await model.reloadShortcutPressed()
    expectNoDifference(model.chat.outsideChatText, nil)

    fake.setCaptures([Fixture.capture()])
    await model.reloadShortcutPressed()
    expectNoDifference(model.chat.outsideChatText, "Stream: outside chat")

    fake.setCaptures(.failure(.invalidResponse))
    await model.reloadShortcutPressed()
    expectNoDifference(model.chat.outsideChatText, nil)

    fake.setCaptures([Fixture.capture()])
    await model.reloadShortcutPressed()
    fake.setDiscoverError(URLError(.cannotConnectToHost))
    await model.reloadShortcutPressed()
    expectNoDifference(model.chat.outsideChatText, nil)
  }

  @Test func linkChangeRefreshesCaptures() async {
    let model = await connectedModel()
    fake.setCaptures([Fixture.capture(binding: nil)])
    await model.chat.onLinkChanged()
    expectNoDifference(model.chat.outsideChatText, nil)
  }

  @Test func confirmationRefreshesTheLinkedBinding() async {
    listSessions(.setupPending)
    fake.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "7", state: .setupPending))])
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setCaptures([Fixture.capture()])

    await send(Fixture.agentConnection(1, state: "connected"))
    await Task.megaYield()

    expectNoDifference(model.selectedSession?.capture?.binding, CaptureBinding(generation: "7", state: .connected))
  }

  @Test func aChatLinkedFromTheTerminalRefreshesTheBinding() async {
    listSessions(.disconnected(reason: "no_agent"))
    fake.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "6", state: .unlinked))])
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "7", state: .setupPending))])

    await send(Fixture.agentConnection(1, state: "setup_pending"))
    await Task.megaYield()

    expectNoDifference(model.selectedSession?.capture?.binding, CaptureBinding(generation: "7", state: .setupPending))
  }

  @Test func unlinkingRefreshesTheLinkedBinding() async {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "7", state: .unlinked))])

    await send(Fixture.agentUnlinked(1))
    await Task.megaYield()

    expectNoDifference(model.selectedSession?.capture?.binding, CaptureBinding(generation: "7", state: .unlinked))
  }

  @Test func linkingAnotherChatRefreshesTheBindingEvenInTheSameState() async {
    listSessions(.setupPending)
    fake.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "7", state: .setupPending))])
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "8", state: .setupPending))])

    await send(Fixture.agentBinding(1, generation: "8"))
    await Task.megaYield()

    expectNoDifference(model.selectedSession?.capture?.binding, CaptureBinding(generation: "8", state: .setupPending))
    expectNoDifference(model.sections.flatMap(\.items).count, 0)
  }

  // MARK: - Sessions

  @Test func sessionsKeepTheirIDAsLabelAndRemovedOnesHidden() async {
    fake.setCaptures([])
    fake.setSessions(
      [
        SessionSummary(id: "a", durableSeq: .zero, removed: false),
        SessionSummary(id: "b", durableSeq: .zero, removed: true),
        SessionSummary(id: "c", durableSeq: .zero, removed: false),
      ],
      starts: ["a": SessionStarted(root: "/work/alpha", startedAtMs: 1_791_037_090_974)]
    )
    let model = makeModel()
    await model.viewAppeared()
    expectNoDifference(
      model.sessions,
      [
        SessionOption(id: "a", label: "a", root: "/work/alpha"),
        SessionOption(id: "c", label: "c"),
      ]
    )
    #expect(model.selectedSession == nil)
    #expect(model.emptyStateText == "No capture sessions yet")
  }

  @Test func aRefreshPublishesOnlyOnceEveryFolderIsKnown() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionStartGates: ["slow": gate])
    daemon.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/slipstream-test/workspaces/ready/w", startedAtMs: 0)])
    daemon.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let before = model.sidebarGroups
    daemon.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: "slow", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/slipstream-test/workspaces/ready/w", startedAtMs: 0),
        "slow": SessionStarted(root: "/tmp/slipstream-test/workspaces/slow/w", startedAtMs: 0),
      ])

    let reloading = Task { await model.reloadShortcutPressed() }
    await daemon.waitForSessionStartCall(2)
    await Task.megaYield()
    expectNoDifference(model.sidebarGroups, before)
    #expect(model.sessions[id: "slow"] == nil)

    release.yield()
    await reloading.value
    expectNoDifference(model.sidebarGroups.map(\.name), ["ready", "slow"])
  }

  @Test func aNewSessionTakesItsCapturesFolder() async {
    fake.setSessions([SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false)])
    fake.setCaptures([Fixture.capture(session: Fixture.otherSession, root: Self.workspaceRoot)])
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()

    expectNoDifference(Self.names(model.sidebarGroups), [["r", "workspace-1"]])
    expectNoDifference(fake.sessionStartCallCount, 0)
  }

  @Test func aSessionWithoutAFolderIsNotListed() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/project", startedAtMs: 0)])
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(Self.names(model.sidebarGroups), [["r", "project"]])
  }

  static func names(_ groups: [SidebarGroup]) -> [[String]] {
    groups.map { [$0.name] + $0.rows.map(SidebarGroup.rowName) }
  }

  @Test func closingTheWindowDuringSessionDiscoveryStartsNothing() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)])
    let model = makeModel(daemon: daemon)
    let appeared = Task { await model.viewAppeared() }
    await Task.megaYield()
    model.viewDisappeared()
    open.yield()
    await appeared.value
    #expect(model.selectedSession == nil)
    #expect(daemon.follows.isEmpty)
  }

  @Test func aReloadQueuedBeforeTheWindowClosesStartsNothing() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)])
    let model = makeModel(daemon: daemon)
    let appeared = Task { await model.viewAppeared() }
    await Task.megaYield()
    await model.reloadShortcutPressed()
    model.viewDisappeared()
    open.yield()
    open.yield()
    await appeared.value
    #expect(model.selectedSession == nil)
    #expect(daemon.follows.isEmpty)
  }

  @Test func singleSessionIsSelectedAutomatically() async {
    let model = await connectedModel()
    #expect(model.selectedSession?.id == Fixture.session)
    expectNoDifference(fake.follows, [FollowRequest(token: "token-1", sessionID: Fixture.session, cursor: .zero)])
    #expect(model.statusText == "Connecting…")
    #expect(model.emptyStateText == "Waiting for changes…")
  }

  @Test func selectedFolderComesFromStartRecord() async {
    let model = await connectedModel()
    #expect(model.selectedFolder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
  }

  @Test func rootSurvivesRefreshThatFailsStartFetch() async {
    let model = await connectedModel()
    fake.setSessionStartError(URLError(.networkConnectionLost))
    await model.reloadShortcutPressed()
    #expect(model.selectedFolder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
    #expect(model.sessions[id: Fixture.session]?.root == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
  }

  @Test func aSessionIsSelectedOnlyOnceItsFolderLoads() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionStartGates: [Fixture.session: gate])
    daemon.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel(daemon: daemon)
    let appeared = Task { await model.viewAppeared() }
    await daemon.waitForSessionStartCall(1)
    await Task.megaYield()
    #expect(model.selectedSession == nil)
    #expect(model.selectedFolder == nil)
    #expect(model.openIn.folder == nil)
    release.yield()
    await appeared.value
    #expect(model.selectedFolder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
    #expect(model.openIn.folder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
  }

  @Test func selectingStreamTellsChatTheFolder() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/other", startedAtMs: 0),
      ])
    fake.setCaptures([Fixture.capture(root: "/tmp/slipstream-test/workspaces/r/project")])
    let model = await connectedModel()
    #expect(model.chat.folder == nil)
    #expect(model.chat.noWorkspaceText == "Choose a capture session to watch its changes")

    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()

    #expect(model.chatEmptyText == nil)
    #expect(model.chat.folder == ChangeStreamPageModel.normalizedFolder("/tmp/slipstream-test/workspaces/r/other"))
    #expect(model.chat.noWorkspaceText == nil)
    #expect(model.chat.visibleTabs.count == 1)
  }

  /// SwiftUI builds a page model on every App body pass and keeps only the first, so a
  /// discarded one must not reset the shared chat.
  @Test func buildingPageLeavesChatWorkspaceAlone() {
    let chat = makeChat()
    chat.workspaceChanged(folder: "/w", emptyText: nil)

    _ = makeModel(chat: chat)

    #expect(chat.folder == "/w")
  }

  @Test func chatTextWhileFolderUnknown() async {
    let daemon = DaemonFake()
    daemon.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    daemon.setSessionStartError(URLError(.networkConnectionLost))
    let model = makeModel(daemon: daemon)

    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.chatEmptyText == "Finding this stream's folder…")
    #expect(model.chat.noWorkspaceText == "Finding this stream's folder…")

    daemon.setSessionStartError(nil)
    await model.reloadShortcutPressed()
    #expect(model.chatEmptyText == nil)
    #expect(model.chat.folder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
  }

  @Test func comparisonOpenTellsChat() async {
    let model = await connectedModel()
    await send(
      Fixture.frame(1, type: "slipstream.capture.baseline.completed.v1", data: [:]),
      Fixture.edited(2)
    )

    model.compareFunctionsTapped()
    #expect(model.chat.isComparisonShown)

    model.functionChangesClosed()
    #expect(model.chat.isComparisonShown == false)

    model.compareFunctionsTapped()
    fake.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
    ])
    await model.reloadShortcutPressed()
    model.sessionSelected(Fixture.otherSession)
    #expect(model.chat.isComparisonShown == false)
  }

  /// Closing the window mid-comparison and cancelling the quit brings back a fresh page.
  @Test func reopenedPageTellsChatComparisonIsClosed() async {
    let chat = makeChat()
    chat.comparisonVisibilityChanged(isShown: true)
    let model = makeModel(chat: chat)

    await model.viewAppeared()

    #expect(chat.isComparisonShown == false)
  }

  @Test func reopenedPageRestoresTheStreamForItsChatWorkspace() async {
    let chat = makeChat()
    let folder = ChangeStreamPageModel.normalizedFolder("/tmp/project")
    chat.workspaceChanged(folder: folder, emptyText: nil)
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let model = makeModel(chat: chat)

    await model.viewAppeared()

    #expect(model.selectedSession?.id == Fixture.session)
    #expect(chat.folder == folder)
  }

  @Test func pickerRowBoldWhenFolderWaiting() async throws {
    let folder = ChangeStreamPageModel.normalizedFolder("/tmp/project")
    let chat = makeChat(records: [
      ChatTabRecord(id: UUID(50), folder: folder, model: "claude-opus-5-5", effort: .high, isWaiting: true)
    ])
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let model = makeModel(chat: chat)
    await model.viewAppeared()
    await Task.megaYield()

    let waiting = try #require(model.sessions[id: Fixture.session])
    let other = try #require(model.sessions[id: Fixture.otherSession])
    #expect(model.isBold(waiting))
    #expect(model.isBold(other) == false)
  }

  @Test func folderIsNormalized() {
    #expect(ChangeStreamPageModel.normalizedFolder("/work/./alpha/../alpha/") == "/work/alpha")
  }

  @Test func compareFunctionsFreezesRecordedBaselineAndCurrentFeedHead() async {
    let model = await connectedModel()
    #expect(!model.canCompareFunctions)
    expectNoDifference(
      model.compareFunctionsHelpText,
      "Available once Slipstream has recorded where this workspace started")
    await send(
      Fixture.frame(1, type: "slipstream.capture.baseline.completed.v1", data: [:]),
      Fixture.edited(2)
    )
    #expect(model.canCompareFunctions)
    expectNoDifference(
      model.compareFunctionsHelpText, "Compare each function before and after this session's changes")
    model.compareFunctionsTapped()
    expectNoDifference(model.functionChanges?.sessionID, Fixture.session)
    expectNoDifference(model.functionChanges?.before, Fixture.seq(1))
    expectNoDifference(model.functionChanges?.after, Fixture.seq(2))
    await send(Fixture.edited(3))
    expectNoDifference(model.functionChanges?.after, Fixture.seq(2))
    await send(Fixture.frame(4, type: "slipstream.capture.baseline.completed.v1", data: [:]))
    model.compareFunctionsTapped()
    expectNoDifference(model.functionChanges?.before, Fixture.seq(1))
    expectNoDifference(model.functionChanges?.after, Fixture.seq(4))
    fake.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: Fixture.seq(4), removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
    ])
    await model.reloadShortcutPressed()
    model.sessionSelected(Fixture.otherSession)
    #expect(model.functionChanges == nil)
    #expect(!model.canCompareFunctions)
  }

  @Test func missingDaemonIsExplained() async {
    fake.setDiscoverError(DescriptorError.noRuntimeDirectory(path: "/tmp/store/runtime", errno: ENOENT, message: "No such file or directory"))
    let model = makeModel()
    await model.viewAppeared()
    #expect(model.emptyStateText == "The app found no recorder address to connect to.")
  }

  @Test func refreshPicksUpNewSessions() async {
    fake.setCaptures([])
    fake.setSessions([])
    let model = makeModel()
    await model.viewAppeared()
    #expect(model.emptyStateText == "No capture sessions yet")
    fake.setSessions([SessionSummary(id: "a", durableSeq: .zero, removed: false), SessionSummary(id: "b", durableSeq: .zero, removed: false)])
    await model.reloadShortcutPressed()
    #expect(model.sessions.ids == ["a", "b"])
  }

  // MARK: - Workspace names

  @Test func namesUpdateRowAndBreadcrumbTogether() async {
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Agent's name"))],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()
    fake.setSessions(
      [
        SessionSummary(
          id: Fixture.session, durableSeq: .zero, removed: false,
          naming: SessionNaming(agentName: "Agent's name", userName: "My name"))
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])

    await model.reloadShortcutPressed()

    expectNoDifference([model.rowName(model.sessions[0]), model.breadcrumbWorkspaceText], ["My name", "My name"])
  }

  @Test func firstMessageInAnUnnamedWorkspaceNamesItsSession() async {
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming())],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()

    model.chat.onMessageSent("/tmp/project", "Fix the sidebar")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, ["Fix the sidebar"])
    expectNoDifference(
      nameFake.calls, [.init(sessionID: Fixture.session, name: "Sidebar Polling Backoff", isAgentName: true)])
  }

  @Test func captureOnlyWorkspaceWithoutNamingStillGetsNamed() async {
    let model = makeModel()
    await model.viewAppeared()
    expectNoDifference(model.sessions[id: Fixture.session]?.naming, nil)

    model.chat.onMessageSent("/tmp/project", "Fix the sidebar")
    await Task.megaYield()

    expectNoDifference(nameFake.calls.map(\.sessionID), [Fixture.session])
  }

  @Test func firstMessageInANamedWorkspaceDoesNothing() async {
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Agent's name"))],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()

    model.chat.onMessageSent("/tmp/project", "Fix the sidebar")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, [])
    expectNoDifference(nameFake.calls, [])
  }

  @Test func firstMessageInAFolderWithNoSessionDoesNothing() async {
    fake.setCaptures([])
    fake.setSessions([])
    let model = makeModel()
    await model.viewAppeared()

    model.chat.onMessageSent("/tmp/elsewhere", "Fix the sidebar")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, [])
    expectNoDifference(nameFake.calls, [])
  }

  @Test func queuedNoticeUsesLatestNameAfterPoll() async {
    fake.setCaptures([])
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Agent's name")),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()
    model.selectedSession = model.sessions[id: Fixture.otherSession]
    model.connection = .live
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { try AskAgentPageTests.ack($0) }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    await model.askQuestionTapped(composer)
    fake.setSessions(
      [
        SessionSummary(
          id: Fixture.session, durableSeq: .zero, removed: false,
          naming: SessionNaming(agentName: "Agent's name", userName: "My name")),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])

    await model.reloadShortcutPressed()

    expectNoDifference(
      model.footerText, "Connected · New changes appear below · Question queued for My name (delivery not confirmed)")
  }

  @Test func renameDisabledReasons() {
    let model = makeModel()

    expectNoDifference(
      [
        SessionOption(id: "named", label: "named", naming: SessionNaming()),
        SessionOption(id: "capture-only", label: "w", hasHistory: false),
        SessionOption(id: "older-daemon", label: "older-daemon"),
      ].map(model.renameDisabledReason),
      [
        nil,
        "Can be named once work starts here.",
        "This version of the Slipstream daemon can't rename workspaces.",
      ])
  }

  @Test func renameHelpTextIsTheDisabledReason() {
    let model = makeModel()

    expectNoDifference(
      [
        SessionOption(id: "named", label: "named", naming: SessionNaming()),
        SessionOption(id: "capture-only", label: "w", hasHistory: false),
      ].map(model.renameHelpText),
      ["", "Can be named once work starts here."])
  }

  @Test func useAgentNameEnabledOnlyWithUserName() {
    let model = makeModel()

    expectNoDifference(
      [
        SessionOption(id: "renamed", label: "renamed", naming: SessionNaming(agentName: "Agent's name", userName: "My name")),
        SessionOption(id: "agent-named", label: "agent-named", naming: SessionNaming(agentName: "Agent's name")),
        SessionOption(id: "older-daemon", label: "older-daemon"),
      ].map(model.isUseAgentNameEnabled),
      [true, false, false])
  }

  @Test func pollDoesNotChangeDraft() async {
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Agent's name"))],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.renameMenuTapped(model.sessions[0])
    model.naming.draftChanged("My draft")
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Newer agent name"))],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let poll = Task { await model.sessionPollTask() }

    await clock.advance(by: .seconds(2))
    await Task.megaYield()

    expectNoDifference(model.rowName(model.sessions[0]), "Newer agent name")
    expectNoDifference(model.naming.dialog?.draft, "My draft")
    poll.cancel()
    await poll.value
  }

  @Test func useAgentNameFailureRaisesAlert() async {
    fake.setSessions(
      [
        SessionSummary(
          id: Fixture.session, durableSeq: .zero, removed: false,
          naming: SessionNaming(agentName: "Agent's name", userName: "My name"))
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()
    nameFake.setFailure(.rejected(code: "STORAGE_UNAVAILABLE", message: "store lock lost"))

    await model.useAgentNameMenuTapped(model.sessions[0])

    expectNoDifference([model.isWorkspaceFailurePresented, model.isWorkspaceFailureCopyShown], [true, true])
    expectNoDifference(
      [model.workspaceFailureTitle, model.workspaceFailureText, model.workspaceFailureDetail],
      [
        "Couldn't switch back to the agent's name", "STORAGE_UNAVAILABLE: store lock lost",
        "STORAGE_UNAVAILABLE: store lock lost",
      ])
    model.copyWorkspaceFailureTapped()
    expectNoDifference(copied.value, ["STORAGE_UNAVAILABLE: store lock lost"])
  }

  @Test func namingMenuActionsAreDisabledWhileAMutationRuns() async {
    fake.setSessions(
      [
        SessionSummary(
          id: Fixture.session, durableSeq: .zero, removed: false,
          naming: SessionNaming(agentName: "Agent's name", userName: "My name"))
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()
    nameFake.hold()

    let clear = Task { await model.useAgentNameMenuTapped(model.sessions[0]) }
    await Task.megaYield()

    expectNoDifference(
      [model.isRenameEnabled(model.sessions[0]), model.isUseAgentNameEnabled(model.sessions[0])], [false, false])
    nameFake.release()
    await clear.value
  }

  // MARK: - Session poll

  @Test func pollRefreshesEveryTwoSeconds() async {
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let calls = fake.sessionsCallCount
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, naming: SessionNaming(agentName: "Agent's name"))],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let poll = Task { await model.sessionPollTask() }

    await clock.advance(by: .seconds(2))
    await Task.megaYield()

    expectNoDifference(fake.sessionsCallCount, calls + 1)
    expectNoDifference(model.rowName(model.sessions[0]), "Agent's name")
    poll.cancel()
    await poll.value
  }

  @Test func noPollWhileInactive() async {
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let poll = Task { await model.sessionPollTask() }
    await Task.megaYield()
    model.chat.appActivityChanged(isActive: false)
    let calls = fake.sessionsCallCount

    await clock.advance(by: .seconds(10))
    await Task.megaYield()

    expectNoDifference(fake.sessionsCallCount, calls)
    #expect(!model.isSessionPollRunning)
    poll.cancel()
    await poll.value
  }

  @Test func reactivationRefreshesImmediately() async {
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.chat.appActivityChanged(isActive: false)
    let calls = fake.sessionsCallCount

    await model.appBecameActive()

    expectNoDifference(fake.sessionsCallCount, calls + 1)
    #expect(model.isSessionPollRunning)
  }

  @Test func pollFetchesStartRecordsOnce() async {
    fake.setCaptures([])
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let poll = Task { await model.sessionPollTask() }

    for _ in 1...3 {
      await clock.advance(by: .seconds(2))
      await Task.megaYield()
    }

    expectNoDifference(fake.sessionStartCallCount, 2)
    poll.cancel()
    await poll.value
  }

  @Test func pollTicksCoalesce() async {
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
    open.yield()
    await appeared.value
    let calls = daemon.sessionsCallCount
    let poll = Task { await model.sessionPollTask() }
    await clock.advance(by: .seconds(2))
    await Task.megaYield()

    await model.reloadShortcutPressed()
    await model.reloadShortcutPressed()
    expectNoDifference(daemon.sessionsCallCount, calls + 1)
    open.yield()
    await Task.megaYield()
    open.yield()
    await Task.megaYield()

    expectNoDifference(daemon.sessionsCallCount, calls + 2)
    poll.cancel()
    open.finish()
    await poll.value
  }

  @Test func backgroundingMidPollKeepsTheRefresh() async {
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
    open.yield()
    await appeared.value
    let calls = daemon.sessionsCallCount
    let poll = Task { await model.sessionPollTask() }
    await clock.advance(by: .seconds(2))
    await Task.megaYield()

    model.chat.appActivityChanged(isActive: false)
    poll.cancel()
    await model.appBecameActive()
    open.yield()
    await Task.megaYield()
    open.yield()
    await Task.megaYield()

    expectNoDifference(daemon.sessionsCallCount, calls + 2)
    expectNoDifference(model.captureAvailability, .available(checkedAt: Fixture.checkedAt))
    open.finish()
    await poll.value
  }

  @Test func namingWriteAfterTheWindowClosesDoesNotRefresh() async {
    fake.setSessions(
      [
        SessionSummary(
          id: Fixture.session, durableSeq: .zero, removed: false,
          naming: SessionNaming(agentName: "Agent's name", userName: "My name"))
      ],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel()
    await model.viewAppeared()
    nameFake.hold()
    let clear = Task { await model.useAgentNameMenuTapped(model.sessions[0]) }
    await Task.megaYield()

    model.viewDisappeared()
    let calls = fake.sessionsCallCount
    nameFake.release()
    await clear.value

    expectNoDifference(fake.sessionsCallCount, calls)
  }

  // MARK: - Cursor

  @Test func eventsBuildSectionsAndAdvanceTheCursor() async {
    let model = await connectedModel()
    await send(
      .heartbeat,
      Fixture.sessionStarted(1),
      Fixture.edited(2, "README.md"),
      Fixture.taskStarted(3, "Convert isActive"),
      Fixture.edited(4),
      Fixture.taskStarted(5, "Update checks"),
      Fixture.captureGap(6),
      Fixture.sessionResumed(7),
      Fixture.unknown(8)
    )
    #expect(model.statusText == "Connected")
    #expect(model.lastAppliedSeq == Fixture.seq(8))
    expectNoDifference(
      model.sections,
      [
        FeedSection(
          id: .zero,
          heading: nil,
          items: [.file(FileChangeRow(id: Fixture.seq(2), path: "README.md", before: .content(sha256: Fixture.shaA, size: 10), after: .content(sha256: Fixture.shaB, size: 10), time: "10:42:18"))]
        ),
        FeedSection(
          id: Fixture.seq(3),
          heading: TaskHeading(number: "01", title: "Convert isActive"),
          items: [.file(FileChangeRow(id: Fixture.seq(4), path: "src/user.ts", before: .content(sha256: Fixture.shaA, size: 10), after: .content(sha256: Fixture.shaB, size: 10), time: "10:42:18"))]
        ),
        FeedSection(
          id: Fixture.seq(5),
          heading: TaskHeading(number: "02", title: "Update checks"),
          items: [
            .marker(FeedMarker(id: Fixture.seq(6), text: "Capture gap — the file watcher failed (src/)"))
          ]
        ),
        FeedSection(
          id: Fixture.seq(7),
          heading: nil,
          items: [
            .marker(FeedMarker(id: Fixture.seq(7), text: "Capture restarting")),
            .marker(FeedMarker(id: Fixture.seq(8), text: "Unsupported event: slipstream.future.thing.v1")),
          ]
        ),
      ]
    )
    #expect(model.newestFileID == Fixture.seq(4))
  }

  @Test func aResumeSaysTheCaptureIsRestartingAndThatNothingWasRecordedWhileStopped() async {
    let model = await connectedModel()
    await send(Fixture.sessionResumed(1), Fixture.restartGap(2))
    expectNoDifference(
      model.sections.flatMap(\.items),
      [
        .marker(FeedMarker(id: Fixture.seq(1), text: "Capture restarting")),
        .marker(FeedMarker(id: Fixture.seq(2), text: "Capture gap — nothing was recorded while capture was stopped (whole session)")),
      ]
    )
  }

  @Test func changesAfterAResumeAreNotFiledUnderThePreviousTask() async {
    let model = await connectedModel()
    await send(
      Fixture.taskStarted(1, "Convert isActive"),
      Fixture.edited(2),
      Fixture.sessionResumed(3),
      Fixture.restartGap(4),
      Fixture.edited(5)
    )
    expectNoDifference(model.sections.map(\.heading?.title), ["Convert isActive", nil])
    #expect(model.sections[1].items.ids == [Fixture.seq(3), Fixture.seq(4), Fixture.seq(5)])
  }

  @Test func duplicateSeqIsIgnored() async {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(1), Fixture.edited(2))
    #expect(model.sections[0].items.ids == [Fixture.seq(1), Fixture.seq(2)])
  }

  @Test func gapHaltsTheStream() async {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(3))
    #expect(model.statusText == "Stream out of order — expected #2, got #3")
    #expect(model.isRetryVisible)
    #expect(model.lastAppliedSeq == Fixture.seq(1))
  }

  @Test func malformedKnownEventHaltsTheStream() async {
    let model = await connectedModel()
    await send(Fixture.frame(1, type: "slipstream.file.changed.v1", data: ["path": "x"]))
    #expect(model.statusText == "Unreadable event #1 — feed stopped")
    #expect(model.sections.isEmpty)
  }

  @Test func gitScopeOutageRemainsVisibleAndRecoveryDoesNotEraseIt() async {
    let model = await connectedModel()
    await send(Fixture.frame(1, type: "slipstream.capture.scope.v1", data: [
      "session_id": Fixture.session, "policy": "git", "status": "active",
    ]))
    #expect(model.sections.isEmpty)
    await send(Fixture.frame(2, type: "slipstream.capture.scope.v1", data: [
      "session_id": Fixture.session, "policy": "git", "status": "unavailable",
    ]))
    await send(Fixture.frame(3, type: "slipstream.capture.scope.v1", data: [
      "session_id": Fixture.session, "policy": "git", "status": "active",
    ]))
    expectNoDifference(model.sections.flatMap { Array($0.items) }, [
      .marker(FeedMarker(id: Fixture.seq(2), text: "Capture gap — Git couldn't determine which files to capture (whole session)"))
    ])
    expectNoDifference(model.lastAppliedSeq, Fixture.seq(3))
  }

  @Test func reconnectResumesAfterLastAppliedSeqWithRediscoveredDescriptor() async {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    fake.setTokens(["token-2"])
    fake.close()
    await Task.megaYield()
    #expect(model.statusText == "Reconnecting (attempt 1)")
    await clock.advance(by: .milliseconds(500))
    expectNoDifference(
      fake.follows.map(\.cursor),
      [.zero, Fixture.seq(2)]
    )
    #expect(fake.follows.map(\.token) == ["token-1", "token-2"])
    await send(Fixture.edited(2), Fixture.edited(3))
    #expect(model.sections[0].items.ids == [Fixture.seq(1), Fixture.seq(2), Fixture.seq(3)])
    #expect(model.statusText == "Connected")
  }

  @Test func cursorAheadOfDaemonIsAnExplicitErrorAndNeverResetsSilently() async {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    fake.close(throwing: DaemonHTTPError.status(409, durableSeq: Fixture.seq(1)))
    await Task.megaYield()
    #expect(model.statusText == "Daemon history ends at #1 but this feed is at #2")
    #expect(model.retryButtonText == "Reload from start")
    #expect(model.sections[0].items.count == 2)
  }

  @Test func reloadingFromStartAfterTheDaemonFellBehindReplaysTheSession() async {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    fake.close(throwing: DaemonHTTPError.status(409, durableSeq: Fixture.seq(1)))
    await Task.megaYield()
    model.retryTapped()
    await Task.megaYield()
    #expect(fake.follows.last?.cursor == .zero)
    #expect(model.sections.isEmpty)
    #expect(model.retryButtonText == "Retry")
  }

  @Test func reloadingRolledBackHistoryResetsTheReadinessWatermark() async {
    listSessions(.disconnected(reason: "capture_not_live"))
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.agentConnection(2, state: "connected"))
    fake.close(throwing: DaemonHTTPError.status(409, durableSeq: Fixture.seq(1)))
    await Task.megaYield()
    model.retryTapped()
    await Task.megaYield()
    await send(Fixture.agentConnection(1, state: "connected"))
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
  }

  @Test func removedSessionStops() async {
    let model = await connectedModel()
    fake.close(throwing: DaemonHTTPError.status(410, durableSeq: nil))
    await Task.megaYield()
    #expect(model.statusText == "Session removed")
    #expect(!model.isRetryVisible)
  }

  @Test func unknownSessionIsTerminal() async {
    let model = await connectedModel()
    fake.close(throwing: DaemonHTTPError.status(404, durableSeq: nil))
    await Task.megaYield()
    #expect(model.statusText == "Session not found")
    #expect(fake.follows.count == 1)
  }

  // MARK: - Reconnect budget

  @Test func reconnectBudgetExhaustsToDisconnectedAndRetryResumes() async {
    let model = await connectedModel()
    await send(Fixture.edited(1))
    fake.setDiscoverError(URLError(.cannotConnectToHost))
    fake.close(throwing: URLError(.networkConnectionLost))
    await Task.megaYield()
    var seen = [model.statusText]
    for delay in [500, 1000, 2000, 4000, 8000, 8000] {
      await clock.advance(by: .milliseconds(delay))
      seen.append(model.statusText)
    }
    expectNoDifference(
      seen,
      [
        "Reconnecting (attempt 1)", "Reconnecting (attempt 2)", "Reconnecting (attempt 3)",
        "Reconnecting (attempt 4)", "Reconnecting (attempt 5)", "Reconnecting (attempt 6)", "Disconnected",
      ]
    )
    #expect(model.isRetryVisible)
    fake.setDiscoverError(nil)
    model.retryTapped()
    await Task.megaYield()
    #expect(model.statusText == "Connecting…")
    #expect(fake.follows.last?.cursor == Fixture.seq(1))
  }

  @Test func footerShowsConnectionTroubleInsteadOfLive() async {
    let model = await connectedModel()
    await send(Fixture.edited(1))
    fake.close()
    await Task.megaYield()
    #expect(model.footerText == "Reconnecting (attempt 1)")
    #expect(model.footerColor == DesignTokens.Status.warning)
    await clock.advance(by: .milliseconds(500))
    await send(Fixture.edited(1), Fixture.edited(2))
    #expect(model.footerText == "Connected · New changes appear below")
  }

  @Test func silentConnectionIsTreatedAsDead() async {
    let model = await connectedModel()
    await send(.heartbeat)
    await clock.advance(by: .seconds(44))
    #expect(model.statusText == "Connected")
    await clock.advance(by: .seconds(1))
    #expect(model.statusText == "Reconnecting (attempt 1)")
  }

  // MARK: - Ownership

  @Test func switchingSessionsDiscardsTheOldStream() async {
    fake.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
    ])
    let model = makeModel()
    await model.viewAppeared()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    await send(Fixture.edited(1))
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    fake.send(to: 0, Fixture.edited(2))
    await Task.megaYield()
    #expect(model.sections.isEmpty)
    #expect(model.lastAppliedSeq == .zero)
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session, Fixture.otherSession])
    expectNoDifference(fake.follows.map(\.cursor), [.zero, .zero])
  }

  @Test func staleCardLoadIsDiscardedAfterSessionSwitch() async throws {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(clipsGate: gate)
    daemon.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
    ])
    daemon.setClips(ClipsResponse(status: .skipped, fallbackReason: "no-change", clips: []), for: Fixture.seq(1))
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    daemon.send(Fixture.edited(1))
    await Task.megaYield()
    let row = try #require(fileRow(model, 1))
    let load = Task { await model.cardAppeared(row) }
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    open.yield()
    await load.value
    #expect(model.cardContents.isEmpty)
  }

  @Test func retryKeepsAPendingCardLoad() async throws {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(clipsGate: gate)
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)])
    daemon.setClips(ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: []), for: Fixture.seq(1))
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    daemon.send(Fixture.edited(1))
    await Task.megaYield()
    let row = try #require(fileRow(model, 1))
    let load = Task { await model.cardAppeared(row) }
    await Task.megaYield()
    model.retryTapped()
    open.yield()
    await load.value
    #expect(model.content(for: row) == .note("Binary file — not shown"))
  }

  // MARK: - Cards

  func loadedContent(_ change: StreamItem, clips: ClipsResponse? = nil) async -> CardContent {
    let model = await connectedModel()
    if let clips { fake.setClips(clips, for: Fixture.seq(1)) }
    await send(change)
    guard let row = fileRow(model, 1) else {
      Issue.record("No row")
      return .loading
    }
    await model.cardAppeared(row)
    return model.content(for: row)
  }

  func functionClip(_ start: Int, _ end: Int, truncated: Bool = false) -> Clip {
    Clip(
      after: ClipSide(span: ClipSpan(lineStart: start, lineEnd: end, truncated: truncated), method: .function)
    )
  }

  @Test func functionClipShowsAfterSpanWithMarkers() async {
    fake.setBlob(Fixture.shaA, "a\nfunction f() {\n  return 1\n}\nz\n")
    fake.setBlob(Fixture.shaB, "a\nfunction f() {\n  return 2\n}\nz\n")
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .ready, clips: [functionClip(2, 4)])
    )
    expectNoDifference(
      content,
      .code(
        [
          CodeBlock(
            id: 0,
            separatorText: nil,
            lines: [
              CodeLine(id: 2, number: "2", text: "function f() {", isChanged: false),
              CodeLine(id: 3, number: "3", text: "  return 2", isChanged: true, changedRanges: [9..<10]),
              CodeLine(id: 4, number: "4", text: "}", isChanged: false),
            ],
            truncationText: nil
          )
        ]
      )
    )
  }

  func highlightedLines(before: String, after: String, clips: [Clip]) async -> [CodeLine] {
    fake.setBlob(Fixture.shaA, before)
    fake.setBlob(Fixture.shaB, after)
    let content = await loadedContent(Fixture.edited(1), clips: ClipsResponse(status: .ready, clips: clips))
    guard case .code(let blocks) = content else {
      Issue.record("Expected code, got \(content)")
      return []
    }
    return blocks.flatMap(\.lines)
  }

  @Test func deletionOnlyEditMarksWhereTextWasRemoved() async {
    let lines = await highlightedLines(before: "foo(a, b)\n", after: "foo(a)\n", clips: [functionClip(1, 1)])
    expectNoDifference(
      lines,
      [
        CodeLine(
          id: 1, number: "1", text: "foo(a)", isChanged: true, removalOffsets: [5],
          accessibilityText: "foo(a, removed text, )"
        )
      ]
    )
  }

  @Test func tabsShiftHighlightsToTheDisplayedColumns() async {
    let lines = await highlightedLines(before: "\tx\t= 1\n", after: "\tx\t= 2\n", clips: [functionClip(1, 1)])
    expectNoDifference(
      lines,
      [CodeLine(id: 1, number: "1", text: "    x    = 2", sourceText: "\tx\t= 2", isChanged: true, changedRanges: [11..<12])]
    )
  }

  @Test func emojiAndCombiningMarksAreHighlightedWhole() async {
    let lines = await highlightedLines(
      before: "say(\"👍\", cafe)\n", after: "say(\"👩‍👩‍👧\", cafe\u{301})\n", clips: [functionClip(1, 1)]
    )
    expectNoDifference(lines.map(\.changedRanges), [[5..<13, 19..<21]])
  }

  @Test func everyBlockOfACardIsHighlighted() async {
    let lines = await highlightedLines(
      before: "one = 1\ntwo\nthree\nfour = 4\n", after: "one = 2\ntwo\nthree\nfour = 5\n",
      clips: [functionClip(1, 1), functionClip(4, 4)]
    )
    expectNoDifference(lines.map(\.changedRanges), [[6..<7], [7..<8]])
  }

  @Test func crlfLineHighlightsWithoutTheCarriageReturn() async {
    let lines = await highlightedLines(before: "x = 1\r\n", after: "x = 2\r\n", clips: [functionClip(1, 1)])
    expectNoDifference(lines, [CodeLine(id: 1, number: "1", text: "x = 2", isChanged: true, changedRanges: [4..<5])])
  }

  @Test func multipleClipsBecomeSeparateBlocksAndTruncationIsShown() async {
    fake.setBlob(Fixture.shaA, "one\ntwo\nthree\nfour\n")
    fake.setBlob(Fixture.shaB, "ONE\ntwo\nthree\nFOUR\n")
    let rangeClip = Clip(
      after: ClipSide(span: ClipSpan(lineStart: 4, lineEnd: 4, truncated: true), method: .changedRange)
    )
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .fallback, fallbackReason: "no-enclosing-function", clips: [functionClip(1, 1), rangeClip])
    )
    expectNoDifference(
      content,
      .code(
        [
          CodeBlock(id: 0, separatorText: nil, lines: [CodeLine(id: 1, number: "1", text: "ONE", isChanged: true)], truncationText: nil),
          CodeBlock(id: 1, separatorText: "···", lines: [CodeLine(id: 4, number: "4", text: "FOUR", isChanged: true)], truncationText: "… truncated"),
        ]
      )
    )
  }

  @Test func overlappingClipsShowTheirLinesOnce() async {
    fake.setBlob(Fixture.shaB, "function f() {\n  return 1\n}\n")
    let rangeClip = Clip(
      after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 2, truncated: false), method: .changedRange)
    )
    let content = await loadedContent(
      Fixture.fileChanged(1, "new.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)),
      clips: ClipsResponse(status: .ready, clips: [rangeClip, functionClip(1, 3)])
    )
    expectNoDifference(
      content,
      .code(
        [
          CodeBlock(
            id: 0,
            separatorText: nil,
            lines: [
              CodeLine(id: 1, number: "1", text: "function f() {", isChanged: true),
              CodeLine(id: 2, number: "2", text: "  return 1", isChanged: true),
              CodeLine(id: 3, number: "3", text: "}", isChanged: true),
            ],
            truncationText: nil
          )
        ]
      )
    )
  }

  @Test func nestedTruncatedClipKeepsItsTruncationNote() async {
    fake.setBlob(Fixture.shaB, "a\nb\nc\nd\n")
    let content = await loadedContent(
      Fixture.fileChanged(1, "new.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)),
      clips: ClipsResponse(status: .ready, clips: [functionClip(1, 4), functionClip(2, 3, truncated: true)])
    )
    guard case .code(let blocks) = content else {
      Issue.record("Expected code, got \(content)")
      return
    }
    expectNoDifference(blocks.map(\.truncationText), ["… truncated"])
  }

  @Test func aFailedCardLoadIsRetriedOnce() async {
    fake.failClips(times: 1)
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: [])
    )
    #expect(content == .note("Binary file — not shown"))
  }

  @Test func aCardLoadThatFailsTwiceIsExplained() async {
    fake.failClips(times: 2)
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: [])
    )
    #expect(content == .note("Couldn't load this change"))
  }

  @Test func aFailedCardLoadIsRetriedWhenTheCardReappears() async throws {
    let model = await connectedModel()
    fake.failClips(times: 2)
    fake.setClips(ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: []), for: Fixture.seq(1))
    await send(Fixture.edited(1))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    #expect(model.content(for: row) == .note("Couldn't load this change"))
    model.cardDisappeared(row)
    await model.cardAppeared(row)
    #expect(model.content(for: row) == .note("Binary file — not shown"))
  }

  @Test func aVisibleFailedCardCanRetryWithoutDisappearing() async throws {
    let model = await connectedModel()
    fake.failClips(times: 2)
    fake.setClips(ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: []), for: Fixture.seq(1))
    await send(Fixture.edited(1))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    #expect(model.content(for: row) == .note("Couldn't load this change"))
    #expect(model.isCardRetryable(row))
    await model.cardRetryTapped(row)
    #expect(model.content(for: row) == .note("Binary file — not shown"))
    #expect(!model.isCardRetryable(row))
  }

  @Test func anOlderLoadFailingLateDoesNotOverwriteANewerRetrySuccess() async throws {
    let daemon = DaemonFake(gatesEachClipsCall: true)
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)])
    daemon.setBlob(Fixture.shaB, "x\n")
    daemon.setBlob(Fixture.shaA, "y\n")
    daemon.setClips(ClipsResponse(status: .ready, clips: [functionClip(1, 1)]), for: Fixture.seq(1))
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    daemon.send(Fixture.edited(1))
    await Task.megaYield()
    let row = try #require(fileRow(model, 1))

    let olderLoad = Task { await model.cardAppeared(row) }
    await daemon.waitForClipsCall(1)
    let newerRetry = Task { await model.cardRetryTapped(row) }
    await daemon.waitForClipsCall(2)

    daemon.failClips(times: 1)
    daemon.releaseClipsCall(1)
    await daemon.waitForClipsCall(3)
    daemon.releaseClipsCall(2)
    await newerRetry.value
    daemon.failClips(times: 1)
    daemon.releaseClipsCall(3)
    await olderLoad.value

    expectNoDifference(
      model.content(for: row),
      .code([CodeBlock(id: 0, separatorText: nil, lines: [CodeLine(id: 1, number: "1", text: "x", isChanged: true)], truncationText: nil)])
    )
  }

  @Test func truncatedAfterSideIsNotMistakenForARemoval() async {
    fake.setBlob(Fixture.shaA, "a\nb\n")
    fake.setBlob(Fixture.shaB, "a\n")
    let truncated = Clip(after: ClipSide(span: nil, method: .function))
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .fallback, fallbackReason: "truncated-after", clips: [truncated])
    )
    #expect(content == .note("Change is too large to show"))
  }

  @Test func newFileMarksEveryLine() async {
    fake.setBlob(Fixture.shaB, "x\ny\n")
    let wholeFile = Clip(
      after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 2, truncated: false), method: .wholeFile)
    )
    let content = await loadedContent(
      Fixture.fileChanged(1, "new.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)),
      clips: ClipsResponse(status: .ready, clips: [wholeFile])
    )
    expectNoDifference(
      content,
      .code(
        [
          CodeBlock(
            id: 0,
            separatorText: nil,
            lines: [CodeLine(id: 1, number: "1", text: "x", isChanged: true), CodeLine(id: 2, number: "2", text: "y", isChanged: true)],
            truncationText: nil
          )
        ]
      )
    )
  }

  @Test func unavailableBeforeContentIsShownButNotMarkedAsConfirmedChanged() async {
    fake.setBlob(Fixture.shaB, "x\ny\n")
    let wholeFile = Clip(
      after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 2, truncated: false), method: .wholeFile)
    )
    let content = await loadedContent(
      Fixture.fileChanged(1, "existing.ts", before: Fixture.unavailable("baseline-unknown"), after: Fixture.content(Fixture.shaB)),
      clips: ClipsResponse(status: .ready, clips: [wholeFile])
    )
    expectNoDifference(
      content,
      .code(
        [
          CodeBlock(
            id: 0,
            separatorText: nil,
            lines: [
              CodeLine(id: 1, number: "1", text: "x", isChanged: true, isVerified: false),
              CodeLine(id: 2, number: "2", text: "y", isChanged: true, isVerified: false),
            ],
            truncationText: nil
          )
        ]
      )
    )
  }

  @Test func deletedFileIsANote() async {
    let content = await loadedContent(Fixture.fileChanged(1, "gone.ts", before: Fixture.content(Fixture.shaA), after: Fixture.absent))
    #expect(content == .note("File deleted"))
  }

  @Test func unavailableSideIsExplained() async {
    let content = await loadedContent(
      Fixture.fileChanged(1, "busy.ts", before: Fixture.content(Fixture.shaA), after: Fixture.unavailable("unstable"))
    )
    #expect(content == .note("File was changing too fast to capture"))
  }

  @Test func unavailableBeforeStillFetchesAfter() async {
    fake.setBlob(Fixture.shaB, "a\nfunction f() {\n  return 2\n}\nz\n")
    let content = await loadedContent(
      Fixture.fileChanged(1, "new.ts", before: Fixture.unavailable("baseline-unknown"), after: Fixture.content(Fixture.shaB)),
      clips: ClipsResponse(status: .ready, clips: [functionClip(2, 4)])
    )
    expectNoDifference(
      content,
      .code(
        [
          CodeBlock(
            id: 0,
            separatorText: nil,
            lines: [
              CodeLine(id: 2, number: "2", text: "function f() {", isChanged: true, isVerified: false),
              CodeLine(id: 3, number: "3", text: "  return 2", isChanged: true, isVerified: false),
              CodeLine(id: 4, number: "4", text: "}", isChanged: true, isVerified: false),
            ],
            truncationText: nil
          )
        ]
      )
    )
  }

  @Test func oversizeContentIsNotFetched() async {
    let content = await loadedContent(
      Fixture.fileChanged(1, "big.json", before: Fixture.content(Fixture.shaA), after: Fixture.content(Fixture.shaB, size: (1 << 20) + 1))
    )
    #expect(content == .note("Too large to show"))
  }

  @Test func missingBlobIsExplained() async {
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .ready, clips: [functionClip(1, 1)])
    )
    #expect(content == .note("Content no longer available"))
  }

  @Test func binaryContentIsNotShown() async {
    fake.setBlob(Fixture.shaA, "a\n")
    fake.setBlob(Fixture.shaB, data: Data([0x61, 0x00, 0x62]))
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .ready, clips: [functionClip(1, 1)])
    )
    #expect(content == .note("Binary file — not shown"))
  }

  @Test func skippedClipShowsItsReason() async {
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: [])
    )
    #expect(content == .note("Binary file — not shown"))
  }

  @Test func unavailableClipShowsItsReason() async {
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .unavailable, fallbackReason: "clip-too-large", clips: [])
    )
    #expect(content == .note("Change is too large to show"))
  }

  @Test func removalOnlyChangeIsANote() async {
    fake.setBlob(Fixture.shaA, "a\nb\n")
    fake.setBlob(Fixture.shaB, "a\n")
    let removal = Clip(
      after: ClipSide(span: nil, method: .changedRange)
    )
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(status: .fallback, fallbackReason: "unsupported-language", clips: [removal])
    )
    #expect(content == .note("Only lines removed — nothing to show"))
  }

  @Test func cardContentCacheIsBounded() async throws {
    let model = await connectedModel()
    for value in 1...(ChangeStreamPageModel.cardContentLimit + 1) {
      await send(Fixture.fileChanged(value, "f\(value).ts", before: Fixture.content(Fixture.shaA), after: Fixture.absent))
      let row = try #require(fileRow(model, value))
      await model.cardAppeared(row)
      model.cardDisappeared(row)
    }
    #expect(model.cardContents.count == ChangeStreamPageModel.cardContentLimit)
    #expect(model.cardContents[Fixture.seq(1)] == nil)
  }

  @Test func cardsOnScreenAreNeverEvicted() async throws {
    let model = await connectedModel()
    await send(Fixture.fileChanged(1, "f1.ts", before: Fixture.content(Fixture.shaA), after: Fixture.absent))
    await model.cardAppeared(try #require(fileRow(model, 1)))
    for value in 2...(ChangeStreamPageModel.cardContentLimit + 1) {
      await send(Fixture.fileChanged(value, "f\(value).ts", before: Fixture.content(Fixture.shaA), after: Fixture.absent))
      let row = try #require(fileRow(model, value))
      await model.cardAppeared(row)
      model.cardDisappeared(row)
    }
    #expect(model.cardContents[Fixture.seq(1)] == .note("File deleted"))
    #expect(model.cardContents[Fixture.seq(2)] == nil)
  }

  // MARK: - Follow

  @Test func userScrollAwayPausesAndCountsNewCards() async {
    let model = await connectedModel()
    await send(Fixture.edited(1))
    #expect(model.footerText == "Connected · New changes appear below")
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    #expect(model.footerText == "Paused · No new changes")
    await send(Fixture.edited(2))
    #expect(model.footerText == "1 new change")
    await send(Fixture.captureGap(3), Fixture.edited(4))
    #expect(model.footerText == "2 new changes")
    #expect(fake.follows.count == 1)
    #expect(model.statusText == "Connected")
  }

  @Test func jumpToLatestResumesFollowing() async {
    let model = await connectedModel()
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    let request = model.scrollToLatestRequest
    model.jumpToLatestTapped()
    #expect(model.follow == .following)
    #expect(model.scrollToLatestRequest == request + 1)
  }

  @Test func scrollingBackToTheBottomResumesFollowing() async {
    let model = await connectedModel()
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1990)
    #expect(model.follow == .following)
  }

  @Test func layoutChangesAndProgrammaticScrollsNeverFlipFollowing() async {
    let model = await connectedModel()
    model.scrollPhaseChanged(.idle)
    model.scrollGeometryChanged(contentHeight: 5000, visibleMaxY: 1000)
    model.scrollPhaseChanged(.animating)
    model.scrollGeometryChanged(contentHeight: 5000, visibleMaxY: 3000)
    #expect(model.follow == .following)
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 5000, visibleMaxY: 1000)
    model.scrollPhaseChanged(.idle)
    model.scrollGeometryChanged(contentHeight: 5000, visibleMaxY: 5000)
    #expect(model.follow == .paused(newCount: 0))
  }

  @Test func contentGrowingDuringAGestureKeepsFollowing() async {
    let model = await connectedModel()
    model.scrollGeometryChanged(contentHeight: 1000, visibleMaxY: 1000)
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 1600, visibleMaxY: 1000)
    #expect(model.follow == .following)
  }

  @Test func appendsRequestAScrollOnlyWhileFollowing() async {
    let model = await connectedModel()
    let before = model.scrollToLatestRequest
    await send(Fixture.edited(1))
    #expect(model.scrollToLatestRequest == before + 1)
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    await send(Fixture.edited(2))
    #expect(model.scrollToLatestRequest == before + 1)
  }

  @Test func newQuestionBarsRequestAScrollOnlyWhileFollowing() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    let before = model.scrollToLatestRequest
    await send(Fixture.questionQueued(2, id: "q1"))
    #expect(model.scrollToLatestRequest == before + 1)
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    await send(Fixture.questionAnswered(3, id: "q1"))
    #expect(model.scrollToLatestRequest == before + 1)
  }

  @Test func newestCardIsEmphasised() async throws {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    #expect(model.emphasis(for: try #require(fileRow(model, 1))) == .other)
    #expect(model.emphasis(for: try #require(fileRow(model, 2))) == .newest)
  }

  @Test func onlyTheNewestCardIsMarkedOpen() async throws {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    #expect(model.openIndicatorText(for: try #require(fileRow(model, 1))) == nil)
    #expect(model.openIndicatorText(for: try #require(fileRow(model, 2))) == "OPEN →")
  }

  @Test func fixturePaneDoesNotMarkAnUnrelatedFeedCardOpen() async throws {
    let model = makeModel(isFunctionDemoVisible: true)
    await model.viewAppeared()
    await Task.megaYield()
    await send(Fixture.edited(1))
    #expect(model.openIndicatorText(for: try #require(fileRow(model, 1))) == nil)
  }

  @Test func switchingBackToTheStreamKeepsTheScrollPosition() async {
    let model = await connectedModel()
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    model.rightPaneSelected(.terminals)
    #expect(!model.isStreamShown)
    model.rightPaneSelected(.stream)
    #expect(model.isStreamShown)
    expectNoDifference(model.follow, .paused(newCount: 0))
  }

  @Test func feedPresentationFollowsTheSelectedRightPane() {
    let model = makeModel()
    expectNoDifference(model.feedOpacity, 1)
    #expect(model.isFeedInteractive)

    model.rightPaneSelected(.terminals)

    expectNoDifference(model.feedOpacity, 0)
    #expect(!model.isFeedInteractive)

    model.rightPaneToggleTapped()

    expectNoDifference(model.feedOpacity, 0)
    #expect(!model.isFeedInteractive)
  }

  @Test func switchingPanesKeepsWatching() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let watchTask = model.watchTask
    model.rightPaneSelected(.terminals)
    #expect(model.watchTask == watchTask)
    #expect(model.watchTask?.isCancelled == false)
    await send(Fixture.edited(1))
    #expect(fileRow(model, 1) != nil)
  }

  @Test func switchingWorkspaceKeepsTheRightPane() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    model.rightPaneSelected(.terminals)
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    #expect(model.rightPane == .terminals)
  }

  @Test func rightPaneTabsAreLabelled() {
    let model = makeModel()
    expectNoDifference(ChangeStreamPageModel.RightPane.allCases.map(model.rightPaneText), ["Change stream", "Terminals"])
    #expect(model.isSelected(.stream))
    #expect(!model.isSelected(.terminals))
  }

  @Test func onlyTheStreamTabCarriesANote() {
    let model = makeModel()
    expectNoDifference(ChangeStreamPageModel.RightPane.allCases.map(model.rightPaneNote), ["Full functions", nil])
  }

  @Test func aTaskHeadingIsPinnedOnlyWhileItSitsAtTheTop() async throws {
    let model = await connectedModel()
    await send(Fixture.taskStarted(1, "Convert isActive"), Fixture.edited(2))
    let section = try #require(model.sections.first)
    #expect(!model.isHeadingPinned(section))
    model.headingMoved(section, minY: 0)
    #expect(model.isHeadingPinned(section))
    model.headingMoved(section, minY: 48)
    #expect(!model.isHeadingPinned(section))
  }

  @Test func aFileNameSticksBelowThePinnedTaskHeadingWhileItsCardScrollsPast() async throws {
    let model = await connectedModel()
    await send(Fixture.taskStarted(1, "Convert isActive"), Fixture.edited(2))
    let section = try #require(model.sections.first)
    let row = try #require(fileRow(model, 2))
    model.taskHeadingMeasured(height: 40)
    model.fileHeaderMeasured(height: 30)
    model.cardMoved(row, in: section, frame: CGRect(x: 0, y: 100, width: 400, height: 300))
    #expect(model.fileHeaderOffset(for: row) == 0)
    model.cardMoved(row, in: section, frame: CGRect(x: 0, y: -60, width: 400, height: 300))
    #expect(model.fileHeaderOffset(for: row) == 100)
  }

  @Test func aFileNameRecalculatesWhenItsCardMovesBeforeItsHeightsAreMeasured() async throws {
    let model = await connectedModel()
    await send(Fixture.taskStarted(1, "Convert isActive"), Fixture.edited(2))
    let section = try #require(model.sections.first)
    let row = try #require(fileRow(model, 2))
    model.cardMoved(row, in: section, frame: CGRect(x: 0, y: -60, width: 400, height: 300))
    #expect(model.fileHeaderOffset(for: row) == 60)
    model.taskHeadingMeasured(height: 40)
    #expect(model.fileHeaderOffset(for: row) == 100)
    model.fileHeaderMeasured(height: 30)
    #expect(model.fileHeaderOffset(for: row) == 100)
  }

  @Test func aStickyFileNameLeavesWithTheBottomOfItsCard() async throws {
    let model = await connectedModel()
    await send(Fixture.taskStarted(1, "Convert isActive"), Fixture.edited(2))
    let section = try #require(model.sections.first)
    let row = try #require(fileRow(model, 2))
    model.taskHeadingMeasured(height: 40)
    model.fileHeaderMeasured(height: 30)
    model.cardMoved(row, in: section, frame: CGRect(x: 0, y: -280, width: 400, height: 300))
    #expect(model.fileHeaderOffset(for: row) == 270)
  }

  @Test func aFileNameOutsideAnyTaskSticksToTheTopOfTheFeed() async throws {
    let model = await connectedModel()
    await send(Fixture.edited(1))
    let section = try #require(model.sections.first)
    let row = try #require(fileRow(model, 1))
    model.taskHeadingMeasured(height: 40)
    model.fileHeaderMeasured(height: 30)
    model.cardMoved(row, in: section, frame: CGRect(x: 0, y: -60, width: 400, height: 300))
    #expect(model.fileHeaderOffset(for: row) == 60)
  }
}


extension ChangeStreamPageTests {
  @Test func selectedDraftSurvivesCacheEvictionAndSessionSwitchWithoutRetargeting() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setBlob(Fixture.shaB, "\u{FEFF}one\r\n\ttwo\r\n\nlast\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 4, truncated: false), method: .changedRange))]), for: Fixture.seq(1))
    await send(Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing source"); return }
    model.sourceDragged(row: row, block: blocks[0], startY: 23, endY: 60, frame: CGRect(x: 20, y: 100, width: 600, height: 88))
    model.sourceDragEnded()
    let composer = try #require(model.askAgent)
    composer.draftChanged("Why?")
    expectNoDifference(composer.context.lineStart, 2)
    expectNoDifference(composer.context.lineEnd, 3)
    expectNoDifference(model.highlightRect(row: row, block: blocks[0], width: 600), CGRect(x: 0, y: 22, width: 600, height: 44))
    model.cardDisappeared(row)
    for value in 2...66 {
      await send(Fixture.fileChanged(value, "other.ts", before: Fixture.content(Fixture.shaA), after: Fixture.absent))
      let next = try #require(fileRow(model, value))
      await model.cardAppeared(next)
      model.cardDisappeared(next)
    }
    #expect(model.cardContents[row.id] == nil)
    #expect(model.askAgent === composer)
    model.sessions.append(SessionOption(id: Fixture.otherSession, label: "Other"))
    model.sessionSelected(Fixture.otherSession)
    #expect(model.askAgent === composer)
    expectNoDifference(composer.sessionID, Fixture.session)
    expectNoDifference(composer.draft, "Why?")
    expectNoDifference(composer.context.snapshotSHA256, Fixture.shaB)
    #expect(!model.showsSelectionConnector)
  }

  @Test func questionEventsAdvanceReplayWithoutAddingRows() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let context: [String: Any] = [
      "change_seq": "1", "path": "a.ts", "snapshot_sha256": Fixture.shaB, "line_start": 1, "line_end": 1, "selected_text": "a",
    ]
    await send(
      Fixture.frame(1, type: "slipstream.question.queued.v1", data: [
        "question_id": "q1", "request_id": "r-q1", "text": "Why?", "context": context, "queued_at_ms": 1,
      ]),
      Fixture.frame(2, type: "slipstream.question.dispatch_attempted.v1", data: ["question_id": "q1", "queued_seq": "1"]),
      Fixture.frame(3, type: "slipstream.question.answered.v1", data: [
        "question_id": "q1", "attempt_seq": "2", "text": "Because.", "answered_at_ms": 3,
      ]))
    expectNoDifference(model.lastAppliedSeq, Fixture.seq(3))
    #expect(model.sections.isEmpty)
  }

  @Test func failedQuestionDoesNotChangeCaptureHealthAndOldCompletionCannotCloseNewComposer() async throws {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { request in
        for await _ in gate { break }
        return try AskAgentPageTests.ack(request)
      }
    } operation: { makeModel() }
    await model.viewAppeared()
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let context = AskAgentPageTests.context
    let original = withDependencies(from: model) { AskAgentPageTests.composer(sessionID: Fixture.session, context: context) }
    model.askAgent = original
    original.draftChanged("Why?")
    let send = Task { await model.askQuestionTapped(original) }
    await Task.megaYield()
    let health = model.connection
    model.questionDismissed()
    let newer = AskAgentPageTests.composer(sessionID: Fixture.otherSession, context: context)
    newer.draftChanged("A different question")
    model.askAgent = newer
    resume.yield()
    await send.value
    #expect(model.askAgent === newer)
    expectNoDifference(newer.draft, "A different question")
    expectNoDifference(model.connection, health)
  }
}

extension ChangeStreamPageTests {
  @Test func uncertainSubmissionRequiresExplicitDiscardConfirmation() async {
    let model = makeModel()
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { _ in throw QuestionError.outcomeUnknown }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    await model.askQuestionTapped(composer)
    model.questionDismissTapped()
    #expect(model.isQuestionDismissConfirmationPresented)
    #expect(model.askAgent === composer)
    expectNoDifference(composer.draft, "Why?")
    model.questionDismissed()
    #expect(model.askAgent == nil)
    #expect(!model.isQuestionDismissConfirmationPresented)
  }

  @Test func inFlightDismissalKeepsIntentUntilExplicitlyConfirmed() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let model = makeModel()
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { request in
        for await _ in gate { break }
        return try AskAgentPageTests.ack(request)
      }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    let send = Task { await model.askQuestionTapped(composer) }
    await Task.megaYield()
    model.questionDismissTapped()
    #expect(model.isQuestionDismissConfirmationPresented)
    #expect(model.askAgent === composer)
    resume.yield()
    await send.value
    #expect(model.askAgent == nil)
    #expect(!model.isQuestionDismissConfirmationPresented)
  }

  @Test func queueConfirmationPreservesCaptureHealth() async {
    let model = makeModel()
    model.selectedSession = SessionOption(id: Fixture.session, label: "Current")
    model.connection = .live
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { try AskAgentPageTests.ack($0) }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    await model.askQuestionTapped(composer)
    expectNoDifference(model.connection, .live)
    expectNoDifference(model.footerText, "Connected · New changes appear below · Question queued (delivery not confirmed)")
  }

  @Test func retainedComposerStaysSendableAfterWindowDisappearsAndReappears() async {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = withDependencies(from: model) {
      $0.uuid = .incrementing
      $0.questionClient.send = { try AskAgentPageTests.ack($0) }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    model.viewDisappeared()
    await model.viewAppeared()
    await Task.megaYield()
    #expect(model.askAgent === composer)
    #expect(composer.canSubmit)
    await model.askQuestionTapped(composer)
    #expect(model.askAgent == nil)
  }

  @Test func sendFailureDuringDiscardConfirmationQueuesErrorBehindItAndKeepsRetryIdentity() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[String]>([])
    let model = makeModel()
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { request in
        requests.withValue { $0.append(request.requestID) }
        for await _ in gate { break }
        throw QuestionError.outcomeUnknown
      }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    let send = Task { await model.askQuestionTapped(composer) }
    await Task.megaYield()
    model.questionDismissTapped()
    #expect(model.isQuestionDismissConfirmationPresented)
    resume.yield()
    await send.value
    #expect(model.isQuestionDismissConfirmationPresented)
    #expect(composer.isErrorPresented)
    #expect(model.askAgent === composer)
    expectNoDifference(composer.draft, "Why?")
    model.isQuestionDismissConfirmationPresented = false
    composer.isErrorPresented = false
    let retry = Task { await model.askQuestionTapped(composer) }
    await Task.megaYield()
    resume.yield()
    await retry.value
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(Set(requests.value).count, 1)
  }

  @Test func startingAnotherQuestionClearsTheEarlierQueueNotice() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(
      span: ClipSpan(lineStart: 1, lineEnd: 3, truncated: false), method: .changedRange))]), for: Fixture.seq(1))
    await send(Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing code"); return }
    let composer = withDependencies(from: model) {
      $0.uuid = .incrementing
      $0.questionClient.send = { try AskAgentPageTests.ack($0) }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    await model.askQuestionTapped(composer)
    #expect(model.footerText.hasSuffix("Question queued (delivery not confirmed)"))
    model.sourceDragged(row: row, block: blocks[0], startY: 0, endY: 60,
      frame: CGRect(x: 30, y: 30, width: 620, height: 66))
    model.sourceDragEnded()
    #expect(model.askAgent != nil)
    #expect(!model.footerText.contains("Question queued"))
  }

  @Test func successAfterSwitchingCapturesNamesTheOriginalCapture() async {
    let model = makeModel()
    model.sessions = [
      SessionOption(id: Fixture.session, label: "project"),
      SessionOption(id: Fixture.otherSession, label: "other"),
    ]
    model.selectedSession = model.sessions[id: Fixture.otherSession]
    model.connection = .live
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { try AskAgentPageTests.ack($0) }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    await model.askQuestionTapped(composer)
    #expect(model.askAgent == nil)
    expectNoDifference(model.footerText,
      "Connected · New changes appear below · Question queued for project (delivery not confirmed)")
  }

  @Test func selectionConnectorUsesVisibleSourceAndHidesWhenBlockDisappears() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(
      span: ClipSpan(lineStart: 1, lineEnd: 3, truncated: false), method: .changedRange))]), for: Fixture.seq(1))
    await send(Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing code"); return }
    model.viewportChanged(CGSize(width: 1100, height: 800))
    model.feedViewportChanged(CGRect(x: 0, y: 52, width: 680, height: 710))
    model.sourceDragged(row: row, block: blocks[0], startY: 0, endY: 60,
      frame: CGRect(x: 30, y: 30, width: 620, height: 66))
    #expect(model.showsSelectionConnector)
    #expect(model.questionPlacement.selectionAnchor.y >= 52)
    model.sourceBlockDisappeared(row: row, block: blocks[0])
    #expect(!model.showsSelectionConnector)
    #expect(model.sourceSelection != nil)
    model.sourceBlockMoved(row: row, block: blocks[0], frame: CGRect(x: 30, y: -100, width: 620, height: 66))
    #expect(!model.showsSelectionConnector)
  }

  // MARK: - Question bars

  func bars(_ model: ChangeStreamPageModel, _ rowID: Int) throws -> [QuestionBar] {
    model.questionBars(for: try #require(fileRow(model, rowID)))
  }

  func bar(_ model: ChangeStreamPageModel, _ questionID: String) throws -> QuestionBar {
    try #require(try bars(model, 1).first { $0.id == questionID })
  }

  func open(_ model: ChangeStreamPageModel, _ questionID: String) throws -> QuestionThreadPageModel {
    model.questionBarTapped(try bar(model, questionID))
    return try #require(model.reply)
  }

  @Test func questionBarsSitUnderTheirSourceInAskOrder() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.edited(2, "src/api.ts"),
      Fixture.questionQueued(3, id: "q1", text: "Why this type?"),
      Fixture.questionQueued(4, id: "q2", text: "Why this route?", changeSeq: 2, path: "src/api.ts"),
      Fixture.questionQueued(5, id: "q3", text: "And this line?"),
      Fixture.questionAnswered(6, id: "q1"))
    expectNoDifference(try bars(model, 1), [
      QuestionBar(id: "q1", preview: "Why this type?", status: .newReply, isOpen: false),
      QuestionBar(id: "q3", preview: "And this line?", status: .waiting, isOpen: false),
    ])
    expectNoDifference(try bars(model, 2), [
      QuestionBar(id: "q2", preview: "Why this route?", status: .waiting, isOpen: false),
    ])
    expectNoDifference(model.paneSubtitle, "3 questions · 1 new reply")
    #expect(model.sections[0].items.ids == [Fixture.seq(1), Fixture.seq(2)])
  }

  @Test func exchangeRecordedAddsNoFeedRow() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1"))
    #expect(model.sections.flatMap(\.items).map(\.id) == [Fixture.seq(1)])
    expectNoDifference(try bars(model, 1), [
      QuestionBar(id: "q1", preview: "Why did this change?", status: .newReply, isOpen: false)
    ])
  }

  @Test func relayUpdatedAddsNoFeedRow() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1", relay: "rl1"),
      Fixture.questionRelayUpdated(3, id: "q1", relay: "rl1", update: ["kind": "picked_up"]))
    #expect(model.sections.flatMap(\.items).map(\.id) == [Fixture.seq(1)])
  }

  func relayUpdated(_ value: Int, id: String = "q1", relay: String = "rl1", _ kind: String, outcome: String? = nil)
    -> StreamItem
  {
    var update: [String: Any] = ["kind": kind]
    if let outcome {
      update["outcome"] = outcome
      update["text"] = "Renamed it."
    }
    return Fixture.questionRelayUpdated(value, id: id, relay: relay, update: update)
  }

  func readEverything(_ model: ChangeStreamPageModel, _ seqs: Int...) throws {
    let reply = try open(model, "q1")
    for seq in seqs { reply.answerDisplayed(Fixture.seq(seq)) }
  }

  @Test func barWorkingWhileAnyTurnInProgress() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1", relay: "rl1"), relayUpdated(3, "picked_up"),
      Fixture.questionExchangeRecorded(4, id: "q2", replyTo: "q1", relay: "rl2"),
      relayUpdated(5, id: "q2", relay: "rl2", "picked_up"), relayUpdated(6, id: "q2", relay: "rl2", "reported", outcome: "done"))
    try readEverything(model, 2, 4, 6)

    expectNoDifference(try bar(model, "q1").status, .working)
    expectNoDifference(try bar(model, "q1").statusText, "Working")
  }

  @Test func barDoneWhenAllDoneAndSeen() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1", relay: "rl1"), relayUpdated(3, "picked_up"),
      relayUpdated(4, "reported", outcome: "done"))
    try readEverything(model, 2, 4)

    expectNoDifference(try bar(model, "q1").status, .done)
    expectNoDifference(try bar(model, "q1").statusText, "Done")
  }

  @Test func unseenReportShowsNewReply() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1", relay: "rl1"), relayUpdated(3, "picked_up"),
      relayUpdated(4, "reported", outcome: "not_done_yet"))
    try readEverything(model, 2)

    expectNoDifference(try bar(model, "q1").status, .newReply)
    expectNoDifference(model.paneSubtitle, "1 question · 1 new reply")
  }

  @Test func notDeliveredBarWhenNothingElseInProgress() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1", relay: "rl1"), relayUpdated(3, "not_delivered"))
    try readEverything(model, 2)
    expectNoDifference(try bar(model, "q1").status, .notDelivered)

    await send(
      Fixture.questionExchangeRecorded(4, id: "q2", replyTo: "q1", relay: "rl2"),
      relayUpdated(5, id: "q2", relay: "rl2", "picked_up"))
    model.reply?.answerDisplayed(Fixture.seq(4))
    expectNoDifference(try bar(model, "q1").status, .working)
  }

  @Test func headerKeepsItsSubtitleUntilSomeoneAsks() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    expectNoDifference(model.paneSubtitle, "Full functions")
    #expect(!model.isQuestionSummaryShown)
    await send(Fixture.questionQueued(2, id: "q1"))
    expectNoDifference(model.paneSubtitle, "1 question")
    #expect(model.isQuestionSummaryShown)
  }

  @Test func answerArrivingDoesNotMarkItReadButDisplayingItDoes() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    let reply = try open(model, "q1")
    expectNoDifference(try bar(model, "q1"), QuestionBar(id: "q1", preview: "Why did this change?", status: .waiting, isOpen: true))
    await send(Fixture.questionAnswered(3, id: "q1", text: "To split the type."))
    expectNoDifference(reply.thread.turns.map(\.answer?.text), ["To split the type."])
    #expect(try bar(model, "q1").status == .newReply)
    expectNoDifference(model.paneSubtitle, "1 question · 1 new reply")
    reply.answerDisplayed(Fixture.seq(3))
    #expect(try bar(model, "q1").status == .answered)
    expectNoDifference(model.paneSubtitle, "1 question")
  }

  @Test func newReplyOutranksAWaitingFollowUp() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1"),
      Fixture.questionAnswered(3, id: "q1"),
      Fixture.questionQueued(4, id: "q2", text: "Follow-up", replyTo: "q1"))
    #expect(try bar(model, "q1").status == .newReply)
    try open(model, "q1").answerDisplayed(Fixture.seq(3))
    #expect(try bar(model, "q1").status == .waiting)
    await send(Fixture.questionAnswered(5, id: "q2"))
    #expect(try bar(model, "q1").status == .newReply)
    model.reply?.answerDisplayed(Fixture.seq(5))
    #expect(try bar(model, "q1").status == .answered)
  }

  @Test func aQuestionQueuedBeforeARestartIsMarkedNotDeliveredAndCanBeAskedAgain() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    let reply = try open(model, "q1")
    #expect(reply.isFollowUpDisabled)
    await send(Fixture.sessionResumed(3))
    expectNoDifference(try bar(model, "q1").status, .notDelivered)
    expectNoDifference(try bar(model, "q1").statusText, "Not delivered")
    expectNoDifference(reply.thread.turns.map(\.status), [.notDelivered])
    #expect(!reply.isFollowUpDisabled)
  }

  @Test func anUncertainQuestionThatARestartDroppedIsAskedAgainWithAFreshRequest() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let requests = LockIsolated<[String]>([])
    let composer = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { request in
        requests.withValue { $0.append(request.requestID) }
        if requests.value.count == 1 { throw QuestionError.outcomeUnknown }
        return try AskAgentPageTests.ack(request)
      }
    } operation: { AskAgentPageTests.composer(sessionID: Fixture.session) }
    model.askAgent = composer
    composer.draftChanged("Why?")
    await model.askQuestionTapped(composer)
    await send(
      Fixture.questionQueued(1, id: "q1", requestID: requests.value[0]),
      Fixture.sessionResumed(2),
      Fixture.agentConnection(3, state: "connected"))
    composer.isErrorPresented = false
    await model.askQuestionTapped(composer)
    expectNoDifference(requests.value, ["00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000001"])
  }

  @Test func aQuestionAlreadySentToTheAgentKeepsWaitingAfterARestart() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1"),
      Fixture.questionDispatchAttempted(3, id: "q1", queuedSeq: 2),
      Fixture.sessionResumed(4))
    expectNoDifference(try bar(model, "q1").status, .waiting)
  }

  @Test func unlinkEventAddsNoFeedRow() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.agentUnlinked(1))
    expectNoDifference(model.lastAppliedSeq, Fixture.seq(1))
    #expect(model.sections.isEmpty)
  }

  @Test func aMovedQuestionShowsResendingUntilAChatPicksItUp() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1"),
      Fixture.questionDispatchAttempted(3, id: "q1", queuedSeq: 2))
    let reply = try open(model, "q1")
    await send(Fixture.agentUnlinked(4))
    expectNoDifference(reply.thread.turns.map(\.status), [.resending])
    expectNoDifference(try bar(model, "q1").status, .waiting)
    #expect(reply.isFollowUpDisabled)
    await send(Fixture.questionDispatchAttempted(5, id: "q1", queuedSeq: 2))
    expectNoDifference(reply.thread.turns.map(\.status), [.waiting])
  }

  @Test func resendingCountsAsWaitingForUnreadAndFollowUps() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1"),
      Fixture.questionAnswered(3, id: "q1"),
      Fixture.questionQueued(4, id: "q2", text: "Follow-up", replyTo: "q1"),
      Fixture.agentUnlinked(5))
    #expect(try bar(model, "q1").status == .newReply)
    try open(model, "q1").answerDisplayed(Fixture.seq(3))
    #expect(try bar(model, "q1").status == .waiting)
  }

  @Test func anEarlierUnansweredFollowUpKeepsTheThreadWaiting() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1"),
      Fixture.questionAnswered(3, id: "q1"),
      Fixture.questionQueued(4, id: "q2", text: "First follow-up", replyTo: "q1"),
      Fixture.questionQueued(5, id: "q3", text: "Second follow-up", replyTo: "q1"),
      Fixture.questionAnswered(6, id: "q3"))
    let reply = try open(model, "q1")
    reply.answerDisplayed(Fixture.seq(3))
    reply.answerDisplayed(Fixture.seq(6))
    #expect(try bar(model, "q1").status == .waiting)
  }

  @Test func collapsedReplyCannotMarkAnswersRead() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"), Fixture.questionAnswered(3, id: "q1"))
    let reply = try open(model, "q1")
    model.replyDismissTapped()
    #expect(model.reply == nil)
    reply.answerDisplayed(Fixture.seq(3))
    reply.draft = "Too late"
    #expect(try bar(model, "q1").status == .newReply)
    expectNoDifference(try open(model, "q1").draft, "")
  }

  @Test func sendingAReplyFollowsUpTheLatestTurnAndWaitsForItsAnswer() async throws {
    let q1 = "11111111-1111-4111-8111-111111111111"
    let q2 = "22222222-2222-4222-8222-222222222222"
    let queuedID = "33333333-3333-4333-8333-333333333333"
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = await withDependencies {
      $0.uuid = UUIDGenerator { UUID(uuidString: queuedID)! }
      $0.questionClient.send = { request in
        requests.withValue { $0.append(request) }
        _ = try request.encoded()
        return try AskAgentPageTests.ack(request)
      }
    } operation: { await connectedModel() }
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: q1),
      Fixture.questionAnswered(3, id: q1),
      Fixture.questionQueued(4, id: q2, text: "Follow-up", replyTo: q1),
      Fixture.questionAnswered(5, id: q2))
    let reply = try open(model, q1)
    reply.answerDisplayed(Fixture.seq(3))
    reply.answerDisplayed(Fixture.seq(5))
    reply.draft = "And the tests?"
    await reply.sendReplyTapped()
    let request = try #require(requests.value.first)
    expectNoDifference(request.sessionID, Fixture.session)
    expectNoDifference(request.replyToQuestionID, q2)
    expectNoDifference(request.context, model.questionThreads.threads[id: q1]?.source.context)
    #expect(reply.isFollowUpDisabled)
    await send(Fixture.questionQueued(6, id: queuedID, text: "And the tests?", replyTo: q2))
    expectNoDifference(reply.thread.turns.map(\.questionID), [q1, q2, queuedID])
    #expect(try bar(model, q1).status == .waiting)
    #expect(reply.isFollowUpDisabled)
  }

  @Test func collapsingTheReplyKeepsItsDraft() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"), Fixture.questionAnswered(3, id: "q1"))
    let first = try open(model, "q1")
    first.draft = "What about the tests?"
    model.questionBarTapped(try bar(model, "q1"))
    #expect(model.reply == nil)
    #expect(try bar(model, "q1").isOpen == false)
    let reopened = try open(model, "q1")
    #expect(reopened !== first)
    expectNoDifference(reopened.draft, "What about the tests?")
  }

  @Test func twoThreadsAnsweredOutOfOrderKeepTheirOwnAnswers() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1", text: "First?"),
      Fixture.questionQueued(3, id: "q2", text: "Second?"),
      Fixture.questionAnswered(4, id: "q2", text: "Second."),
      Fixture.questionAnswered(5, id: "q1", text: "First."))
    expectNoDifference(model.questionThreads.threads.map { $0.turns.map(\.answer?.text) }, [["First."], ["Second."]])
    expectNoDifference(try bars(model, 1).map(\.status), [.newReply, .newReply])
    expectNoDifference(model.paneSubtitle, "2 questions · 2 new replies")
    try open(model, "q2").answerDisplayed(Fixture.seq(4))
    expectNoDifference(try bars(model, 1).map(\.status), [.newReply, .answered])
  }

  @Test func replayingTheHistoryReproducesTheThreads() async throws {
    let history = [
      Fixture.edited(1),
      Fixture.questionQueued(2, id: "q1"),
      Fixture.questionQueued(3, id: "q2"),
      Fixture.questionAnswered(4, id: "q2"),
      Fixture.questionQueued(5, id: "q3", replyTo: "q2"),
    ]
    let live = await connectedModel()
    defer { live.viewDisappeared() }
    for item in history { fake.send(to: 0, item) }
    await Task.megaYield()
    let restarted = await connectedModel(storage: InMemoryStorage())
    defer { restarted.viewDisappeared() }
    for item in history { fake.send(to: 1, item) }
    await Task.megaYield()
    #expect(restarted.questionThreads.threads.count == 2)
    expectNoDifference(restarted.questionThreads, live.questionThreads)
    expectNoDifference(try bars(restarted, 1), try bars(live, 1))
  }

  @Test func readMarkersAndDraftsAreSharedAcrossWindows() async throws {
    let history = [Fixture.edited(1), Fixture.questionQueued(2, id: "q1"), Fixture.questionAnswered(3, id: "q1")]
    let first = await connectedModel()
    defer { first.viewDisappeared() }
    for item in history { fake.send(to: 0, item) }
    let second = await connectedModel()
    defer { second.viewDisappeared() }
    for item in history { fake.send(to: 1, item) }
    await Task.megaYield()
    let reply = try open(first, "q1")
    reply.answerDisplayed(Fixture.seq(3))
    reply.draft = "Shared draft"
    #expect(try bar(second, "q1") == QuestionBar(id: "q1", preview: "Why did this change?", status: .answered, isOpen: false))
    expectNoDifference(try open(second, "q1").draft, "Shared draft")
  }

  @Test func appRestartShowsEveryAnswerAsANewReply() async throws {
    let history = [Fixture.edited(1), Fixture.questionQueued(2, id: "q1"), Fixture.questionAnswered(3, id: "q1")]
    let before = await connectedModel()
    for item in history { fake.send(to: 0, item) }
    await Task.megaYield()
    let reply = try open(before, "q1")
    reply.answerDisplayed(Fixture.seq(3))
    reply.draft = "Unsent"
    before.viewDisappeared()
    let after = await connectedModel(storage: InMemoryStorage())
    defer { after.viewDisappeared() }
    for item in history { fake.send(to: 1, item) }
    await Task.megaYield()
    #expect(try bar(after, "q1").status == .newReply)
    expectNoDifference(try open(after, "q1").draft, "")
  }

  @Test func readMarkersAndDraftsBelongToTheirStore() async throws {
    let otherStore = DaemonFake(storeID: "store-b")
    otherStore.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)])
    let history = [Fixture.edited(1), Fixture.questionQueued(2, id: "q1"), Fixture.questionAnswered(3, id: "q1")]
    let first = await connectedModel()
    defer { first.viewDisappeared() }
    for item in history { fake.send(item) }
    await Task.megaYield()
    let reply = try open(first, "q1")
    reply.answerDisplayed(Fixture.seq(3))
    reply.draft = "Store A draft"
    await send(Fixture.questionQueued(4, id: "q2", replyTo: "q1"))
    let second = makeModel(daemon: otherStore)
    await second.viewAppeared()
    await Task.megaYield()
    defer { second.viewDisappeared() }
    for item in history { otherStore.send(item) }
    await Task.megaYield()
    #expect(try bar(second, "q1").status == .newReply)
    let otherStoreReply = try open(second, "q1")
    expectNoDifference(otherStoreReply.draft, "")
    #expect(!otherStoreReply.isFollowUpDisabled)
    expectNoDifference(
      Array(first.replyDrafts.keys), [QuestionThreadKey(storeID: "store-a", sessionID: Fixture.session, rootQuestionID: "q1")])
  }

  @Test func sessionSwitchClosesTheReplyAndDiscardsStaleQuestionEvents() async throws {
    fake.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
    ])
    let model = makeModel()
    await model.viewAppeared()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let history = [Fixture.edited(1), Fixture.questionQueued(2, id: "q1"), Fixture.questionAnswered(3, id: "q1")]
    for item in history { fake.send(to: 0, item) }
    await Task.megaYield()
    let reply = try open(model, "q1")
    reply.answerDisplayed(Fixture.seq(3))
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    #expect(model.reply == nil)
    fake.send(to: 0, Fixture.questionQueued(4, id: "q2"))
    await Task.megaYield()
    #expect(model.questionThreads.threads.isEmpty)
    expectNoDifference(model.paneSubtitle, "Full functions")
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    for item in history { fake.send(to: 2, item) }
    await Task.megaYield()
    #expect(try bar(model, "q1") == QuestionBar(id: "q1", preview: "Why did this change?", status: .answered, isOpen: false))
  }

  @Test func reconnectKeepsTheOpenReply() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    let reply = try open(model, "q1")
    fake.close()
    await Task.megaYield()
    await clock.advance(by: .milliseconds(500))
    await send(Fixture.questionAnswered(3, id: "q1"))
    #expect(model.reply === reply)
    expectNoDifference(reply.thread.turns.map(\.answer?.text), ["Because."])
  }

  @Test func switchingToTerminalsCollapsesTheReply() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    _ = try open(model, "q1")
    model.rightPaneSelected(.terminals)
    #expect(model.reply == nil)
  }

  @Test func connectorsHideWhileTerminalsShows() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    model.viewportChanged(CGSize(width: 1400, height: 900))
    model.feedViewportChanged(CGRect(x: 680, y: 52, width: 720, height: 800))
    let bar = try bar(model, "q1")
    model.questionBarMoved(bar, frame: CGRect(x: 700, y: 300, width: 640, height: 42))
    model.questionBarTapped(bar)
    model.replyMeasured(CGSize(width: 420, height: 300))
    #expect(model.showsReplyConnector)
    model.rightPaneSelected(.terminals)
    #expect(!model.showsReplyConnector)
  }

  @Test func askingAndReplyingNeverOverlap() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(
      span: ClipSpan(lineStart: 1, lineEnd: 3, truncated: false), method: .changedRange))]), for: Fixture.seq(1))
    await send(
      Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)),
      Fixture.questionQueued(2, id: "q1", path: "source.ts"))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing code"); return }
    _ = try open(model, "q1")
    model.sourceDragged(row: row, block: blocks[0], startY: 0, endY: 20, frame: CGRect(x: 30, y: 30, width: 620, height: 66))
    model.sourceDragEnded()
    #expect(model.askAgent != nil)
    #expect(model.reply == nil)
    model.questionBarTapped(try bar(model, "q1"))
    #expect(model.reply == nil)
  }

  @Test func replyOpensBesideItsBarWithAConnector() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    model.viewportChanged(CGSize(width: 1400, height: 900))
    model.feedViewportChanged(CGRect(x: 680, y: 52, width: 720, height: 800))
    let bar = try bar(model, "q1")
    model.questionBarMoved(bar, frame: CGRect(x: 700, y: 300, width: 640, height: 42))
    model.questionBarTapped(bar)
    model.replyMeasured(CGSize(width: 420, height: 300))
    expectNoDifference(model.replyPlacement.popover, CGRect(x: 236, y: 300, width: 420, height: 300))
    expectNoDifference(model.replyPlacement.barAnchor, CGPoint(x: 700, y: 321))
    expectNoDifference(model.replyPlacement.popoverAnchor, CGPoint(x: 656, y: 321))
    #expect(model.showsReplyConnector)

    model.questionBarMoved(bar, frame: CGRect(x: 300, y: 300, width: 640, height: 42))
    expectNoDifference(model.replyPlacement.popover, CGRect(x: 16, y: 300, width: 420, height: 300))
    #expect(!model.showsReplyConnector)

    model.questionBarMoved(bar, frame: CGRect(x: 700, y: 300, width: 640, height: 42))
    model.questionBarDisappeared(bar)
    #expect(!model.showsReplyConnector)
  }
}

extension ChangeStreamPageTests {
  // MARK: - Follow-ups across windows

  static let root = "11111111-1111-4111-8111-111111111111"
  static let firstFollowUp = "22222222-2222-4222-8222-222222222222"

  @Test func laggingWindowCannotReplyWhileAnotherWindowSawTheLatestTurnWaiting() async throws {
    let requests = LockIsolated<[QuestionRequest]>([])
    let (current, lagging) = await withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { request in
        requests.withValue { $0.append(request) }
        if requests.value.count == 1 { throw QuestionError.outcomeUnknown }
        return try AskAgentPageTests.ack(request)
      }
    } operation: {
      let current = await connectedModel()
      return (current, await connectedModel())
    }
    defer {
      current.viewDisappeared()
      lagging.viewDisappeared()
    }
    for item in [Fixture.edited(1), Fixture.questionQueued(2, id: Self.root), Fixture.questionAnswered(3, id: Self.root)] {
      fake.send(to: 0, item)
      fake.send(to: 1, item)
    }
    await Task.megaYield()
    let reply = try open(current, Self.root)
    reply.draft = "First follow-up"
    await reply.sendReplyTapped()
    #expect(reply.isErrorPresented)
    current.replyDismissTapped()
    let queued = Fixture.questionQueued(4, id: Self.firstFollowUp, text: "First follow-up", replyTo: Self.root)
    await send(to: 0, queued)

    let stale = try open(lagging, Self.root)
    #expect(stale.isFollowUpDisabled)
    stale.draft = "A different follow-up"
    await stale.sendReplyTapped()
    expectNoDifference(requests.value.count, 1)
    expectNoDifference(stale.draft, "First follow-up")
    await send(to: 1, queued)
    #expect(stale.isFollowUpDisabled)
    await send(to: 1, Fixture.questionAnswered(5, id: Self.firstFollowUp))
    #expect(!stale.isFollowUpDisabled)

    stale.draft = "A different follow-up"
    await stale.sendReplyTapped()
    expectNoDifference(requests.value.map(\.replyToQuestionID), [Self.root, Self.firstFollowUp])
    expectNoDifference(Set(requests.value.map(\.requestID)).count, 2)
  }

  @Test func olderReplayCannotReopenRepliesBehindANewerWaitingTurn() async throws {
    let secondFollowUp = "44444444-4444-4444-8444-444444444444"
    let history = [
      Fixture.edited(1), Fixture.questionQueued(2, id: Self.root), Fixture.questionAnswered(3, id: Self.root),
      Fixture.questionQueued(4, id: Self.firstFollowUp, replyTo: Self.root),
      Fixture.questionAnswered(5, id: Self.firstFollowUp),
    ]
    let waiting = Fixture.questionQueued(6, id: secondFollowUp, replyTo: Self.firstFollowUp)
    let current = await connectedModel()
    defer { current.viewDisappeared() }
    for item in history + [waiting] { fake.send(to: 0, item) }
    await Task.megaYield()
    let replaying = await connectedModel()
    defer { replaying.viewDisappeared() }
    for item in history { fake.send(to: 1, item) }
    await Task.megaYield()

    let reply = try open(replaying, Self.root)
    #expect(reply.isFollowUpDisabled)
    await send(to: 1, waiting)
    #expect(reply.isFollowUpDisabled)
    await send(to: 1, Fixture.questionAnswered(7, id: secondFollowUp))
    #expect(!reply.isFollowUpDisabled)
  }
}

extension ChangeStreamPageTests {
  @Test func largerTextRescalesAnExistingSourceSelection() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\nlast\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(
      span: ClipSpan(lineStart: 1, lineEnd: 4, truncated: false), method: .changedRange
    ))]), for: Fixture.seq(1))
    await send(Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing source"); return }
    let block = blocks[0]
    model.sourceDragged(
      row: row, block: block, startY: 23, endY: 60,
      frame: CGRect(x: 20, y: 100, width: 600, height: 88)
    )
    model.sourceDragEnded()
    let composer = try #require(model.askAgent)
    expectNoDifference(composer.context.lineStart, 2)
    expectNoDifference(composer.context.lineEnd, 3)

    model.$fontSizeStep.withLock { $0 = 5 }
    model.sourceBlockMoved(
      row: row, block: block, frame: CGRect(x: 20, y: 100, width: 600, height: 176)
    )

    expectNoDifference(composer.context.lineStart, 2)
    expectNoDifference(composer.context.lineEnd, 3)
    expectNoDifference(model.highlightRect(row: row, block: block, width: 600), CGRect(x: 0, y: 44, width: 600, height: 88))
    expectNoDifference(model.selectionFrame, CGRect(x: 20, y: 144, width: 600, height: 88))
  }

  @Test func largerTextScalesSourceRowsAndSelection() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    model.$fontSizeStep.withLock { $0 = 5 }
    expectNoDifference(model.sourceLineHeight, 44)
    expectNoDifference(model.sourceLineNumberWidth, 50)
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\nlast\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 4, truncated: false), method: .changedRange))]), for: Fixture.seq(1))
    await send(Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing source"); return }
    model.sourceDragged(row: row, block: blocks[0], startY: 45, endY: 100, frame: CGRect(x: 20, y: 100, width: 600, height: 176))
    model.sourceDragEnded()
    let composer = try #require(model.askAgent)
    expectNoDifference(composer.context.lineStart, 2)
    expectNoDifference(composer.context.lineEnd, 3)
    expectNoDifference(model.highlightRect(row: row, block: blocks[0], width: 600), CGRect(x: 0, y: 44, width: 600, height: 88))
  }
}

extension ChangeStreamPageTests {
  func composer(
    _ model: ChangeStreamPageModel, session: String = Fixture.session, agentConnection: AgentConnection
  ) -> AskAgentPageModel {
    let composer = withDependencies(from: model) {
      AskAgentPageTests.composer(
        sessionID: session, agentConnection: agentConnection,
        captureStatus: model.selectedCaptureStatus ?? AskAgentPageTests.capture())
    }
    model.askAgent = composer
    composer.draftChanged("Why?")
    return composer
  }

  func listSessions(_ connection: AgentConnection, durableSeq: Int = 0, other: AgentConnection? = nil) {
    var summaries = [
      SessionSummary(id: Fixture.session, durableSeq: Fixture.seq(durableSeq), removed: false, agentConnection: connection)
    ]
    if let other {
      summaries.append(SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false, agentConnection: other))
    }
    fake.setSessions(summaries)
  }

  @Test func sessionsCarryTheListedAgentConnection() async {
    listSessions(.setupPending, other: .connected)
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.sessions[id: Fixture.session]?.agentConnection, .setupPending)
    expectNoDifference(model.sessions[id: Fixture.otherSession]?.agentConnection, .connected)
  }

  func liveModel() async -> ChangeStreamPageModel {
    let model = await connectedModel()
    await send(.heartbeat)
    return model
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

  @Test func theCaptureStripReadsTheDaemonsSnapshot() async {
    let model = await liveModel()
    defer { model.viewDisappeared() }
    #expect(model.isCaptureStripShown)
    expectNoDifference(model.captureText, "Recording")
    expectNoDifference(model.captureCheckedText, "Checked 10:42:20")
    expectNoDifference(model.chatLinkText, "Linked — changes are possibly the agent's")
    expectNoDifference(model.footerText, "Connected · New changes appear below")
  }

  func listThreeSessionsWithOneRecording() {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: "uncaptured", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/old", startedAtMs: 0),
        "uncaptured": SessionStarted(root: "/tmp/slipstream-test/workspaces/r/uncaptured", startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(root: "/tmp/slipstream-test/workspaces/r/project"),
      Fixture.capture(.stopped, reason: "archived", session: Fixture.otherSession, root: "/tmp/slipstream-test/workspaces/r/old", binding: nil),
    ])
  }

  @Test func theSidebarHidesInactiveWorkspaces() async {
    listThreeSessionsWithOneRecording()
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.sidebarGroups.flatMap(\.rows).map(\.id), [Fixture.session])
  }

  @Test func theSelectedWorkspaceStaysInTheSidebarWhenItStops() async {
    listThreeSessionsWithOneRecording()
    fake.setCaptures([Fixture.capture(root: "/tmp/slipstream-test/workspaces/r/project"), Fixture.capture(session: Fixture.otherSession, root: "/tmp/slipstream-test/workspaces/r/old")])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    listThreeSessionsWithOneRecording()
    await model.reloadShortcutPressed()
    expectNoDifference(model.sidebarGroups.flatMap(\.rows).map(\.id), [Fixture.session, Fixture.otherSession])
  }

  @Test func theSidebarListsEveryAppWorkspaceWhenCaptureStateIsUnknown() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: "conductor", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/one", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/slipstream-test/workspaces/r/two", startedAtMs: 0),
        "conductor": SessionStarted(root: "/tmp/conductor-test/workspaces/r/three", startedAtMs: 0),
      ])
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.sidebarGroups.flatMap(\.rows).map(\.id), [Fixture.otherSession, Fixture.session])
  }

  /// Capture-only rows: each capture is a row rooted at its own folder.
  func listCaptures(_ captures: CaptureSummary...) {
    fake.setSessions([])
    fake.setCaptures(captures)
  }

  /// `WorkspaceClient.testValue`'s roots, whose repo groups get looked up.
  static var testRootsWorkspace: WorkspaceClient {
    var workspace = WorkspaceClient.testValue
    workspace.repository = { _ in nil }
    return workspace
  }

  func sidebarRowIDs(_ model: ChangeStreamPageModel) -> [String] {
    model.sidebarGroups.flatMap(\.rows).map(\.id)
  }

  @Test func aPausedRowShowsOnlyWhileItsFolderExists() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "detached", session: "deleted", root: "/tmp/slipstream-test/workspaces/r/deleted", binding: nil),
      Fixture.capture(.stopped, reason: "detached", session: "kept", root: "/tmp/slipstream-test/workspaces/r/kept", binding: nil))
    terminal.setMissing("/tmp/slipstream-test/workspaces/r/deleted")
    let model = makeModel(workspace: Self.testRootsWorkspace)
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(sidebarRowIDs(model), ["kept"])
    let row = try #require(model.sessions[id: "kept"])
    #expect(model.isPaused(row))
    expectNoDifference(model.rowActionText(row), "Record")
  }

  @Test func aPausedRowShowsOnlyInsideTheWorkspacesFolder() async throws {
    listCaptures(
      Fixture.capture(
        .stopped, reason: "detached", session: "conductor", root: "/tmp/conductor-test/workspaces/r/taipei",
        binding: nil),
      Fixture.capture(
        .stopped, reason: "detached", session: "managed", root: "/tmp/slipstream-test/workspaces/r/workspace-1",
        binding: nil),
      Fixture.capture(session: "recording", root: "/tmp/conductor-test/workspaces/r/brisbane", binding: nil))
    let model = makeModel(workspace: Self.testRootsWorkspace)
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(sidebarRowIDs(model), ["managed"])
  }

  @Test func onlyWorkspacesTheAppCreatedAreListed() async {
    listCaptures(
      Fixture.capture(session: "conductor", root: "/tmp/conductor-test/workspaces/r/brisbane", binding: nil),
      Fixture.capture(session: "elsewhere", root: "/tmp/project", binding: nil),
      Fixture.capture(session: "managed", root: "/tmp/slipstream-test/workspaces/r/workspace-1", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(sidebarRowIDs(model), ["managed"])
  }

  @Test func aPausedRowBrightensWhenSelectedOrHovered() async throws {
    listCaptures(
      Fixture.capture(session: "recording", root: "/work/recording", binding: nil),
      Fixture.capture(.stopped, reason: "detached", session: "paused", root: "/work/paused", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let row = try #require(model.sessions[id: "paused"])
    model.sessionSelected("recording")
    await Task.megaYield()
    expectNoDifference(model.rowNameColor(row), DesignTokens.Sidebar.pausedRowNameColor(isHighlighted: false))

    model.rowHoverChanged(row, isHovering: true)
    expectNoDifference(model.rowNameColor(row), DesignTokens.Sidebar.pausedRowNameColor(isHighlighted: true))

    model.rowHoverChanged(row, isHovering: false)
    model.sessionSelected("paused")
    await Task.megaYield()
    expectNoDifference(model.rowNameColor(row), DesignTokens.Sidebar.pausedRowNameColor(isHighlighted: true))
  }

  @Test func aNotRecordingCaptureShowsWithPause() async throws {
    listCaptures(
      Fixture.capture(session: "recording", root: "/tmp/slipstream-test/workspaces/r/recording", binding: nil),
      Fixture.capture(.notRecording, reason: "storage-unavailable", session: "retrying", root: "/tmp/slipstream-test/workspaces/r/retrying", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(sidebarRowIDs(model), ["retrying", "recording"])
    let row = try #require(model.sessions[id: "retrying"])
    expectNoDifference(model.rowActionText(row), "Pause")
    #expect(!model.isRecordingDotShown(row))
  }

  @Test func archivedAndMaintenanceRowsStayHiddenUnlessSelected() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "archived", session: "archived", root: "/tmp/slipstream-test/workspaces/r/archived", binding: nil),
      Fixture.capture(.stopped, reason: "maintenance", session: "maintenance", root: "/tmp/slipstream-test/workspaces/r/maintenance", binding: nil),
      Fixture.capture(session: "recording", root: "/tmp/slipstream-test/workspaces/r/recording", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(sidebarRowIDs(model), ["recording"])

    model.sessionSelected("maintenance")
    await Task.megaYield()
    let row = try #require(model.sessions[id: "maintenance"])
    model.rowHoverChanged(row, isHovering: true)

    expectNoDifference(sidebarRowIDs(model), ["recording", "maintenance"])
    #expect(!model.isRowActionShown(row))
  }

  @Test func aRecreatedFolderShowsOneRowAndPauseSendsItsPath() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "detached", session: "old", root: "/tmp/slipstream-test/workspaces/r/farmerville", binding: nil),
      Fixture.capture(session: "new", root: "/tmp/slipstream-test/workspaces/r/farmerville", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(sidebarRowIDs(model), ["new"])

    let row = try #require(model.sessions[id: "new"])
    await model.rowActionTapped(row)

    expectNoDifference(recordingFake.calls, [.pause("/tmp/slipstream-test/workspaces/r/farmerville")])
  }

  @Test func aRecreatedFolderThatIsRetryingShowsItsRetryingCaptureWithPause() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "detached", session: "old", root: "/tmp/slipstream-test/workspaces/r/farmerville", binding: nil),
      Fixture.capture(.notRecording, reason: "storage-unavailable", session: "new", root: "/tmp/slipstream-test/workspaces/r/farmerville", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(sidebarRowIDs(model), ["new"])
    let row = try #require(model.sessions[id: "new"])
    expectNoDifference(model.rowActionText(row), "Pause")
  }

  @Test func theHeaderCountsRecordingRowsOnly() async {
    listCaptures(
      Fixture.capture(session: "a", root: "/tmp/slipstream-test/workspaces/r/a", binding: nil),
      Fixture.capture(session: "b", root: "/tmp/slipstream-test/workspaces/r/b", binding: nil),
      Fixture.capture(session: "c", root: "/tmp/slipstream-test/workspaces/r/c", binding: nil),
      Fixture.capture(.queued, session: "d", root: "/tmp/slipstream-test/workspaces/r/d", binding: nil),
      Fixture.capture(.queued, session: "e", root: "/tmp/slipstream-test/workspaces/r/e", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(model.recordingCountText, "3 recording")
  }

  @Test func theHeaderCountIsHiddenWhileCaptureStateIsUnknown() async {
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(model.recordingCountText, nil)
  }

  @Test func aReplyAfterTheSelectionChangedDoesNotMoveIt() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "detached", session: "a", root: "/work/a", binding: nil),
      Fixture.capture(session: "b", root: "/work/b", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let paused = try #require(model.sessions[id: "a"])
    recordingFake.hold()
    let record = Task { await model.rowActionTapped(paused) }
    await Task.megaYield()
    expectNoDifference(model.rowActionText(paused), "Recording…")
    #expect(model.isRowActionDisabled(paused))

    model.sessionSelected("b")
    await Task.megaYield()
    fake.setCaptures([
      Fixture.capture(session: "a", root: "/work/a", binding: nil),
      Fixture.capture(session: "b", root: "/work/b", binding: nil),
    ])
    recordingFake.release()
    await record.value

    expectNoDifference(model.selectedSession?.id, "b")
    let recording = try #require(model.sessions[id: "a"])
    expectNoDifference(model.rowActionText(recording), "Pause")
    #expect(model.isRecordingDotShown(recording))
  }

  @Test func aRefusedRecordShowsItsMessageUnderTheRow() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "detached", session: "a", root: "/tmp/slipstream-test/workspaces/r/a", binding: nil),
      Fixture.capture(session: "b", root: "/tmp/slipstream-test/workspaces/r/b", binding: nil))
    recordingFake.setFailures(.rejected(code: "CAPTURE_LIMIT_REACHED", message: "full"))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let paused = try #require(model.sessions[id: "a"])

    await model.rowActionTapped(paused)

    expectNoDifference(
      model.rowMessage(paused),
      RecordingMessage(text: "All recording slots are in use. Pause a workspace first.", isFull: true))
    expectNoDifference(model.recordingCountText, "1 recording")
  }

  @Test func recordingAFolderThatIsAlreadyRecordingSelectsItsRow() async {
    listCaptures(
      Fixture.capture(session: "a", root: "/work/a", binding: nil),
      Fixture.capture(session: "b", root: "/work/b", binding: nil))
    let model = makeModel(workspace: workspaceClient(choose: URL(filePath: "/work/b")))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.recordFolderTapped()

    expectNoDifference(recordingFake.calls, [.record("/work/b")])
    expectNoDifference(model.selectedSession?.id, "b")
    expectNoDifference(model.footerMessage, nil)
  }

  @Test func recordingARecreatedFolderSelectsItsCurrentCaptureInsteadOfOldHistory() async {
    fake.setSessions(
      [SessionSummary(id: "old", durableSeq: .zero, removed: false)],
      starts: ["old": SessionStarted(root: "/work/b", startedAtMs: 0)])
    fake.setCaptures([Fixture.capture(session: "new", root: "/work/b", binding: nil)])
    let model = makeModel(workspace: workspaceClient(choose: URL(filePath: "/work/b")))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.recordFolderTapped()

    expectNoDifference(model.selectedSession?.id, "new")
  }

  @Test func aRowSelectedWhileRecordingAFolderKeepsTheSelection() async {
    listCaptures(
      Fixture.capture(session: "a", root: "/work/a", binding: nil),
      Fixture.capture(session: "b", root: "/work/b", binding: nil),
      Fixture.capture(session: "c", root: "/work/c", binding: nil))
    let model = makeModel(workspace: workspaceClient(choose: URL(filePath: "/work/b")))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    recordingFake.hold()

    let record = Task { await model.recordFolderTapped() }
    await Task.megaYield()
    model.sessionSelected("c")
    await Task.megaYield()
    recordingFake.release()
    await record.value
    await Task.megaYield()

    expectNoDifference(model.selectedSession?.id, "c")
  }

  @Test func recordingAPausedWorkspaceLinksItsChatOnce() async {
    fake.setCaptures([Fixture.capture(.stopped, reason: "detached", binding: nil)])
    agent.setTranscript(Self.tab, .found([.user(uuid: "u1", timestamp: Fixture.checkedAt, isPrompt: true, blocks: [.text("Hi")])]))
    let chat = makeChat(records: [
      ChatTabRecord(id: Self.tab, folder: "/tmp/project", model: "claude-opus-5-5", effort: .high, isWaiting: false)
    ])
    let model = makeModel(chat: chat)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()
    #expect(link.calls.isEmpty)

    fake.setCaptures([Fixture.capture(.queued, binding: nil)])
    await model.recording.recordTapped(folder: "/tmp/project")
    await Task.megaYield()

    expectNoDifference(link.calls, [.link(folder: "/tmp/project", tabID: Self.tab, replacing: nil)])
  }

  @Test func allInactiveSessionsReadNoCaptureSessionsYet() async {
    listThreeSessionsWithOneRecording()
    fake.setCaptures([
      Fixture.capture(.stopped, reason: "archived"),
      Fixture.capture(.stopped, reason: "archived", session: Fixture.otherSession, root: "/work/old", binding: nil),
    ])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.selectedSession == nil)
    expectNoDifference(model.emptyStateText, "No capture sessions yet")
  }

  @Test func aWorkspaceWithoutChatsIsNeitherBoldNorWorking() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let session = try #require(model.selectedSession)
    #expect(model.isSelected(session))
    #expect(!model.isBold(session))
    #expect(!model.isWorking(session))
  }

  @Test(arguments: [CaptureState.queued, .baselining, .stopped, .notRecording, .unknown("paused")])
  func aConnectedAgentNeverMakesANonRecordingCaptureReadRecording(_ state: CaptureState) async {
    listSessions(.connected)
    fake.setCaptures([Fixture.capture(state)])
    let model = await liveModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    #expect(model.captureText?.hasPrefix("Recording") == false)
    #expect(!model.footerText.contains("Recording"))
    #expect(!composer.canSubmit)
  }

  @Test func aReaderWithoutTheCapturesEndpointShowsTheStateAsUnknown() async {
    fake.setCaptures(.notFound)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureText, "Capture state unavailable from this reader")
    expectNoDifference(model.chatLinkText, "Chat-link state unknown")
    #expect(model.captureCheckedText == nil)
    #expect(model.isFooterShown)
  }

  @Test func aFailedCapturesRequestShowsTheStateAsUnknownWhileTheFeedStillLoads() async {
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = await liveModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureText, "Capture state unknown — the capture list didn't load")
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session])
  }

  @Test func aFailedReloadKeepsTheListButStopsClaimingTheLastCheckedState() async {
    let model = await liveModel()
    defer { model.viewDisappeared() }
    fake.setSessionsError(URLError(.cannotConnectToHost))
    await model.reloadShortcutPressed()
    expectNoDifference(model.sessions.ids, [Fixture.session])
    expectNoDifference(model.selectedSession?.id, Fixture.session)
    expectNoDifference(model.sessionsError, nil)
    expectNoDifference(model.captureText, "Capture state unknown — the capture list didn't load")
    #expect(model.captureCheckedText == nil)
  }

  @Test func aFailedReloadWithoutASelectionExplainsHowToTryAgain() async {
    fake.setCaptures([])
    fake.setSessions([
      SessionSummary(id: "a", durableSeq: .zero, removed: false),
      SessionSummary(id: "b", durableSeq: .zero, removed: false),
    ])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.sessions.ids, ["a", "b"])
    expectNoDifference(model.selectedSession, nil)

    fake.setCaptures(.failure(.invalidResponse))
    fake.setSessionsError(URLError(.cannotConnectToHost))
    await model.reloadShortcutPressed()

    expectNoDifference(model.sessions.ids, ["a", "b"])
    expectNoDifference(model.selectedSession, nil)
    expectNoDifference(model.emptyStateText, "The capture list didn't load. Press ⌘R to check again.")
  }

  @Test func aFailedReloadOfAnEmptyListSaysSo() async {
    fake.setCaptures([])
    fake.setSessions([])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    fake.setSessionsError(DaemonHTTPError.status(503, durableSeq: nil, body: "store is migrating"))
    await model.reloadShortcutPressed()
    expectNoDifference(
      model.sessionsError,
      RecorderMessage(
        icon: .failure, tone: .error, headline: "The recorder answered the session list with HTTP 503.",
        footer: "The recorder answered the session list with HTTP 503.",
        evidence: Evidence(source: "GET /v1/sessions → 503", text: "store is migrating"), actions: [.tryAgain]))
  }

  @Test func aPausedRowOffersNoActionWhileItsStateIsUnknown() async throws {
    listCaptures(Fixture.capture(.stopped, reason: "detached", session: "kept", root: "/work/kept", binding: nil))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    fake.setSessionsError(URLError(.cannotConnectToHost))
    await model.reloadShortcutPressed()
    let row = try #require(model.sessions[id: "kept"])
    #expect(!model.isRowActionAvailable(row))
  }

  @Test func aWorkspaceThatIsNotRecordingIsFollowedOnceItRecords() async {
    fake.setCaptures([
      Fixture.capture(),
      Fixture.capture(.notRecording, reason: "root-overlap", session: Fixture.otherSession, root: "/work/seventeenth", binding: nil),
    ])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    expectNoDifference(model.breadcrumbWorkspaceText, "seventeenth")
    expectNoDifference(model.captureText, "Not recording — folder overlaps another capture")
    expectNoDifference(model.captureDetailText, nil)
    expectNoDifference(model.chatLinkText, "No chat linked")
    expectNoDifference(model.emptyStateText, "No change history is available yet. Press ⌘R to check again.")
    #expect(!model.isFooterShown)
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session])

    listSessions(.connected, other: .connected)
    fake.setCaptures([Fixture.capture(), Fixture.capture(session: Fixture.otherSession, root: "/work/seventeenth")])
    await model.reloadShortcutPressed()
    await Task.megaYield()
    expectNoDifference(model.captureText, "Recording")
    #expect(model.isFooterShown)
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session, Fixture.otherSession])
  }

  @Test func choosingAWorkspaceWithoutHistoryStopsFollowingThePreviousOne() async {
    fake.setCaptures([
      Fixture.capture(),
      Fixture.capture(.queued, session: Fixture.otherSession, root: "/work/other", binding: nil),
    ])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    await send(Fixture.edited(1))
    #expect(model.sections.isEmpty)
    expectNoDifference(model.connection, .idle)
  }

  @Test func aWorkspaceThatLosesItsHistoryStopsBeingFollowed() async {
    let model = await liveModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    #expect(!model.sections.isEmpty)
    fake.setSessions([])
    await model.reloadShortcutPressed()
    await Task.megaYield()
    await send(Fixture.edited(2))
    #expect(model.sections.isEmpty)
    expectNoDifference(model.connection, .idle)
  }

  @Test func theCheckedTimeIsWhenTheCaptureStateArrived() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)])
    let now = LockIsolated(Fixture.checkedAt)
    let model = makeModel(daemon: daemon, now: { now.value })
    let appeared = Task { await model.viewAppeared() }
    await Task.megaYield()
    now.setValue(Fixture.checkedAt.addingTimeInterval(100))
    open.yield()
    await appeared.value
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureCheckedText, "Checked 10:42:20")
  }

  @Test func aRefreshThatFailsWhileTheFeedDropsStopsClaimingRecording() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .connected)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()
    daemon.send(.heartbeat)
    await Task.megaYield()
    expectNoDifference(model.captureText, "Recording")
    daemon.setCaptures(.failure(.status(500, durableSeq: nil)))
    daemon.setSessionsError(DaemonHTTPError.status(500, durableSeq: nil))
    let refresh = Task { await model.reloadShortcutPressed() }
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    open.yield()
    await refresh.value
    expectNoDifference(model.captureText, "Capture state unknown — the capture list didn't load")
  }

  @Test func aCaptureStateThatArrivesWhileTheFeedDropsIsStillShown() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .connected)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()
    daemon.send(.heartbeat)
    await Task.megaYield()
    daemon.setCaptures([Fixture.capture(.stopped, reason: "maintenance")])
    let refresh = Task { await model.reloadShortcutPressed() }
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    open.yield()
    await refresh.value
    expectNoDifference(model.captureText, "Stopped — maintenance in progress")
  }

  @Test func aCaptureOnlyWorkspaceThatArrivesWhileTheFeedDropsIsAddedToThePicker() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .connected)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()
    daemon.send(.heartbeat)
    await Task.megaYield()
    daemon.setCaptures([
      Fixture.capture(),
      Fixture.capture(.queued, session: Fixture.otherSession, root: "/work/other", binding: nil),
    ])
    let refresh = Task { await model.reloadShortcutPressed() }
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    open.yield()
    await refresh.value
    expectNoDifference(model.sessions.ids, [Fixture.session, Fixture.otherSession])
    expectNoDifference(model.sessions[id: Fixture.otherSession]?.hasHistory, false)
  }

  @Test func closingTheWindowBeforeASelectionRefreshRunsStartsNothing() async {
    fake.setCaptures([
      Fixture.capture(),
      Fixture.capture(.queued, session: Fixture.otherSession, root: "/work/other", binding: nil),
    ])
    let model = makeModel()
    await model.viewAppeared()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    model.viewDisappeared()
    listSessions(.connected, other: .connected)
    fake.setCaptures([Fixture.capture(), Fixture.capture(session: Fixture.otherSession, root: "/work/other")])
    await Task.megaYield()
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session])
  }

  @Test func maintenanceStopsTheCaptureUntilARefreshShowsItRecording() async {
    fake.setCaptures([Fixture.capture(.stopped, reason: "maintenance")])
    let model = await liveModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureText, "Stopped — maintenance in progress")
    expectNoDifference(
      model.captureDetailText,
      "Slipstream is cleaning up its storage. Capture resumes on its own afterwards. Press ⌘R to check again.")
    fake.setCaptures([Fixture.capture()])
    await model.reloadShortcutPressed()
    expectNoDifference(model.captureText, "Recording")
    #expect(model.captureDetailText == nil)
  }

  @Test func aStorageOutageWhileRecordingReadsNotRecording() async {
    fake.setCaptures([Fixture.capture(.notRecording, reason: "storage-unavailable")])
    let model = await liveModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureText, "Not recording — storage unavailable")
  }

  @Test func aRestartedCaptureReadsQueuedWhileItsChatWaitsForSetup() async {
    listSessions(.connected)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    #expect(composer.canSubmit)
    listSessions(.disconnected(reason: "no_agent"), durableSeq: 2)
    fake.setCaptures([Fixture.capture(.queued, binding: CaptureBinding(generation: "7", state: .setupPending))])
    let callsBefore = fake.capturesCallCount
    await send(Fixture.sessionResumed(1), Fixture.restartGap(2))
    await Task.megaYield()
    expectNoDifference(fake.capturesCallCount, callsBefore + 1)
    expectNoDifference(model.captureText, "Queued — not recording yet")
    expectNoDifference(model.chatLinkText, "Waiting for setup — the chat hasn't confirmed it can answer yet")
    #expect(!composer.canSubmit)
  }

  @Test func eachWorkspacesQuestionReachesItsOwnChat() async throws {
    listSessions(.connected, other: .connected)
    fake.setCaptures([
      Fixture.capture(binding: CaptureBinding(generation: "7", state: .connected)),
      Fixture.capture(session: Fixture.otherSession, root: "/work/other", binding: CaptureBinding(generation: "9", state: .connected)),
    ])
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = { request in
        requests.withValue { $0.append(request) }
        return try AskAgentPageTests.ack(request)
      }
    } operation: { makeModel() }
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    for session in [Fixture.session, Fixture.otherSession] {
      model.sessionSelected(session)
      await Task.megaYield()
      await send(to: fake.follows.count - 1, .heartbeat)
      let composer = withDependencies(from: model) {
        AskAgentPageTests.composer(sessionID: session, captureStatus: model.selectedCaptureStatus!)
      }
      model.askAgent = composer
      composer.draftChanged("Why?")
      await model.askQuestionTapped(composer)
    }
    expectNoDifference(requests.value.map(\.sessionID), [Fixture.session, Fixture.otherSession])
    expectNoDifference(requests.value.map(\.verb), [.ask(bindingGeneration: "7"), .ask(bindingGeneration: "9")])
  }

  @Test func returningToAStoppedWorkspaceRefreshesItsCaptureState() async {
    listSessions(.connected, other: .connected)
    fake.setCaptures([Fixture.capture(), Fixture.capture(session: Fixture.otherSession)])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    fake.setCaptures([Fixture.capture(.stopped, reason: "detached"), Fixture.capture(session: Fixture.otherSession)])
    let callsBefore = fake.capturesCallCount
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    expectNoDifference(fake.capturesCallCount, callsBefore + 1)
    expectNoDifference(model.captureText, "Paused")
  }

  @Test func changesBeyondTheListedPositionOfAnEndedCaptureRefreshTheSessions() async {
    listSessions(.disconnected(reason: "capture_not_live"), durableSeq: 2)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    listSessions(.connected, durableSeq: 3)
    let callsBefore = fake.sessionsCallCount
    await send(Fixture.edited(1), Fixture.edited(2), Fixture.edited(3))
    expectNoDifference(fake.sessionsCallCount, callsBefore + 1)
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
  }

  @Test func aCaptureStoppedReportRefreshesTheCaptureSnapshot() async {
    listSessions(.connected)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    fake.setCaptures([Fixture.capture(.stopped, reason: "maintenance")])
    let callsBefore = fake.capturesCallCount
    await send(Fixture.agentConnection(1, state: "capture_not_live"))
    await Task.megaYield()
    expectNoDifference(fake.capturesCallCount, callsBefore + 1)
    expectNoDifference(model.captureText, "Stopped — maintenance in progress")
  }

  @Test func aCaptureStoppedEventRefreshesTheCaptureSnapshotWithoutARow() async {
    listSessions(.connected)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    fake.setCaptures([Fixture.capture(.stopped, reason: "maintenance")])
    let callsBefore = fake.capturesCallCount

    await send(Fixture.captureStopped(1, reason: "maintenance"))
    await Task.megaYield()

    expectNoDifference(fake.capturesCallCount, callsBefore + 1)
    expectNoDifference(model.captureText, "Stopped — maintenance in progress")
    expectNoDifference(model.sections.flatMap(\.items).count, 0)
  }

  @Test func replayingAnEndedCapturesHistoryDoesNotRefresh() async {
    listSessions(.disconnected(reason: "capture_not_live"), durableSeq: 2)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    let callsBefore = fake.sessionsCallCount
    await send(Fixture.edited(1), Fixture.edited(2))
    expectNoDifference(fake.sessionsCallCount, callsBefore)
  }

  @Test func aResumeDisablesAskUntilTheAgentConnectsAgain() async {
    listSessions(.connected)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    #expect(composer.canSubmit)
    await send(Fixture.sessionResumed(1), Fixture.restartGap(2))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
    await send(Fixture.agentConnection(3, state: "connected"))
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func replayingAnOldResumeKeepsTheListedReadiness() async {
    listSessions(.connected, durableSeq: 2)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    let callsBefore = fake.sessionsCallCount
    await send(Fixture.sessionResumed(1), Fixture.restartGap(2))
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(fake.sessionsCallCount, callsBefore)
  }

  func reconnectedWithAReplayedSetupPending(_ daemon: DaemonFake, gate open: AsyncStream<Void>.Continuation) async -> ChangeStreamPageModel {
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .disconnected(reason: "capture_not_live"))])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    daemon.send(.heartbeat)
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    await clock.advance(by: .milliseconds(500))
    daemon.send(.heartbeat)
    await Task.megaYield()
    daemon.send(Fixture.agentConnection(1, state: "setup_pending"))
    await Task.megaYield()
    return model
  }

  @Test func aReplayedSetupPendingWaitsForTheFreshListing() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    let model = await reconnectedWithAReplayedSetupPending(daemon, gate: open)
    defer { model.viewDisappeared() }
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    open.yield()
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .setupPending)
  }

  @Test func aLinkMovedWhileAFreshSnapshotIsInFlightIsReadAgain() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "6", state: .unlinked))])
    let model = await reconnectedWithAReplayedSetupPending(daemon, gate: open)
    defer { model.viewDisappeared() }
    daemon.setCaptures([Fixture.capture(binding: CaptureBinding(generation: "7", state: .setupPending))])

    open.yield()
    await Task.megaYield()
    open.yield()
    await Task.megaYield()

    expectNoDifference(model.selectedSession?.capture?.binding, CaptureBinding(generation: "7", state: .setupPending))
  }

  @Test func aReplayedSetupPendingStaysUnconfirmedWhenTheRefreshFails() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    let model = await reconnectedWithAReplayedSetupPending(daemon, gate: open)
    defer { model.viewDisappeared() }
    daemon.setSessionsError(URLError(.cannotConnectToHost))
    open.yield()
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(model.captureText, "Capture state unknown — the capture list didn't load")
  }

  @Test func aConnectionEventUpdatesTheWatchedSessionAndItsComposerWithoutAddingARow() async {
    listSessions(.setupPending)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .setupPending)
    #expect(!composer.canSubmit)
    await send(Fixture.agentConnection(1, state: "connected"))
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(model.sessions[id: Fixture.session]?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
    #expect(model.sections.isEmpty)
    expectNoDifference(model.lastAppliedSeq, Fixture.seq(1))
  }

  @Test func aConnectionEventDoesNotTouchAComposerBoundToAnotherCapture() async {
    listSessions(.setupPending, other: .setupPending)
    let model = await connectedModel()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let composer = composer(model, session: Fixture.otherSession, agentConnection: .setupPending)
    await send(Fixture.agentConnection(1, state: "connected"))
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .setupPending)
    expectNoDifference(composer.sessionID, Fixture.otherSession)
    expectNoDifference(composer.draft, "Why?")
  }

  @Test func switchingCapturesDisablesTheRetainedOutgoingComposer() async {
    listSessions(.connected, other: .connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    let composer = composer(model, agentConnection: .connected)
    model.sessionSelected(Fixture.otherSession)
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
    await Task.megaYield()
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
  }

  @Test func refreshingAfterSwitchingCapturesKeepsTheOutgoingComposerDisabled() async {
    listSessions(.connected, other: .connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    let composer = composer(model, agentConnection: .connected)
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    await model.reloadShortcutPressed()
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
  }

  @Test func returningToTheComposersCaptureRefreshesItsReadiness() async {
    listSessions(.connected, other: .connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    let composer = composer(model, agentConnection: .connected)

    model.sessionSelected(Fixture.otherSession)
    #expect(!composer.canSubmit)

    model.sessionSelected(Fixture.session)
    await Task.megaYield()

    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
    expectNoDifference(composer.draft, "Why?")
  }

  @Test func aConnectionEventReplacesAnUnreportedState() async {
    listSessions(.unreported)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.agentConnection(1, state: "setup_pending"))
    expectNoDifference(model.selectedSession?.agentConnection, .setupPending)
  }

  @Test func aSessionsRefreshPushesTheListedStateToTheOpenComposer() async {
    listSessions(.setupPending)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .setupPending)
    listSessions(.connected)
    await model.reloadShortcutPressed()
    expectNoDifference(composer.agentConnection, .connected)
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    #expect(composer.canSubmit)
    listSessions(.disconnected(reason: "no_agent"))
    await model.reloadShortcutPressed()
    expectNoDifference(composer.agentConnection, .disconnected(reason: "no_agent"))
    #expect(!composer.canSubmit)
    expectNoDifference(composer.draft, "Why?")
  }

  @Test func aSessionsRefreshDisconnectsAComposerWhoseCaptureIsNoLongerListed() async {
    listSessions(.connected, other: .connected)
    let model = await connectedModel()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let composer = composer(model, session: Fixture.otherSession, agentConnection: .connected)
    listSessions(.connected)
    await model.reloadShortcutPressed()
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.sessionID, Fixture.otherSession)
    #expect(!composer.canSubmit)
  }

  @Test func openingTheComposerStartsFromTheSelectedSessionsState() async throws {
    listSessions(.setupPending)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\nlast\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 4, truncated: false), method: .changedRange))]), for: Fixture.seq(1))
    await send(Fixture.fileChanged(1, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 1))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing source"); return }
    model.sourceDragged(row: row, block: blocks[0], startY: 23, endY: 60, frame: CGRect(x: 20, y: 100, width: 600, height: 88))
    model.sourceDragEnded()
    let composer = try #require(model.askAgent)
    expectNoDifference(composer.agentConnection, .setupPending)
    await send(Fixture.agentConnection(2, state: "connected"))
    expectNoDifference(composer.agentConnection, .connected)
  }

  @Test func aLateSessionsResponseNeverOverwritesNewerReadiness() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .setupPending)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .setupPending)
    let refresh = Task { await model.reloadShortcutPressed() }
    await Task.megaYield()
    daemon.send(Fixture.agentConnection(1, state: "connected"))
    await Task.megaYield()
    open.yield()
    await refresh.value
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(model.sessions[id: Fixture.session]?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func replayingHistoryNeverDowngradesWhatTheSnapshotAlreadyCovers() async {
    listSessions(.connected, durableSeq: 2)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    await send(Fixture.agentConnection(1, state: "setup_pending"), Fixture.agentConnection(2, state: "setup_pending"))
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
    expectNoDifference(model.lastAppliedSeq, Fixture.seq(2))
  }

  @Test func aConnectionEventNewerThanAStartupDisconnectedSnapshotEnablesAsk() async {
    listSessions(.disconnected(reason: "capture_not_live"), durableSeq: 2)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .disconnected(reason: "capture_not_live"))
    await send(Fixture.edited(1), Fixture.edited(2), Fixture.agentConnection(3, state: "connected"))
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(model.sessions[id: Fixture.session]?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func leavingLiveDisablesAskUntilAFreshSnapshotShowsADetach() async {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    await send(Fixture.agentConnection(1, state: "connected"))
    fake.close()
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(model.sessions[id: Fixture.session]?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
    listSessions(.disconnected(reason: "capture_not_live"), durableSeq: 1)
    await clock.advance(by: .milliseconds(500))
    await send(.heartbeat)
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: "capture_not_live"))
    expectNoDifference(composer.agentConnection, .disconnected(reason: "capture_not_live"))
    #expect(!composer.canSubmit)
    expectNoDifference(composer.draft, "Why?")
  }

  @Test func reconnectingToAStillAttachedCaptureRestoresAsk() async {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    await send(Fixture.agentConnection(1, state: "connected"))
    fake.close()
    await Task.megaYield()
    #expect(!composer.canSubmit)
    listSessions(.connected, durableSeq: 1)
    await clock.advance(by: .milliseconds(500))
    await send(.heartbeat)
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func aSnapshotRequestedBeforeLeavingLiveCannotReEnableAsk() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .connected)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    daemon.send(Fixture.agentConnection(1, state: "connected"))
    await Task.megaYield()
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: Fixture.seq(1), removed: false, agentConnection: .connected)])
    let refresh = Task { await model.reloadShortcutPressed() }
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    open.yield()
    await refresh.value
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(model.sessions[id: Fixture.session]?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
    await clock.advance(by: .milliseconds(500))
    daemon.send(.heartbeat)
    await Task.megaYield()
    open.yield()
    await Task.megaYield()
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func aReplayedConnectedEventCannotReEnableAskBeforeAFreshSnapshotApplies() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .connected)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    daemon.send(Fixture.agentConnection(1, state: "connected"))
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    #expect(!composer.canSubmit)
    await clock.advance(by: .milliseconds(500))
    daemon.send(.heartbeat)
    await Task.megaYield()
    daemon.send(Fixture.agentConnection(2, state: "connected"))
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
    daemon.send(Fixture.agentConnection(3, state: "setup_pending"))
    await Task.megaYield()
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: Fixture.seq(3), removed: false, agentConnection: .setupPending)])
    open.yield()
    await Task.megaYield()
    expectNoDifference(composer.agentConnection, .setupPending)
    daemon.send(Fixture.agentConnection(4, state: "connected"))
    await Task.megaYield()
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func aNewConnectedEventIsAppliedAfterTheFreshSnapshot() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    daemon.setCaptures([Fixture.capture()])
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false, agentConnection: .connected)])
    open.yield()
    let model = makeModel(daemon: daemon)
    await model.viewAppeared()
    await Task.megaYield()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    daemon.send(Fixture.agentConnection(1, state: "connected"))
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    daemon.setSessions([SessionSummary(id: Fixture.session, durableSeq: Fixture.seq(1), removed: false, agentConnection: .setupPending)])
    await clock.advance(by: .milliseconds(500))
    daemon.send(.heartbeat)
    await Task.megaYield()
    daemon.send(Fixture.agentConnection(2, state: "connected"))
    await Task.megaYield()
    open.yield()
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    expectNoDifference(composer.agentConnection, .connected)
    #expect(composer.canSubmit)
  }

  @Test func aHaltedFeedDisablesAsk() async {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    await send(Fixture.agentConnection(1, state: "connected"))
    fake.close(throwing: DaemonHTTPError.status(409, durableSeq: Fixture.seq(0)))
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
  }

  @Test func aRemovedWatchedSessionDisablesAsk() async {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    fake.close(throwing: DaemonHTTPError.status(410, durableSeq: nil))
    await Task.megaYield()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
  }

  @Test func aRefreshThatDropsTheWatchedCaptureDisablesItsComposerAndReopeningStaysDisabled() async throws {
    listSessions(.connected)
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.agentConnection(1, state: "connected"))
    let composer = composer(model, agentConnection: .connected)
    fake.setSessions([])
    fake.setCaptures([])
    await model.reloadShortcutPressed()
    expectNoDifference(model.selectedSession?.agentConnection, .disconnected(reason: nil))
    expectNoDifference(composer.agentConnection, .disconnected(reason: nil))
    #expect(!composer.canSubmit)
    model.questionDismissed()
    fake.setBlob(Fixture.shaB, "one\ntwo\nthree\nlast\n")
    fake.setClips(ClipsResponse(status: .ready, clips: [Clip(after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 4, truncated: false), method: .changedRange))]), for: Fixture.seq(2))
    await send(Fixture.fileChanged(2, "source.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)))
    let row = try #require(fileRow(model, 2))
    await model.cardAppeared(row)
    guard case .code(let blocks) = model.content(for: row) else { Issue.record("Missing source"); return }
    model.sourceDragged(row: row, block: blocks[0], startY: 23, endY: 60, frame: CGRect(x: 20, y: 100, width: 600, height: 88))
    model.sourceDragEnded()
    let reopened = try #require(model.askAgent)
    expectNoDifference(reopened.agentConnection, .disconnected(reason: nil))
    #expect(!reopened.canSubmit)
  }
}

extension ChangeStreamPageTests {
  // MARK: - Workspaces

  nonisolated static let managedRoot = URL(filePath: "/work/slipstream/workspaces")
  nonisolated static let workspaceRoot = "/work/slipstream/workspaces/r/workspace-1"

  func workspaceClient(
    choose: URL? = URL(filePath: "/r"),
    archive: @escaping @Sendable (URL, String) async -> String? = { _, _ in nil },
    repository: @escaping @Sendable (URL) async -> URL? = { _ in nil }
  ) -> WorkspaceClient {
    WorkspaceClient(
      roots: { WorkspaceRoots(managed: Self.managedRoot, conductor: URL(filePath: "/work/conductor/workspaces")) },
      chooseFolder: { _, _ in choose }, nextFolder: WorkspaceClient.testValue.nextFolder, archive: archive,
      repository: repository)
  }

  /// The launch running `slipstream workspace create` in the Setup tab.
  var setupLaunch: Int? {
    terminal.launches.lastIndex { $0.arguments.starts(with: ["workspace", "create"]) }
  }

  /// `slipstream workspace create` prints this once the workspace folder exists.
  func setupPrintsPath(_ path: String) {
    terminal.send("workspace_path: \(path)\n", launch: setupLaunch)
  }

  func setupFinishes(_ exit: TerminalExit) {
    terminal.finish(exit, launch: setupLaunch)
  }

  nonisolated func listWorkspace(_ state: CaptureState = .recording, reason: String? = nil) {
    fake.setSessions(
      [SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false)],
      starts: [Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0)])
    fake.setCaptures([Fixture.capture(state, reason: reason, session: Fixture.otherSession, root: Self.workspaceRoot)])
  }

  func makeWorkingChat(_ agent: AgentFake) -> ChatPageModel {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.agentEnvironment = agent.environmentClient
      $0.agentProcess = agent.processClient
      $0.transcripts = agent.transcriptClient
      $0.uuid = .incrementing
      $0.date = DateGenerator { Fixture.checkedAt }
      $0.continuousClock = clock
    } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock { $0 = [] }
      return ChatPageModel()
    }
  }

  @Test func newWorkspaceIsReachableWithNoSessionsAndNoDaemon() async {
    fake.setDiscoverError(DescriptorError.noRuntimeDirectory(path: "/tmp/store/runtime", errno: ENOENT, message: "No such file or directory"))
    let model = makeModel()

    await model.viewAppeared()

    #expect(!model.isWorkspaceBusy)
  }

  @Test func newWorkspaceSwitchesWhenPathArrives() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    expectNoDifference(setupLaunch.map { terminal.launches[$0].arguments }, ["workspace", "create", "/r", "--store", "store-a"])
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
      ])
    setupPrintsPath(Self.workspaceRoot)
    await creating.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.chat.folder == Self.workspaceRoot)
  }

  @Test func newWorkspaceAvailableAgainAfterMove() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    #expect(model.isWorkspaceBusy)
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()

    #expect(!model.isWorkspaceBusy)
    #expect(model.terminals.state.tabs.contains { $0.folder == Self.workspaceRoot && $0.kind == .setup(.running) })
    setupFinishes(.exited(0))
    await creating.value
  }

  @Test func newWorkspaceAvailableWhileSessionsRefreshAfterMove() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    open.yield()
    let model = makeModel(daemon: daemon, workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()

    #expect(!model.isWorkspaceBusy)
    open.yield()
    setupFinishes(.exited(0))
    open.yield()
    await creating.value
  }

  @Test func secondNewWorkspaceWinsWhileFirstSessionsRefreshFinishes() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionsGate: gate)
    open.yield()
    let model = makeModel(daemon: daemon, workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let first = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    daemon.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
      ])
    terminal.send("workspace_path: \(Self.workspaceRoot)\n", launch: 0)
    await Task.megaYield()

    let second = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    open.yield()
    await Task.megaYield()
    #expect(model.selectedSession == nil)
    #expect(model.chatEmptyText == "Creating workspace-1…")

    daemon.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: "new", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        "new": SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
      ])
    setupPrintsPath(Self.secondWorkspaceRoot)
    open.yield()
    await second.value
    terminal.finish(.exited(0), launch: 0)
    open.yield()
    await first.value

    #expect(model.selectedSession?.id == "new")
    #expect(model.chat.folder == Self.secondWorkspaceRoot)
  }

  @Test func newWorkspaceShowsHiddenPane() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.rightPaneToggleTapped()
    #expect(model.rightPane == .stream)
    #expect(!model.isRightPaneShown)

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()

    #expect(model.rightPane == .terminals)
    #expect(model.isRightPaneShown)
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func failedNewWorkspaceShowsNoAlert() async {
    openTheSessionsFolder()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    terminal.send("slipstream: /r has no \"origin\" remote to branch from.\r\n", launch: setupLaunch)
    setupFinishes(.exited(1))
    await creating.value

    #expect(!model.isWorkspaceFailurePresented)
    #expect(!model.isWorkspaceBusy)
    #expect(model.selectedSession?.id == Fixture.session)
    #expect(model.sidebarGroups.allSatisfy { $0.repository != "r" })
  }

  @Test func firstEverWorkspaceShowsSetupInEmptyPane() async {
    fake.setSessions([])
    fake.setCaptures([])
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()

    expectNoDifference(model.terminals.shownTabs.map(\.title), ["Setup"])
    #expect(!model.terminals.isEmptyStateVisible)
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func creatingAWorkspaceDoesNotOverrideASelectionChangedDuringCreation() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    model.sessionSelected(Fixture.session)
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: "new", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
        "new": SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
      ])
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()
    #expect(model.selectedSession?.id == Fixture.session)
    setupFinishes(.exited(0))
    await creating.value

    #expect(model.selectedSession?.id == Fixture.session)
  }

  @Test func creatingAWorkspaceDoesNotOverrideASelectionChangedWhileRootsLoad() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let (gate, release) = AsyncStream<Void>.makeStream()
    let (lookups, lookupStarted) = AsyncStream<Void>.makeStream()
    let workspace = workspaceClient()
    let slowWorkspace = WorkspaceClient(
      roots: {
        lookupStarted.yield()
        for await _ in gate { break }
        return await workspace.roots()
      },
      chooseFolder: workspace.chooseFolder, nextFolder: workspace.nextFolder, archive: workspace.archive,
      repository: workspace.repository)
    let model = makeModel(workspace: slowWorkspace)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)

    let creating = Task { await model.newWorkspaceTapped() }
    var started = lookups.makeAsyncIterator()
    _ = await started.next()
    _ = await started.next()
    model.sessionSelected(Fixture.otherSession)
    release.yield()
    release.yield()
    await Task.megaYield()

    #expect(model.selectedSession?.id == Fixture.otherSession)
    setupFinishes(.exited(1))
    await creating.value
  }

  /// Lists `Fixture.session` in the sidebar, as a folder opened in the app.
  func openTheSessionsFolder() {
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: ChangeStreamPageModel.normalizedFolder("/tmp/project"))]
  }

  func newRows(_ model: ChangeStreamPageModel) -> [SessionOption] {
    model.sidebarGroups.first { $0.repository == "r" }?.rows ?? []
  }

  @Test func aNewWorkspaceIsListedAndSelectedRightAway() async throws {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()

    let row = try #require(newRows(model).first)
    expectNoDifference(newRows(model).map(model.rowName), ["workspace-1"])
    #expect(model.isSelected(row))
    #expect(model.isSettingUp(row))
    #expect(!model.isArchivable(row))
    #expect(model.rowNameColor(row) == DesignTokens.Sidebar.settingUpRowNameColor)
    #expect(model.selectedSession == nil)
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func theChatSpinsWhileTheNewWorkspaceIsCreated() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()

    #expect(model.chatEmptyText == "Creating workspace-1…")
    #expect(model.chat.folder == nil)
    #expect(model.chat.isNoWorkspaceSpinnerShown)
    setupFinishes(.exited(1))
    await creating.value
    #expect(!model.chat.isNoWorkspaceSpinnerShown)
  }

  @Test func theNewRowTakesTheNameTheDaemonPicked() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.secondWorkspaceRoot)
    await Task.megaYield()

    expectNoDifference(newRows(model).map(model.rowName), ["workspace-2"])
    #expect(model.chat.noWorkspaceText == "Creating workspace-2…")
    setupFinishes(.exited(0))
    await creating.value
  }

  @Test func aNewWorkspaceThatIsNeverListedIsDroppedWhenSetupEnds() async {
    openTheSessionsFolder()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()
    setupFinishes(.exited(0))
    await creating.value

    expectNoDifference(newRows(model), [])
    #expect(model.selectedSession?.id == Fixture.session)
  }

  @Test func theListedWorkspaceSpinsUntilSetupFinishes() async throws {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    listWorkspace()
    setupPrintsPath(Self.workspaceRoot)
    await creating.value

    let row = try #require(model.selectedSession)
    expectNoDifference(newRows(model).map(\.id), [Fixture.otherSession])
    #expect(model.chat.folder == Self.workspaceRoot)
    #expect(model.isSettingUp(row))
    #expect(model.rowNameColor(row) == DesignTokens.Sidebar.settingUpRowNameColor)

    setupFinishes(.exited(0))
    await Task.megaYield()

    #expect(!model.isSettingUp(row))
  }

  @Test func returningToTheNewRowStillOpensTheWorkspaceOnceListed() async throws {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    model.sessionSelected(Fixture.session)
    #expect(model.selectedSession?.id == Fixture.session)
    model.sessionSelected(try #require(newRows(model).first).id)
    #expect(model.selectedSession == nil)

    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
      ])
    setupPrintsPath(Self.workspaceRoot)
    await creating.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
  }

  @Test func aFailedSecondWorkspaceGoesBackToTheFirstStillBeingCreated() async {
    openTheSessionsFolder()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let first = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    let firstSetup = setupLaunch
    terminal.send("workspace_path: \(Self.workspaceRoot)\n", launch: firstSetup)
    await Task.megaYield()
    let second = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupFinishes(.exited(1))
    await second.value

    expectNoDifference(newRows(model).map(\.id), ["creating-workspace-1"])
    #expect(newRows(model).allSatisfy(model.isSelected))
    #expect(model.chat.noWorkspaceText == "Creating workspace-1…")
    terminal.finish(.exited(0), launch: firstSetup)
    await first.value
    #expect(model.selectedSession?.id == Fixture.session)
  }

  @Test func aFailedSecondWorkspaceGoesToTheFirstOnceItIsListed() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let first = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    let firstSetup = setupLaunch
    terminal.send("workspace_path: \(Self.workspaceRoot)\n", launch: firstSetup)
    await Task.megaYield()
    let second = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    listWorkspace()
    await model.reloadShortcutPressed()
    setupFinishes(.exited(1))
    await second.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
    terminal.finish(.exited(0), launch: firstSetup)
    await first.value
  }

  @Test func aFailedNewWorkspaceDoesNotGoBackToAnArchivedOne() async throws {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let archived = try #require(model.selectedSession)

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.secondWorkspaceRoot)
    await Task.megaYield()
    model.archiveTapped(archived)
    await model.archiveConfirmed()
    setupFinishes(.exited(0))
    await creating.value

    #expect(model.selectedSession == nil)
  }

  @Test func theNewWorkspacesSetupStaysInViewOnceItsFolderExists() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()

    #expect(model.terminals.selectedTab?.title == "Setup")
    #expect(model.chat.folder == nil)
    setupFinishes(.exited(0))
    await creating.value
  }

  @Test func setupEndingAfterTheWindowClosesStartsNoRefresh() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()
    model.viewDisappeared()
    let calls = fake.sessionsCallCount
    setupFinishes(.exited(0))
    await creating.value

    #expect(fake.sessionsCallCount == calls)
  }

  @Test func aFailedRefreshAfterSetupKeepsTheNewRow() async throws {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()
    fake.setSessionsError(DaemonHTTPError.status(500, durableSeq: nil))
    setupFinishes(.exited(0))
    await creating.value
    expectNoDifference(newRows(model).map(\.id), ["creating-workspace-1"])
    #expect(!model.isSettingUp(try #require(newRows(model).first)))

    fake.setSessionsError(nil)
    listWorkspace()
    await model.reloadShortcutPressed()

    #expect(model.selectedSession?.id == Fixture.otherSession)
  }

  @Test func theOnlyOtherWorkspaceDoesNotTakeTheSelectionFromTheNewRow() async {
    fake.setSessions([])
    fake.setCaptures([])
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    fake.setCaptures([Fixture.capture()])
    await model.reloadShortcutPressed()

    #expect(model.selectedSession == nil)
    #expect(model.chatEmptyText == "Creating workspace-1…")
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func newWorkspaceCancelledDoesNothing() async {
    let model = makeModel(workspace: workspaceClient(choose: nil))

    await model.newWorkspaceTapped()

    #expect(setupLaunch == nil)
    #expect(!model.isWorkspaceBusy)
  }

  @Test func newWorkspaceShowsAPlaceholderInItsRepositoryUntilTheSetupEnds() async {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    expectNoDifference(newRows(model).map(model.rowName), ["workspace-1"])
    setupFinishes(.exited(1))
    await creating.value

    expectNoDifference(model.sidebarGroups.map(\.name), [])
  }

  @Test func choosingAWorkspaceFolderPutsThePlaceholderInItsRepository() async {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient(choose: URL(filePath: Self.workspaceRoot)))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    expectNoDifference(model.sidebarGroups.map(\.name), ["r"])
    #expect(newRows(model).contains { $0.id.hasPrefix("creating-workspace-") })
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func newWorkspaceCancelledShowsNoPlaceholder() async {
    let model = makeModel(workspace: workspaceClient(choose: nil))

    await model.newWorkspaceTapped()

    expectNoDifference(model.sidebarGroups, [])
  }


  @Test func archiveConfirmationWarnsWhenClaudeIsWorking() async throws {
    listWorkspace()
    let agent = AgentFake()
    let model = makeModel(chat: makeWorkingChat(agent), workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.archiveConfirmationText == "Its folder is removed. The branch is kept.")

    model.chat.selectedTab?.draft = "hi"
    await model.chat.sendTapped()
    await Task.megaYield()
    model.archiveTapped(try #require(model.selectedSession))

    #expect(model.isArchiveConfirmationPresented)
    #expect(
      model.archiveConfirmationText
        == "Its folder is removed. The branch is kept. Claude's current reply will be stopped.")
  }

  @Test func reloadShortcutAlsoRefreshesPRStatus() async throws {
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let before = model.prStatusBar.pollKey

    await model.reloadShortcutPressed()

    #expect(model.prStatusBar.pollKey != before)
  }

  @Test func prStatusStaysShownWhileTheRightPanelIsHidden() async throws {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.prStatusBar.isShown)

    model.rightPaneToggleTapped()

    #expect(!model.isRightPaneShown)
    #expect(model.prStatusBar.isShown)
  }

  @Test func prStatusIsHiddenWithoutAWorkspace() {
    let model = makeModel(workspace: workspaceClient())

    #expect(!model.prStatusBar.isShown)
  }

  @Test func windowResizeReachesThePRStatusLayout() {
    let model = makeModel()
    model.prStatusBar.openInMeasured(width: 60)
    model.prStatusBar.layoutMeasured(.full, width: 400)
    model.prStatusBar.layoutMeasured(.withoutDetail, width: 300)
    #expect(model.prStatusBar.layout == .iconsOnly)

    model.viewportChanged(CGSize(width: PRStatusBarTests.windowWidth(room: 400, openIn: 60), height: 900))

    #expect(model.prStatusBar.layout == .full)
  }

  @Test func openInFollowsTheRightPaneDivider() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1400, height: 900))
    model.prStatusBar.openInMeasured(width: 60)
    model.rightPaneMeasured(minX: 900)
    expectNoDifference(model.openInTrailingGap, model.prStatusBar.openInTrailingGap(dividerInset: 500))

    model.rightPaneToggleTapped()

    expectNoDifference(model.openInTrailingGap, model.prStatusBar.openInTrailingGap(dividerInset: 0))
  }

  @Test func archiveFromBarUsesArchiveConfirmation() async throws {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(!model.isArchiveConfirmationPresented)

    model.prStatusBar.archiveTapped()

    #expect(model.isArchiveConfirmationPresented)
    expectNoDifference(model.archiveTarget?.id, Fixture.otherSession)
  }

  @Test func barIsArchivableOnlyForAnArchivableSelection() async throws {
    let model = makeModel(workspace: workspaceClient())
    #expect(!model.prStatusBar.isArchivable())

    listWorkspace()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.prStatusBar.isArchivable())

    let conductorRoot = "/work/conductor/workspaces/r/lisbon"
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: conductorRoot, startedAtMs: 0)])
    fake.setCaptures([Fixture.capture(session: Fixture.session, root: conductorRoot)])
    await model.reloadShortcutPressed()
    model.sessionSelected(Fixture.session)
    #expect(!model.prStatusBar.isArchivable())
  }

  @Test func archiveStopsChatsBeforeRunningTheCommand() async throws {
    listWorkspace()
    let agent = AgentFake()
    let chat = makeWorkingChat(agent)
    let shutdownsAtArchive = LockIsolated<Int?>(nil)
    let archived = LockIsolated<[[String]]>([])
    let model = makeModel(chat: chat, workspace: workspaceClient(archive: { [self] workspace, store in
      shutdownsAtArchive.setValue(agent.shutdowns(0))
      archived.withValue { $0.append([workspace.path, store]) }
      listWorkspace(.stopped, reason: "archived")
      return nil
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    chat.selectedTab?.draft = "hi"
    await chat.sendTapped()
    await Task.megaYield()
    let sessionsCalls = fake.sessionsCallCount

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    #expect(shutdownsAtArchive.value == 1)
    expectNoDifference(archived.value, [[Self.workspaceRoot, "store-a"]])
    #expect(model.selectedSession == nil)
    #expect(chat.folder == nil)
    #expect(chat.records.isEmpty)
    #expect(fake.sessionsCallCount > sessionsCalls)
    #expect(!model.isWorkspaceBusy)
  }

  @Test func archivedWorkspaceIsNotAutomaticallySelectedWhenCaptureLoadingFails() async throws {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      nil
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    #expect(model.selectedSession == nil)
    #expect(model.chat.folder == nil)
  }

  /// The daemon lists sessions in id order, which for real UUIDs is random.
  nonisolated func listWorkspacesInIDOrder(_ workspaces: [(id: String, root: String)]) {
    let sorted = workspaces.sorted { $0.id < $1.id }
    fake.setSessions(sorted.map { SessionSummary(id: $0.id, durableSeq: .zero, removed: false) })
    fake.setCaptures(sorted.map { Fixture.capture(session: $0.id, root: $0.root) })
  }

  static let threeWorkspaces = [
    (id: "e1", root: "/work/slipstream/workspaces/zeta/workspace-1"),
    (id: "b2", root: "/work/slipstream/workspaces/Alpha/workspace-10"),
    (id: "d3", root: "/work/slipstream/workspaces/Alpha/workspace-2"),
    (id: "a4", root: "/tmp/elsewhere"),
  ]

  @Test func addingAndArchivingAWorkspaceMovesNothingElse() async {
    listWorkspacesInIDOrder(Self.threeWorkspaces)
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()
    expectNoDifference(
      Self.names(model.sidebarGroups),
      [["Alpha", "workspace-10", "workspace-2"], ["zeta", "workspace-1"]])

    listWorkspacesInIDOrder(Self.threeWorkspaces + [(id: "0new", root: "/work/slipstream/workspaces/zeta/workspace-3")])
    await expectDifference(Self.names(model.sidebarGroups)) {
      await model.reloadShortcutPressed()
    } changes: {
      $0[1].insert("workspace-3", at: 1)
    }

    listWorkspacesInIDOrder(
      Self.threeWorkspaces.filter { $0.id != "d3" } + [(id: "0new", root: "/work/slipstream/workspaces/zeta/workspace-3")])
    await expectDifference(Self.names(model.sidebarGroups)) {
      await model.reloadShortcutPressed()
    } changes: {
      $0[0].remove(at: 2)
    }
  }

  @Test func renamingAWorkspaceKeepsItsPlace() async {
    listTwoWorkspaces()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()
    expectNoDifference(Self.names(model.sidebarGroups), [["r", "workspace-2", "workspace-1"]])

    fake.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(
        id: Fixture.otherSession, durableSeq: .zero, removed: false,
        naming: SessionNaming(agentName: nil, userName: "Aardvark")),
    ])
    await expectDifference(Self.names(model.sidebarGroups)) {
      await model.reloadShortcutPressed()
    } changes: {
      $0[0][1] = "Aardvark"
    }
  }

  @Test func rowsGroupByRepoOnceTheRootsLoad() async {
    let otherRoot = "/work/slipstream/workspaces/r/lisbon"
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: otherRoot, startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(root: Self.workspaceRoot),
      Fixture.capture(session: Fixture.otherSession, root: otherRoot),
    ])
    let (gate, release) = AsyncStream<Void>.makeStream()
    let workspace = workspaceClient()
    let model = makeModel(workspace: WorkspaceClient(
      roots: {
        for await _ in gate { break }
        return await workspace.roots()
      },
      chooseFolder: workspace.chooseFolder, nextFolder: workspace.nextFolder, archive: workspace.archive,
      repository: workspace.repository))
    let appeared = Task { await model.viewAppeared() }
    defer { model.viewDisappeared() }
    await appeared.value
    await Task.megaYield()
    let selected = model.selectedSession
    expectNoDifference(model.sidebarGroups.flatMap(\.rows).map(\.id), [selected?.id].compactMap { $0 })

    release.yield()
    await Task.megaYield()

    expectNoDifference(model.sidebarGroups.map(\.name), ["r"])
    expectNoDifference(model.sidebarGroups.first?.rows.map(\.id), [Fixture.session, Fixture.otherSession])
    expectNoDifference(model.selectedSession, selected)
  }

  @Test func rootsArrivalUpdatesTheChatEmptyText() async {
    listTwoWorkspaces()
    let (gate, release) = AsyncStream<Void>.makeStream()
    let workspace = workspaceClient()
    let model = makeModel(workspace: WorkspaceClient(
      roots: {
        for await _ in gate { break }
        return await workspace.roots()
      },
      chooseFolder: workspace.chooseFolder, nextFolder: workspace.nextFolder, archive: workspace.archive,
      repository: workspace.repository))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(model.chat.noWorkspaceText, "No capture sessions yet")

    release.yield()
    await Task.megaYield()

    expectNoDifference(model.chat.noWorkspaceText, "Choose a capture session to watch its changes")
  }

  @Test func breadcrumbNamesRepoAndWorkspace() async {
    let project = await connectedModel()
    expectNoDifference(project.breadcrumbRepositoryText, nil)
    expectNoDifference(project.breadcrumbWorkspaceText, "project")
    #expect(project.isOpenInShown)
    project.viewDisappeared()

    listWorkspace()
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    await Task.megaYield()
    expectNoDifference(model.breadcrumbRepositoryText, "r")
    expectNoDifference(model.breadcrumbWorkspaceText, "workspace-1")
    model.viewDisappeared()

    fake.setSessions([])
    fake.setCaptures([])
    let empty = makeModel()
    await empty.viewAppeared()
    defer { empty.viewDisappeared() }
    expectNoDifference(empty.breadcrumbRepositoryText, nil)
    expectNoDifference(empty.breadcrumbWorkspaceText, nil)
    #expect(!empty.isOpenInShown)
    expectNoDifference(empty.compareFunctionsHelpText, "Choose a workspace to compare its functions")
  }

  @Test func sessionDiscoveryDoesNotWaitForWorkspaceRoots() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let workspace = workspaceClient()
    let slowWorkspace = WorkspaceClient(
      roots: {
        for await _ in gate { break }
        return await workspace.roots()
      },
      chooseFolder: workspace.chooseFolder,
      nextFolder: workspace.nextFolder,
      archive: workspace.archive,
      repository: workspace.repository
    )
    let model = makeModel(workspace: slowWorkspace)
    let appeared = Task { await model.viewAppeared() }
    defer { release.yield() }

    await Task.megaYield()

    #expect(model.selectedSession?.id == Fixture.session)
    release.yield()
    await appeared.value
  }

  @Test func explicitSessionSelectionClearsAnUnresolvedWorkspacePreference() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ]
    )
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: "new", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
        "new": SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
      ]
    )

    model.sessionSelected(Fixture.otherSession)
    setupFinishes(.exited(0))
    await creating.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
  }

  @Test func archiveHidesTheChatWhileTheCommandRuns() async throws {
    listWorkspace()
    let (gate, release) = AsyncStream<Void>.makeStream()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      for await _ in gate { break }
      return "refused"
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.chat.showsNewTabButton)

    model.archiveTapped(try #require(model.selectedSession))
    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()

    #expect(model.chat.folder == nil)
    #expect(!model.chat.showsNewTabButton)
    #expect(!model.chat.isMessageBoxEnabled)
    release.yield()
    await archiving.value
  }

  @Test func refusedArchiveGivesBackItsConversationsAndShowsTheError() async throws {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      "slipstream: the workspace has uncommitted or untracked changes."
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let conversations = model.chat.records.map(\.id)

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.chat.folder == Self.workspaceRoot)
    expectNoDifference(model.chat.visibleTabs.map(\.id), conversations)
    #expect(model.isWorkspaceFailurePresented)
    #expect(model.workspaceFailureTitle == "Couldn't archive the workspace")
    #expect(model.workspaceFailureText == "slipstream: the workspace has uncommitted or untracked changes.")
    #expect(!model.isWorkspaceFailureCopyShown)
  }

  @Test func refusedArchiveRestoresEachDraft() async throws {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      "refused"
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let tab = try #require(model.chat.selectedTab)
    tab.draft = "Keep this draft"

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    #expect(model.chat.selectedTab?.draft == "Keep this draft")
  }

  nonisolated static let secondWorkspaceRoot = "/work/slipstream/workspaces/r/workspace-2"

  nonisolated func listTwoWorkspaces() {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(session: Fixture.session, root: Self.workspaceRoot),
      Fixture.capture(session: Fixture.otherSession, root: Self.secondWorkspaceRoot),
    ])
  }

  /// The first workspace is selected and the second has a reply running.
  func twoWorkspacesModel(
    archive: @escaping @Sendable (URL, String) async -> String? = { _, _ in nil }
  ) async -> ChangeStreamPageModel {
    listTwoWorkspaces()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: archive))
    await model.viewAppeared()
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    model.chat.selectedTab?.draft = "hi"
    await model.chat.sendTapped()
    await Task.megaYield()
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    return model
  }

  @Test func plusCreatesInTheGroupsFirstFolderWithoutTheChooser() async throws {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient(choose: nil))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let group = try #require(model.sidebarGroups.first)
    let creating = Task { await model.newWorkspaceTapped(in: group) }
    await Task.megaYield()
    expectNoDifference(
      setupLaunch.map { terminal.launches[$0].arguments }, ["workspace", "create", Self.workspaceRoot, "--store", "store-a"])
    let created = "1b2c3d4e-2222-4c55-9a7e-2f4b8c9d0e1b"
    fake.setSessions(
      [
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: created, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        created: SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(session: Fixture.otherSession, root: Self.workspaceRoot),
      Fixture.capture(session: created, root: Self.secondWorkspaceRoot),
    ])
    setupPrintsPath(Self.secondWorkspaceRoot)
    await creating.value

    #expect(model.selectedSession?.id == created)
    #expect(model.chat.folder == Self.secondWorkspaceRoot)
    #expect(!model.isWorkspaceBusy)
  }

  @Test func plusShowsAPlaceholderAtopTheGroupThenTheNewWorkspaceFirst() async throws {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient(choose: nil))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let group = try #require(model.sidebarGroups.first)
    let creating = Task { await model.newWorkspaceTapped(in: group) }
    await Task.megaYield()
    #expect(model.sidebarGroups.first?.rows.first?.id.hasPrefix("creating-workspace-") == true)
    let created = "1b2c3d4e-2222-4c55-9a7e-2f4b8c9d0e1b"
    fake.setSessions(
      [
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: created, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        created: SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(session: Fixture.otherSession, root: Self.workspaceRoot),
      Fixture.capture(session: created, root: Self.secondWorkspaceRoot),
    ])
    setupPrintsPath(Self.secondWorkspaceRoot)
    await creating.value

    expectNoDifference(model.sidebarGroups.first?.rows.map(\.id), [created, Fixture.otherSession])
  }

  @Test func aNewWorkspaceIsSettingUpUntilItsSetupFinishes() async throws {
    listWorkspace()
    let model = makeModel(workspace: workspaceClient(choose: nil))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let group = try #require(model.sidebarGroups.first)
    let creating = Task { await model.newWorkspaceTapped(in: group) }
    await Task.megaYield()
    fake.setSessions(
      [SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
       SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        Fixture.session: SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(session: Fixture.otherSession, root: Self.workspaceRoot),
      Fixture.capture(session: Fixture.session, root: Self.secondWorkspaceRoot),
    ])
    setupPrintsPath(Self.secondWorkspaceRoot)
    await creating.value
    let rows = try #require(model.sidebarGroups.first?.rows)
    expectNoDifference(rows.map(model.isSettingUp), [true, false])

    setupFinishes(.exited(0))
    await Task.megaYield()

    expectNoDifference(rows.map(model.isSettingUp), [false, false])
  }


  @Test func aRepoStaysListedAfterItsLastWorkspaceGoes() async throws {
    let fileStorage = FileStorage.inMemory
    withDependencies { $0.defaultFileStorage = fileStorage } operation: {
      @Shared(.sidebarRepositories) var repositories
      $repositories.withLock { $0 = ["r": "/moved-from/r"] }
    }
    listWorkspace()
    let lookedUp = LockIsolated<[String]>([])
    let model = makeModel(
      workspace: workspaceClient(repository: { folder in
        lookedUp.withValue { $0.append(folder.path) }
        return URL(filePath: "/code/r")
      }),
      fileStorage: fileStorage)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()

    fake.setSessions([])
    fake.setCaptures([])
    await model.reloadShortcutPressed()

    expectNoDifference(Self.names(model.sidebarGroups), [["r"]])
    expectNoDifference(lookedUp.value, [Self.workspaceRoot])
    let group = try #require(model.sidebarGroups.first)
    let creating = Task { await model.newWorkspaceTapped(in: group) }
    await Task.megaYield()
    expectNoDifference(
      setupLaunch.map { terminal.launches[$0].arguments }, ["workspace", "create", "/code/r", "--store", "store-a"])
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func aLiveWorkspaceRemembersItsRepoWhenAnArchivedWorkspaceSortsFirst() async {
    let archivedRoot = "/work/slipstream/workspaces/r/workspace-9"
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: archivedRoot, startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
      ])
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let lookedUp = LockIsolated<[String]>([])
    let model = makeModel(workspace: workspaceClient(repository: { folder in
      lookedUp.withValue { $0.append(folder.path) }
      return folder.path == Self.workspaceRoot ? URL(filePath: "/code/r") : nil
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()

    fake.setSessions([])
    fake.setCaptures([])
    await model.reloadShortcutPressed()

    expectNoDifference(lookedUp.value, [archivedRoot, Self.workspaceRoot])
    expectNoDifference(Self.names(model.sidebarGroups), [["r"]])
  }

  @Test func aRememberedRepoShowsWithoutWorkspacesOnLaunch() async {
    let fileStorage = FileStorage.inMemory
    withDependencies { $0.defaultFileStorage = fileStorage } operation: {
      @Shared(.sidebarRepositories) var repositories
      $repositories.withLock { $0 = ["r": "/code/r"] }
    }
    fake.setSessions([])
    fake.setCaptures([])
    let model = makeModel(workspace: workspaceClient(), fileStorage: fileStorage)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()

    expectNoDifference(Self.names(model.sidebarGroups), [["r"]])
    expectNoDifference(model.emptyStateText, "No capture sessions yet")
  }

  @Test func removeFromSidebarIsOfferedOnlyForARepoWithoutWorkspaces() async throws {
    let fileStorage = FileStorage.inMemory
    withDependencies { $0.defaultFileStorage = fileStorage } operation: {
      @Shared(.sidebarRepositories) var repositories
      $repositories.withLock { $0 = ["r": "/code/r", "s": "/code/s"] }
    }
    listWorkspace()
    let model = makeModel(workspace: workspaceClient(), fileStorage: fileStorage)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()

    expectNoDifference(model.sidebarGroups.map(model.isRemoveFromSidebarAvailable), [false, true])
  }

  @Test func removingARepoWithoutWorkspacesForgetsIt() async throws {
    let fileStorage = FileStorage.inMemory
    withDependencies { $0.defaultFileStorage = fileStorage } operation: {
      @Shared(.sidebarRepositories) var repositories
      $repositories.withLock { $0 = ["r": "/code/r", "s": "/code/s"] }
    }
    fake.setSessions([])
    fake.setCaptures([])
    let model = makeModel(workspace: workspaceClient(), fileStorage: fileStorage)
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    await Task.megaYield()

    model.removeFromSidebarTapped(try #require(model.sidebarGroups.first))

    expectNoDifference(Self.names(model.sidebarGroups), [["s"]])
    expectNoDifference(model.sidebarRepositories, ["s": "/code/s"])
  }

  @Test func archiveIconShowsOnHoverOrFocusForManagedRowsOnly() async throws {
    let conductorRoot = "/work/conductor/workspaces/r/lisbon"
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: conductorRoot, startedAtMs: 0),
      ])
    fake.setCaptures([
      Fixture.capture(session: Fixture.session, root: Self.workspaceRoot),
      Fixture.capture(session: Fixture.otherSession, root: conductorRoot),
    ])
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let managed = try #require(model.sessions[id: Fixture.session])
    let conductor = try #require(model.sessions[id: Fixture.otherSession])
    #expect(!model.isArchiveIconShown(for: managed))

    model.rowHoverChanged(managed, isHovering: true)
    #expect(model.isArchiveIconShown(for: managed))
    model.rowFocusChanged(managed, isFocused: true)
    model.rowHoverChanged(managed, isHovering: false)
    #expect(model.isArchiveIconShown(for: managed))
    model.rowFocusChanged(managed, isFocused: false)
    #expect(!model.isArchiveIconShown(for: managed))

    model.rowHoverChanged(conductor, isHovering: true)
    model.rowFocusChanged(conductor, isFocused: true)
    #expect(model.isHighlighted(conductor))
    #expect(!model.isArchiveIconShown(for: conductor))
  }

  @Test func archivingAnotherRowKeepsTheSelection() async throws {
    let archived = LockIsolated<[String]>([])
    let model = await twoWorkspacesModel(archive: { workspace, _ in
      archived.withValue { $0.append(workspace.path) }
      return nil
    })
    defer { model.viewDisappeared() }
    let second = try #require(model.sessions[id: Fixture.otherSession])

    model.archiveTapped(second)
    #expect(model.isArchiveConfirmationPresented)
    #expect(model.archiveConfirmationText.hasSuffix("Claude's current reply will be stopped."))
    await model.archiveConfirmed()

    expectNoDifference(archived.value, [Self.secondWorkspaceRoot])
    #expect(model.selectedSession?.id == Fixture.session)
    #expect(model.chat.folder == Self.workspaceRoot)
    #expect(!model.chat.records.contains { $0.folder == Self.secondWorkspaceRoot })
  }

  @Test func refusedArchiveOfAnotherRowRestoresItsTabsAndDrafts() async throws {
    let model = await twoWorkspacesModel(archive: { _, _ in "refused" })
    defer { model.viewDisappeared() }
    let second = try #require(model.sessions[id: Fixture.otherSession])
    let record = try #require(model.chat.records.first { $0.folder == Self.secondWorkspaceRoot })
    model.chat.tabs[id: record.id]?.draft = "Keep this draft"

    model.archiveTapped(second)
    await model.archiveConfirmed()

    #expect(model.chat.tabs[id: record.id]?.draft == "Keep this draft")
    #expect(model.selectedSession?.id == Fixture.session)
    #expect(model.isWorkspaceFailurePresented)
  }

  @Test func archiveTargetSurvivesAReloadDuringTheCommand() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let archived = LockIsolated<[String]>([])
    let model = await twoWorkspacesModel(archive: { workspace, _ in
      for await _ in gate { break }
      archived.withValue { $0.append(workspace.path) }
      return nil
    })
    defer { model.viewDisappeared() }
    model.archiveTapped(try #require(model.sessions[id: Fixture.otherSession]))

    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0)])
    await model.reloadShortcutPressed()
    release.yield()
    await archiving.value

    expectNoDifference(archived.value, [Self.secondWorkspaceRoot])
    #expect(!model.chat.records.contains { $0.folder == Self.secondWorkspaceRoot })
    #expect(model.selectedSession?.id == Fixture.session)
  }

  @Test func switchingRowsDuringARefusedArchiveKeepsTheNewRow() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let model = await twoWorkspacesModel(archive: { _, _ in
      for await _ in gate { break }
      return "refused"
    })
    defer { model.viewDisappeared() }
    model.archiveTapped(try #require(model.selectedSession))

    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    release.yield()
    await archiving.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.chat.folder == Self.secondWorkspaceRoot)
  }

  @Test func switchingRowsWhileAnArchiveCleansUpKeepsTheNewRow() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    var history = terminal.historyClient
    history.delete = { _ in for await _ in gate { break } }
    listTwoWorkspaces()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(), terminals: makeTerminals(history: history))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    model.archiveTapped(try #require(model.selectedSession))

    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        SessionSummary(id: "third-session", durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
        "third-session": SessionStarted(root: "/tmp/third", startedAtMs: 0),
      ])
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    let watch = try #require(model.watchTask)
    release.yield()
    await archiving.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.watchTask == watch)
  }

  /// Two live sessions share the first workspace's folder; the second workspace is selected.
  func sharedFolderModel(
    archive: @escaping @Sendable (URL, String) async -> String?
  ) async -> ChangeStreamPageModel {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: "sibling-session", durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        "sibling-session": SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: Self.secondWorkspaceRoot, startedAtMs: 0),
      ])
    fake.setCaptures([Fixture.capture(root: Self.workspaceRoot)])
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: archive))
    await model.viewAppeared()
    await Task.megaYield()
    return model
  }

  @Test func archivingASharedFolderClearsTheSelectedSibling() async throws {
    let model = await sharedFolderModel(archive: { _, _ in nil })
    defer { model.viewDisappeared() }
    model.sessionSelected("sibling-session")
    await Task.megaYield()

    model.archiveTapped(try #require(model.sessions[id: Fixture.session]))
    await model.archiveConfirmed()

    #expect(model.selectedSession == nil)
    #expect(model.chat.folder == nil)
  }

  @Test func aSiblingOfTheFolderBeingArchivedCannotBeSelected() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let model = await sharedFolderModel(archive: { _, _ in
      for await _ in gate { break }
      return nil
    })
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    model.archiveTapped(try #require(model.sessions[id: Fixture.session]))

    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()
    model.sessionSelected("sibling-session")
    release.yield()
    await archiving.value

    #expect(model.selectedSession?.id == Fixture.otherSession)
  }

  @Test func aWorkspacePickedWhileCreatingStaysSelected() async {
    let sessions = [
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
    ]
    let starts = [
      Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
      Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
    ]
    fake.setSessions(sessions, starts: starts)
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()

    model.sessionSelected(Fixture.otherSession)
    fake.setSessions(
      sessions + [SessionSummary(id: "created-session", durableSeq: .zero, removed: false)],
      starts: starts.merging(["created-session": SessionStarted(root: Self.workspaceRoot, startedAtMs: 0)]) { $1 })
    setupPrintsPath(Self.workspaceRoot)
    await Task.megaYield()

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.terminals.state.tabs.contains { $0.folder == Self.workspaceRoot && $0.kind == .setup(.running) })
    setupFinishes(.exited(0))
    await creating.value
  }

  @Test func theRowBeingArchivedCannotBeSelected() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let model = await twoWorkspacesModel(archive: { _, _ in
      for await _ in gate { break }
      return nil
    })
    defer { model.viewDisappeared() }
    model.archiveTapped(try #require(model.sessions[id: Fixture.otherSession]))

    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    release.yield()
    await archiving.value

    #expect(model.selectedSession?.id == Fixture.session)
    #expect(!model.chat.records.contains { $0.folder == Self.secondWorkspaceRoot })
  }

  @Test func selectingAWorkspaceWhileBusySwitches() async {
    fake.setSessions(
      [
        SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
        SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      ],
      starts: [
        Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
        Fixture.otherSession: SessionStarted(root: "/tmp/other", startedAtMs: 0),
      ])
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    #expect(model.isWorkspaceBusy)

    model.sessionSelected(Fixture.otherSession)

    #expect(model.selectedSession?.id == Fixture.otherSession)
    setupFinishes(.exited(1))
    await creating.value
  }

  @Test func archiveWhileBusyDoesNothing() async throws {
    let archived = LockIsolated(0)
    listWorkspace()
    let model = makeModel(workspace: workspaceClient(archive: { _, _ in
      archived.withValue { $0 += 1 }
      return nil
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let workspace = try #require(model.selectedSession)
    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()

    model.archiveTapped(workspace)
    await model.archiveConfirmed()

    #expect(archived.value == 0)
    setupFinishes(.exited(1))
    await creating.value
  }
}

extension ChangeStreamPageTests {
  // MARK: - Terminals

  func workspaceModel(archive: @escaping @Sendable (URL, String) async -> String? = { _, _ in nil }) async -> ChangeStreamPageModel {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: archive))
    await model.viewAppeared()
    await Task.megaYield()
    return model
  }

  @Test func terminalsFollowTheSelectedWorkspace() async {
    let model = await workspaceModel()
    defer { model.viewDisappeared() }

    #expect(model.terminals.folder == Self.workspaceRoot)
    expectNoDifference(terminal.launches.map(\.directory), [Self.workspaceRoot])
  }

  @Test func archiveStopsTerminalsBeforeTheCommand() async throws {
    let callsAtArchive = LockIsolated<[TerminalFake.Call]>([])
    let model = await workspaceModel(archive: { [terminal] _, _ in
      callsAtArchive.setValue(terminal.calls)
      return "refused"
    })
    defer { model.viewDisappeared() }

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    #expect(callsAtArchive.value.contains(.stop(launch: 0)))
  }

  @Test func failedArchiveRestoresTerminals() async throws {
    let model = await workspaceModel(archive: { _, _ in "refused" })
    defer { model.viewDisappeared() }

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    #expect(model.terminals.folder == Self.workspaceRoot)
    expectNoDifference(model.terminals.shownTabs.map(\.title), ["Terminal 1"])
    expectNoDifference(terminal.launches.map(\.directory), [Self.workspaceRoot, Self.workspaceRoot])
  }

  @Test func successfulArchiveForgetsTerminals() async throws {
    let model = await workspaceModel(archive: { [self] _, _ in
      listWorkspace(.stopped, reason: "archived")
      return nil
    })
    defer { model.viewDisappeared() }

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()
    await Task.megaYield()

    #expect(model.terminals.folder == nil)
    expectNoDifference(terminal.saved?.tabs.elements, [])
  }

  @Test func sidebarHiddenIsRemembered() {
    let model = makeModel()
    #expect(model.isSidebarShown)
    #expect(model.sidebarToggleHelpText == "Hide Sidebar")

    model.sidebarToggleTapped()

    let reopened = makeModel()
    #expect(!reopened.isSidebarShown)
    #expect(reopened.sidebarToggleHelpText == "Show Sidebar")
  }

  @Test func rightPaneHiddenIsRemembered() {
    let model = makeModel()
    #expect(model.isRightPaneShown)
    #expect(model.rightPaneToggleHelpText == "Hide Right Panel")

    model.rightPaneToggleTapped()

    let reopened = makeModel()
    #expect(!reopened.isRightPaneShown)
    #expect(!reopened.isStreamShown)
    #expect(reopened.rightPaneToggleHelpText == "Show Right Panel")
  }

  @Test func hidingTheRightPanelCollapsesTheReply() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    _ = try open(model, "q1")

    model.rightPaneToggleTapped()

    #expect(model.reply == nil)
  }

  @Test func showingTheRightPanelKeepsTheScrollPosition() async {
    let model = await connectedModel()
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    model.rightPaneToggleTapped()

    model.rightPaneToggleTapped()

    expectNoDifference(model.follow, .paused(newCount: 0))
  }

  @Test func hiddenRightPanelKeepsTheWidthItHadWhenShown() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1800, height: 900))
    expectNoDifference(model.rightPaneContentWidth, nil)
    expectNoDifference(model.rightPaneMinWidth, 680)
    expectNoDifference(model.rightPaneMaxWidth, .infinity)

    model.rightPaneToggleTapped()

    expectNoDifference(model.rightPaneContentWidth, 820)
    expectNoDifference(model.rightPaneMinWidth, 0)
    expectNoDifference(model.rightPaneMaxWidth, 0)
  }

  @Test func hidingTheRightPanelTakesTheTerminalsOutOfTheWindow() {
    let model = makeModel()
    model.rightPaneSelected(.terminals)
    #expect(model.isTerminalsShown)

    model.rightPaneToggleTapped()

    #expect(!model.isTerminalsShown)
    #expect(model.isSelected(.terminals))
  }

  @Test func commandWClosesChatWhileTheRightPanelIsHidden() async throws {
    let model = await workspaceModel()
    defer { model.viewDisappeared() }
    let chatTab = try #require(model.chat.selectedTab?.id)
    let terminalTab = try #require(model.terminals.selectedTab?.id)
    model.rightPaneSelected(.terminals)
    model.terminals.terminalFocusChanged(terminalTab, isFocused: true)
    model.rightPaneToggleTapped()

    await model.closeShortcutPressed()

    #expect(!model.chat.records.contains { $0.id == chatTab })
    #expect(!terminal.calls.contains(.delete(terminalTab)))
  }

  @Test func draggingTheSidebarEdgeResizesItWithinLimits() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1600, height: 900))
    var widths: [CGFloat] = []
    for translation in [40, 100, 400, -400] as [CGFloat] {
      model.sidebarEdgeDragged(by: translation)
      widths.append(model.sidebarColumnWidth)
    }
    model.edgeDragEnded()

    expectNoDifference(widths, [300, 360, 420, 200])
    expectNoDifference(makeModel().sidebarColumnWidth, 200)
  }

  @Test func draggingTheSidebarEdgeLeavesTheChatItsMinimum() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1360, height: 900))

    model.sidebarEdgeDragged(by: 100)

    expectNoDifference(model.sidebarColumnWidth, 260)
    expectNoDifference(model.chatColumnWidth, 420)
  }

  @Test func narrowViewportLimitsDisplayedSidebarWithoutChangingPreference() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1800, height: 900))
    model.sidebarEdgeDragged(by: 160)
    model.edgeDragEnded()
    expectNoDifference(model.sidebarWidth, 420)

    model.viewportChanged(CGSize(width: 1360, height: 900))

    expectNoDifference(model.sidebarColumnWidth, 260)
    expectNoDifference(model.sidebarWidth, 420)
  }

  @Test func doubleClickingTheSidebarEdgeRestoresItsWidth() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1600, height: 900))
    model.sidebarEdgeDragged(by: 100)
    model.edgeDragEnded()

    model.sidebarEdgeDoubleClicked()

    expectNoDifference(model.sidebarColumnWidth, 260)
  }

  @Test func draggingTheChatEdgeResizesTheChatAndTheStreamKeepsItsMinimum() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1800, height: 900))
    var widths: [CGFloat] = []
    for translation in [-100, -400, 400] as [CGFloat] {
      model.chatEdgeDragged(by: translation)
      widths.append(model.chatColumnWidth)
    }
    model.edgeDragEnded()

    expectNoDifference(widths, [620, 420, 860])
    let reopened = makeModel()
    reopened.viewportChanged(CGSize(width: 1800, height: 900))
    expectNoDifference(reopened.chatColumnWidth, 860)
  }

  @Test func doubleClickingTheChatEdgeRestoresItsWidth() {
    let model = makeModel()
    model.viewportChanged(CGSize(width: 1800, height: 900))
    model.chatEdgeDragged(by: -200)
    model.edgeDragEnded()

    model.chatEdgeDoubleClicked()

    expectNoDifference(model.chatColumnWidth, 720)
  }

  @Test func chatShrinksBeforeTheStream() {
    let model = makeModel()
    var widths: [CGFloat] = []
    for width in [2040, 1600, 1360] as [CGFloat] {
      model.viewportChanged(CGSize(width: width, height: 900))
      widths.append(model.chatColumnWidth)
    }
    expectNoDifference(widths, [720, 660, 420])

    model.viewportChanged(CGSize(width: 1360, height: 900))
    model.sidebarToggleTapped()

    expectNoDifference(model.chatColumnWidth, 680)
  }

  @Test func chatGivesWayOnAScreenTooNarrowForAllThreeColumns() {
    let model = makeModel()
    var widths: [CGFloat] = []
    for width in [1360, 1280, 1200] as [CGFloat] {
      model.viewportChanged(CGSize(width: width, height: 900))
      widths.append(model.chatColumnWidth)
    }
    expectNoDifference(widths, [420, 400, 320])
  }

  @Test func windowMinimumFollowsTheSidebar() {
    let model = makeModel()
    #expect(model.windowMinWidth(visibleScreenWidth: 2560) == 1360)

    model.sidebarToggleTapped()

    #expect(model.windowMinWidth(visibleScreenWidth: 2560) == 1100)
  }

  @Test func windowMinimumFollowsTheRightPanel() {
    let model = makeModel()

    model.rightPaneToggleTapped()

    #expect(model.windowMinWidth(visibleScreenWidth: 2560) == 680)
  }

  @Test func windowMinimumCappedBySmallScreen() {
    let model = makeModel()

    #expect(model.windowMinWidth(visibleScreenWidth: 1280) == 1280)
    #expect(model.windowMinWidth(visibleScreenWidth: 900) == 900)
  }

  @Test func commandWClosesTerminalWhenFocused() async throws {
    let model = await workspaceModel()
    defer { model.viewDisappeared() }
    let chatTab = try #require(model.chat.selectedTab?.id)
    let terminalTab = try #require(model.terminals.selectedTab?.id)
    model.rightPaneSelected(.terminals)
    model.terminals.terminalFocusChanged(terminalTab, isFocused: true)

    await model.closeShortcutPressed()

    #expect(terminal.calls.contains(.delete(terminalTab)))
    #expect(model.chat.records.contains { $0.id == chatTab })
  }

  @Test func commandWClosesChatWhileStreamShows() async throws {
    let model = await workspaceModel()
    defer { model.viewDisappeared() }
    let chatTab = try #require(model.chat.selectedTab?.id)
    let terminalTab = try #require(model.terminals.selectedTab?.id)
    model.rightPaneSelected(.terminals)
    model.terminals.terminalFocusChanged(terminalTab, isFocused: true)
    model.rightPaneSelected(.stream)

    await model.closeShortcutPressed()

    #expect(!model.chat.records.contains { $0.id == chatTab })
    #expect(!terminal.calls.contains(.delete(terminalTab)))
  }

  @Test func commandWClosesChatOtherwise() async throws {
    let model = await workspaceModel()
    defer { model.viewDisappeared() }
    let chatTab = try #require(model.chat.selectedTab?.id)
    let terminalTab = try #require(model.terminals.selectedTab?.id)

    await model.closeShortcutPressed()

    #expect(!model.chat.records.contains { $0.id == chatTab })
    #expect(!terminal.calls.contains(.delete(terminalTab)))
  }
}

extension ChangeStreamPageTests {
  // MARK: - Instant answers

  static let tab = UUID(uuidString: "4BAD416C-1D04-4063-9E76-61EBB936AE06")!
  static let firstRequest = "00000000-0000-0000-0000-000000000000"
  static let secondRequest = "00000000-0000-0000-0000-000000000001"

  /// The capture's folder is linked to an app tab, so its questions are answered by `fork`.
  func linkedModel(fork: ForkFake, recorder: RecordFake = RecordFake()) async -> ChangeStreamPageModel {
    fake.setCaptures([
      Fixture.capture(
        binding: CaptureBinding(generation: "7", state: .connected, harnessSessionID: Self.tab.uuidString.lowercased()))
    ])
    agent.setTranscript(Self.tab, .found([.user(uuid: "u1", timestamp: Fixture.checkedAt, isPrompt: true, blocks: [.text("Hi")])]))
    let chat = makeChat(records: [
      ChatTabRecord(id: Self.tab, folder: "/tmp/project", model: "claude-opus-5-5", effort: .high, isWaiting: false)
    ])
    let model = makeModel(chat: chat, instantAsk: .fake(chat: chat, fork: fork, recorder: recorder))
    await model.viewAppeared()
    await Task.megaYield()
    return model
  }

  func askedRightAway(_ model: ChangeStreamPageModel, _ text: String) async {
    let composer = withDependencies(from: model) {
      AskAgentPageTests.composer(
        sessionID: Fixture.session, folder: "/tmp/project",
        context: QuestionContext(changeSeq: "1", path: "src/user.ts", snapshotSHA256: Fixture.shaB, lineStart: 7, lineEnd: 9),
        route: .app, instantAsk: model.instantAsk)
    }
    model.askAgent = composer
    composer.draftChanged(text)
    await model.askQuestionTapped(composer)
    await Task.megaYield()
  }

  @Test func pendingRootShowsWaitingBarAtLines() async throws {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    expectNoDifference(try bars(model, 1), [
      QuestionBar(id: Self.firstRequest, preview: "Why?", status: .waiting, isOpen: true)
    ])
    #expect(model.askAgent == nil)
    #expect(model.queuedQuestionNotice == nil)
    expectNoDifference(model.reply?.pendingTurn?.text, "Why?")
  }

  @Test func historyReadinessRefreshesAnOpenAskRoute() async throws {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    let composer = withDependencies(from: model) {
      AskAgentPageTests.composer(
        sessionID: Fixture.session, folder: "/tmp/project",
        context: QuestionContext(changeSeq: "1", path: "src/user.ts", snapshotSHA256: Fixture.shaB, lineStart: 7, lineEnd: 9),
        route: .none, instantAsk: model.instantAsk)
    }
    model.askAgent = composer

    expectNoDifference(composer.route, .none)
    model.chat.onReadinessChanged()
    expectNoDifference(composer.route, .app)
  }

  @Test func pendingFollowUpUpdatesTheSavedThreadBar() async throws {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    await send(
      Fixture.edited(1),
      Fixture.questionExchangeRecorded(2, id: "q1", chat: Self.tab.uuidString.lowercased()))
    let reply = try open(model, "q1")
    reply.answerDisplayed(Fixture.seq(2))
    model.replyDismissTapped()
    let thread = try #require(model.questionThreads.threads[id: "q1"])

    _ = model.instantAsk.ask(
      InstantQuestion(
        storeID: "store-a", sessionID: Fixture.session, folder: "/tmp/project", source: thread.source,
        replyToQuestionID: "q1", threadChatSessionID: Self.tab.uuidString.lowercased(),
        earlier: [], text: "What next?"))

    expectNoDifference(try bar(model, "q1").status, .waiting)
  }

  @Test func failedPendingRootShowsNotDelivered() async throws {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    fork.reply(.failure(.timedOut))
    await Task.megaYield()
    expectNoDifference(try bars(model, 1).map(\.status), [.notDelivered])
  }

  @Test func barAndOpenPanelMoveToQuestionIDOnFold() async throws {
    let fork = ForkFake()
    let recorder = RecordFake()
    recorder.script(.success("q1"))
    let model = await linkedModel(fork: fork, recorder: recorder)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    model.questionBarMoved(try bar(model, Self.firstRequest), frame: CGRect(x: 0, y: 40, width: 600, height: 42))
    fork.answer("Because.")
    await Task.megaYield()
    await send(
      Fixture.questionExchangeRecorded(
        2, id: "q1", text: "Why?", requestID: Self.firstRequest, chat: Self.tab.uuidString.lowercased()))
    expectNoDifference(try bars(model, 1), [QuestionBar(id: "q1", preview: "Why?", status: .newReply, isOpen: true)])
    expectNoDifference(model.reply?.thread.turns.map(\.answer?.text), ["Because."])
    #expect(model.instantAsk.pending.isEmpty)
    expectNoDifference(model.replyBarFrame, CGRect(x: 0, y: 40, width: 600, height: 42))
  }

  @Test func twoNewQuestionsShowTwoPendingBars() async throws {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    await askedRightAway(model, "And why here?")
    expectNoDifference(try bars(model, 1), [
      QuestionBar(id: Self.firstRequest, preview: "Why?", status: .waiting, isOpen: false),
      QuestionBar(id: Self.secondRequest, preview: "And why here?", status: .waiting, isOpen: true),
    ])
    expectNoDifference(fork.requests.count, 2)
  }

  @Test func quittingWithoutThreadsKeepsTodayFlow() async {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    #expect(model.chat.quitAlertText == nil)
    await model.instantAsk.quitConfirmed()
    #expect(model.instantAsk.pending.isEmpty)
    expectNoDifference(fork.stopCount, 1)
  }

  @Test func reconnectAsksTheDaemonAboutRelaysAgain() async {
    let fork = ForkFake()
    let recorder = RecordFake()
    recorder.setRelaySupport(.success(true))
    let model = await linkedModel(fork: fork, recorder: recorder)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    expectNoDifference(recorder.capabilityChecks.count, 1)
    fake.close()
    await Task.megaYield()
    await clock.advance(by: .milliseconds(500))
    await send(Fixture.edited(2))
    await askedRightAway(model, "And why here?")
    expectNoDifference(recorder.capabilityChecks.count, 2)
  }

  @Test func replayedPickupIsCheckedOnceHistoryCatchesUp() async {
    fake.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: Fixture.seq(3), removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    let relay = "6f1c1f0e-8d1e-4b7a-9c2f-3a5b7d9e1f20"

    await send(Fixture.edited(1), Fixture.questionExchangeRecorded(2, id: "q1", chat: Self.tab.uuidString.lowercased(), relay: relay))
    expectNoDifference(fork.requests, [])
    await send(relayUpdated(3, relay: relay, "picked_up"))
    await Task.megaYield()

    expectNoDifference(fork.requests.map(\.kind), [.report])
  }

  @Test func deletedCaptureDropsItsPendingQuestions() async throws {
    let fork = ForkFake()
    let model = await linkedModel(fork: fork)
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1))
    await askedRightAway(model, "Why?")
    fake.setSessions([], starts: [:])
    fake.setCaptures([])
    await model.reloadShortcutPressed()
    await Task.megaYield()
    #expect(model.instantAsk.pending.isEmpty)
    expectNoDifference(fork.stopCount, 1)
  }
}

@MainActor
extension ChangeStreamPageTests {
  nonisolated static let recorderEvidence = Evidence(
    source: "daemon.log since the app started the recorder · last exit code = 1",
    text: "Error: Cannot find module 'watcher.node'")

  nonisolated static let recorderStates: [RecorderState] = [
    .starting(RecorderModelTests.bundled),
    .restarting(from: "0.3.1", to: RecorderModelTests.bundled),
    .updateDidntFinish(
      running: RecorderModelTests.oldBuild, bundled: RecorderModelTests.bundled, .mismatch("watcher.node hash"),
      recorderEvidence),
    .anotherRecorder(
      pid: 30117, running: DaemonBuild(version: "0.3.0", build: nil), bundled: RecorderModelTests.bundled,
      recorderEvidence),
    .wontStart(RecorderModelTests.bundled, .exited(code: "1"), recorderEvidence),
    .migrationIncomplete(
      RecorderModelTests.bundled, MigrationFailure(links: ["slipstream"], adoptFailed: true), recorderEvidence),
  ]

  func closedStreamModel(_ state: RecorderState) async -> ChangeStreamPageModel {
    fake.setCaptures([])
    fake.setSessions([])
    let model = makeModel(recorder: RecorderModel(state: state))
    await model.viewAppeared()
    return model
  }

  @Test func startingShowsTheBundledBuild() async {
    let model = await closedStreamModel(.starting(RecorderModelTests.bundled))
    defer { model.viewDisappeared() }
    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(
        icon: .starting, tone: .neutral, headline: "Starting the recorder 0.3.2 (build 7f3c9a1e)…",
        footer: "Starting the recorder 0.3.2 (build 7f3c9a1e)…", evidence: nil, actions: []))
  }

  @Test func restartingShowsBothBuilds() async {
    let model = await closedStreamModel(.restarting(from: "0.3.1", to: RecorderModelTests.bundled))
    defer { model.viewDisappeared() }
    let text = "Restarting the recorder 0.3.1 → 0.3.2 (build 7f3c9a1e)… changes resume when it's back"
    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(icon: .restarting, tone: .neutral, headline: text, footer: text, evidence: nil, actions: []))
  }

  @Test func updateDidntFinishNamesWhatDidntMatch() async {
    let model = await closedStreamModel(Self.recorderStates[2])
    defer { model.viewDisappeared() }
    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(
        icon: .warning, tone: .warning,
        headline:
          "The copy of recorder 0.3.2 didn't match the one signed into the app, so the app kept recorder 0.3.1 running.",
        footer: "Recorder 0.3.1 still running · copy of 0.3.2 didn't match the app (watcher.node hash)",
        evidence: Self.recorderEvidence, actions: [.tryAgain]))
  }

  @Test func anotherRecorderOffersReplaceIt() async {
    let recorderFake = RecorderFake(clock: clock)
    recorderFake.running.setValue(DaemonBuild(version: "0.3.0", build: nil))
    recorderFake.lockPID.setValue(30117)
    recorderFake.descriptions.setValue([30117: "node /npm/slipstream/dist/cli.js start"])
    let recorder = withDependencies {
      $0.daemon = fake.client
      $0.continuousClock = clock
      $0.recorderService = recorderFake.service
      $0.runtimeInstall = recorderFake.runtimeInstall
    } operation: {
      RecorderModel()
    }
    await recorder.appLaunched()
    fake.setCaptures([])
    fake.setSessions([])
    let model = makeModel(recorder: recorder)
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(
      model.recorderMessage?.headline,
      "A recorder this app didn't start (pid 30117, npm 0.3.0) is using store-a. "
        + "It's still recording; the app won't stop it unless you replace it.")
    expectNoDifference(model.recorderMessage?.footer, "Recorder pid 30117 is npm 0.3.0, not started by this app")
    expectNoDifference(model.recorderMessage?.evidence?.source, "status · owner.lock · launchctl")
    expectNoDifference(model.recorderMessage?.actions, [.replaceIt])
  }

  @Test func newerRecorderSaysToUpdateSlipstream() async {
    let model = await closedStreamModel(
      .anotherRecorder(
        pid: 8594, running: DaemonBuild(version: "0.3.3", build: nil), bundled: RecorderModelTests.bundled,
        Self.recorderEvidence))
    defer { model.viewDisappeared() }

    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(
        icon: .warning, tone: .warning,
        headline: "A recorder newer than this app's 0.3.2 (pid 8594, npm 0.3.3) is using store-a. "
          + "It's still recording; update Slipstream so the app can switch to its own recorder.",
        footer: "Recorder pid 8594 is npm 0.3.3, newer than this app's 0.3.2", evidence: Self.recorderEvidence,
        actions: []))
  }

  @Test func wontStartOffersTheLog() async {
    let model = await closedStreamModel(Self.recorderStates[4])
    defer { model.viewDisappeared() }
    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(
        icon: .failure, tone: .error, headline: "Recorder 0.3.2 exited with code 1 before it was ready.",
        footer: "Recorder 0.3.2 exited with code 1 before it was ready.", evidence: Self.recorderEvidence,
        actions: [.tryAgain, .openLogFile]))
  }

  @Test func dockedRecorderMessageKeepsEveryAction() async {
    let model = await closedStreamModel(Self.recorderStates[4])
    defer { model.viewDisappeared() }

    expectNoDifference(model.recorderMessage?.dockedActions, [.tryAgain, .openLogFile])
  }

  @Test func migrationIncompleteNamesWhatStillPointsAtNpm() async {
    let model = await closedStreamModel(Self.recorderStates[5])
    defer { model.viewDisappeared() }
    let text =
      "Recorder 0.3.2 is running, but 2 setup changes didn't finish: "
      + "the slipstream command link and the agent hooks still point at the old npm install."
    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(
        icon: .warning, tone: .warning, headline: text, footer: text, evidence: Self.recorderEvidence,
        actions: [.tryAgain]))
  }

  @Test(arguments: recorderStates, [false, true])
  func recorderMessageDocksOverAnOpenStream(state: RecorderState, isStreamOpen: Bool) async {
    if !isStreamOpen {
      fake.setCaptures([])
      fake.setSessions([])
    }
    let model = makeModel(recorder: RecorderModel(state: state))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let isMigration = if case .migrationIncomplete = state { true } else { false }
    expectNoDifference(model.selectedSession != nil, isStreamOpen)
    expectNoDifference(model.recorderMessageIsDocked, isStreamOpen || isMigration)
  }

  @Test func persistentRecorderDockKeepsTheSelectedStreamFooterVisible() async {
    let model = makeModel(recorder: RecorderModel(state: Self.recorderStates[5]))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    #expect(model.isRecorderDockShown)
    #expect(model.isFooterShown)
  }

  @Test func recorderRetryDoesNotReloadAfterThePageDisappears() async {
    let recorderFake = RecorderFake(clock: clock)
    let recorder = withDependencies {
      $0.continuousClock = clock
      $0.recorderService = recorderFake.service
      $0.runtimeInstall = recorderFake.runtimeInstall
    } operation: {
      RecorderModel(
        state: .wontStart(
          RecorderModelTests.bundled, .probe,
          Evidence(source: "status", text: "connection closed")))
    }
    let model = makeModel(recorder: recorder)
    await model.viewAppeared()
    let calls = fake.sessionsCallCount

    let retry = Task { await model.recorderActionTapped(.tryAgain) }
    await Task.megaYield()
    model.viewDisappeared()
    await clock.advance(by: .milliseconds(250))
    await retry.value

    expectNoDifference(fake.sessionsCallCount, calls)
  }

  @Test func connectionErrorShowsDetail() async {
    fake.setDiscoverError(
      DescriptorError.noUsableDescriptor(
        directory: "/tmp/store/runtime",
        rejected: [
          DescriptorRejection(file: "a.json", reason: "mode 0644 (group/other bits set)"),
          DescriptorRejection(file: "b.json", reason: #"missing "token" string"#),
        ]))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(
      model.recorderMessage,
      RecorderMessage(
        icon: .failure, tone: .error, headline: "The app found no recorder address to connect to.",
        footer: "The app found no recorder address to connect to.",
        evidence: Evidence(
          source: "discovery",
          text: """
            no usable descriptor in /tmp/store/runtime:
              a.json: mode 0644 (group/other bits set)
              b.json: missing "token" string
            """),
        actions: [.tryAgain]))
  }

  @Test func noGenericDaemonText() async {
    fake.setDiscoverError(
      DescriptorError.noRuntimeDirectory(
        path: "/tmp/store/runtime", errno: ENOENT, message: "No such file or directory"))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let shown = [
      model.emptyStateText, model.footerText, model.captureText, model.recorderMessage?.headline,
      model.recorderMessage?.footer, model.recorderMessage?.evidence?.text,
    ].compactMap { $0 }
    let generic = shown.filter { text in
      ["daemon isn't running", "Couldn't reach", "couldn't reach", "npm i -g"].contains { text.contains($0) }
    }
    expectNoDifference(generic, [])
  }

  @Test func copyCopiesTheEvidenceSourceAndText() async {
    fake.setDiscoverError(
      DescriptorError.noRuntimeDirectory(
        path: "/tmp/store/runtime", errno: ENOENT, message: "No such file or directory"))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    model.recorderCopyTapped()

    expectNoDifference(
      copied.value, ["discovery\n\ncan't read /tmp/store/runtime: No such file or directory (errno 2)"])
  }

  @Test func tryAgainAfterAConnectionErrorReloads() async {
    fake.setDiscoverError(
      DescriptorError.noRuntimeDirectory(
        path: "/tmp/store/runtime", errno: ENOENT, message: "No such file or directory"))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    fake.setDiscoverError(nil)

    await model.recorderActionTapped(.tryAgain)

    expectNoDifference(model.recorderMessage, nil)
    expectNoDifference(model.sessions.ids, [Fixture.session])
  }
}

extension ChangeStreamPageTests {
  // MARK: - Opened folders

  nonisolated static let plainFolder = "/work/plain"

  /// A workspace the app made, plus a plain checkout the daemon also captures.
  func listManagedAndPlain(_ plain: CaptureState = .recording, reason: String? = nil) {
    listCaptures(
      Fixture.capture(session: "managed", root: Self.workspaceRoot, binding: nil),
      Fixture.capture(plain, reason: reason, session: "plain", root: Self.plainFolder, binding: nil))
  }

  func modelRecordingThePlainFolder() async -> ChangeStreamPageModel {
    let model = makeModel(workspace: workspaceClient(choose: URL(filePath: Self.plainFolder)))
    await model.viewAppeared()
    await model.recordFolderTapped()
    return model
  }

  func selectManaged(_ model: ChangeStreamPageModel) async {
    model.sessionSelected("managed")
    await Task.megaYield()
  }

  var storedOpenedFolders: Set<OpenedFolder> {
    get {
      withDependencies { $0.defaultFileStorage = .inMemory(fileSystem: files) } operation: {
        @Shared(.openedFolders) var opened
        return opened
      }
    }
    nonmutating set {
      withDependencies { $0.defaultFileStorage = .inMemory(fileSystem: files) } operation: {
        @Shared(.openedFolders) var opened
        $opened.withLock { $0 = newValue }
      }
    }
  }

  @Test func aRecordedFolderStaysListedAfterAnotherRowIsSelected() async {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }
    expectNoDifference(model.selectedSession?.id, "plain")

    await selectManaged(model)

    expectNoDifference(sidebarRowIDs(model), ["managed", "plain"])
  }

  @Test func aRecordedFolderIsListedAfterRelaunch() async {
    listManagedAndPlain()
    await modelRecordingThePlainFolder().viewDisappeared()

    let model = makeModel(files: LockIsolated(files.value), workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(model.selectedSession?.id, nil)
    expectNoDifference(sidebarRowIDs(model), ["managed", "plain"])
  }

  @Test func aRecordedFolderStaysListedThroughPauseAndRecord() async throws {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }
    await selectManaged(model)

    listManagedAndPlain(.stopped, reason: "detached")
    await model.rowActionTapped(try #require(model.sessions[id: "plain"]))
    expectNoDifference(sidebarRowIDs(model), ["managed", "plain"])
    #expect(model.isPaused(try #require(model.sessions[id: "plain"])))

    listManagedAndPlain()
    await model.rowActionTapped(try #require(model.sessions[id: "plain"]))
    expectNoDifference(sidebarRowIDs(model), ["managed", "plain"])
    expectNoDifference(
      recordingFake.calls, [.record(Self.plainFolder), .pause(Self.plainFolder), .record(Self.plainFolder)])
  }

  @Test func selectingAConductorCaptureWithoutRecordingItDoesNotListIt() async {
    listCaptures(
      Fixture.capture(session: "managed", root: Self.workspaceRoot, binding: nil),
      Fixture.capture(session: "conductor", root: "/work/conductor/workspaces/r/brisbane", binding: nil))
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    model.sessionSelected("conductor")
    await Task.megaYield()
    await selectManaged(model)

    expectNoDifference(sidebarRowIDs(model), ["managed"])
    expectNoDifference(storedOpenedFolders, [])
  }

  @Test func aFolderOpenedForAnotherStoreIsNotListed() async {
    listManagedAndPlain()
    storedOpenedFolders = [OpenedFolder(storeID: "store-b", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    expectNoDifference(sidebarRowIDs(model), ["managed"])
  }

  @Test func archivingAWorkspaceForgetsThatItWasOpened() async throws {
    listWorkspace()
    storedOpenedFolders = [
      OpenedFolder(storeID: "store-a", folder: Self.workspaceRoot),
      OpenedFolder(storeID: "store-a", folder: Self.plainFolder),
    ]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    model.archiveTapped(try #require(model.selectedSession))
    await model.archiveConfirmed()

    expectNoDifference(storedOpenedFolders, [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)])
  }

  @Test func removeFromSidebarIsOfferedOnlyForRecordedFoldersOutsideTheWorkspacesFolder() async throws {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }

    #expect(model.isRemoveFromSidebarAvailable(try #require(model.sessions[id: "plain"])))
    #expect(!model.isRemoveFromSidebarAvailable(try #require(model.sessions[id: "managed"])))
  }

  @Test func removeFromSidebarPausesTheFolderAndHidesIt() async throws {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }
    await selectManaged(model)

    listManagedAndPlain(.stopped, reason: "detached")
    await model.removeFromSidebarTapped(try #require(model.sessions[id: "plain"]))

    expectNoDifference(recordingFake.calls, [.record(Self.plainFolder), .pause(Self.plainFolder)])
    expectNoDifference(sidebarRowIDs(model), ["managed"])
    expectNoDifference(storedOpenedFolders, [])
  }

  @Test func removeFromSidebarPausesARecreatedFolderUsingItsCurrentCapture() async throws {
    listCaptures(
      Fixture.capture(.stopped, reason: "detached", session: "old", root: Self.plainFolder, binding: nil),
      Fixture.capture(session: "new", root: Self.plainFolder, binding: nil))
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected("old")
    await Task.megaYield()

    await model.removeFromSidebarTapped(try #require(model.selectedSession))

    expectNoDifference(recordingFake.calls, [.pause(Self.plainFolder)])
  }

  @Test func removeFromSidebarDoesNotPauseAPausedFolder() async throws {
    listManagedAndPlain(.stopped, reason: "detached")
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.removeFromSidebarTapped(try #require(model.sessions[id: "plain"]))

    expectNoDifference(recordingFake.calls, [])
    expectNoDifference(sidebarRowIDs(model), ["managed"])
  }

  @Test func removingTheSelectedFolderDeselectsIt() async throws {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }

    listManagedAndPlain(.stopped, reason: "detached")
    await model.removeFromSidebarTapped(try #require(model.selectedSession))
    await Task.megaYield()

    expectNoDifference(model.selectedSession, nil)
    expectNoDifference(model.chat.folder, nil)
    expectNoDifference(sidebarRowIDs(model), ["managed"])
  }

  @Test func aFolderStaysInTheSidebarWhenItsPauseFails() async throws {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }
    await selectManaged(model)
    recordingFake.setFailures(.rejected(code: "BUSY", message: "busy"))

    let row = try #require(model.sessions[id: "plain"])
    await model.removeFromSidebarTapped(row)

    expectNoDifference(sidebarRowIDs(model), ["managed", "plain"])
    expectNoDifference(model.rowMessage(row), RecordingMessage(text: "Couldn't pause: busy", isFull: false))
  }

  @Test func removeFromSidebarWaitsForTheWorkspacesFolderToLoad() async throws {
    listManagedAndPlain()
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.workspaceRoot)]
    let roots = AsyncStream<Void>.makeStream()
    let model = makeModel(
      workspace: WorkspaceClient(
        roots: {
          for await _ in roots.stream {}
          return WorkspaceRoots(managed: Self.managedRoot, conductor: URL(filePath: "/work/conductor/workspaces"))
        },
        chooseFolder: { _, _ in nil }, nextFolder: WorkspaceClient.testValue.nextFolder, archive: { _, _ in nil },
        repository: { _ in nil }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    #expect(!model.isRemoveFromSidebarAvailable(try #require(model.sessions[id: "managed"])))
    roots.continuation.finish()
  }

  @Test func removeFromSidebarCompletesWhenTheRecordingIsAlreadyGone() async throws {
    listManagedAndPlain()
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }
    await selectManaged(model)
    recordingFake.setFailures(.rejected(code: "TARGET_NOT_FOUND", message: "gone"))

    await model.removeFromSidebarTapped(try #require(model.sessions[id: "plain"]))

    expectNoDifference(storedOpenedFolders, [])
  }

  @Test func removeFromSidebarPausesAFolderStoppedForMaintenance() async throws {
    listManagedAndPlain(.stopped, reason: "maintenance")
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.removeFromSidebarTapped(try #require(model.sessions[id: "plain"]))

    expectNoDifference(recordingFake.calls, [.pause(Self.plainFolder)])
  }

  @Test func removeFromSidebarPausesAFolderWhoseCaptureStateIsUnknown() async throws {
    fake.setSessions(
      [SessionSummary(id: "plain", durableSeq: .zero, removed: false)],
      starts: ["plain": SessionStarted(root: Self.plainFolder, startedAtMs: 0)])
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.removeFromSidebarTapped(try #require(model.sessions[id: "plain"]))

    expectNoDifference(recordingFake.calls, [.pause(Self.plainFolder)])
  }

  @Test func removeFromSidebarIsNotOfferedWhileTheFolderIsBeingRecorded() async throws {
    listManagedAndPlain(.stopped, reason: "detached")
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let paused = try #require(model.sessions[id: "plain"])
    recordingFake.hold()
    let record = Task { await model.rowActionTapped(paused) }
    await Task.megaYield()

    #expect(!model.isRemoveFromSidebarAvailable(paused))
    await model.removeFromSidebarTapped(paused)

    recordingFake.release()
    await record.value
    expectNoDifference(storedOpenedFolders, [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)])
  }

  @Test func anUnconfirmedRecordStillListsTheFolder() async {
    listManagedAndPlain()
    recordingFake.setFailures(.outcomeUnknown)
    let model = await modelRecordingThePlainFolder()
    defer { model.viewDisappeared() }

    await selectManaged(model)

    expectNoDifference(sidebarRowIDs(model), ["managed", "plain"])
  }

  @Test func aRemovedFolderIsNotSelectedAgainWhenItIsTheOnlyWorkspace() async throws {
    listCaptures(Fixture.capture(.stopped, reason: "detached", session: "plain", root: Self.plainFolder, binding: nil))
    storedOpenedFolders = [OpenedFolder(storeID: "store-a", folder: Self.plainFolder)]
    let model = makeModel(workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.selectedSession?.id, "plain")

    await model.removeFromSidebarTapped(try #require(model.selectedSession))
    await model.reloadShortcutPressed()

    expectNoDifference(model.selectedSession?.id, nil)
    expectNoDifference(sidebarRowIDs(model), [])
  }
}
