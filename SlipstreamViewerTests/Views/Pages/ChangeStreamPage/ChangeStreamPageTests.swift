import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SlipstreamCore
import SwiftUI
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct ChangeStreamPageTests {
  let fake: DaemonFake
  let clock = TestClock()

  init() {
    fake = DaemonFake()
    fake.setSessions([SessionSummary(id: Fixture.session, durableSeq: .zero, removed: false)], roots: [Fixture.session: "/tmp/project"])
  }

  func makeModel(daemon: DaemonFake? = nil) -> ChangeStreamPageModel {
    withDependencies {
      $0.daemon = (daemon ?? fake).client
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(ConstantGenerator())
      $0.timeZone = TimeZone(identifier: "UTC")!
    } operation: {
      ChangeStreamPageModel()
    }
  }

  func connectedModel() async -> ChangeStreamPageModel {
    let model = makeModel()
    await model.viewAppeared()
    await Task.megaYield()
    return model
  }

  func send(_ items: StreamItem...) async {
    for item in items { fake.send(item) }
    await Task.megaYield()
  }

  func fileRow(_ model: ChangeStreamPageModel, _ id: Int) -> FileChangeRow? {
    for section in model.sections {
      if case .file(let row) = section.items[id: Fixture.seq(id)] { return row }
    }
    return nil
  }

  // MARK: - Sessions

  @Test func sessionsAreLabelledByRootAndRemovedOnesHidden() async {
    fake.setSessions(
      [
        SessionSummary(id: "a", durableSeq: .zero, removed: false),
        SessionSummary(id: "b", durableSeq: .zero, removed: true),
        SessionSummary(id: "c", durableSeq: .zero, removed: false),
      ],
      roots: ["a": "/work/alpha"]
    )
    let model = makeModel()
    await model.viewAppeared()
    expectNoDifference(
      model.sessions,
      [SessionOption(id: "a", label: "/work/alpha"), SessionOption(id: "c", label: "c")]
    )
    #expect(model.selectedSession == nil)
    #expect(model.emptyStateText == "Choose a capture session to watch its changes")
  }

  @Test func singleSessionIsSelectedAutomatically() async {
    let model = await connectedModel()
    #expect(model.sessionPickerTitle == "/tmp/project")
    expectNoDifference(fake.follows, [FollowRequest(token: "token-1", sessionID: Fixture.session, cursor: .zero)])
    #expect(model.statusText == "Connecting…")
    #expect(model.emptyStateText == "Waiting for changes…")
  }

  @Test func missingDaemonIsExplained() async {
    fake.setDiscoverError(DescriptorError.noDaemonRunning(store: "/tmp/store"))
    let model = makeModel()
    await model.viewAppeared()
    #expect(model.emptyStateText == "The Slipstream daemon isn't running")
    #expect(model.isSessionPickerDisabled)
  }

  @Test func refreshPicksUpNewSessions() async {
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
            .marker(FeedMarker(id: Fixture.seq(6), text: "Capture gap — the file watcher failed (src/)")),
            .marker(FeedMarker(id: Fixture.seq(7), text: "Session resumed after the daemon restarted")),
            .marker(FeedMarker(id: Fixture.seq(8), text: "Unsupported event: slipstream.future.thing.v1")),
          ]
        ),
      ]
    )
    #expect(model.newestFileID == Fixture.seq(4))
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

  @Test func cursorAheadOfDaemonIsAnExplicitErrorAndNeverResets() async {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    fake.close(throwing: DaemonHTTPError.status(409, durableSeq: Fixture.seq(1)))
    await Task.megaYield()
    #expect(model.statusText == "Daemon history ends at #1 but this feed is at #2")
    model.retryTapped()
    await Task.megaYield()
    #expect(fake.follows.last?.cursor == Fixture.seq(2))
    #expect(model.sections[0].items.count == 2)
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
    daemon.setClips(ClipsResponse(changeSeq: Fixture.seq(1), status: .skipped, fallbackReason: "no-change", clips: []))
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

  // MARK: - Cards

  func loadedContent(_ change: StreamItem, clips: ClipsResponse? = nil) async -> CardContent {
    let model = await connectedModel()
    if let clips { fake.setClips(clips) }
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
      before: ClipSide(span: ClipSpan(lineStart: start, lineEnd: end, truncated: false), method: .function),
      after: ClipSide(span: ClipSpan(lineStart: start, lineEnd: end, truncated: truncated), method: .function)
    )
  }

  @Test func functionClipShowsAfterSpanWithMarkers() async {
    fake.setBlob(Fixture.shaA, "a\nfunction f() {\n  return 1\n}\nz\n")
    fake.setBlob(Fixture.shaB, "a\nfunction f() {\n  return 2\n}\nz\n")
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .ready, clips: [functionClip(2, 4)])
    )
    expectNoDifference(
      content,
      .code(
        subtitle: "Full function",
        blocks: [
          CodeBlock(
            id: 0,
            separatorText: nil,
            lines: [
              CodeLine(id: 2, number: "2", text: "function f() {", isChanged: false),
              CodeLine(id: 3, number: "3", text: "  return 2", isChanged: true),
              CodeLine(id: 4, number: "4", text: "}", isChanged: false),
            ],
            truncationText: nil
          )
        ]
      )
    )
  }

  @Test func multipleClipsBecomeSeparateBlocksAndTruncationIsShown() async {
    fake.setBlob(Fixture.shaA, "one\ntwo\nthree\nfour\n")
    fake.setBlob(Fixture.shaB, "ONE\ntwo\nthree\nFOUR\n")
    let rangeClip = Clip(
      before: ClipSide(span: ClipSpan(lineStart: 4, lineEnd: 4, truncated: false), method: .changedRange),
      after: ClipSide(span: ClipSpan(lineStart: 4, lineEnd: 4, truncated: true), method: .changedRange)
    )
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .fallback, fallbackReason: "no-enclosing-function", clips: [functionClip(1, 1), rangeClip])
    )
    expectNoDifference(
      content,
      .code(
        subtitle: "Full function · Changed lines",
        blocks: [
          CodeBlock(id: 0, separatorText: nil, lines: [CodeLine(id: 1, number: "1", text: "ONE", isChanged: true)], truncationText: nil),
          CodeBlock(id: 1, separatorText: "···", lines: [CodeLine(id: 4, number: "4", text: "FOUR", isChanged: true)], truncationText: "… truncated"),
        ]
      )
    )
  }

  @Test func newFileMarksEveryLine() async {
    fake.setBlob(Fixture.shaB, "x\ny\n")
    let wholeFile = Clip(
      before: ClipSide(span: nil, method: .absent),
      after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 2, truncated: false), method: .wholeFile)
    )
    let content = await loadedContent(
      Fixture.fileChanged(1, "new.ts", before: Fixture.absent, after: Fixture.content(Fixture.shaB)),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .ready, clips: [wholeFile])
    )
    expectNoDifference(
      content,
      .code(
        subtitle: "Whole file",
        blocks: [
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

  @Test func oversizeContentIsNotFetched() async {
    let content = await loadedContent(
      Fixture.fileChanged(1, "big.json", before: Fixture.content(Fixture.shaA), after: Fixture.content(Fixture.shaB, size: (1 << 20) + 1))
    )
    #expect(content == .note("Too large to show"))
  }

  @Test func missingBlobIsExplained() async {
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .ready, clips: [functionClip(1, 1)])
    )
    #expect(content == .note("Content no longer available"))
  }

  @Test func binaryContentIsNotShown() async {
    fake.setBlob(Fixture.shaA, "a\n")
    fake.setBlob(Fixture.shaB, data: Data([0x61, 0x00, 0x62]))
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .ready, clips: [functionClip(1, 1)])
    )
    #expect(content == .note("Binary file — not shown"))
  }

  @Test func skippedClipShowsItsReason() async {
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .skipped, fallbackReason: "not-utf8", clips: [])
    )
    #expect(content == .note("Binary file — not shown"))
  }

  @Test func unavailableClipShowsItsReason() async {
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .unavailable, fallbackReason: "clip-too-large", clips: [])
    )
    #expect(content == .note("Change is too large to show"))
  }

  @Test func removalOnlyChangeIsANote() async {
    fake.setBlob(Fixture.shaA, "a\nb\n")
    fake.setBlob(Fixture.shaB, "a\n")
    let removal = Clip(
      before: ClipSide(span: ClipSpan(lineStart: 2, lineEnd: 2, truncated: false), method: .changedRange),
      after: ClipSide(span: nil, method: .changedRange)
    )
    let content = await loadedContent(
      Fixture.edited(1),
      clips: ClipsResponse(changeSeq: Fixture.seq(1), status: .fallback, fallbackReason: "unsupported-language", clips: [removal])
    )
    #expect(content == .note("Only lines removed — nothing to show"))
  }

  @Test func cardContentCacheIsBounded() async throws {
    let model = await connectedModel()
    for value in 1...(ChangeStreamPageModel.cardContentLimit + 1) {
      await send(Fixture.fileChanged(value, "f\(value).ts", before: Fixture.content(Fixture.shaA), after: Fixture.absent))
      await model.cardAppeared(try #require(fileRow(model, value)))
    }
    #expect(model.cardContents.count == ChangeStreamPageModel.cardContentLimit)
    #expect(model.cardContents[Fixture.seq(1)] == nil)
  }

  // MARK: - Follow

  @Test func userScrollAwayPausesAndCountsNewCards() async {
    let model = await connectedModel()
    await send(Fixture.edited(1))
    #expect(model.footerText == "Live · New changes appear below")
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

  @Test func newestCardIsEmphasised() async throws {
    let model = await connectedModel()
    await send(Fixture.edited(1), Fixture.edited(2))
    #expect(model.emphasis(for: try #require(fileRow(model, 1))) == .other)
    #expect(model.emphasis(for: try #require(fileRow(model, 2))) == .newest)
  }
}
