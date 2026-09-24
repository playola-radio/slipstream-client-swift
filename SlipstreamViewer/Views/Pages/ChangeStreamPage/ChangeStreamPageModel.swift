import Dependencies
import Foundation
import IdentifiedCollections
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

  // MARK: - Initialization

  override init() {
    super.init()
  }

  // MARK: - Properties

  static let cardContentLimit = 64

  var sessions: IdentifiedArrayOf<SessionOption> = []
  var hasLoadedSessions = false
  var sessionsError: String?
  var selectedSession: SessionOption?
  var connection: ConnectionState = .idle
  var sections: IdentifiedArrayOf<FeedSection> = []
  private(set) var feedGeneration = 0
  var newestFileID: Seq?
  var follow: FollowState = .following
  var scrollToLatestRequest = 0
  private(set) var historyRolledBack = false
  private(set) var cardContents: [Seq: CardContent] = [:]

  @ObservationIgnored private(set) var lastAppliedSeq: Seq = .zero
  @ObservationIgnored private(set) var watchTask: Task<Void, Never>?
  @ObservationIgnored private var cardContentOrder: [Seq] = []
  @ObservationIgnored private var visibleCards: Set<Seq> = []
  @ObservationIgnored private var taskCount = 0
  @ObservationIgnored private var watchGeneration = 0
  @ObservationIgnored private var sessionsGeneration = 0
  @ObservationIgnored private var isUserScrolling = false
  @ObservationIgnored private var lastVisibleMaxY: Double?

  // MARK: - Display Text

  let paneTitle = "Change stream"
  let paneSubtitle = "Full functions"
  let refreshButtonText = "Refresh"
  let jumpToLatestText = "Jump to latest ↓"

  var retryButtonText: String {
    historyRolledBack ? "Reload from start" : "Retry"
  }

  var sessionPickerTitle: String {
    selectedSession?.label ?? "Choose a session"
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
    guard connection == .live else { return statusText }
    return switch follow {
    case .following: "Live · New changes appear below"
    case .paused(0): "Paused · No new changes"
    case .paused(1): "1 new change"
    case .paused(let count): "\(count) new changes"
    }
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

  var isSessionPickerDisabled: Bool {
    sessions.isEmpty
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
    return follow == .following ? DesignTokens.Colors.liveStatus : DesignTokens.Colors.jumpToLatest
  }

  func emphasis(for row: FileChangeRow) -> CardEmphasis {
    row.id == newestFileID ? .newest : .other
  }

  func content(for row: FileChangeRow) -> CardContent {
    cardContents[row.id] ?? .loading
  }

  func subtitle(for row: FileChangeRow) -> String? {
    guard case .code(let subtitle, _) = content(for: row) else { return nil }
    return subtitle
  }

  func isCardRetryable(_ row: FileChangeRow) -> Bool {
    guard let content = cardContents[row.id] else { return false }
    return CardContentLoader.isRetryable(content)
  }

  func topGap(for item: FeedItem, in section: FeedSection) -> CGFloat {
    item.id == section.items.first?.id ? DesignTokens.Stream.groupGap : DesignTokens.Stream.itemGap
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
    guard let session = sessions[id: id], session.id != selectedSession?.id else { return }
    selectedSession = session
    resetFeed()
    startWatching()
  }

  func viewDisappeared() {
    watchTask?.cancel()
    watchGeneration += 1
    sessionsGeneration += 1
  }

  func retryTapped() {
    guard selectedSession != nil else { return }
    if historyRolledBack { resetFeed() }
    startWatching()
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
    let generation = feedGeneration
    guard let content = await CardContentLoader.load(row, sessionID: sessionID, daemon: daemon),
      generation == feedGeneration
    else { return }
    storeCardContent(content, for: row.id)
    if follow == .following { scrollToLatestRequest += 1 }
  }

  private func loadSessions() async {
    sessionsGeneration += 1
    let generation = sessionsGeneration
    let daemon = daemon
    do {
      let descriptor = try await daemon.discover()
      let summaries = try await daemon.sessions(descriptor).filter { !$0.removed }
      guard generation == sessionsGeneration else { return }
      sessions = IdentifiedArray(uniqueElements: summaries.map { SessionOption(id: $0.id, label: $0.id) })
      sessionsError = nil
      hasLoadedSessions = true
      if selectedSession == nil, sessions.count == 1 {
        sessionSelected(sessions[0].id)
      }
      await withTaskGroup(of: (String, String?).self) { group in
        for summary in summaries {
          group.addTask { (summary.id, try? await daemon.sessionRoot(descriptor, summary.id)) }
        }
        for await (id, root) in group {
          guard generation == sessionsGeneration, let root else { continue }
          sessions[id: id]?.label = root
          if selectedSession?.id == id { selectedSession?.label = root }
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
    case .live: connection = .live
    case .reconnecting(let attempt): connection = .reconnecting(attempt: attempt)
    }
  }

  private func followerExited(_ exit: FollowerExit, generation: Int) {
    guard generation == watchGeneration else { return }
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
    case .sessionStarted, .recordedWithoutRow:
      break
    }
    lastAppliedSeq = event.seq
    return true
  }

  private func append(_ item: FeedItem) {
    if sections.isEmpty {
      sections.append(FeedSection(id: .zero, heading: nil))
    }
    sections[sections.count - 1].items.append(item)
    if follow == .following { scrollToLatestRequest += 1 }
  }

  private func time(_ milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
  }

  private func resetFeed() {
    feedGeneration += 1
    sections = []
    newestFileID = nil
    cardContents = [:]
    cardContentOrder = []
    taskCount = 0
    lastAppliedSeq = .zero
    follow = .following
    historyRolledBack = false
  }

  private func storeCardContent(_ content: CardContent, for id: Seq) {
    cardContents[id] = content
    touchCardContent(id)
    while cardContentOrder.count > Self.cardContentLimit,
      let index = cardContentOrder.firstIndex(where: { !visibleCards.contains($0) })
    {
      cardContents[cardContentOrder.remove(at: index)] = nil
    }
  }

  private func touchCardContent(_ id: Seq) {
    cardContentOrder.removeAll { $0 == id }
    cardContentOrder.append(id)
  }
}
