import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
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

  init() {
    fake = DaemonFake()
    fake.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)], starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    fake.setCaptures([Fixture.capture()])
  }

  func makeModel(
    daemon: DaemonFake? = nil, storage: InMemoryStorage? = nil,
    isFunctionDemoVisible: Bool = false, now: (@Sendable () -> Date)? = nil,
    chat: ChatPageModel? = nil, workspace: WorkspaceClient = .testValue
  ) -> ChangeStreamPageModel {
    withDependencies {
      $0.workspace = workspace
      $0.defaultInMemoryStorage = storage ?? self.storage
      $0.daemon = (daemon ?? fake).client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(ConstantGenerator())
      $0.timeZone = TimeZone(identifier: "UTC")!
      $0.date = DateGenerator(now ?? { Fixture.checkedAt })
    } operation: {
      ChangeStreamPageModel(chat: chat ?? makeChat(), isFunctionDemoVisible: isFunctionDemoVisible)
    }
  }

  func makeChat(records: [ChatTabRecord] = []) -> ChatPageModel {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.uuid = .incrementing
      $0.chatLink = link.client
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
    await model.refreshTapped()
    expectNoDifference(model.chat.outsideChatText, nil)

    fake.setCaptures([Fixture.capture()])
    await model.refreshTapped()
    expectNoDifference(model.chat.outsideChatText, "Stream: outside chat")

    fake.setCaptures(.failure(.invalidResponse))
    await model.refreshTapped()
    expectNoDifference(model.chat.outsideChatText, nil)

    fake.setCaptures([Fixture.capture()])
    await model.refreshTapped()
    fake.setDiscoverError(URLError(.cannotConnectToHost))
    await model.refreshTapped()
    expectNoDifference(model.chat.outsideChatText, nil)
  }

  @Test func linkChangeRefreshesCaptures() async {
    let model = await connectedModel()
    fake.setCaptures([Fixture.capture(binding: nil)])
    await model.chat.onLinkChanged()
    expectNoDifference(model.chat.outsideChatText, nil)
  }

  // MARK: - Sessions

  @Test func sessionsAreLabelledByRootAndStartTimeAndRemovedOnesHidden() async {
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
        SessionOption(id: "a", label: "/work/alpha · started Oct 3 14:18:10", root: "/work/alpha"),
        SessionOption(id: "c", label: "c"),
      ]
    )
    #expect(model.selectedSession == nil)
    #expect(model.emptyStateText == "Choose a capture session to watch its changes")
  }

  @Test func capturesOfTheSameFolderAreToldApartByStartTime() async {
    fake.setCaptures([])
    fake.setSessions(
      [
        SessionSummary(id: "a", durableSeq: .zero, removed: false),
        SessionSummary(id: "b", durableSeq: .zero, removed: false),
      ],
      starts: [
        "a": SessionStarted(root: "/work/alpha", startedAtMs: 1_790_950_000_000),
        "b": SessionStarted(root: "/work/alpha", startedAtMs: 1_791_037_090_974),
      ]
    )
    let model = makeModel()
    await model.viewAppeared()
    expectNoDifference(
      model.sessions.map(\.label),
      ["/work/alpha · started Oct 2 14:06:40", "/work/alpha · started Oct 3 14:18:10"]
    )
  }

  @Test func readySessionLabelAppearsWhileAnotherStartLookupIsSlow() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionStartGates: ["slow": gate])
    daemon.setSessions(
      [
        SessionSummary(id: "slow", durableSeq: .zero, removed: false),
        SessionSummary(id: "ready", durableSeq: .zero, removed: false),
      ],
      starts: [
        "slow": SessionStarted(root: "/work/slow", startedAtMs: 1_791_037_090_974),
        "ready": SessionStarted(root: "/work/ready", startedAtMs: 1_791_037_090_974),
      ]
    )
    let model = makeModel(daemon: daemon)
    let appeared = Task { await model.viewAppeared() }
    await daemon.waitForSessionStartCall(2)
    await Task.megaYield()
    #expect(model.sessions[id: "ready"]?.label == "/work/ready · started Oct 3 14:18:10")
    release.yield()
    await appeared.value
  }

  @Test func capturesStartedInTheSameSecondAreToldApartByID() async {
    fake.setCaptures([])
    fake.setSessions(
      [
        SessionSummary(id: "11111111-aaaa", durableSeq: .zero, removed: false),
        SessionSummary(id: "22222222-bbbb", durableSeq: .zero, removed: false),
        SessionSummary(id: "33333333-cccc", durableSeq: .zero, removed: false),
      ],
      starts: [
        "11111111-aaaa": SessionStarted(root: "/work/alpha", startedAtMs: 1_791_037_090_100),
        "22222222-bbbb": SessionStarted(root: "/work/alpha", startedAtMs: 1_791_037_090_974),
        "33333333-cccc": SessionStarted(root: "/work/beta", startedAtMs: 1_791_037_090_100),
      ]
    )
    let model = makeModel()
    await model.viewAppeared()
    expectNoDifference(
      model.sessions.map(\.label),
      [
        "/work/alpha · started Oct 3 14:18:10 · 11111111-aaaa",
        "/work/alpha · started Oct 3 14:18:10 · 22222222-bbbb",
        "/work/beta · started Oct 3 14:18:10",
      ]
    )
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

  @Test func singleSessionIsSelectedAutomatically() async {
    let model = await connectedModel()
    #expect(model.sessionPickerTitle == "/tmp/project · started Jan 1 00:00:00")
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
    await model.refreshTapped()
    #expect(model.selectedFolder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
    #expect(model.sessions[id: Fixture.session]?.root == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
  }

  @Test func rootIsNilUntilStartLoads() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionStartGates: [Fixture.session: gate])
    daemon.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel(daemon: daemon)
    let appeared = Task { await model.viewAppeared() }
    await daemon.waitForSessionStartCall(1)
    await Task.megaYield()
    #expect(model.selectedSession != nil)
    #expect(model.selectedFolder == nil)
    release.yield()
    await appeared.value
    #expect(model.selectedFolder == ChangeStreamPageModel.normalizedFolder("/tmp/project"))
  }

  @Test func selectingStreamTellsChatTheFolder() async {
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
    #expect(model.chat.folder == nil)
    #expect(model.chat.noWorkspaceText == "Choose a capture session to watch its changes")

    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()

    #expect(model.chatEmptyText == nil)
    #expect(model.chat.folder == ChangeStreamPageModel.normalizedFolder("/tmp/other"))
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
    let (gate, release) = AsyncStream<Void>.makeStream()
    let daemon = DaemonFake(sessionStartGates: [Fixture.session: gate])
    daemon.setSessions(
      [SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)],
      starts: [Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0)])
    let model = makeModel(daemon: daemon)

    let appeared = Task { await model.viewAppeared() }
    await daemon.waitForSessionStartCall(1)
    await Task.megaYield()
    #expect(model.chatEmptyText == "Finding this stream's folder…")
    #expect(model.chat.noWorkspaceText == "Finding this stream's folder…")

    release.yield()
    await appeared.value
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
    await model.refreshTapped()
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
    await send(
      Fixture.frame(1, type: "slipstream.capture.baseline.completed.v1", data: [:]),
      Fixture.edited(2)
    )
    #expect(model.canCompareFunctions)
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
    await model.refreshTapped()
    model.sessionSelected(Fixture.otherSession)
    #expect(model.functionChanges == nil)
    #expect(!model.canCompareFunctions)
  }

  @Test func missingDaemonIsExplained() async {
    fake.setDiscoverError(DescriptorError.noDaemonRunning(store: "/tmp/store"))
    let model = makeModel()
    await model.viewAppeared()
    #expect(model.emptyStateText == "The Slipstream daemon isn't running")
  }

  @Test func refreshPicksUpNewSessions() async {
    fake.setCaptures([])
    fake.setSessions([])
    let model = makeModel()
    await model.viewAppeared()
    #expect(model.emptyStateText == "No capture sessions yet")
    fake.setSessions([SessionSummary(id: "a", durableSeq: .zero, removed: false), SessionSummary(id: "b", durableSeq: .zero, removed: false)])
    await model.refreshTapped()
    #expect(model.sessions.ids == ["a", "b"])
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
      [CodeLine(id: 1, number: "1", text: "    x    = 2", isChanged: true, changedRanges: [11..<12])]
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

  @Test func showingAHiddenFeedReturnsToTheLatestChange() async {
    let model = await connectedModel()
    model.hideFeedTapped()
    #expect(model.isFeedHidden)
    model.scrollPhaseChanged(.interacting)
    model.scrollGeometryChanged(contentHeight: 2000, visibleMaxY: 1500)
    model.showFeedTapped()
    #expect(!model.isFeedHidden)
    #expect(model.follow == .following)
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
    let original = withDependencies(from: model) { AskAgentPageModel(sessionID: Fixture.session, context: context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
    model.askAgent = original
    original.draftChanged("Why?")
    let send = Task { await model.askQuestionTapped(original) }
    await Task.megaYield()
    let health = model.connection
    model.questionDismissed()
    let newer = AskAgentPageModel(sessionID: Fixture.otherSession, context: context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false)
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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
    } operation: { AskAgentPageModel(sessionID: Fixture.session, context: AskAgentPageTests.context, agentConnection: .connected, captureStatus: AskAgentPageTests.capture(), isAppTabLinked: false) }
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

  @Test func hidingTheFeedCollapsesTheReply() async throws {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    await send(Fixture.edited(1), Fixture.questionQueued(2, id: "q1"))
    _ = try open(model, "q1")
    model.hideFeedTapped()
    #expect(model.reply == nil)
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
    model.feedViewportChanged(CGRect(x: 0, y: 52, width: 680, height: 800))
    let bar = try bar(model, "q1")
    model.questionBarMoved(bar, frame: CGRect(x: 20, y: 300, width: 640, height: 42))
    model.questionBarTapped(bar)
    model.replyMeasured(CGSize(width: 420, height: 300))
    expectNoDifference(model.replyPlacement.popover, CGRect(x: 704, y: 300, width: 420, height: 300))
    expectNoDifference(model.replyPlacement.barAnchor, CGPoint(x: 660, y: 321))
    #expect(model.showsReplyConnector)
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
      AskAgentPageModel(
        sessionID: session, context: AskAgentPageTests.context, agentConnection: agentConnection,
        captureStatus: model.selectedCaptureStatus ?? AskAgentPageTests.capture(), isAppTabLinked: false)
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

  @Test func theCaptureStripReadsTheDaemonsSnapshot() async {
    let model = await liveModel()
    defer { model.viewDisappeared() }
    #expect(model.isCaptureStripShown)
    expectNoDifference(model.captureText, "Recording")
    expectNoDifference(model.captureCheckedText, "Checked 10:42:20")
    expectNoDifference(model.chatLinkText, "Linked — changes are possibly the agent's")
    expectNoDifference(model.sessionMenuText(for: model.selectedSession!), "\(model.sessionPickerTitle) · Recording")
    expectNoDifference(model.footerText, "Connected · New changes appear below")
  }

  @Test func theMenuNamesEachWorkspacesCaptureState() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    let captures: [CaptureSummary?] = [
      Fixture.capture(), Fixture.capture(.queued), Fixture.capture(.baselining),
      Fixture.capture(.stopped, reason: "maintenance"),
      Fixture.capture(.notRecording, reason: "capture-limit-reached"),
      Fixture.capture(.notRecording, reason: "storage-unavailable"),
      Fixture.capture(.unknown("paused")), nil,
    ]
    expectNoDifference(
      captures.map { model.sessionMenuText(for: SessionOption(id: "a", label: "alpha", capture: $0)) },
      [
        "alpha · Recording", "alpha · Queued", "alpha · Preparing", "alpha · Stopped",
        "alpha · Waiting for a free slot", "alpha · Not recording", "alpha · State unknown", "alpha · Not captured",
      ]
    )
  }

  func listThreeSessionsWithOneRecording() {
    fake.setSessions([
      SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
      SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
      SessionSummary(id: "uncaptured", durableSeq: .zero, removed: false),
    ])
    fake.setCaptures([
      Fixture.capture(),
      Fixture.capture(.stopped, reason: "archived", session: Fixture.otherSession, root: "/work/old", binding: nil),
    ])
  }

  @Test func thePickerHidesInactiveWorkspacesBehindAToggle() async {
    listThreeSessionsWithOneRecording()
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.pickerSessions.map(\.id), [Fixture.session])
    expectNoDifference(model.inactiveSessionsToggleText, "Show 2 inactive sessions")

    model.inactiveSessionsToggleTapped()
    expectNoDifference(model.pickerSessions.map(\.id), [Fixture.session, Fixture.otherSession, "uncaptured"])
    expectNoDifference(model.inactiveSessionsToggleText, "Hide inactive sessions")

    model.inactiveSessionsToggleTapped()
    expectNoDifference(model.pickerSessions.map(\.id), [Fixture.session])
  }

  @Test func theWatchedWorkspaceStaysInThePickerWhenItStops() async {
    listThreeSessionsWithOneRecording()
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.inactiveSessionsToggleTapped()
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    model.inactiveSessionsToggleTapped()
    expectNoDifference(model.pickerSessions.map(\.id), [Fixture.session, Fixture.otherSession])
    expectNoDifference(model.inactiveSessionsToggleText, "Show 1 inactive session")
  }

  @Test func thePickerHasNoToggleWhenEveryWorkspaceIsActive() async {
    let model = await connectedModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.pickerSessions.map(\.id), [Fixture.session])
    #expect(model.inactiveSessionsToggleText == nil)
  }

  @Test func thePickerHidesNothingWhenCaptureStateIsUnknown() async {
    listThreeSessionsWithOneRecording()
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    expectNoDifference(model.pickerSessions.map(\.id), [Fixture.session, Fixture.otherSession, "uncaptured"])
    #expect(model.inactiveSessionsToggleText == nil)
  }

  @Test(arguments: [CaptureState.queued, .baselining, .stopped, .notRecording, .unknown("paused")])
  func aConnectedAgentNeverMakesANonRecordingCaptureReadRecording(_ state: CaptureState) async {
    listSessions(.connected)
    fake.setCaptures([Fixture.capture(state)])
    let model = await liveModel()
    defer { model.viewDisappeared() }
    let composer = composer(model, agentConnection: .connected)
    #expect(model.captureText?.hasPrefix("Recording") == false)
    #expect(!model.sessionMenuText(for: model.selectedSession!).hasSuffix("Recording"))
    #expect(!model.footerText.contains("Recording"))
    #expect(!composer.canSubmit)
  }

  @Test func aReaderWithoutTheCapturesEndpointShowsTheStateAsUnknown() async {
    fake.setCaptures(.notFound)
    let model = await liveModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureText, "Capture state unavailable from this reader")
    expectNoDifference(model.chatLinkText, "Chat-link state unknown")
    expectNoDifference(model.sessionMenuText(for: model.selectedSession!), "\(model.sessionPickerTitle) · State unknown")
    #expect(model.captureCheckedText == nil)
    #expect(model.isFooterShown)
  }

  @Test func aFailedCapturesRequestShowsTheStateAsUnknownWhileTheFeedStillLoads() async {
    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    let model = await liveModel()
    defer { model.viewDisappeared() }
    expectNoDifference(model.captureText, "Capture state unknown — couldn't reach Slipstream")
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session])
  }

  @Test func aFailedRefreshStopsClaimingTheLastCheckedState() async {
    let model = await liveModel()
    defer { model.viewDisappeared() }
    fake.setSessionsError(URLError(.cannotConnectToHost))
    await model.refreshTapped()
    expectNoDifference(model.captureText, "Capture state unknown — couldn't reach Slipstream")
    #expect(model.captureCheckedText == nil)
  }

  @Test func theSeventeenthWorkspaceWaitsForAFreeSlotThenRecords() async {
    fake.setCaptures([
      Fixture.capture(),
      Fixture.capture(.notRecording, reason: "capture-limit-reached", session: Fixture.otherSession, root: "/work/seventeenth", binding: nil),
    ])
    let model = makeModel()
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    model.sessionSelected(Fixture.session)
    await Task.megaYield()
    model.sessionSelected(Fixture.otherSession)
    await Task.megaYield()
    expectNoDifference(model.sessionPickerTitle, "seventeenth")
    expectNoDifference(model.sessionMenuText(for: model.selectedSession!), "seventeenth · Waiting for a free slot")
    expectNoDifference(model.captureText, "Not recording — waiting for a free capture slot")
    expectNoDifference(
      model.captureDetailText,
      "Every capture slot is in use. This workspace starts on its own, oldest first, when one frees up. Refresh to check again.")
    expectNoDifference(model.chatLinkText, "No chat linked")
    expectNoDifference(model.emptyStateText, "No change history is available yet. Refresh to check again.")
    #expect(!model.isFooterShown)
    expectNoDifference(fake.follows.map(\.sessionID), [Fixture.session])

    listSessions(.connected, other: .connected)
    fake.setCaptures([Fixture.capture(), Fixture.capture(session: Fixture.otherSession, root: "/work/seventeenth")])
    await model.refreshTapped()
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
    await model.refreshTapped()
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
    let refresh = Task { await model.refreshTapped() }
    await Task.megaYield()
    daemon.close()
    await Task.megaYield()
    open.yield()
    await refresh.value
    expectNoDifference(model.captureText, "Capture state unknown — couldn't reach Slipstream")
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
    let refresh = Task { await model.refreshTapped() }
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
    let refresh = Task { await model.refreshTapped() }
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
      "Slipstream is cleaning up its storage. Capture resumes on its own afterwards. Refresh to check again.")
    fake.setCaptures([Fixture.capture()])
    await model.refreshTapped()
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
    expectNoDifference(model.sessionMenuText(for: model.selectedSession!), "\(model.sessionPickerTitle) · Queued")
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
        AskAgentPageModel(
          sessionID: session, context: AskAgentPageTests.context, agentConnection: .connected,
          captureStatus: model.selectedCaptureStatus!, isAppTabLinked: false)
      }
      model.askAgent = composer
      composer.draftChanged("Why?")
      await model.askQuestionTapped(composer)
    }
    expectNoDifference(
      requests.value.map { [$0.sessionID, $0.bindingGeneration] },
      [[Fixture.session, "7"], [Fixture.otherSession, "9"]])
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
    expectNoDifference(model.captureText, "Stopped — capture detached")
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
    expectNoDifference(model.captureText, "Capture state unknown — couldn't reach Slipstream")
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
    await model.refreshTapped()
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
    await model.refreshTapped()
    expectNoDifference(composer.agentConnection, .connected)
    expectNoDifference(model.selectedSession?.agentConnection, .connected)
    #expect(composer.canSubmit)
    listSessions(.disconnected(reason: "no_agent"))
    await model.refreshTapped()
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
    await model.refreshTapped()
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
    let refresh = Task { await model.refreshTapped() }
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
    let refresh = Task { await model.refreshTapped() }
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
    await model.refreshTapped()
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
    create: @escaping @Sendable (URL, String) async -> WorkspaceOutcome = { _, _ in WorkspaceOutcome() },
    archive: @escaping @Sendable (URL, String) async -> WorkspaceOutcome = { _, _ in WorkspaceOutcome() }
  ) -> WorkspaceClient {
    WorkspaceClient(managedRoot: { Self.managedRoot }, chooseRepository: { choose }, create: create, archive: archive)
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
    fake.setDiscoverError(DescriptorError.noDaemonRunning(store: "/tmp/store"))
    let model = makeModel()

    await model.viewAppeared()

    #expect(!model.isSessionPickerDisabled)
  }

  @Test func newWorkspaceCreatesThenSelectsIt() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let calls = LockIsolated<[[String]]>([])
    let model = makeModel(workspace: workspaceClient(create: { [fake] repository, store in
      calls.withValue { $0.append([repository.path, store]) }
      for await _ in gate { break }
      fake.setSessions(
        [
          SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false),
          SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false),
        ],
        starts: [
          Fixture.session: SessionStarted(root: "/tmp/project", startedAtMs: 0),
          Fixture.otherSession: SessionStarted(root: Self.workspaceRoot, startedAtMs: 0),
        ])
      return WorkspaceOutcome(workspacePath: Self.workspaceRoot)
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    let creating = Task { await model.newWorkspaceTapped() }
    await Task.megaYield()
    #expect(model.isWorkspaceBusy)
    #expect(model.isSessionPickerDisabled)
    release.yield()
    await creating.value

    expectNoDifference(calls.value, [["/r", "store-a"]])
    #expect(!model.isWorkspaceBusy)
    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.chat.folder == Self.workspaceRoot)
    #expect(!model.isWorkspaceFailurePresented)
  }

  @Test func newWorkspaceCancelledDoesNothing() async {
    let calls = LockIsolated(0)
    let model = makeModel(workspace: workspaceClient(choose: nil, create: { _, _ in
      calls.withValue { $0 += 1 }
      return WorkspaceOutcome()
    }))

    await model.newWorkspaceTapped()

    #expect(calls.value == 0)
    #expect(!model.isWorkspaceBusy)
  }

  @Test func failedSetupStillSelectsWorkspaceAndShowsTheTail() async {
    let model = makeModel(workspace: workspaceClient(create: { [self] _, _ in
      listWorkspace()
      return WorkspaceOutcome(workspacePath: Self.workspaceRoot, failureText: "slipstream: the setup script exited 2.")
    }))
    fake.setSessions([])
    fake.setCaptures([])
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.newWorkspaceTapped()

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.isWorkspaceFailurePresented)
    #expect(model.workspaceFailureTitle == "Couldn't finish creating the workspace")
    #expect(model.workspaceFailureText == "slipstream: the setup script exited 2.")
  }

  @Test func archiveIsOnlyOfferedUnderTheManagedRoot() async {
    func isOffered(_ root: String) async -> Bool {
      fake.setSessions(
        [SessionSummary(id: Fixture.otherSession, durableSeq: .zero, removed: false)],
        starts: [Fixture.otherSession: SessionStarted(root: root, startedAtMs: 0)])
      fake.setCaptures([])
      let model = makeModel(workspace: workspaceClient())
      await model.viewAppeared()
      defer { model.viewDisappeared() }
      return model.isArchiveWorkspaceShown
    }

    #expect(await isOffered(Self.workspaceRoot))
    #expect(await !isOffered("/Users/x/conductor/workspaces/r/w"))
    #expect(await !isOffered("/work/slipstream/workspaces-old/r/w"))
    #expect(await !isOffered("/work/slipstream/workspaces/r"))
  }

  @Test func archiveConfirmationWarnsWhenClaudeIsWorking() async {
    listWorkspace()
    let agent = AgentFake()
    let model = makeModel(chat: makeWorkingChat(agent), workspace: workspaceClient())
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.archiveConfirmationText == "Its folder is removed. The branch is kept.")

    model.chat.selectedTab?.draft = "hi"
    await model.chat.sendTapped()
    await Task.megaYield()
    model.archiveWorkspaceTapped()

    #expect(model.isArchiveConfirmationPresented)
    #expect(
      model.archiveConfirmationText
        == "Its folder is removed. The branch is kept. Claude's current reply will be stopped.")
  }

  @Test func archiveStopsChatsBeforeRunningTheCommand() async {
    listWorkspace()
    let agent = AgentFake()
    let chat = makeWorkingChat(agent)
    let shutdownsAtArchive = LockIsolated<Int?>(nil)
    let archived = LockIsolated<[[String]]>([])
    let model = makeModel(chat: chat, workspace: workspaceClient(archive: { [self] workspace, store in
      shutdownsAtArchive.setValue(agent.shutdowns(0))
      archived.withValue { $0.append([workspace.path, store]) }
      listWorkspace(.stopped, reason: "archived")
      return WorkspaceOutcome()
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    chat.selectedTab?.draft = "hi"
    await chat.sendTapped()
    await Task.megaYield()
    let sessionsCalls = fake.sessionsCallCount

    await model.archiveConfirmed()

    #expect(shutdownsAtArchive.value == 1)
    expectNoDifference(archived.value, [[Self.workspaceRoot, "store-a"]])
    #expect(model.selectedSession == nil)
    #expect(chat.folder == nil)
    #expect(chat.records.isEmpty)
    #expect(fake.sessionsCallCount > sessionsCalls)
    #expect(!model.isWorkspaceBusy)
  }

  @Test func archivedWorkspaceIsNotAutomaticallySelectedWhenCaptureLoadingFails() async {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      WorkspaceOutcome()
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    fake.setCaptures(.failure(.status(500, durableSeq: nil)))
    await model.archiveConfirmed()

    #expect(model.selectedSession == nil)
    #expect(model.chat.folder == nil)
  }

  @Test func sessionDiscoveryDoesNotWaitForManagedWorkspaceRoot() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let workspace = workspaceClient()
    let slowWorkspace = WorkspaceClient(
      managedRoot: {
        for await _ in gate { break }
        return Self.managedRoot
      },
      chooseRepository: workspace.chooseRepository,
      create: workspace.create,
      archive: workspace.archive
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
    let model = makeModel(workspace: workspaceClient(create: { [fake] _, _ in
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
      return WorkspaceOutcome(workspacePath: Self.workspaceRoot)
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }

    await model.newWorkspaceTapped()
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
    await Task.megaYield()

    #expect(model.selectedSession?.id == Fixture.otherSession)
  }

  @Test func archiveHidesTheChatWhileTheCommandRuns() async {
    listWorkspace()
    let (gate, release) = AsyncStream<Void>.makeStream()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      for await _ in gate { break }
      return WorkspaceOutcome(failureText: "refused")
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    #expect(model.chat.showsNewTabButton)

    let archiving = Task { await model.archiveConfirmed() }
    await Task.megaYield()

    #expect(model.chat.folder == nil)
    #expect(!model.chat.showsNewTabButton)
    #expect(!model.chat.isMessageBoxEnabled)
    release.yield()
    await archiving.value
  }

  @Test func refusedArchiveGivesBackItsConversationsAndShowsTheError() async {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      WorkspaceOutcome(failureText: "slipstream: the workspace has uncommitted or untracked changes.")
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let conversations = model.chat.records.map(\.id)

    await model.archiveConfirmed()

    #expect(model.selectedSession?.id == Fixture.otherSession)
    #expect(model.chat.folder == Self.workspaceRoot)
    expectNoDifference(model.chat.visibleTabs.map(\.id), conversations)
    #expect(model.isWorkspaceFailurePresented)
    #expect(model.workspaceFailureTitle == "Couldn't archive the workspace")
    #expect(model.workspaceFailureText == "slipstream: the workspace has uncommitted or untracked changes.")
  }

  @Test func refusedArchiveRestoresEachDraft() async throws {
    listWorkspace()
    let model = makeModel(chat: makeWorkingChat(AgentFake()), workspace: workspaceClient(archive: { _, _ in
      WorkspaceOutcome(failureText: "refused")
    }))
    await model.viewAppeared()
    defer { model.viewDisappeared() }
    let tab = try #require(model.chat.selectedTab)
    tab.draft = "Keep this draft"

    await model.archiveConfirmed()

    #expect(model.chat.selectedTab?.draft == "Keep this draft")
  }
}
