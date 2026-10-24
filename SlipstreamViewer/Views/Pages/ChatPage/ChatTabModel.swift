import Dependencies
import Foundation
import Sharing
import SlipstreamCore

@MainActor
@Observable
final class ChatTabModel: ViewModel, Identifiable {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.agentEnvironment) var agentEnvironment
  @ObservationIgnored @Dependency(\.agentProcess) var agentProcess
  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.transcripts) var transcripts
  @ObservationIgnored @Dependency(\.date) var date
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard
  @ObservationIgnored @Dependency(\.timeZone) var timeZone
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Shared State

  @ObservationIgnored @Shared var record: ChatTabRecord

  // MARK: - Initialization

  init(record: Shared<ChatTabRecord>, needsHistory: Bool) {
    _record = record
    id = record.wrappedValue.id
    self.needsHistory = needsHistory
  }

  // MARK: - Properties

  let id: UUID
  var title = ChatTabModel.newChatTitle
  var projection = TranscriptProjection()
  var draft = ""
  var errorText: String?
  var isWorking: Bool { activeTurn != nil }
  var isTitleBold: Bool { record.isWaiting }
  var showsSpinner: Bool { isWorking }
  var showsStop: Bool { isWorking }
  var isPickerEnabled: Bool { !isWorking }
  /// Slipstream can link a chat only once it has a transcript.
  private(set) var hasSentMessage = false

  /// Called once each time a turn ends, so the page can mark the tab waiting.
  @ObservationIgnored var onTurnEnded: () -> Void = {}

  private var activeTurn: ActiveTurn?
  private var toggledItemIDs: Set<String> = []
  private var isClosed = false
  private var now = Date.distantPast
  private var needsHistory: Bool
  /// The process predates this chat's link, so it is dropped when the running turn ends.
  @ObservationIgnored private var reloadWhenIdle = false
  @ObservationIgnored private var handle: AgentProcessHandle?
  @ObservationIgnored private var follower: Task<Void, Never>?
  @ObservationIgnored private var titleRefresh: Task<Void, Never>?
  @ObservationIgnored private var starting: [Task<Bool, Never>] = []
  /// Shutdowns still running, so quitting can wait for every process to be gone.
  @ObservationIgnored private var retiring: [Task<Void, Never>] = []
  @ObservationIgnored private var generation = 0

  // MARK: - Display Text

  var workingText: String? {
    guard let activeTurn else { return nil }
    let working = Self.durationText(seconds: now.timeIntervalSince(activeTurn.startedAt))
    let quiet = Self.durationText(seconds: now.timeIntervalSince(activeTurn.lastOutputAt))
    return "Working \(working) · last output \(quiet) ago"
  }

  let thinkingText = "Thinking"
  let closeAccessibilityLabel = "Close chat"
  let copyAccessibilityLabel = "Copy reply"

  var pickerText: String {
    Self.pickerText(model: record.model, effort: record.effort)
  }

  static func pickerText(model: String, effort: ChatEffort) -> String {
    let name = ChatModelChoice.all.first { $0.id == model }?.name ?? model
    return "\(name) \(effort.name)"
  }

  // MARK: - View Helpers

  func rowText(for item: TranscriptItem) -> String {
    switch item.kind {
    case .userMessage(let text), .reply(let text), .thinking(let text):
      return text.trimmingCharacters(in: .newlines)
    case .toolCall(let name, let target, let status, _):
      let (running, ran) = Self.verbs(Self.toolKind(name))
      let subject = "`\(target ?? name)`"
      switch status {
      case .running: return "\(running) \(subject)"
      case .done: return "\(ran) \(subject)"
      case .failed: return "\(ran) \(subject) · failed"
      case .stopped: return "\(ran) \(subject) · stopped"
      }
    case .turnFooter(let ending, let duration, let time):
      let text = "\(Self.durationText(seconds: Double(duration.components.seconds))) · \(timeText(time))"
      switch ending {
      case .completed: return text
      case .failed: return "Failed · \(text)"
      case .stopped: return "Stopped · \(text)"
      }
    case .gap:
      return Self.gapText
    }
  }

  func detailText(for item: TranscriptItem) -> String? {
    guard case .toolCall(_, _, _, let detail) = item.kind else { return nil }
    return detail
  }

  func toolKind(for item: TranscriptItem) -> ChatToolKind? {
    guard case .toolCall(let name, _, _, _) = item.kind else { return nil }
    return Self.toolKind(name)
  }

  func isRunning(_ item: TranscriptItem) -> Bool {
    if case .toolCall(_, _, .running, _) = item.kind { true } else { false }
  }

  /// Thinking starts open and tool calls start closed.
  func isExpanded(_ item: TranscriptItem) -> Bool {
    let startsOpen = if case .thinking = item.kind { true } else { false }
    return startsOpen != toggledItemIDs.contains(item.id)
  }

  enum MarkdownBlock: Equatable {
    case prose(AttributedString)
    case code(String)
  }

  /// Fenced code blocks come out whole; the prose between them gets inline markdown only.
  static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var lines: [Substring] = []
    var isCode = false
    func flush() {
      defer { lines = [] }
      let joined = lines.joined(separator: "\n")
      if isCode {
        blocks.append(.code(joined))
        return
      }
      let prose = joined.trimmingCharacters(in: .newlines)
      guard !prose.isEmpty else { return }
      blocks.append(.prose(inlineMarkdown(prose)))
    }
    // A fence closes only on a bare run of at least as many backticks as opened it.
    var fence = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let ticks = trimmed.prefix { $0 == "`" }.count
      if !isCode, ticks >= 3, !trimmed.dropFirst(ticks).contains("`") {
        flush()
        isCode = true
        fence = ticks
      } else if isCode, ticks >= fence, ticks == trimmed.count {
        flush()
        isCode = false
      } else {
        lines.append(line)
      }
    }
    if isCode || !lines.isEmpty { flush() }
    return blocks
  }

  func rowMarkdown(for item: TranscriptItem) -> AttributedString {
    Self.inlineMarkdown(rowText(for: item))
  }

  private static func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }

  // MARK: - Page Actions

  func shown() async {
    guard needsHistory, handle == nil, activeTurn == nil else { return }
    await loadHistory()
  }

  func send() async {
    let sentDraft = draft
    let text = sentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, activeTurn == nil else { return }
    await awaitRetired()
    guard activeTurn == nil, !isClosed else { return }
    errorText = nil
    now = date.now
    let turn = ActiveTurn(id: uuid(), startedAt: now, lastOutputAt: now)
    activeTurn = turn
    if handle == nil, await !start() {
      if activeTurn?.id == turn.id { activeTurn = nil }
      return
    }
    guard let handle, activeTurn?.id == turn.id else { return }
    let itemID = uuid().uuidString
    projection.userSent(text, id: itemID)
    do {
      try await handle.write(ClaudeInvocation.userMessage(text))
    } catch {
      projection.removeUserMessage(id: itemID)
      guard activeTurn?.id == turn.id else { return }
      activeTurn = nil
      errorText = Self.sendFailedText
      return
    }
    if draft == sentDraft { draft = "" }
    if activeTurn?.id == turn.id {
      $record.withLock { $0.isWaiting = false }
    }
  }

  /// Asks Claude to stop, and gives up on it after the deadline.
  func stop() async {
    guard var turn = activeTurn, !turn.isStopPressed else { return }
    turn.isStopPressed = true
    activeTurn = turn
    guard let handle else {
      generation += 1
      endTurn(.stopped, duration: duration(of: turn))
      return
    }
    // Not awaited: a write blocked on a full pipe must not hold back the deadline.
    let interrupt = ClaudeInvocation.interrupt(requestID: uuid().uuidString)
    Task { try? await handle.write(interrupt) }
    try? await clock.sleep(for: Self.stopDeadline)
    guard activeTurn?.id == turn.id else { return }
    let duration = duration(of: turn)
    follower?.cancel()
    // Only this process: a stale launch from an earlier turn mustn't hold up this footer.
    await retireProcess()?.value
    guard activeTurn?.id == turn.id else { return }
    endTurn(.stopped, duration: duration)
  }

  /// Relaunches with `--resume` and reloads history. Nothing is resent.
  func tryAgain() async {
    guard !isWorking else { return }
    errorText = nil
    follower?.cancel()
    retireProcess()
    let generation = generation
    await awaitRetired()
    guard generation == self.generation, await loadHistory(), handle == nil, !isWorking else { return }
    _ = await start()
  }

  /// The new choice applies from the next send.
  func choiceSelected(model: String, effort: ChatEffort) async {
    guard !isWorking else { return }
    $record.withLock {
      $0.model = model
      $0.effort = effort
    }
    await shutdown()
    await shown()
  }

  func itemToggled(_ item: TranscriptItem) {
    if toggledItemIDs.remove(item.id) == nil { toggledItemIDs.insert(item.id) }
  }

  func copyTapped(_ footer: TranscriptItem) {
    pasteboard.copy(projection.replyText(endingAt: footer.id))
  }

  func clockTicked() {
    guard isWorking else { return }
    now = date.now
  }

  /// A running Claude doesn't load the hook and answer tool a link installs, so a process that
  /// predates the link is dropped once idle. The next send resumes in a fresh one.
  func streamLinked() {
    guard handle != nil || !starting.isEmpty else { return }
    if isWorking {
      reloadWhenIdle = true
    } else {
      follower?.cancel()
      retireProcess()
    }
  }

  /// Shuts down for good: a send still waiting on an earlier shutdown launches nothing.
  func close() async {
    isClosed = true
    await shutdown()
  }

  /// Stops the process and waits for it to exit. Its late events are dropped.
  func shutdown() async {
    activeTurn = nil
    follower?.cancel()
    retireProcess()
    await awaitRetired()
  }

  // MARK: - Private Helpers

  private struct ActiveTurn {
    let id: UUID
    let startedAt: Date
    var lastOutputAt: Date
    var isStopPressed = false
  }

  private struct Failure: Error {
    let message: String
  }

  private static let stopDeadline = Duration.seconds(10)
  private static let newChatTitle = "New chat"
  private static let cantStartText = "Claude couldn't start"
  private static let unreadableText = "Couldn't read this chat's history from Claude"
  private static let sendFailedText = "Couldn't send your message to Claude"
  private static let turnFailedText = "Claude couldn't finish this turn"
  private static let crashedText = "Claude stopped unexpectedly"
  private static let gapText = "Part of this conversation couldn't be shown"

  /// Tracked, so a shutdown can wait for a launch that is still on its way. The generation is
  /// taken before the task is scheduled, so a shutdown in between still invalidates it.
  private func start() async -> Bool {
    generation += 1
    let generation = generation
    let task = Task { await launchProcess(generation: generation) }
    starting.append(task)
    defer { starting.removeAll { $0 == task } }
    return await task.value
  }

  private func launchProcess(generation: Int) async -> Bool {
    do throws(Failure) {
      let (environment, lookup) = try await readTranscript()
      guard generation == self.generation else { return false }
      if needsHistory { showHistory(lookup) }
      let session: ClaudeSessionStart = lookup == .notFound ? .new(id) : .resume(id)
      let launch = AgentLaunch(
        executable: environment.claudePath,
        arguments: ClaudeInvocation.arguments(model: record.model, effort: record.effort.rawValue, session: session),
        environment: environment.variables,
        directory: record.folder
      )
      let handle: AgentProcessHandle
      do {
        handle = try await agentProcess.launch(launch)
      } catch {
        throw Failure(message: Self.cantStartText)
      }
      guard generation == self.generation else {
        retire(handle)
        return false
      }
      self.handle = handle
      follower = Task { [weak self] in
        for await event in handle.events {
          self?.received(event, from: handle, generation: generation)
        }
      }
      return true
    } catch {
      if generation == self.generation { errorText = error.message }
      return false
    }
  }

  /// True when the history was shown.
  @discardableResult
  private func loadHistory() async -> Bool {
    generation += 1
    let generation = generation
    do throws(Failure) {
      let (_, lookup) = try await readTranscript()
      guard generation == self.generation else { return false }
      showHistory(lookup)
      return true
    } catch {
      if generation == self.generation { errorText = error.message }
      return false
    }
  }

  private func showHistory(_ lookup: TranscriptLookup) {
    needsHistory = false
    let lines = if case .found(let lines) = lookup { lines } else { [AgentLine]() }
    projection = .history(lines)
    title = Self.title(lines)
    if !lines.isEmpty { hasSentMessage = true }
  }

  /// Drops the process: its late events are ignored, and its shutdown runs until done.
  @discardableResult
  private func retireProcess() -> Task<Void, Never>? {
    generation += 1
    reloadWhenIdle = false
    follower = nil
    defer { handle = nil }
    return handle.map(retire)
  }

  @discardableResult
  private func retire(_ handle: AgentProcessHandle) -> Task<Void, Never> {
    let task = Task { await handle.shutdown() }
    retiring.append(task)
    return task
  }

  /// A stale start retires its process before finishing, so starts are drained first.
  private func awaitRetired() async {
    while true {
      if let task = starting.first {
        _ = await task.value
        starting.removeAll { $0 == task }
      } else if let task = retiring.first {
        await task.value
        retiring.removeAll { $0 == task }
      } else {
        return
      }
    }
  }

  private func readTranscript() async throws(Failure) -> (AgentEnvironment, TranscriptLookup) {
    let environment: AgentEnvironment
    do {
      environment = try await agentEnvironment.resolve()
    } catch {
      throw Failure(message: (error as? AgentEnvironmentError)?.message ?? Self.cantStartText)
    }
    do {
      return (environment, try await transcripts.load(environment.configDirectory, id))
    } catch {
      throw Failure(message: Self.unreadableText)
    }
  }

  private func received(_ event: AgentProcessEvent, from handle: AgentProcessHandle, generation: Int) {
    guard generation == self.generation else { return }
    switch event {
    case .line(let data):
      outputArrived()
      received(AgentLine.decode(data), from: handle)
    case .overflow:
      outputArrived()
      received(.gap, from: handle)
    case .exited(_, let stderrTail):
      exited(stderrTail: stderrTail)
    }
  }

  private func outputArrived() {
    now = date.now
    activeTurn?.lastOutputAt = now
  }

  private func received(_ line: AgentLine, from handle: AgentProcessHandle) {
    switch line {
    case .result(let durationMs, let isError, let text):
      guard let turn = activeTurn else { return }
      let ending: TurnEnding = turn.isStopPressed ? .stopped : isError ? .failed : .completed
      if ending == .failed { errorText = text ?? Self.turnFailedText }
      endTurn(ending, duration: .milliseconds(durationMs))
    case .controlRequest(let requestID, let subtype, let input):
      // Not awaited, so a full stdin pipe can't stall the lines behind this one.
      let reply = ClaudeInvocation.reply(requestID: requestID, subtype: subtype, input: input)
      Task { try? await handle.write(reply) }
    default:
      projection.apply(line)
    }
  }

  /// The process ended on its own. A turn still running fails; the next send relaunches.
  /// Runs inside the follower, so it retires the process without cancelling the follower.
  private func exited(stderrTail: String) {
    retireProcess()
    if let turn = activeTurn, turn.isStopPressed {
      endTurn(.stopped, duration: duration(of: turn))
    } else if let turn = activeTurn {
      let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
      errorText = tail.isEmpty ? Self.crashedText : "\(Self.crashedText)\n\(tail)"
      endTurn(.failed, duration: duration(of: turn))
    }
  }

  private func endTurn(_ ending: TurnEnding, duration: Duration) {
    guard let turn = activeTurn else { return }
    activeTurn = nil
    hasSentMessage = true
    projection.endTurn(ending, duration: duration, at: date.now, id: turn.id.uuidString)
    onTurnEnded()
    if reloadWhenIdle { retireProcess() }
    titleRefresh?.cancel()
    let generation = generation
    titleRefresh = Task { [weak self] in await self?.refreshTitle(generation: generation) }
  }

  private func duration(of turn: ActiveTurn) -> Duration {
    .seconds(date.now.timeIntervalSince(turn.startedAt))
  }

  private func refreshTitle(generation: Int) async {
    guard
      case .found(let lines)? = try? await readTranscript().1,
      !Task.isCancelled,
      generation == self.generation
    else { return }
    title = Self.title(lines)
  }

  private func timeText(_ time: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: time)
  }

  private static func durationText(seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
  }

  private static func toolKind(_ tool: String) -> ChatToolKind {
    switch tool {
    case "Bash": .run
    case "Read": .read
    case "Edit", "MultiEdit", "Write": .edit
    default: .other
    }
  }

  private static func verbs(_ kind: ChatToolKind) -> (running: String, ran: String) {
    switch kind {
    case .run: ("Running", "Ran")
    case .read: ("Reading", "Read")
    case .edit: ("Editing", "Edited")
    case .other: ("Using", "Used")
    }
  }

  private static func title(_ lines: [AgentLine]) -> String {
    for line in lines.reversed() {
      if case .title(let title) = line { return title }
    }
    return newChatTitle
  }
}

enum ChatToolKind: Equatable {
  case edit, run, read, other
}
