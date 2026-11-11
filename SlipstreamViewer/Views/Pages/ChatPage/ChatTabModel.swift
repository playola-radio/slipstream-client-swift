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
  @ObservationIgnored var onReadinessChanged: () -> Void = {}
  /// Called each time a message reaches the process, so the page can link the chat while it works.
  @ObservationIgnored var onMessageSent: () -> Void = {}
  /// Called once per relay, when the agent reads it or its process ends first.
  @ObservationIgnored var onRelayDelivery: (RelayDelivery) -> Void = { _ in }

  private var activeTurn: ActiveTurn?
  private var toggledItemIDs: Set<String> = []
  private var isClosed = false
  private var now = Date.distantPast
  private var needsHistory: Bool
  /// The process predates this chat's link, so it is dropped when the running turn ends.
  @ObservationIgnored private var reloadWhenIdle = false
  @ObservationIgnored private var handle: AgentProcessHandle?
  @ObservationIgnored private var handleGeneration = 0
  /// Relays written to each launch that it hasn't echoed yet, in the order they were sent.
  @ObservationIgnored private var unreadRelays: [Int: [UUID]] = [:]
  /// Of the current launch.
  @ObservationIgnored private var echoes: Set<String> = []
  /// Sends written behind an unread relay of the current launch and not yet read.
  @ObservationIgnored private var queuedSends = 0
  @ObservationIgnored private var followers: [Int: Task<Void, Never>] = [:]
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
    case .userMessage(let text, _), .reply(let text), .thinking(let text):
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

  func relayLabel(for item: TranscriptItem) -> String? {
    guard case .userMessage(_, let relay?) = item.kind else { return nil }
    return relay.label
  }

  /// Only a relay the agent hasn't read gets a status line.
  func relayStatus(for item: TranscriptItem) -> RelayStatus? {
    guard case .userMessage(_, let relay?) = item.kind else { return nil }
    switch relay.delivery {
    case .waiting: return .waiting
    case .notDelivered: return .notDelivered
    case .pickedUp: return nil
    }
  }

  func relayStatusText(_ status: RelayStatus) -> String {
    switch status {
    case .waiting: "Waiting"
    case .notDelivered: "Not delivered"
    }
  }

  func relayStatusDetail(_ status: RelayStatus) -> String {
    switch status {
    case .waiting: "the agent will read this after its current step"
    case .notDelivered: "the chat stopped before the agent read this"
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
    let turn = beginTurn()
    if handle == nil, await !start() {
      if activeTurn?.id == turn { activeTurn = nil }
      return
    }
    guard let handle, activeTurn?.id == turn else { return }
    let itemID = uuid().uuidString
    let launch = handleGeneration
    let isQueued = hasUnreadInput
    projection.userSent(text, id: itemID)
    if isQueued { queuedSends += 1 }
    do {
      try await handle.write(ClaudeInvocation.userMessage(text))
    } catch {
      if isQueued, launch == handleGeneration { queuedSends = max(0, queuedSends - 1) }
      projection.removeUserMessage(id: itemID)
      guard activeTurn?.id == turn else { return }
      // An echo means the process is already working on a message it read for this turn.
      if activeTurn?.isEchoed == false { activeTurn = nil }
      errorText = Self.sendFailedText
      return
    }
    if draft == sentDraft { draft = "" }
    if activeTurn?.id == turn {
      $record.withLock { $0.isWaiting = false }
    }
    messageReachedProcess()
  }

  /// Writes straight away, even mid-turn: the agent reads it after its current step. The draft
  /// is left alone. Throws when nothing reached the process.
  func relay(_ message: AskRelayMessage) async throws {
    if activeTurn == nil { await awaitRetired() }
    guard !isClosed, !Task.isCancelled else { throw RelayNotWritten() }
    let startedTurn = activeTurn == nil ? beginTurn() : nil
    if handle == nil, startedTurn != nil {
      _ = await start()
    } else if handle == nil {
      for task in starting { _ = await task.value }
    }
    guard let handle, !isClosed, !Task.isCancelled else {
      if let startedTurn, activeTurn?.id == startedTurn { activeTurn = nil }
      throw RelayNotWritten()
    }
    let launch = handleGeneration
    let itemID = message.relayID.uuidString
    projection.userSent(message.text, id: itemID, relay: RelayMark(label: message.label, delivery: .waiting))
    unreadRelays[launch, default: []].append(message.relayID)
    do {
      try await handle.write(ClaudeInvocation.userMessage(message.text, uuid: message.relayID))
    } catch {
      // Already echoed or reported as unread, so it is no longer this call's to fail.
      guard unreadRelays[launch]?.contains(message.relayID) == true else { return }
      unreadRelays[launch]?.removeAll { $0 == message.relayID }
      projection.markRelay(id: itemID, delivery: .notDelivered)
      if let startedTurn, activeTurn?.id == startedTurn, activeTurn?.isEchoed == false { activeTurn = nil }
      throw RelayNotWritten()
    }
    if let startedTurn, activeTurn?.id == startedTurn {
      $record.withLock { $0.isWaiting = false }
    }
    messageReachedProcess()
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
    let launch = handleGeneration
    // Only this process: a stale launch from an earlier turn mustn't hold up this footer.
    await retireProcess()?.value
    // Its last pickups belong to this turn, so they are reported before it ends.
    await followers[launch]?.value
    guard activeTurn?.id == turn.id else { return }
    endTurn(.stopped, duration: duration)
  }

  /// Relaunches with `--resume` and reloads history. Nothing is resent.
  func tryAgain() async {
    guard !isWorking else { return }
    errorText = nil
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
    if isWorking || hasUnreadInput {
      reloadWhenIdle = true
    } else {
      retireProcess()
    }
  }

  /// Shuts down for good: a send still waiting on an earlier shutdown launches nothing.
  func close() async {
    isClosed = true
    await shutdown()
  }

  /// Stops the process and waits for it to exit. Its late events are dropped, apart from
  /// resolving its relays.
  func shutdown() async {
    activeTurn = nil
    retireProcess()
    // Taken first: a send that launches while this drains has a live follower that never ends.
    let retired = Array(followers.values)
    await awaitRetired()
    for follower in retired { await follower.value }
  }

  // MARK: - Private Helpers

  private struct ActiveTurn {
    let id: UUID
    let startedAt: Date
    var lastOutputAt: Date
    var isStopPressed = false
    /// The process has read a message for this turn.
    var isEchoed = false
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
      handleGeneration = generation
      echoes = []
      queuedSends = 0
      // Not cancelled on retire: a retired launch still resolves its relays as it winds down.
      followers[generation] = Task { [weak self] in
        for await event in handle.events {
          self?.received(event, from: handle, generation: generation)
        }
        self?.followers[generation] = nil
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
    if !lines.isEmpty {
      hasSentMessage = true
      onReadinessChanged()
    }
  }

  /// Drops the process: its late events are ignored, and its shutdown runs until done.
  @discardableResult
  private func retireProcess() -> Task<Void, Never>? {
    generation += 1
    reloadWhenIdle = false
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

  /// A retired launch only resolves its relays; everything else it says is dropped.
  private func received(_ event: AgentProcessEvent, from handle: AgentProcessHandle, generation: Int) {
    let isCurrent = generation == self.generation
    switch event {
    case .line(let data):
      let line = AgentLine.decode(data)
      let isPickup = if case .echo(let uuid) = line { relayEchoed(uuid, launch: generation) } else { false }
      guard isCurrent else { return }
      outputArrived()
      received(line, isPickup: isPickup, from: handle)
    case .overflow:
      guard isCurrent else { return }
      outputArrived()
      received(.gap, from: handle)
    case .exited(_, let stderrTail):
      if isCurrent { exited(stderrTail: stderrTail) }
      launchEnded(generation)
    }
  }

  private func relayEchoed(_ uuid: String, launch: Int) -> Bool {
    guard let relayID = UUID(uuidString: uuid), unreadRelays[launch]?.contains(relayID) == true else { return false }
    unreadRelays[launch]?.removeAll { $0 == relayID }
    projection.markRelay(id: relayID.uuidString, delivery: .pickedUp)
    onRelayDelivery(.pickedUp(relayID: relayID))
    return true
  }

  private func launchEnded(_ launch: Int) {
    for relayID in unreadRelays.removeValue(forKey: launch) ?? [] {
      projection.markRelay(id: relayID.uuidString, delivery: .notDelivered)
      onRelayDelivery(.exitedUnread(relayID: relayID))
    }
  }

  private func outputArrived() {
    now = date.now
    activeTurn?.lastOutputAt = now
  }

  private func received(_ line: AgentLine, isPickup: Bool = false, from handle: AgentProcessHandle) {
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
    case .echo(let uuid):
      guard echoes.insert(uuid).inserted else { return }
      messageReachedProcess()
      if !isPickup { queuedSends = max(0, queuedSends - 1) }
      // A message queued behind a finished or stopped turn starts a turn of its own.
      if activeTurn == nil { beginTurn() } else { activeTurn?.isEchoed = true }
    default:
      projection.apply(line)
    }
  }

  /// The process ended on its own. A turn still running fails; the next send relaunches.
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

  private func messageReachedProcess() {
    hasSentMessage = true
    onReadinessChanged()
    onMessageSent()
  }

  @discardableResult
  private func beginTurn() -> UUID {
    errorText = nil
    now = date.now
    let turn = ActiveTurn(id: uuid(), startedAt: now, lastOutputAt: now)
    activeTurn = turn
    return turn.id
  }

  private func endTurn(_ ending: TurnEnding, duration: Duration) {
    guard let turn = activeTurn else { return }
    activeTurn = nil
    projection.endTurn(ending, duration: duration, at: date.now, id: turn.id.uuidString)
    onTurnEnded()
    if reloadWhenIdle, !hasUnreadInput { retireProcess() }
    titleRefresh?.cancel()
    let generation = generation
    titleRefresh = Task { [weak self] in await self?.refreshTitle(generation: generation) }
  }

  /// A process that predates a link stays up until it has read every relay sent to it, and
  /// every send queued behind one.
  private var hasUnreadInput: Bool {
    handle != nil && (queuedSends > 0 || !(unreadRelays[handleGeneration] ?? []).isEmpty)
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

enum RelayStatus: Equatable {
  case waiting, notDelivered
}

struct AskRelayMessage: Equatable, Sendable {
  let relayID: UUID
  let text: String
  let label: String
}

enum RelayDelivery: Equatable, Sendable {
  case pickedUp(relayID: UUID)
  case exitedUnread(relayID: UUID)
}

struct RelayNotWritten: Error {}
