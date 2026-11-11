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
  @ObservationIgnored @Dependency(\.date) var date
  @ObservationIgnored @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator
  @ObservationIgnored @Dependency(\.timeZone) var timeZone
  @ObservationIgnored @Dependency(\.workspace) var workspace
  @ObservationIgnored @Dependency(\.terminalRuntime) var terminalRuntime
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard

  // MARK: - Shared State

  @ObservationIgnored @Shared(.readAnswers) var readAnswers
  @ObservationIgnored @Shared(.replyDrafts) var replyDrafts
  @ObservationIgnored @Shared(.fontSizeStep) var fontSizeStep
  @ObservationIgnored @Shared(.isSidebarHidden) var isSidebarHidden
  @ObservationIgnored @Shared(.isRightPaneHidden) var isRightPaneHidden
  @ObservationIgnored @Shared(.sidebarWidth) var sidebarWidth
  @ObservationIgnored @Shared(.chatWidth) var chatWidth

  // MARK: - Initialization

  init(
    chat: ChatPageModel, instantAsk: InstantAskModel, terminals: TerminalPageModel,
    isFunctionDemoVisible: Bool = false
  ) {
    self.chat = chat
    self.instantAsk = instantAsk
    self.terminals = terminals
    self.isFunctionDemoVisible = isFunctionDemoVisible
    super.init()
    chat.onLinkChanged = { [weak self] in await self?.loadSessions() }
    chat.onReadinessChanged = { [weak self] in self?.askRouteChanged() }
    recording.onChanged = { [weak self] in await self?.loadSessions(preferring: $0) }
    recording.onRecorded = { [weak chat] in chat?.recorded(folder: $0) }
    recording.onRecordOutcomeUnknown = { [weak chat] in chat?.recordOutcomeUnknown(folder: $0) }
    naming.onWriteFinished = { [weak self] in await self?.reloadSessions() }
    naming.onClearFailed = { [weak self] detail in
      self?.workspaceFailed(title: "Couldn't switch back to the agent's name", text: detail, detail: detail)
    }
  }

  // MARK: - Properties

  static let cardContentLimit = 64

  let chat: ChatPageModel
  let instantAsk: InstantAskModel
  let terminals: TerminalPageModel
  let openIn = OpenInModel()
  let recording = RecordingControlsModel()
  let naming = WorkspaceNamingModel()

  var askAgent: AskAgentPageModel?
  private(set) var reply: QuestionThreadPageModel?
  private(set) var questionThreads = QuestionThreads()
  private(set) var replySize = CGSize(width: DesignTokens.Reply.width, height: 240)
  private(set) var replyBarFrame = CGRect.zero
  private(set) var isReplyBarVisible = false
  var isQuestionDismissConfirmationPresented = false
  private(set) var isWorkspaceBusy = false
  private(set) var workspaceRoots: WorkspaceRoots?
  private(set) var archiveTarget: SessionOption?
  private var listedCaptureSessionIDs: Set<String> = []
  private var archivingFolder: String?
  private var hoveredRowID: String?
  private var focusedRowID: String?
  var isArchiveConfirmationPresented = false
  var isWorkspaceFailurePresented = false
  private(set) var workspaceFailureTitle = ""
  private(set) var workspaceFailureText = ""
  /// The raw error behind the alert, copied by "Copy error"; nil hides that button.
  private(set) var workspaceFailureDetail: String?
  private var queuedQuestion: QueuedQuestion?
  private(set) var feedViewport = CGRect.zero
  private(set) var isSourceBlockVisible = false
  private(set) var sourceSelection: SourceSelection?
  private(set) var selectionFrame = CGRect.zero
  private(set) var viewport = CGRect.zero
  private(set) var composerSize = CGSize(width: DesignTokens.Ask.width, height: 396)

  var sessions: IdentifiedArrayOf<SessionOption> = [] { didSet { chatWorkspaceMayHaveChanged() } }
  var hasLoadedSessions = false { didSet { chatWorkspaceMayHaveChanged() } }
  var sessionsError: String? { didSet { chatWorkspaceMayHaveChanged() } }
  var selectedSession: SessionOption? {
    didSet {
      openIn.folder = selectedFolder
      chatWorkspaceMayHaveChanged()
    }
  }
  private(set) var captureAvailability = CaptureAvailability.loading
  var selectedFolder: String? { selectedSession?.root }
  private(set) var baselineCompletedSeq: Seq?
  private(set) var functionChanges: FunctionChangesLiveModel? {
    didSet {
      guard (oldValue == nil) != (functionChanges == nil) else { return }
      chat.comparisonVisibilityChanged(isShown: functionChanges != nil)
    }
  }
  var connection: ConnectionState = .idle
  var sections: IdentifiedArrayOf<FeedSection> = []
  private(set) var feedGeneration = 0
  var newestFileID: Seq?
  var follow: FollowState = .following
  var scrollToLatestRequest = 0
  private(set) var historyRolledBack = false
  private(set) var cardContents: [Seq: CardContent] = [:]
  private(set) var rightPane: RightPane = .stream
  private var resizeStartWidth: CGFloat?
  private(set) var isFunctionDemoVisible: Bool
  private(set) var pinnedHeadings: Set<Seq> = []
  private(set) var fileHeaderOffsets: [Seq: CGFloat] = [:]

  @ObservationIgnored private(set) var lastAppliedSeq: Seq = .zero
  /// Where the log stood when this feed started from the beginning; events up to it are replay.
  @ObservationIgnored private var replayEndSeq: Seq = .zero
  @ObservationIgnored private(set) var watchTask: Task<Void, Never>?
  @ObservationIgnored private var cardContentOrder: [Seq] = []
  @ObservationIgnored private var cardLoadGenerations: [Seq: Int] = [:]
  @ObservationIgnored private var cardLoadCount = 0
  @ObservationIgnored private var visibleCards: Set<Seq> = []
  @ObservationIgnored private var taskCount = 0
  @ObservationIgnored private var watchGeneration = 0
  @ObservationIgnored private var userSessionSelectionGeneration = 0
  @ObservationIgnored private var isReloading = false
  @ObservationIgnored private var isReloadQueued = false
  @ObservationIgnored private var sessionsGeneration = 0
  @ObservationIgnored private var pendingPreferredRoot: String?
  @ObservationIgnored private var archivedSessionIDs: Set<String> = []
  @ObservationIgnored private var workspaceRootsTask: Task<Void, Never>?
  @ObservationIgnored private var workspaceRootsGeneration = 0
  @ObservationIgnored private var refreshGeneration = 0
  private var isShown = false
  @ObservationIgnored private var needsReadinessRefresh = false
  @ObservationIgnored private var awaitsFreshSnapshot = false
  @ObservationIgnored private var pendingReadiness: (state: AgentConnection, seq: Seq)?
  /// A binding event that landed while a fresh snapshot was in flight; that snapshot may predate it.
  @ObservationIgnored private var bindingMovedWhileAwaitingSnapshot = false
  @ObservationIgnored private var isUserScrolling = false
  @ObservationIgnored private var lastVisibleMaxY: Double?
  @ObservationIgnored private var barFrames: [String: CGRect] = [:]
  @ObservationIgnored private var cardFrames: [Seq: (row: FileChangeRow, section: FeedSection, frame: CGRect)] = [:]
  @ObservationIgnored private var taskHeadingHeight: CGFloat = 0
  @ObservationIgnored private var fileHeaderHeight: CGFloat = 0
  @ObservationIgnored private var chatWorkspace: ChatWorkspace?

  // MARK: - Display Text

  let questionDismissTitle = "Discard this question?"
  let questionDismissMessage = "This submission may already be queued. Closing does not withdraw it and discards the draft and its retry ID. Sending it again could queue a duplicate."
  let questionDiscardText = "Discard draft"
  let questionKeepText = "Keep question"

  let newWorkspaceHelpText = "New workspace"
  let archiveWorkspaceHelpText = "Archive workspace"
  let archiveConfirmationTitle = "Archive this workspace?"
  let archiveConfirmText = "Archive"
  let cancelText = "Cancel"
  let workspaceFailureDismissText = "OK"
  let workspaceFailureCopyText = "Copy error"

  var sidebarToggleHelpText: String { isSidebarHidden ? "Show Sidebar" : "Hide Sidebar" }
  var rightPaneToggleHelpText: String { isRightPaneHidden ? "Show Right Panel" : "Hide Right Panel" }

  func rightPaneNote(_ pane: RightPane) -> String? {
    pane == .stream ? paneSubtitle : nil
  }

  func rightPaneText(_ pane: RightPane) -> String {
    switch pane {
    case .stream: "Change stream"
    case .terminals: "Terminals"
    }
  }

  var archiveConfirmationText: String {
    let text = "Its folder is removed. The branch is kept."
    guard let folder = archiveTarget?.root, chat.hasWorkingTab(in: folder) else { return text }
    return text + " Claude's current reply will be stopped."
  }

  let compareFunctionsText = "Compare functions"
  let jumpToLatestText = "Jump to latest ↓"
  let captureStripLabel = "CAPTURE"
  let chatStripLabel = "CHAT"

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

  let sidebarTitleText = "Workspaces"
  let addRepositoryText = "Add repository…"
  let recordFolderText = "Record a folder…"

  /// Counts rows recording now, not slots in use.
  var recordingCountText: String? {
    guard case .available = captureAvailability else { return nil }
    let count = pickerSessions.filter { captureStatus(of: $0).captureDot == .recording }.count
    return "\(count) recording"
  }

  func rowActionText(_ session: SessionOption) -> String {
    switch session.capture.flatMap({ recording.operation(for: $0.root) }) {
    case .pausing: "Pausing…"
    case .recording: "Recording…"
    case nil: isPaused(session) ? "Record" : "Pause"
    }
  }

  var breadcrumbRepositoryText: String? {
    guard selectedSession != nil else { return nil }
    return selectedFolder.flatMap { workspaceRoots?.repository(of: $0) }
  }

  var breadcrumbWorkspaceText: String? {
    selectedSession.map(rowName)
  }

  var compareFunctionsHelpText: String {
    if selectedSession == nil { return "Choose a workspace to compare its functions" }
    if baselineCompletedSeq == nil {
      return "Available once Slipstream has recorded where this workspace started"
    }
    return "Compare each function before and after this session's changes"
  }

  var selectedCaptureStatus: CaptureStatus? {
    selectedSession.map(captureStatus(of:))
  }

  var captureText: String? { selectedCaptureStatus?.captureText }
  var captureDetailText: String? { selectedCaptureStatus?.detailText(timeZone: timeZone) }
  var captureCheckedText: String? { selectedCaptureStatus?.checkedText(timeZone: timeZone) }
  var chatLinkText: String? { selectedCaptureStatus?.chatText }

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

  var queuedQuestionNotice: String? {
    switch queuedQuestion {
    case nil: nil
    case .here: "Question queued (delivery not confirmed)"
    case .elsewhere(let sessionID):
      "Question queued for \(workspaceName(for: sessionID) ?? "another capture") (delivery not confirmed)"
    }
  }

  var footerText: String {
    let captureText: String
    if connection == .live {
      captureText = switch follow {
      case .following: "Connected · New changes appear below"
      case .paused(0): "Paused · No new changes"
      case .paused(1): "1 new change"
      case .paused(let count): "\(count) new changes"
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
      if captureAvailability == .failed { return "Couldn't reach Slipstream. Press ⌘R to check again." }
      return pickerSessions.isEmpty ? "No capture sessions yet" : "Choose a capture session to watch its changes"
    }
    if selectedSession?.hasHistory == false { return "No change history is available yet. Press ⌘R to check again." }
    return sections.isEmpty ? "Waiting for changes…" : nil
  }

  /// What the chat shows while it has no folder. A selected stream's folder arrives with its
  /// start record, so until then the feed's own text doesn't apply.
  var chatEmptyText: String? {
    if selectedFolder != nil { return nil }
    if selectedSession == nil { return emptyStateText }
    return "Finding this stream's folder…"
  }

  // MARK: - View Helpers

  var isSessionPollRunning: Bool { isShown && chat.isAppActive }

  var isSidebarShown: Bool { !isSidebarHidden }
  var isRightPaneShown: Bool { !isRightPaneHidden }

  var sidebarColumnWidth: CGFloat {
    min(
      max(sidebarWidth, DesignTokens.Workspace.sidebarMinWidth),
      DesignTokens.Workspace.sidebarMaxWidth,
      sidebarMaxDisplayedWidth)
  }

  var detailPaneWidth: CGFloat? { isRightPaneShown ? chatColumnWidth : nil }
  var detailPaneMaxWidth: CGFloat? { isRightPaneShown ? nil : .infinity }

  /// The chat's dragged width, until the window is too narrow for it: then the chat gives way
  /// before the stream does. Only a screen too narrow for all three columns takes the chat under
  /// its minimum.
  var chatColumnWidth: CGFloat {
    min(
      chatWidth,
      max(
        isSidebarShown ? DesignTokens.Workspace.chatNarrowScreenMinWidth : DesignTokens.Workspace.chatMinWidth,
        chatMaxWidth))
  }

  /// Never past the screen's visible width.
  func windowMinWidth(visibleScreenWidth: CGFloat) -> CGFloat {
    let width = isFunctionDemoVisible
      ? DesignTokens.FunctionMap.demoWorkspaceMinWidth
      : DesignTokens.Workspace.chatMinWidth
        + (isRightPaneShown ? DesignTokens.FeedPane.width : 0)
        + (isSidebarShown ? sidebarColumnWidth : 0)
    return min(width, visibleScreenWidth)
  }

  var isStreamShown: Bool { isRightPaneShown && rightPane == .stream }

  func isSelected(_ pane: RightPane) -> Bool {
    rightPane == pane
  }

  func rowName(_ session: SessionOption) -> String {
    SidebarGroup.rowName(session)
  }

  func renameDisabledReason(_ session: SessionOption) -> String? {
    if !session.hasHistory { return "Can be named once work starts here." }
    if session.naming == nil { return "This version of the Slipstream daemon can't rename workspaces." }
    return nil
  }

  func isRenameEnabled(_ session: SessionOption) -> Bool {
    renameDisabledReason(session) == nil && !naming.isMutationInFlight
  }

  func isUseAgentNameEnabled(_ session: SessionOption) -> Bool {
    session.naming?.userName != nil && !naming.isMutationInFlight
  }

  func isSelected(_ session: SessionOption) -> Bool {
    session.id == selectedSession?.id
  }

  func isBold(_ session: SessionOption) -> Bool {
    session.root.map(chat.isWaiting) ?? false
  }

  func isWorking(_ session: SessionOption) -> Bool {
    session.root.map(chat.hasWorkingTab(in:)) ?? false
  }

  /// Only the workspaces `slipstream workspace create` makes, `<managedRoot>/<repo>/<name>`, can be archived.
  func isArchivable(_ session: SessionOption) -> Bool {
    session.root.map { workspaceRoots?.isArchivable($0) ?? false } ?? false
  }

  func isHighlighted(_ session: SessionOption) -> Bool {
    session.id == hoveredRowID || session.id == focusedRowID
  }

  func isArchiveIconShown(for session: SessionOption) -> Bool {
    isArchivable(session) && isHighlighted(session)
  }

  func isPaused(_ session: SessionOption) -> Bool {
    captureStatus(of: session).isPaused
  }

  func rowIcon(_ session: SessionOption) -> DesignTokens.Icons.Icon {
    isPaused(session)
      ? DesignTokens.Sidebar.pausedRowIcon(isHighlighted: isLit(session))
      : DesignTokens.Sidebar.rowIcon(isSelected: isSelected(session))
  }

  func rowNameColor(_ session: SessionOption) -> Color {
    isPaused(session)
      ? DesignTokens.Sidebar.pausedRowNameColor(isHighlighted: isLit(session))
      : DesignTokens.Sidebar.rowNameColor(isBold: isBold(session), isSelected: isSelected(session))
  }

  func isRecordingDotShown(_ session: SessionOption) -> Bool {
    captureStatus(of: session).captureDot == .recording && !isWorking(session)
  }

  /// Pause or Record applies: the row has a capture, its state is known, and it isn't archived or stopped for good.
  func isRowActionAvailable(_ session: SessionOption) -> Bool {
    guard case .available = captureAvailability, session.capture != nil else { return false }
    return !captureStatus(of: session).isInactive
  }

  /// On hover or focus, and throughout its operation.
  func isRowActionShown(_ session: SessionOption) -> Bool {
    isRowActionAvailable(session) && (isHighlighted(session) || isRowActionDisabled(session))
  }

  func isRowActionDisabled(_ session: SessionOption) -> Bool {
    session.capture.flatMap { recording.operation(for: $0.root) } != nil
  }

  func rowMessage(_ session: SessionOption) -> RecordingMessage? {
    session.capture.flatMap { recording.message(for: $0.root) }
  }

  var footerMessage: RecordingMessage? { recording.footerMessage }

  var isCaptureStripShown: Bool { selectedSession != nil }
  var isFooterShown: Bool { selectedSession?.hasHistory ?? true }
  var captureDotColor: Color { DesignTokens.CaptureStrip.dot(selectedCaptureStatus?.captureDot ?? .unknown) }
  var chatDotColor: Color { DesignTokens.CaptureStrip.dot(selectedCaptureStatus?.chatDot ?? .unknown) }

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
    reply != nil && isReplyBarVisible && isStreamShown && replyPlacement.showsConnector
      && !replyBarFrame.intersection(feedViewport).isEmpty
  }

  func questionBars(for row: FileChangeRow) -> [QuestionBar] {
    let threads = questionThreads.threads
      .filter { $0.source.context.changeSeq == row.id.decimal }
      .map { thread in
        QuestionBar(
          id: thread.id,
          preview: thread.turns.first?.text ?? "",
          status: status(of: thread),
          isOpen: reply?.key.rootQuestionID == thread.id
        )
      }
    let pending = pendingRoots
      .filter { $0.source.context.changeSeq == row.id.decimal }
      .map { entry in
        QuestionBar(
          id: entry.id,
          preview: entry.text,
          status: status(of: entry),
          isOpen: reply?.key.rootQuestionID == entry.id
        )
      }
    return threads + pending
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
    sourceSelection?.sessionID == selectedSession?.id && isSourceBlockVisible && isStreamShown
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
    queuedQuestion = nil
    askAgent = withDependencies(from: self) {
      AskAgentPageModel(
        sessionID: selection.sessionID,
        folder: sessions[id: selection.sessionID]?.root ?? "",
        source: QuestionSource(context: selection.context, selectedText: selection.selectedText),
        agentConnection: selectedSession?.agentConnection ?? .unreported,
        captureStatus: sessions[id: selection.sessionID].map(captureStatus(of:))
          ?? CaptureStatus(availability: captureAvailability, capture: nil),
        route: askRoute(selection.sessionID),
        instantAsk: instantAsk,
        recording: recording
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
    guard !isOpen, askAgent == nil,
      let thread = questionThreads.threads[id: bar.id] ?? pendingRoots[id: bar.id]?.rootThread
    else { return }
    replyOpened(on: thread)
  }

  func replyDismissTapped() {
    replyCollapsed()
  }

  func askQuestionTapped(_ composer: AskAgentPageModel) async {
    guard askAgent === composer else { return }
    let sent = await composer.askTapped()
    guard askAgent === composer, let sent else { return }
    if case .answering(let requestID) = sent {
      questionDismissed()
      if let entry = pendingRoots[id: requestID] { replyOpened(on: entry.rootThread) }
      return
    }
    queuedQuestion = composer.sessionID == selectedSession?.id ? .here : .elsewhere(sessionID: composer.sessionID)
    questionDismissed()
  }

  var pickerSessions: IdentifiedArrayOf<SessionOption> {
    sessions.filter(isListed)
  }

  var sidebarGroups: [SidebarGroup] {
    SidebarGroup.groups(pickerSessions, roots: workspaceRoots)
  }

  var isOpenInShown: Bool { selectedSession != nil }

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

  func fileHeaderOffset(for row: FileChangeRow) -> CGFloat {
    fileHeaderOffsets[row.id] ?? 0
  }

  func isCardRetryable(_ row: FileChangeRow) -> Bool {
    guard let content = cardContents[row.id] else { return false }
    return CardContentLoader.isRetryable(content)
  }

  // MARK: - User Actions

  func viewAppeared() async {
    isShown = true
    loadWorkspaceRoots()
    chatWorkspaceMayHaveChanged()
    chat.comparisonVisibilityChanged(isShown: functionChanges != nil)
    if selectedSession != nil, watchTask?.isCancelled ?? true {
      startWatching()
    }
    await reloadSessions()
  }

  func appBecameActive() async {
    chat.appActivityChanged(isActive: true)
    openIn.viewAppeared()
    await reloadSessions()
  }

  func sessionPollTask() async {
    while isSessionPollRunning {
      do { try await clock.sleep(for: .seconds(2)) } catch { return }
      guard isSessionPollRunning else { return }
      await reloadSessions()
    }
  }

  func reloadShortcutPressed() async {
    await reloadSessions()
  }

  func sessionSelected(_ id: String) {
    guard archivingFolder == nil || sessions[id: id]?.root != archivingFolder, select(id) else { return }
    userSessionSelectionGeneration += 1
    pendingPreferredRoot = nil
    Task { [weak self] in
      guard let self, isShown else { return }
      await loadSessions()
    }
  }

  func newWorkspaceTapped() async {
    guard !isWorkspaceBusy,
      let repository = await workspace.chooseFolder("Choose a git repository for the new workspace", "Create Workspace")
    else { return }
    await createWorkspace(in: repository)
  }

  func newWorkspaceTapped(in group: SidebarGroup) async {
    guard !isWorkspaceBusy, let folder = group.newWorkspaceFolder else { return }
    await createWorkspace(in: URL(filePath: folder))
  }

  func rowActionTapped(_ session: SessionOption) async {
    guard let folder = session.capture?.root else { return }
    if isPaused(session) {
      await recording.recordTapped(folder: folder)
    } else {
      await recording.pauseTapped(folder: folder)
    }
  }

  func recordFolderTapped() async {
    let selectionGeneration = userSessionSelectionGeneration
    await recording.recordFolderTapped { [weak self] in self?.userSessionSelectionGeneration == selectionGeneration }
  }

  func rowHoverChanged(_ session: SessionOption, isHovering: Bool) {
    if isHovering {
      hoveredRowID = session.id
    } else if hoveredRowID == session.id {
      hoveredRowID = nil
    }
  }

  func rowFocusChanged(_ session: SessionOption, isFocused: Bool) {
    if isFocused {
      focusedRowID = session.id
    } else if focusedRowID == session.id {
      focusedRowID = nil
    }
  }

  func renameMenuTapped(_ session: SessionOption) {
    guard isRenameEnabled(session) else { return }
    naming.renameTapped(sessionID: session.id, currentName: rowName(session))
  }

  func useAgentNameMenuTapped(_ session: SessionOption) async {
    guard isUseAgentNameEnabled(session) else { return }
    await naming.useAgentNameTapped(sessionID: session.id)
  }

  func copyWorkspaceFailureTapped() {
    guard let workspaceFailureDetail else { return }
    pasteboard.copy(workspaceFailureDetail)
  }

  func archiveTapped(_ session: SessionOption) {
    archiveTarget = session
    isArchiveConfirmationPresented = true
  }

  /// Stops the workspace's chats first, hiding them if it is selected: the command removes
  /// the folder they run in. Its conversations come back if the command refuses.
  func archiveConfirmed() async {
    guard !isWorkspaceBusy, let target = archiveTarget, let folder = target.root else { return }
    isWorkspaceBusy = true
    archivingFolder = folder
    defer {
      isWorkspaceBusy = false
      archivingFolder = nil
    }
    if selectedFolder == folder {
      chat.workspaceChanged(folder: nil, emptyText: nil)
      await terminals.workspaceChanged(folder: nil)
    }
    let drafts = await chat.stopTabs(in: folder)
    await terminals.stopTabs(in: folder)
    if let failure = await workspace.archive(URL(filePath: folder), daemon.storeID) {
      let isStillSelected = selectedFolder == folder
      if isStillSelected { chat.workspaceChanged(folder: folder, emptyText: nil) }
      chat.restoreTabs(in: folder, drafts: drafts)
      terminals.restoreTabs(in: folder)
      if isStillSelected { await terminals.workspaceChanged(folder: folder) }
      workspaceFailed(title: "Couldn't archive the workspace", text: failure)
      return
    }
    chat.forgetTabs(in: folder)
    await terminals.forgetTabs(in: folder)
    archivedSessionIDs.formUnion(sessions.filter { $0.root == folder }.map(\.id) + [target.id])
    if selectedFolder == folder {
      selectedSession = nil
      resetFeed()
      startWatching()
    }
    await loadSessions()
  }

  func viewDisappeared() {
    isShown = false
    refreshGeneration += 1
    functionChanges?.viewDisappeared()
    replyCollapsed()
    watchTask?.cancel()
    watchGeneration += 1
    sessionsGeneration += 1
    workspaceRootsTask?.cancel()
    workspaceRootsGeneration += 1
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

  func sidebarToggleTapped() {
    $isSidebarHidden.withLock { $0.toggle() }
  }

  func rightPaneToggleTapped() {
    $isRightPaneHidden.withLock { $0.toggle() }
    if isRightPaneHidden {
      replyCollapsed()
    } else if isStreamShown {
      follow.jumpToLatest()
    }
  }

  /// `translation` is how far the drag has moved since it began.
  func sidebarEdgeDragged(by translation: CGFloat) {
    let start = resizeStartWidth ?? sidebarColumnWidth
    resizeStartWidth = start
    let width = min(start + translation, DesignTokens.Workspace.sidebarMaxWidth, sidebarMaxDisplayedWidth)
    $sidebarWidth.withLock { $0 = max(width, DesignTokens.Workspace.sidebarMinWidth) }
  }

  /// `translation` is how far the drag has moved since it began.
  func chatEdgeDragged(by translation: CGFloat) {
    let start = resizeStartWidth ?? chatColumnWidth
    resizeStartWidth = start
    let width = min(start + translation, max(chatMaxWidth, start))
    $chatWidth.withLock { $0 = max(width, DesignTokens.Workspace.chatMinWidth) }
  }

  func edgeDragEnded() {
    resizeStartWidth = nil
  }

  func sidebarEdgeDoubleClicked() {
    $sidebarWidth.withLock { $0 = DesignTokens.Workspace.sidebarWidth }
  }

  func chatEdgeDoubleClicked() {
    $chatWidth.withLock { $0 = DesignTokens.Workspace.chatWidth }
  }

  func rightPaneSelected(_ pane: RightPane) {
    guard pane != rightPane else { return }
    rightPane = pane
    switch pane {
    case .stream: follow.jumpToLatest()
    case .terminals: replyCollapsed()
    }
  }

  /// ⌘W closes the focused terminal's tab while Terminals shows, otherwise the chat's.
  func closeShortcutPressed() async {
    if isRightPaneShown, rightPane == .terminals, terminals.hasKeyboardFocus {
      await terminals.closeShortcutPressed()
    } else {
      await chat.closeShortcutPressed()
    }
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

  func taskHeadingMeasured(height: CGFloat) {
    guard taskHeadingHeight != height else { return }
    taskHeadingHeight = height
    recalculateFileHeaderOffsets()
  }

  func fileHeaderMeasured(height: CGFloat) {
    guard fileHeaderHeight != height else { return }
    fileHeaderHeight = height
    recalculateFileHeaderOffsets()
  }

  func cardMoved(_ row: FileChangeRow, in section: FeedSection, frame: CGRect) {
    cardFrames[row.id] = (row, section, frame)
    updateFileHeaderOffset(for: row, in: section, frame: frame)
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
    cardFrames[row.id] = nil
    fileHeaderOffsets[row.id] = nil
  }

  // MARK: - Private Helpers

  private enum QueuedQuestion {
    case here
    case elsewhere(sessionID: String)
  }

  private func workspaceName(for sessionID: String) -> String? {
    (sessions[id: sessionID] ?? selectedSession.flatMap { $0.id == sessionID ? $0 : nil }).map(rowName)
  }

  nonisolated static func normalizedFolder(_ root: String) -> String {
    URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private struct ChatWorkspace: Equatable {
    var folder: String?
    var emptyText: String?
  }

  private func chatWorkspaceMayHaveChanged() {
    guard selectedSession != nil || chat.folder == nil else { return }
    let workspace = ChatWorkspace(folder: selectedFolder, emptyText: chatEmptyText)
    guard workspace != chatWorkspace else { return }
    chatWorkspace = workspace
    chat.workspaceChanged(folder: workspace.folder, emptyText: workspace.emptyText)
    Task { [terminals] in await terminals.workspaceChanged(folder: workspace.folder) }
  }

  private func recalculateFileHeaderOffsets() {
    for (row, section, frame) in cardFrames.values {
      updateFileHeaderOffset(for: row, in: section, frame: frame)
    }
  }

  private func updateFileHeaderOffset(for row: FileChangeRow, in section: FeedSection, frame: CGRect) {
    let stickyTop = section.heading == nil ? 0 : taskHeadingHeight
    let offset = min(max(stickyTop - frame.minY, 0), max(frame.height - fileHeaderHeight, 0))
    guard offset != fileHeaderOffset(for: row) else { return }
    fileHeaderOffsets[row.id] = offset == 0 ? nil : offset
  }

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
    if let outgoing = selectedSession {
      instantAsk.captureDeselected(outgoing.id)
      if let composer = askAgent, composer.sessionID == outgoing.id {
        composer.agentConnectionChanged(.disconnected(reason: nil))
      }
    }
    selectedSession = session
    awaitsFreshSnapshot = false
    pendingReadiness = nil
    bindingMovedWhileAwaitingSnapshot = false
    resetFeed()
    startWatching()
    return true
  }

  private func loadWorkspaceRoots() {
    workspaceRootsTask?.cancel()
    workspaceRootsGeneration += 1
    let generation = workspaceRootsGeneration
    let workspace = workspace
    workspaceRootsTask = Task { [weak self] in
      let roots = await workspace.roots()
      guard let self, !Task.isCancelled, isShown, generation == workspaceRootsGeneration else { return }
      workspaceRoots = roots
    }
  }

  /// Busy only until the Setup tab names the new workspace (or its command ends): the setup
  /// script keeps running in that tab while the window switches to it.
  private func createWorkspace(in repository: URL) async {
    isWorkspaceBusy = true
    $isRightPaneHidden.withLock { $0 = false }
    rightPaneSelected(.terminals)
    let selectionGeneration = userSessionSelectionGeneration
    let roots: WorkspaceRoots
    if let workspaceRoots { roots = workspaceRoots } else { roots = await workspace.roots() }
    let folder = await terminals.newWorkspaceStarted(
      repository: repository, store: daemon.storeID, managedRoot: URL(filePath: roots.managed))
    isWorkspaceBusy = false
    if let folder {
      await loadSessions(preferring: userSessionSelectionGeneration == selectionGeneration ? folder : nil)
    }
  }

  private func workspaceFailed(title: String, text: String, detail: String? = nil) {
    workspaceFailureTitle = title
    workspaceFailureText = text
    workspaceFailureDetail = detail
    isWorkspaceFailurePresented = true
  }

  private func reloadSessions() async {
    guard !isReloading else {
      isReloadQueued = true
      return
    }
    isReloading = true
    defer { isReloading = false }
    repeat {
      isReloadQueued = false
      await loadSessions()
    } while isReloadQueued && isShown
  }

  private func loadSessions(preferring preferredRoot: String? = nil) async {
    if let preferredRoot { pendingPreferredRoot = Self.normalizedFolder(preferredRoot) }
    sessionsGeneration += 1
    refreshGeneration += 1
    let generation = sessionsGeneration
    let refresh = refreshGeneration
    let daemon = daemon
    do {
      let descriptor = try await daemon.discover()
      async let captureReply = Self.captures(daemon, descriptor, date)
      let summaries = try await daemon.sessions(descriptor).filter { !$0.removed }
      let (captures, checkedAt) = await captureReply
      guard generation == sessionsGeneration else {
        if refresh == refreshGeneration { capturesArrivedWithoutSessions(captures, checkedAt: checkedAt) }
        return
      }
      let snapshot = captureResultArrived(captures, checkedAt: checkedAt)
      let capturesByID = Dictionary(snapshot.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
      let previous = sessions
      let selected = selectedSession
      sessions = IdentifiedArray(
        uniqueElements: summaries.map { summary in
          var option = SessionOption(
            id: summary.id, label: summary.id, agentConnection: summary.agentConnection,
            readinessSeq: summary.durableSeq, capture: capturesByID[summary.id], naming: summary.naming)
          let known = selected?.id == summary.id ? selected : previous[id: summary.id]
          option.root = known?.root
          if let known, known.readinessSeq > summary.durableSeq {
            option.agentConnection = known.agentConnection
            option.readinessSeq = known.readinessSeq
          }
          return option
        }
      )
      let listedIDs = Set(summaries.map(\.id))
      let captureOnly = snapshot.filter { !listedIDs.contains($0.sessionID) }
      let captureLabels = Self.uniqueLabels(captureOnly.map {
        (id: $0.sessionID, label: URL(fileURLWithPath: $0.root).lastPathComponent)
      })
      for capture in captureOnly {
        sessions.append(
          SessionOption(
            id: capture.sessionID, label: captureLabels[capture.sessionID] ?? capture.sessionID,
            root: Self.normalizedFolder(capture.root), capture: capture, hasHistory: false))
      }
      sessionsError = nil
      hasLoadedSessions = true
      awaitsFreshSnapshot = false
      let askSessionIDs = instantAsk.pending.map(\.sessionID) + instantAsk.relayRuns.values.map(\.sessionID)
      for sessionID in Set(askSessionIDs) where sessions[id: sessionID] == nil {
        instantAsk.captureDeleted(sessionID)
      }
      if bindingMovedWhileAwaitingSnapshot {
        bindingMovedWhileAwaitingSnapshot = false
        Task { [weak self] in await self?.loadSessions() }
      }
      if let pending = pendingReadiness {
        pendingReadiness = nil
        if let listed = sessions[id: selectedSession?.id ?? ""], pending.seq > listed.readinessSeq {
          watchedReadinessChanged(pending.state, seq: pending.seq)
        }
      }
      if let selectedID = selectedSession?.id {
        if let listed = sessions[id: selectedID] {
          let historyChanged = selectedSession?.hasHistory != listed.hasHistory
          selectedSession?.agentConnection = listed.agentConnection
          selectedSession?.readinessSeq = listed.readinessSeq
          selectedSession?.capture = listed.capture
          selectedSession?.hasHistory = listed.hasHistory
          selectedSession?.naming = listed.naming
          if !listed.hasHistory {
            selectedSession?.label = listed.label
            selectedSession?.root = listed.root
          }
          if historyChanged {
            if !listed.hasHistory { resetFeed() }
            startWatching()
          }
        } else {
          selectedSession?.agentConnection = .disconnected(reason: nil)
          selectedSession?.capture = nil
        }
      }
      reply?.captureChanged(selectedSession?.capture)
      if let composer = askAgent {
        let isWatched = composer.sessionID == selectedSession?.id
        composer.agentConnectionChanged(
          isWatched ? sessions[id: composer.sessionID]?.agentConnection ?? .disconnected(reason: nil) : .disconnected(reason: nil))
        composer.captureChanged(
          CaptureStatus(availability: captureAvailability, capture: sessions[id: composer.sessionID]?.capture),
          route: askRoute(composer.sessionID))
      }
      if selectedSession == nil, sessions.count == 1,
        !Self.isArchived(sessions[0]), !archivedSessionIDs.contains(sessions[0].id) {
        _ = select(sessions[0].id)
      }
      await withTaskGroup(of: (String, SessionStarted?).self) { group in
        for summary in summaries where sessions[id: summary.id]?.root == nil {
          group.addTask { (summary.id, try? await daemon.sessionStart(descriptor, summary.id)) }
        }
        for await (id, start) in group {
          guard generation == sessionsGeneration else { return }
          if let start {
            let root = Self.normalizedFolder(start.root)
            sessions[id: id]?.root = root
            if selectedSession?.id == id { selectedSession?.root = root }
          }
        }
      }
      if selectedSession == nil, let folder = chat.folder,
        let session = sessions.first(where: { $0.root == folder }) {
        _ = select(session.id)
      }
      if let pendingPreferredRoot, generation == sessionsGeneration,
        let session = snapshot.current(in: pendingPreferredRoot).flatMap({ sessions[id: $0.sessionID] })
          ?? sessions.first(where: { $0.root == pendingPreferredRoot }) {
        _ = select(session.id)
        self.pendingPreferredRoot = nil
      }
    } catch {
      guard generation == sessionsGeneration else {
        if refresh == refreshGeneration { captureRefreshFailed() }
        return
      }
      if !sessions.isEmpty && sessionsError == nil {
        captureRefreshFailed()
        return
      }
      sessions = []
      captureRefreshFailed()
      hasLoadedSessions = true
      sessionsError = error is DescriptorError
        ? "The Slipstream daemon isn't running"
        : "Couldn't reach the Slipstream daemon"
    }
  }

  /// An archived workspace's folder is gone, so it is never picked for the user.
  private static func isArchived(_ session: SessionOption) -> Bool {
    session.capture?.state == .stopped && session.capture?.reason == "archived"
  }

  private func captureResultArrived(_ result: Result<CaptureList?, any Error>, checkedAt: Date) -> [CaptureSummary] {
    switch result {
    case .success(let list?):
      captureAvailability = .available(checkedAt: checkedAt)
      listedCaptureSessionIDs = listedCaptureSessionIDs(list.captures)
      chat.capturesArrived(list.captures)
      return list.captures
    case .success(nil):
      captureAvailability = .unavailableFromReader
      chat.capturesArrived(nil)
      return []
    case .failure:
      captureAvailability = .failed
      chat.capturesArrived(nil)
      return []
    }
  }

  private func capturesArrivedWithoutSessions(_ result: Result<CaptureList?, any Error>, checkedAt: Date) {
    let snapshot = captureResultArrived(result, checkedAt: checkedAt)
    let capturesByID = Dictionary(snapshot.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
    for id in sessions.ids { sessions[id: id]?.capture = capturesByID[id] }
    let captureOnly = snapshot.filter { sessions[id: $0.sessionID] == nil }
    let labels = Self.uniqueLabels(captureOnly.map {
      (id: $0.sessionID, label: URL(fileURLWithPath: $0.root).lastPathComponent)
    })
    for capture in captureOnly {
      sessions.append(
        SessionOption(
          id: capture.sessionID, label: labels[capture.sessionID] ?? capture.sessionID,
          root: Self.normalizedFolder(capture.root), capture: capture, hasHistory: false))
    }
    if let selectedID = selectedSession?.id { selectedSession?.capture = capturesByID[selectedID] }
    reply?.captureChanged(selectedSession?.capture)
    if let composer = askAgent {
      composer.captureChanged(
        CaptureStatus(availability: captureAvailability, capture: capturesByID[composer.sessionID]),
        route: askRoute(composer.sessionID))
    }
  }

  private func captureRefreshFailed() {
    captureAvailability = .failed
    chat.capturesArrived(nil)
    reply?.captureChanged(nil)
    if let composer = askAgent {
      composer.captureChanged(CaptureStatus(availability: .failed, capture: nil), route: askRoute(composer.sessionID))
    }
  }

  private func askRoute(_ sessionID: String) -> AskRoute {
    sessions[id: sessionID]?.root.map(chat.askRoute(forFolder:)) ?? .outside
  }

  private func askRouteChanged() {
    guard let composer = askAgent else { return }
    composer.routeChanged(askRoute(composer.sessionID))
  }

  /// New questions on the selected capture still being answered, shown as bars at their lines.
  private var pendingRoots: IdentifiedArrayOf<PendingAsk> {
    instantAsk.pending.filter { entry in
      entry.replyToQuestionID == nil && entry.storeID == daemon.storeID && entry.sessionID == selectedSession?.id
    }
  }

  private func replyOpened(on thread: QuestionThread) {
    guard let sessionID = selectedSession?.id else { return }
    let key = QuestionThreadKey(storeID: daemon.storeID, sessionID: sessionID, rootQuestionID: thread.id)
    reply = withDependencies(from: self) {
      QuestionThreadPageModel(
        key: key, thread: thread, bindingGeneration: selectedSession?.capture?.binding?.generation,
        folder: selectedSession?.root, workspaceName: { [weak self] id in self?.workspaceName(for: id) ?? id },
        instantAsk: instantAsk)
    }
    replyBarFrame = barFrames[thread.id] ?? .zero
    isReplyBarVisible = barFrames[thread.id] != nil
  }

  private func startWatching() {
    watchTask?.cancel()
    watchGeneration += 1
    guard let sessionID = selectedSession?.id, selectedSession?.hasHistory == true else {
      connection = .idle
      return
    }
    let generation = watchGeneration
    connection = .connecting
    let after = lastAppliedSeq
    if after == .zero { replayEndSeq = selectedSession?.readinessSeq ?? .zero }
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
      Task { [instantAsk, storeID = daemon.storeID] in await instantAsk.daemonConnected(storeID: storeID) }
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
    let isReadinessEvent: Bool
    if case .agentConnection = event.payload {
      isReadinessEvent = true
    } else {
      isReadinessEvent = false
    }
    let shouldRefreshCaptureSnapshot = event.seq > (selectedSession?.readinessSeq ?? .zero)
      && ((selectedSession?.agentConnection == .disconnected(reason: "capture_not_live") && !isReadinessEvent)
        || event.payload == .sessionResumed
        || event.payload == .agentConnection(.disconnected(reason: "capture_not_live")))
    let bindingMoved = event.seq > (selectedSession?.readinessSeq ?? .zero)
      && Self.changesBinding(event.payload, selectedSession?.capture?.binding)
    if bindingMoved, awaitsFreshSnapshot { bindingMovedWhileAwaitingSnapshot = true }
    let shouldRefreshBinding = bindingMoved && !awaitsFreshSnapshot
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
      let threadsBefore = questionThreads
      questionThreads.apply(event)
      if questionThreads != threadsBefore { threadsFolded() }
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
      sections.append(FeedSection(id: event.seq, heading: nil))
      append(.marker(FeedMarker(id: event.seq, text: "Capture restarting")))
      questionThreads.apply(event)
      openReplyUpdated()
      askAgent?.questionsUpdated(questionThreads.threads)
    case .unsupported(let type):
      append(.marker(FeedMarker(id: event.seq, text: "Unsupported event: \(type)")))
    case .questionQueued, .questionAnswered, .questionExchangeRecorded:
      let previousTurnCount = previousTurnCount(beforeApplying: event)
      questionThreads.apply(event)
      shareQueuedFollowUp(event, previousTurnCount: previousTurnCount)
      threadsFolded()
      if follow == .following { scrollToLatestRequest += 1 }
    case .questionRelayUpdated:
      questionThreads.apply(event)
      threadsFolded()
    case .questionDispatchAttempted, .agentUnlinked:
      questionThreads.apply(event)
      openReplyUpdated()
    case .agentConnection(let state):
      watchedAgentConnectionReported(state, seq: event.seq)
    case .recordedWithoutRow:
      if event.type == "slipstream.capture.baseline.completed.v1", baselineCompletedSeq == nil {
        baselineCompletedSeq = event.seq
      }
    case .sessionStarted:
      break
    }
    if shouldRefreshCaptureSnapshot, selectedSession != nil {
      watchedReadinessChanged(.disconnected(reason: nil), seq: event.seq)
      Task { [weak self] in await self?.loadSessions() }
    } else if shouldRefreshBinding {
      Task { [weak self] in await self?.loadSessions() }
    }
    let wasReplaying = isReplaying
    lastAppliedSeq = event.seq
    if wasReplaying, !isReplaying { threadsFolded() }
    return true
  }

  private var isReplaying: Bool { lastAppliedSeq < replayEndSeq }

  private func isLit(_ session: SessionOption) -> Bool {
    isHighlighted(session) || isSelected(session)
  }

  private func captureStatus(of session: SessionOption) -> CaptureStatus {
    CaptureStatus(availability: captureAvailability, capture: session.capture)
  }

  /// One row per folder, so a recreated folder's old capture is hidden. Unknown capture state
  /// hides nothing.
  /// Only workspaces `slipstream workspace create` made keep a row while paused.
  private func isListed(_ session: SessionOption) -> Bool {
    if session.id == selectedSession?.id { return true }
    let status = captureStatus(of: session)
    guard case .available = status.availability else { return true }
    guard !status.isPaused || isArchivable(session) else { return false }
    return !status.isInactive && listedCaptureSessionIDs.contains(session.id)
  }

  /// The capture `current(in:)` picks for each folder. A paused folder that no longer exists has no
  /// row.
  private func listedCaptureSessionIDs(_ captures: [CaptureSummary]) -> Set<String> {
    let byFolder = Dictionary(grouping: captures) { Self.normalizedFolder($0.root) }
    return Set(byFolder.compactMap { folder, captures in
      guard let current = captures.current(in: folder) else { return nil }
      return current.isPaused && !terminalRuntime.folderExists(current.root) ? nil : current.sessionID
    })
  }

  private static func captures(
    _ daemon: DaemonClient, _ descriptor: DaemonDescriptor, _ date: DateGenerator
  ) async -> (Result<CaptureList?, any Error>, Date) {
    do { return (.success(try await daemon.listCaptures(descriptor)), date.now) } catch { return (.failure(error), date.now) }
  }

  /// The link icon and Ask notice read the capture's binding, which these events move on —
  /// including a chat linked from the terminal.
  private static func changesBinding(_ payload: EventPayload, _ binding: CaptureBinding?) -> Bool {
    switch payload {
    case .agentConnection(.connected): binding?.state != .connected
    case .agentConnection(.setupPending): binding?.state != .setupPending
    case .agentUnlinked: binding?.isLive == true
    default: false
    }
  }

  private func watchedAgentConnectionReported(_ reported: AgentConnection, seq: Seq) {
    guard let watched = selectedSession, seq > watched.readinessSeq else { return }
    let isLiveReadiness = switch reported {
    case .connected, .setupPending, .disconnected(reason: "no_agent"): true
    default: false
    }
    if awaitsFreshSnapshot, isLiveReadiness {
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

  private func openReplyUpdated() {
    guard let reply, let thread = questionThreads.threads[id: reply.key.rootQuestionID] else { return }
    reply.threadUpdated(thread)
  }

  /// A new question's panel moves from its request id to the recorded thread once its answer folds in.
  private func threadsFolded() {
    if let session = selectedSession {
      instantAsk.threadsFolded(
        storeID: daemon.storeID, sessionID: session.id, folder: session.root, isReplaying: isReplaying,
        threads: questionThreads.threads)
    }
    if let reply, !reply.isDismissed,
      let thread = questionThreads.threads.first(where: { $0.turns.first?.requestID == reply.key.rootQuestionID }) {
      let (frame, isBarVisible) = (replyBarFrame, isReplyBarVisible)
      replyOpened(on: thread)
      if barFrames[thread.id] == nil { (replyBarFrame, isReplyBarVisible) = (frame, isBarVisible) }
    }
    openReplyUpdated()
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

  private static func uniqueLabels(_ labels: [(id: String, label: String)]) -> [String: String] {
    let counts = Dictionary(labels.map { ($0.label, 1) }, uniquingKeysWith: +)
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

  /// The widest the chat can be with the stream at its minimum beside it.
  private var chatMaxWidth: CGFloat {
    viewport.width - (isSidebarShown ? sidebarColumnWidth : 0) - DesignTokens.FeedPane.width
  }

  private var sidebarMaxDisplayedWidth: CGFloat {
    guard viewport.width > 0 else { return DesignTokens.Workspace.sidebarMaxWidth }
    let rightPaneWidth = isRightPaneShown ? DesignTokens.FeedPane.width : 0
    return max(
      DesignTokens.Workspace.sidebarMinWidth,
      viewport.width - DesignTokens.Workspace.chatMinWidth - rightPaneWidth)
  }

  private func replyCollapsed() {
    reply?.dismissed()
    reply = nil
    isReplyBarVisible = false
  }

  private func status(of entry: PendingAsk) -> QuestionBarStatus {
    switch entry.state {
    case .answering, .recording, .recorded: .waiting
    case .couldntAnswer, .couldntRecord: .notDelivered
    }
  }

  private func status(of thread: QuestionThread) -> QuestionBarStatus {
    let sessionID = selectedSession?.id ?? ""
    let hasUnread = thread.turns.contains { turn in
      [turn.answer?.seq, turn.relays.last?.report?.seq].contains { seq in
        seq.map { !readAnswers.contains(AnswerReadMarker(storeID: daemon.storeID, sessionID: sessionID, seq: $0)) }
          ?? false
      }
    }
    if hasUnread { return .newReply }
    if let entry = instantAsk.pending.first(where: {
      $0.storeID == daemon.storeID && $0.sessionID == selectedSession?.id
        && $0.replyToQuestionID.map { id in thread.turns.contains { $0.questionID == id } } == true
    }) {
      return status(of: entry)
    }
    let relays = thread.turns.compactMap { $0.relays.last.map(instantAsk.relayStatus) }
    if relays.contains(where: { [.sent, .pickedUp, .working, .notDoneYet, .couldntCheck].contains($0) }) { return .working }
    if thread.turns.contains(where: { $0.status == .waiting || $0.status == .resending }) { return .waiting }
    if relays.contains(where: { $0 == .notDelivered || $0 == .deliveryUnknown }) { return .notDelivered }
    if !relays.isEmpty && relays.allSatisfy({ $0 == .done }) { return .done }
    return thread.turns.last?.status == .notDelivered ? .notDelivered : .answered
  }

  private func resetFeed() {
    functionChanges?.viewDisappeared()
    functionChanges = nil
    baselineCompletedSeq = nil
    replyCollapsed()
    questionThreads = QuestionThreads()
    barFrames = [:]
    queuedQuestion = nil
    isSourceBlockVisible = false
    feedGeneration += 1
    sections = []
    newestFileID = nil
    cardContents = [:]
    cardContentOrder = []
    cardLoadGenerations = [:]
    cardFrames = [:]
    pinnedHeadings = []
    fileHeaderOffsets = [:]
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

  enum RightPane: Equatable, CaseIterable {
    case stream, terminals
  }
}
