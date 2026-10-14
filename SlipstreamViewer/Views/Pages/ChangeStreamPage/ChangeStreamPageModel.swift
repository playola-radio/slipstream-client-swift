import Dependencies
import Foundation
import IdentifiedCollections
import Sharing
import SlipstreamCore
import SwiftUI

@MainActor
@Observable
final class ChangeStreamPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.daemon) var daemon
  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator
  @ObservationIgnored @Dependency(\.timeZone) var timeZone

  // MARK: - Shared State

  @ObservationIgnored @Shared(.readAnswers) var readAnswers
  @ObservationIgnored @Shared(.replyDrafts) var replyDrafts
  @ObservationIgnored @Shared(.fontSizeStep) var fontSizeStep

  // MARK: - Initialization

  init(isFunctionDemoVisible: Bool = false) {
    self.isFunctionDemoVisible = isFunctionDemoVisible
    super.init()
  }

  // MARK: - Properties

  static let cardContentLimit = 64

  var askAgent: AskAgentPageModel?
  private(set) var reply: QuestionThreadPageModel?
  private(set) var questionThreads = QuestionThreads()
  private(set) var replySize = CGSize(width: DesignTokens.Reply.width, height: 240)
  private(set) var replyBarFrame = CGRect.zero
  private(set) var isReplyBarVisible = false
  var isQuestionDismissConfirmationPresented = false
  private(set) var queuedQuestionNotice: String?
  private(set) var feedViewport = CGRect.zero
  private(set) var isSourceBlockVisible = false
  private(set) var sourceSelection: SourceSelection?
  private(set) var selectionFrame = CGRect.zero
  private(set) var viewport = CGRect.zero
  private(set) var composerSize = CGSize(width: DesignTokens.Ask.width, height: 396)

  var sessions: IdentifiedArrayOf<SessionOption> = []
  var hasLoadedSessions = false
  var sessionsError: String?
  var selectedSession: SessionOption?
  private(set) var baselineCompletedSeq: Seq?
  private(set) var functionChanges: FunctionChangesLiveModel?
  var connection: ConnectionState = .idle
  var sections: IdentifiedArrayOf<FeedSection> = []
  private(set) var feedGeneration = 0
  var newestFileID: Seq?
  var follow: FollowState = .following
  var scrollToLatestRequest = 0
  private(set) var historyRolledBack = false
  private(set) var cardContents: [Seq: CardContent] = [:]
  private(set) var isFeedHidden = false
  private(set) var isFunctionDemoVisible: Bool
  private(set) var pinnedHeadings: Set<Seq> = []

  @ObservationIgnored private(set) var lastAppliedSeq: Seq = .zero
  @ObservationIgnored private(set) var watchTask: Task<Void, Never>?
  @ObservationIgnored private var cardContentOrder: [Seq] = []
  @ObservationIgnored private var cardLoadGenerations: [Seq: Int] = [:]
  @ObservationIgnored private var cardLoadCount = 0
  @ObservationIgnored private var visibleCards: Set<Seq> = []
  @ObservationIgnored private var taskCount = 0
  @ObservationIgnored private var watchGeneration = 0
  @ObservationIgnored private var sessionsGeneration = 0
  @ObservationIgnored private var needsReadinessRefresh = false
  @ObservationIgnored private var awaitsFreshSnapshot = false
  @ObservationIgnored private var pendingReadiness: (state: AgentConnection, seq: Seq)?
  @ObservationIgnored private var isUserScrolling = false
  @ObservationIgnored private var lastVisibleMaxY: Double?
  @ObservationIgnored private var barFrames: [String: CGRect] = [:]

  // MARK: - Display Text

  let questionDismissTitle = "Discard this question?"
  let questionDismissMessage = "This submission may already be queued. Closing does not withdraw it and discards the draft and its retry ID. Sending it again could queue a duplicate."
  let questionDiscardText = "Discard draft"
  let questionKeepText = "Keep question"

  let paneTitle = "Change stream"
  let refreshButtonText = "Refresh"
  let compareFunctionsText = "Compare functions"
  let jumpToLatestText = "Jump to latest ↓"
  let hideFeedText = "Hide feed"
  let showFeedText = "◧  Activity"
  let fileViewerPlaceholderText = "Open a change to see its file here"

  var retryButtonText: String {
    historyRolledBack ? "Reload from start" : "Retry"
  }

  var paneSubtitle: String {
    guard isQuestionSummaryShown else { return "Full functions" }
    let count = questionThreads.threads.count
    let newReplies = questionThreads.threads.filter { status(of: $0) == .newReply }.count
    let questions = "\(count) \(count == 1 ? "question" : "questions")"
    guard newReplies > 0 else { return questions }
    return questions + " · \(newReplies) \(newReplies == 1 ? "new reply" : "new replies")"
  }

  var sessionPickerTitle: String {
    selectedSession?.label ?? "Choose a session"
  }

  func sessionMenuText(for session: SessionOption) -> String {
    Self.recordingState(of: session.agentConnection) == .recording ? "\(session.label) · Recording" : session.label
  }

  var statusText: String {
    switch connection {
    case .idle: "Not connected"
    case .connecting: "Connecting…"
    case .live: "Connected"
    case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
    case .disconnected: "Disconnected"
    case .sessionRemoved: "Session removed"
    case .halted(let message): message
    }
  }

  var footerText: String {
    let captureText: String
    if connection == .live {
      captureText = switch (watchedRecordingState, follow) {
      case (.ended, _): "Recording ended"
      case (_, .following): "Live · New changes appear below"
      case (_, .paused(0)): "Paused · No new changes"
      case (_, .paused(1)): "1 new change"
      case (_, .paused(let count)): "\(count) new changes"
      }
    } else {
      captureText = statusText
    }
    return captureText + (queuedQuestionNotice.map { " · " + $0 } ?? "")
  }

  var emptyStateText: String? {
    if let sessionsError, selectedSession == nil { return sessionsError }
    guard hasLoadedSessions || selectedSession != nil else { return "Looking for capture sessions…" }
    if selectedSession == nil {
      return sessions.isEmpty ? "No capture sessions yet" : "Choose a capture session to watch its changes"
    }
    return sections.isEmpty ? "Waiting for changes…" : nil
  }

  // MARK: - View Helpers

  var questionPlacement: QuestionPlacement {
    let visibleSelection = selectionFrame.intersection(feedViewport)
    return QuestionPlacement(selection: visibleSelection.isEmpty ? selectionFrame : visibleSelection,
      viewport: viewport, size: composerSize)
  }

  var isQuestionSummaryShown: Bool { !questionThreads.threads.isEmpty }

  var replyPlacement: ReplyPlacement {
    ReplyPlacement(bar: replyBarFrame, viewport: viewport, size: replySize)
  }

  var replyWidth: CGFloat { max(0, min(DesignTokens.Reply.width, viewport.width - 2 * DesignTokens.Reply.viewportInset)) }
  var showsReplyConnector: Bool {
    reply != nil && isReplyBarVisible && !isFeedHidden && replyPlacement.showsConnector
      && !replyBarFrame.intersection(feedViewport).isEmpty
  }

  func questionBars(for row: FileChangeRow) -> [QuestionBar] {
    questionThreads.threads
      .filter { $0.source.context.changeSeq == row.id.decimal }
      .map { thread in
        QuestionBar(
          id: thread.id,
          preview: thread.turns.first?.text ?? "",
          status: status(of: thread),
          isOpen: reply?.key.rootQuestionID == thread.id
        )
      }
  }

  func replyMeasured(_ size: CGSize) { replySize = size }

  func questionBarMoved(_ bar: QuestionBar, frame: CGRect) {
    barFrames[bar.id] = frame
    guard reply?.key.rootQuestionID == bar.id else { return }
    isReplyBarVisible = true
    if replyBarFrame != frame { replyBarFrame = frame }
  }

  func questionBarDisappeared(_ bar: QuestionBar) {
    barFrames[bar.id] = nil
    guard reply?.key.rootQuestionID == bar.id else { return }
    isReplyBarVisible = false
  }

  var composerWidth: CGFloat { max(0, min(DesignTokens.Ask.width, viewport.width - 2 * DesignTokens.Ask.viewportInset)) }
  var sourceLineHeight: CGFloat { DesignTokens.Card.lineHeight * FontSize.scale(step: fontSizeStep) }
  var sourceLineNumberWidth: CGFloat { DesignTokens.Card.lineNumberWidth * FontSize.scale(step: fontSizeStep) }
  var showsSelectionConnector: Bool {
    sourceSelection?.sessionID == selectedSession?.id && isSourceBlockVisible && !isFeedHidden
      && !selectionFrame.intersection(feedViewport).isEmpty
  }

  func highlightRect(row: FileChangeRow, block: CodeBlock, width: CGFloat) -> CGRect? {
    guard let selection = sourceSelection, selection.sessionID == selectedSession?.id,
      selection.rowID == row.id, selection.blockID == block.id else { return nil }
    return selection.rect(in: CGRect(x: 0, y: 0, width: width, height: 0), lineHeight: sourceLineHeight)
  }

  func feedViewportChanged(_ frame: CGRect) { feedViewport = frame }
  func viewportChanged(_ size: CGSize) { viewport = CGRect(origin: .zero, size: size) }
  func composerMeasured(_ size: CGSize) { composerSize = size }

  func sourceDragged(row: FileChangeRow, block: CodeBlock, startY: CGFloat, endY: CGFloat, frame: CGRect) {
    guard askAgent == nil, let sessionID = selectedSession?.id,
      case .code(let loadedBlocks) = content(for: row), loadedBlocks.contains(block),
      sections.contains(where: { $0.items[id: row.id] == .file(row) })
    else { return }
    let selection = SourceSelection.make(
      sessionID: sessionID, row: row, block: block, startY: startY, endY: endY, lineHeight: sourceLineHeight)
    if sourceSelection != selection { sourceSelection = selection }
    isSourceBlockVisible = true
    let rect = selection?.rect(in: frame, lineHeight: sourceLineHeight) ?? .zero
    if selectionFrame != rect { selectionFrame = rect }
  }

  func sourceDragEnded() {
    guard askAgent == nil, let selection = sourceSelection else { return }
    replyCollapsed()
    queuedQuestionNotice = nil
    askAgent = withDependencies(from: self) {
      AskAgentPageModel(
        sessionID: selection.sessionID,
        context: selection.context,
        agentConnection: selectedSession?.agentConnection ?? .unreported
      )
    }
  }

  func sourceBlockMoved(row: FileChangeRow, block: CodeBlock, frame: CGRect) {
    guard let selection = sourceSelection, selection.sessionID == selectedSession?.id,
      selection.rowID == row.id, selection.blockID == block.id else { return }
    isSourceBlockVisible = true
    let rect = selection.rect(in: frame, lineHeight: sourceLineHeight)
    if selectionFrame != rect { selectionFrame = rect }
  }

  func sourceBlockDisappeared(row: FileChangeRow, block: CodeBlock) {
    guard let selection = sourceSelection, selection.sessionID == selectedSession?.id,
      selection.rowID == row.id, selection.blockID == block.id else { return }
    isSourceBlockVisible = false
  }

  func questionDismissTapped() {
    guard let composer = askAgent else { return }
    if composer.isSubmitting || composer.hasUncertainSubmission {
      isQuestionDismissConfirmationPresented = true
    } else {
      questionDismissed()
    }
  }

  func questionDismissed() {
    isQuestionDismissConfirmationPresented = false
    askAgent?.dismissed()
    askAgent = nil
    sourceSelection = nil
  }

  func questionBarTapped(_ bar: QuestionBar) {
    let isOpen = reply?.key.rootQuestionID == bar.id
    replyCollapsed()
    guard !isOpen, askAgent == nil, let sessionID = selectedSession?.id,
      let thread = questionThreads.threads[id: bar.id]
    else { return }
    let key = QuestionThreadKey(storeID: daemon.storeID, sessionID: sessionID, rootQuestionID: thread.id)
    reply = withDependencies(from: self) { QuestionThreadPageModel(key: key, thread: thread) }
    replyBarFrame = barFrames[thread.id] ?? .zero
    isReplyBarVisible = barFrames[thread.id] != nil
  }

  func replyDismissTapped() {
    replyCollapsed()
  }

  func askQuestionTapped(_ composer: AskAgentPageModel) async {
    guard askAgent === composer else { return }
    let queued = await composer.askTapped()
    guard askAgent === composer, queued else { return }
    if composer.sessionID == selectedSession?.id {
      queuedQuestionNotice = "Question queued (delivery not confirmed)"
    } else {
      let capture = sessions[id: composer.sessionID]?.label ?? "another capture"
      queuedQuestionNotice = "Question queued for \(capture) (delivery not confirmed)"
    }
    questionDismissed()
  }

  var isSessionPickerDisabled: Bool {
    sessions.isEmpty
  }

  var canCompareFunctions: Bool {
    !isFunctionDemoVisible && selectedSession != nil && baselineCompletedSeq != nil
  }

  var isRetryVisible: Bool {
    switch connection {
    case .disconnected, .halted: true
    default: false
    }
  }

  var statusColor: Color {
    switch connection {
    case .live: DesignTokens.Colors.liveStatus
    case .connecting, .reconnecting: DesignTokens.Status.warning
    case .disconnected, .sessionRemoved, .halted: DesignTokens.Status.error
    case .idle: DesignTokens.Colors.eventTime
    }
  }

  var footerColor: Color {
    guard connection == .live else { return statusColor }
    if watchedRecordingState == .ended { return DesignTokens.Colors.paneSubtitle }
    return follow == .following ? DesignTokens.Colors.liveStatus : DesignTokens.Colors.jumpToLatest
  }

  func emphasis(for row: FileChangeRow) -> CardEmphasis {
    row.id == newestFileID ? .newest : .other
  }

  func content(for row: FileChangeRow) -> CardContent {
    cardContents[row.id] ?? .loading
  }

  func openIndicatorText(for row: FileChangeRow) -> String? {
    !isFunctionDemoVisible && row.id == newestFileID ? "OPEN →" : nil
  }

  func isHeadingPinned(_ section: FeedSection) -> Bool {
    pinnedHeadings.contains(section.id)
  }

  func isCardRetryable(_ row: FileChangeRow) -> Bool {
    guard let content = cardContents[row.id] else { return false }
    return CardContentLoader.isRetryable(content)
  }

  // MARK: - User Actions

  func viewAppeared() async {
    if selectedSession != nil, watchTask?.isCancelled ?? true {
      startWatching()
    }
    await loadSessions()
  }

  func refreshTapped() async {
    await loadSessions()
  }

  func sessionSelected(_ id: String) {
    guard select(id) else { return }
    Task { [weak self] in await self?.loadSessions() }
  }

  func viewDisappeared() {
    functionChanges?.viewDisappeared()
    replyCollapsed()
    watchTask?.cancel()
    watchGeneration += 1
    sessionsGeneration += 1
    watchedFollowerLeftLive()
  }

  func compareFunctionsTapped() {
    guard canCompareFunctions, let sessionID = selectedSession?.id,
      let baselineCompletedSeq else { return }
    functionChanges?.viewDisappeared()
    functionChanges = withDependencies(from: self) {
      FunctionChangesLiveModel(
        sessionID: sessionID, before: baselineCompletedSeq, after: lastAppliedSeq)
    }
  }

  func functionChangesClosed() {
    functionChanges?.viewDisappeared()
    functionChanges = nil
  }

  func retryTapped() {
    guard selectedSession != nil else { return }
    if historyRolledBack {
      resetFeed()
      selectedSession?.readinessSeq = .zero
      if let selectedSession { sessions[id: selectedSession.id]?.readinessSeq = .zero }
    }
    startWatching()
  }

  func hideFeedTapped() {
    replyCollapsed()
    isFeedHidden = true
  }

  func showFeedTapped() {
    isFeedHidden = false
    follow.jumpToLatest()
  }

  func headingMoved(_ section: FeedSection, minY: Double) {
    let isPinned = minY <= 0
    guard isPinned != pinnedHeadings.contains(section.id) else { return }
    if isPinned {
      pinnedHeadings.insert(section.id)
    } else {
      pinnedHeadings.remove(section.id)
    }
  }

  func jumpToLatestTapped() {
    follow.jumpToLatest()
    scrollToLatestRequest += 1
  }

  func scrollPhaseChanged(_ phase: ScrollPhase) {
    isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
  }

  func scrollGeometryChanged(contentHeight: Double, visibleMaxY: Double) {
    defer { lastVisibleMaxY = visibleMaxY }
    guard isUserScrolling, visibleMaxY != lastVisibleMaxY else { return }
    follow.userScrolled(distanceFromBottom: contentHeight - visibleMaxY)
  }

  func cardAppeared(_ row: FileChangeRow) async {
    visibleCards.insert(row.id)
    if let cached = cardContents[row.id], !CardContentLoader.isRetryable(cached) {
      touchCardContent(row.id)
      return
    }
    await loadCardContent(row)
  }

  func cardRetryTapped(_ row: FileChangeRow) async {
    await loadCardContent(row)
  }

  func cardDisappeared(_ row: FileChangeRow) {
    visibleCards.remove(row.id)
  }

  // MARK: - Private Helpers

  private func loadCardContent(_ row: FileChangeRow) async {
    guard let sessionID = selectedSession?.id else { return }
    if let note = CardContentLoader.noteBeforeFetching(row) {
      storeCardContent(.note(note), for: row.id)
      return
    }
    let feedGenerationAtStart = feedGeneration
    cardLoadCount += 1
    let loadGeneration = cardLoadCount
    cardLoadGenerations[row.id] = loadGeneration
    guard let content = await CardContentLoader.load(row, sessionID: sessionID, daemon: daemon),
      feedGenerationAtStart == feedGeneration,
      loadGeneration == cardLoadGenerations[row.id]
    else { return }
    storeCardContent(content, for: row.id)
    if follow == .following { scrollToLatestRequest += 1 }
  }

  private func select(_ id: String) -> Bool {
    guard let session = sessions[id: id], session.id != selectedSession?.id else { return false }
    if let outgoing = selectedSession, let composer = askAgent, composer.sessionID == outgoing.id {
      composer.agentConnectionChanged(.disconnected(reason: nil))
    }
    selectedSession = session
    awaitsFreshSnapshot = false
    pendingReadiness = nil
    resetFeed()
    startWatching()
    return true
  }

  private func loadSessions() async {
    sessionsGeneration += 1
    let generation = sessionsGeneration
    let daemon = daemon
    do {
      let descriptor = try await daemon.discover()
      let summaries = try await daemon.sessions(descriptor).filter { !$0.removed }
      guard generation == sessionsGeneration else { return }
      let previous = sessions
      let selected = selectedSession
      sessions = IdentifiedArray(
        uniqueElements: summaries.map { summary in
          var option = SessionOption(
            id: summary.id, label: summary.id, agentConnection: summary.agentConnection,
            readinessSeq: summary.durableSeq)
          let known = selected?.id == summary.id ? selected : previous[id: summary.id]
          if let known, known.readinessSeq > summary.durableSeq {
            option.agentConnection = known.agentConnection
            option.readinessSeq = known.readinessSeq
          }
          return option
        }
      )
      sessionsError = nil
      hasLoadedSessions = true
      awaitsFreshSnapshot = false
      if let pending = pendingReadiness {
        pendingReadiness = nil
        if let listed = sessions[id: selectedSession?.id ?? ""], pending.seq > listed.readinessSeq {
          watchedReadinessChanged(pending.state, seq: pending.seq)
        }
      }
      if let selectedID = selectedSession?.id {
        if let listed = sessions[id: selectedID] {
          selectedSession?.agentConnection = listed.agentConnection
          selectedSession?.readinessSeq = listed.readinessSeq
        } else {
          selectedSession?.agentConnection = .disconnected(reason: nil)
        }
      }
      if let composer = askAgent {
        composer.agentConnectionChanged(sessions[id: composer.sessionID]?.agentConnection ?? .disconnected(reason: nil))
      }
      if selectedSession == nil, sessions.count == 1 {
        _ = select(sessions[0].id)
      }
      await withTaskGroup(of: (String, SessionStarted?).self) { group in
        for summary in summaries {
          group.addTask { (summary.id, try? await daemon.sessionStart(descriptor, summary.id)) }
        }
        var starts: [String: SessionStarted] = [:]
        for await (id, start) in group {
          starts[id] = start
          guard generation == sessionsGeneration else { return }
          for (id, label) in sessionLabels(starts) {
            sessions[id: id]?.label = label
            if selectedSession?.id == id { selectedSession?.label = label }
          }
        }
      }
    } catch {
      guard generation == sessionsGeneration else { return }
      sessions = []
      hasLoadedSessions = true
      sessionsError = error is DescriptorError
        ? "The Slipstream daemon isn't running"
        : "Couldn't reach the Slipstream daemon"
    }
  }

  private func startWatching() {
    guard let sessionID = selectedSession?.id else { return }
    watchTask?.cancel()
    watchGeneration += 1
    let generation = watchGeneration
    connection = .connecting
    let after = lastAppliedSeq
    let daemon = daemon
    let clock = clock
    let random = withRandomNumberGenerator
    watchTask = Task { [weak self] in
      let exit = await Self.follow(
        daemon: daemon,
        sessionID: sessionID,
        after: after,
        clock: clock,
        jitter: { random { Double.random(in: 0...1, using: &$0) } },
        status: { [weak self] status in self?.followerStatusChanged(status, generation: generation) },
        apply: { [weak self] event in self?.apply(event, generation: generation) ?? false }
      )
      self?.followerExited(exit, generation: generation)
    }
  }

  private static func follow<C: Clock<Duration>>(
    daemon: DaemonClient,
    sessionID: String,
    after: Seq,
    clock: C,
    jitter: @escaping @Sendable () -> Double,
    status: @escaping @MainActor @Sendable (FollowerStatus) -> Void,
    apply: @escaping @MainActor @Sendable (SlipstreamEvent) -> Bool
  ) async -> FollowerExit {
    let follower = EventFollower(
      discover: { try await daemon.discover() },
      open: { daemon.follow($0, sessionID, $1) },
      clock: clock,
      jitter: jitter
    )
    return await follower.run(after: after, status: { await status($0) }, apply: { await apply($0) })
  }

  private func followerStatusChanged(_ status: FollowerStatus, generation: Int) {
    guard generation == watchGeneration else { return }
    switch status {
    case .connecting: connection = .connecting
    case .live:
      connection = .live
      if needsReadinessRefresh {
        needsReadinessRefresh = false
        Task { [weak self] in await self?.loadSessions() }
      }
    case .reconnecting(let attempt):
      connection = .reconnecting(attempt: attempt)
      watchedFollowerLeftLive()
    }
  }

  private func followerExited(_ exit: FollowerExit, generation: Int) {
    guard generation == watchGeneration else { return }
    if case .cancelled = exit { return }
    watchedFollowerLeftLive()
    switch exit {
    case .cancelled:
      return
    case .disconnected:
      connection = .disconnected
    case .sessionRemoved:
      connection = .sessionRemoved
    case .cursorAhead(let durableSeq):
      let daemonPosition = durableSeq.map { "#\($0)" } ?? "an earlier change"
      connection = .halted("Daemon history ends at \(daemonPosition) but this feed is at #\(lastAppliedSeq)")
      historyRolledBack = true
    case .sessionNotFound:
      connection = .halted("Session not found")
    case .cursorRejected:
      connection = .halted("The daemon rejected this feed's position")
    case .outOfOrder(let expected, let received):
      connection = .halted("Stream out of order — expected #\(expected), got #\(received)")
    case .malformed(let seq, _):
      connection = .halted("Unreadable event \(seq.map { "#\($0)" } ?? "") — feed stopped")
    }
  }

  private func apply(_ event: SlipstreamEvent, generation: Int) -> Bool {
    guard generation == watchGeneration else { return false }
    switch event.payload {
    case .fileChanged(let change):
      append(
        .file(
          FileChangeRow(
            id: event.seq,
            path: change.path,
            before: change.before,
            after: change.after,
            time: time(change.observedAtMs)
          )
        )
      )
      newestFileID = event.seq
      follow.fileCardAppended()
    case .taskStarted(let task):
      taskCount += 1
      sections.append(
        FeedSection(id: event.seq, heading: TaskHeading(number: String(format: "%02d", taskCount), title: task.title))
      )
      if follow == .following { scrollToLatestRequest += 1 }
    case .captureGap(let gap):
      append(
        .marker(
          FeedMarker(
            id: event.seq,
            text: "Capture gap — \(PlainWords.gapReason(gap.reason)) (\(PlainWords.gapScope(gap.scope)))"
          )
        )
      )
    case .sessionResumed:
      append(.marker(FeedMarker(id: event.seq, text: "Session resumed after the daemon restarted")))
    case .unsupported(let type):
      append(.marker(FeedMarker(id: event.seq, text: "Unsupported event: \(type)")))
    case .questionQueued, .questionAnswered:
      let previousTurnCount = previousTurnCount(beforeApplying: event)
      questionThreads.apply(event)
      shareQueuedFollowUp(event, previousTurnCount: previousTurnCount)
      if let reply, let thread = questionThreads.threads[id: reply.key.rootQuestionID] {
        reply.threadUpdated(thread)
      }
      if follow == .following { scrollToLatestRequest += 1 }
    case .agentConnection(let state):
      watchedAgentConnectionReported(state, seq: event.seq)
    case .recordedWithoutRow:
      if event.type == "slipstream.capture.baseline.completed.v1", baselineCompletedSeq == nil {
        baselineCompletedSeq = event.seq
      }
    case .sessionStarted, .questionDispatchAttempted:
      break
    }
    if watchedRecordingState == .ended, let watched = selectedSession, event.seq > watched.readinessSeq {
      watchedReadinessChanged(.disconnected(reason: nil), seq: event.seq)
      Task { [weak self] in await self?.loadSessions() }
    }
    lastAppliedSeq = event.seq
    return true
  }

  private enum RecordingState {
    case recording, ended, unknown
  }

  private var watchedRecordingState: RecordingState {
    selectedSession.map { Self.recordingState(of: $0.agentConnection) } ?? .unknown
  }

  private static func recordingState(of connection: AgentConnection) -> RecordingState {
    switch connection {
    case .connected, .setupPending, .disconnected(reason: "no_agent"): .recording
    case .disconnected(reason: "capture_not_live"): .ended
    case .disconnected, .unreported: .unknown
    }
  }

  private func watchedAgentConnectionReported(_ reported: AgentConnection, seq: Seq) {
    guard let watched = selectedSession, seq > watched.readinessSeq else { return }
    if awaitsFreshSnapshot, Self.recordingState(of: reported) == .recording {
      if pendingReadiness?.seq ?? .zero < seq {
        pendingReadiness = (reported, seq)
      }
      return
    }
    watchedReadinessChanged(reported, seq: seq)
  }

  private func watchedFollowerLeftLive() {
    needsReadinessRefresh = true
    awaitsFreshSnapshot = true
    sessionsGeneration += 1
    guard let watched = selectedSession, watched.agentConnection != .unreported else { return }
    watchedReadinessChanged(.disconnected(reason: nil), seq: max(watched.readinessSeq, lastAppliedSeq))
  }

  private func watchedReadinessChanged(_ readiness: AgentConnection, seq: Seq) {
    guard let watched = selectedSession else { return }
    selectedSession?.agentConnection = readiness
    selectedSession?.readinessSeq = seq
    sessions[id: watched.id]?.agentConnection = readiness
    sessions[id: watched.id]?.readinessSeq = seq
    if let composer = askAgent, composer.sessionID == watched.id {
      composer.agentConnectionChanged(readiness)
    }
  }

  private func previousTurnCount(beforeApplying event: SlipstreamEvent) -> Int? {
    guard case .questionQueued(let question) = event.payload, let parentID = question.replyToQuestionID else {
      return nil
    }
    return questionThreads.threads.first(where: { thread in thread.turns.contains { $0.questionID == parentID } })?
      .turns.count
  }

  private func shareQueuedFollowUp(_ event: SlipstreamEvent, previousTurnCount: Int?) {
    guard case .questionQueued(let question) = event.payload, question.replyToQuestionID != nil,
      let sessionID = selectedSession?.id,
      let thread = questionThreads.threads.first(where: { $0.turns.last?.questionID == question.questionID }),
      previousTurnCount != thread.turns.count
    else { return }
    let key = QuestionThreadKey(storeID: daemon.storeID, sessionID: sessionID, rootQuestionID: thread.id)
    $replyDrafts.withLock { drafts in
      drafts[key, default: ReplyDraft()].turnQueued(QueuedTurn(questionID: question.questionID, seq: event.seq))
    }
  }

  private func append(_ item: FeedItem) {
    if sections.isEmpty {
      sections.append(FeedSection(id: .zero, heading: nil))
    }
    sections[sections.count - 1].items.append(item)
    if follow == .following { scrollToLatestRequest += 1 }
  }

  private func sessionLabels(_ starts: [String: SessionStarted]) -> [String: String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d HH:mm:ss"
    let labels = starts.mapValues { start in
      let started = formatter.string(from: Date(timeIntervalSince1970: Double(start.startedAtMs) / 1000))
      return "\(start.root) · started \(started)"
    }
    let counts = Dictionary(labels.values.map { ($0, 1) }, uniquingKeysWith: +)
    var unique: [String: String] = [:]
    for (id, label) in labels {
      unique[id] = counts[label, default: 0] > 1 ? "\(label) · \(id)" : label
    }
    return unique
  }

  private func time(_ milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
  }

  private func replyCollapsed() {
    reply?.dismissed()
    reply = nil
    isReplyBarVisible = false
  }

  private func status(of thread: QuestionThread) -> QuestionBarStatus {
    let sessionID = selectedSession?.id ?? ""
    let hasUnread = thread.turns.contains { turn in
      guard let answer = turn.answer else { return false }
      return !readAnswers.contains(AnswerReadMarker(storeID: daemon.storeID, sessionID: sessionID, seq: answer.seq))
    }
    if hasUnread { return .newReply }
    return thread.turns.contains { $0.answer == nil } ? .waiting : .answered
  }

  private func resetFeed() {
    functionChanges?.viewDisappeared()
    functionChanges = nil
    baselineCompletedSeq = nil
    replyCollapsed()
    questionThreads = QuestionThreads()
    barFrames = [:]
    queuedQuestionNotice = nil
    isSourceBlockVisible = false
    feedGeneration += 1
    sections = []
    newestFileID = nil
    cardContents = [:]
    cardContentOrder = []
    cardLoadGenerations = [:]
    pinnedHeadings = []
    taskCount = 0
    lastAppliedSeq = .zero
    follow = .following
    historyRolledBack = false
    pendingReadiness = nil
  }

  private func storeCardContent(_ content: CardContent, for id: Seq) {
    cardContents[id] = content
    touchCardContent(id)
    while cardContentOrder.count > Self.cardContentLimit,
      let index = cardContentOrder.firstIndex(where: { !visibleCards.contains($0) })
    {
      let evicted = cardContentOrder.remove(at: index)
      cardContents[evicted] = nil
      cardLoadGenerations[evicted] = nil
    }
  }

  private func touchCardContent(_ id: Seq) {
    cardContentOrder.removeAll { $0 == id }
    cardContentOrder.append(id)
  }
}
