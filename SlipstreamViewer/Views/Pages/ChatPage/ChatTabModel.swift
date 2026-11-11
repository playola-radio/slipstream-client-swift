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
  @ObservationIgnored @Dependency(\.attachments) var attachments
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
  var attachmentAlert: String?
  var isAttachmentAlertPresented: Bool {
    get { attachmentAlert != nil }
    set { if !newValue { attachmentAlertDismissed() } }
  }
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
  /// Called once per relay, when the agent reads it or its process ends first.
  @ObservationIgnored var onRelayDelivery: (RelayDelivery) -> Void = { _ in }
  /// Whether the folder's stream is linked to this chat, as the last capture read saw it.
  @ObservationIgnored var isStreamLinked: () -> Bool = { false }

  private var activeTurn: ActiveTurn?
  private var toggledItemIDs: Set<String> = []
  private(set) var isClosed = false
  private var now = Date.distantPast
  private var needsHistory: Bool
  /// The process predates this chat's link, so it is dropped when the running turn ends.
  @ObservationIgnored private var reloadWhenIdle = false
  /// Whether the current process launched after its link was seen.
  @ObservationIgnored private var launchedLinked = false
  /// A link made since the last launch, which the last capture read may not show yet.
  @ObservationIgnored private var linkedSinceLaunch = false
  @ObservationIgnored private var handle: AgentProcessHandle?
  @ObservationIgnored private var handleGeneration = 0
  /// Relays written to each launch that it hasn't echoed yet, in the order they were sent.
  @ObservationIgnored private var unreadRelays: [Int: [UUID]] = [:]
  /// Of the current launch.
  @ObservationIgnored private var echoes: Set<String> = []
  /// Sends written behind an unread relay of the current launch and not yet read.
  @ObservationIgnored private var queuedSends = 0
  /// Messages of the current launch enqueued mid-turn and not yet echoed.
  @ObservationIgnored private var unreadEnqueues: Set<UUID> = []
  /// Guidance for the current launch, put in front of the next message written to it.
  @ObservationIgnored private var instructions: [SlipstreamInstruction] = []
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
  let attachmentAlertTitle = "Couldn't open the file"
  let attachmentAlertDismissText = "OK"

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

  func attachment(for item: TranscriptItem) -> AttachmentMarker.Parsed? {
    guard case .userMessage = item.kind else { return nil }
    return AttachmentMarker.parse(rowText(for: item))
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
    case heading(level: Int, text: AttributedString)
    case list([MarkdownListItem])
    case quote(AttributedString)
    case rule
    case code(String)
  }

  struct MarkdownListItem: Equatable {
    let marker: String
    let depth: Int
    let text: AttributedString
  }

  /// Fenced code blocks come out whole; the prose between them is split into headings, lists,
  /// quotes, rules and paragraphs, each with inline markdown.
  static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var lines: [Substring] = []
    var isCode = false
    var open: [(indent: Int, number: Int?)] = []
    func flush() {
      defer { lines = [] }
      if isCode {
        blocks.append(.code(lines.joined(separator: "\n")))
      } else {
        blocks.append(contentsOf: proseBlocks(lines, open: &open))
      }
    }
    // A fence closes only on a bare run of at least as many backticks as opened it.
    var fence = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let ticks = trimmed.prefix { $0 == "`" }.count
      if !isCode, ticks >= 3, !trimmed.dropFirst(ticks).contains("`") {
        flush()
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        while let last = open.last, last.indent >= indent { open.removeLast() }
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

  private static func proseBlocks(
    _ lines: [Substring], open: inout [(indent: Int, number: Int?)]
  ) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [Substring] = []
    var quote: [Substring] = []
    var items: [(number: Int?, indent: Int, lines: [Substring], continuation: Bool)] = []
    var afterBlank = false
    func closeParagraphAndQuote() {
      if !paragraph.isEmpty { blocks.append(.prose(inlineMarkdown(paragraph.joined(separator: "\n")))) }
      if !quote.isEmpty { blocks.append(.quote(inlineMarkdown(quote.joined(separator: "\n")))) }
      paragraph = []
      quote = []
    }
    func closeAll(keepList: Bool = false) {
      defer { if !keepList { open = [] } }
      closeParagraphAndQuote()
      guard !items.isEmpty else { return }
      // Ordered items count up from the first sibling's number, whatever the source says.
      var listItems: [MarkdownListItem] = []
      for item in items {
        var sibling: (indent: Int, number: Int?)?
        while let last = open.last, last.indent >= item.indent { sibling = open.removeLast() }
        let number = item.continuation
          ? sibling?.number
          : item.number.map { start in sibling?.number.map { $0 + 1 } ?? start }
        listItems.append(
          MarkdownListItem(
            marker: item.continuation ? "" : number.map { "\($0)." } ?? "•", depth: open.count,
            text: inlineMarkdown(item.lines.joined(separator: "\n"))))
        open.append((item.indent, number))
      }
      blocks.append(.list(listItems))
      items = []
    }
    for line in lines {
      let trimmed = line.drop { $0 == " " || $0 == "\t" }
      let indent = line.count - trimmed.count
      defer { afterBlank = trimmed.isEmpty }
      if trimmed.isEmpty {
        closeParagraphAndQuote()
      } else if items.isEmpty, open.isEmpty,
        indent >= 4 || line.prefix(indent).contains("\t")
      {
        if !quote.isEmpty { closeAll() }
        paragraph.append(line)
      } else if isRule(trimmed) {
        closeAll()
        blocks.append(.rule)
      } else if case let (level, title)? = heading(trimmed) {
        closeAll()
        blocks.append(.heading(level: level, text: inlineMarkdown(String(title))))
      } else if case let (number, rest)? = listItem(trimmed) {
        closeParagraphAndQuote()
        items.append((number, indent, [rest], false))
      } else if trimmed.first == ">" {
        if !quote.isEmpty { quote.append(trimmed.dropFirst().drop { $0 == " " }) } else {
          closeAll()
          quote = [trimmed.dropFirst().drop { $0 == " " }]
        }
      } else if let owner = afterBlank
        ? items.lastIndex(where: { $0.indent < indent }) : items.indices.last
      {
        if owner == items.count - 1 {
          items[owner].lines.append(contentsOf: afterBlank ? ["", trimmed] : [trimmed])
        } else {
          items.append((items[owner].number, items[owner].indent, [trimmed], true))
        }
      } else {
        if !items.isEmpty || !quote.isEmpty { closeAll() }
        open = []
        paragraph.append(line)
      }
    }
    closeAll(keepList: true)
    return blocks
  }

  /// Three or more of the same `-`, `*` or `_`, optionally spaced.
  private static func isRule(_ line: Substring) -> Bool {
    let marks = line.filter { $0 != " " && $0 != "\t" }
    guard let mark = marks.first, "-*_".contains(mark) else { return false }
    return marks.count >= 3 && marks.allSatisfy { $0 == mark }
  }

  private static func heading(_ line: Substring) -> (Int, Substring)? {
    let level = line.prefix { $0 == "#" }.count
    let rest = line.dropFirst(level)
    guard (1...6).contains(level), rest.isEmpty || rest.first == " " else { return nil }
    return (level, rest.drop { $0 == " " })
  }

  /// A bullet item has no number.
  private static func listItem(_ line: Substring) -> (Int?, Substring)? {
    if let bullet = line.first, "-*+".contains(bullet), line.dropFirst().first == " " {
      return (nil, line.dropFirst(2))
    }
    let digits = line.prefix { ("0"..."9").contains($0) }
    let rest = line.dropFirst(digits.count)
    guard (1...9).contains(digits.count), let delimiter = rest.first, ".)".contains(delimiter),
      rest.dropFirst().first == " "
    else { return nil }
    return (Int(digits), rest.dropFirst(2))
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
    do {
      try await writeUserMessage(text, to: handle)
    } catch {
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
    let sentInstructions = takeInstructions(for: message.text)
    do {
      try await handle.write(
        ClaudeInvocation.userMessage(
          SlipstreamInstruction.prefixed(message.text, with: sentInstructions), uuid: message.relayID))
    } catch {
      if launch == handleGeneration, !sentInstructions.isEmpty { instructions = sentInstructions }
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
  }

  /// Writes like `send()` but also mid-turn, and never reads or clears the draft. Throws when
  /// nothing reached the process.
  func enqueueUserMessage(_ text: String) async throws {
    if activeTurn == nil { await awaitRetired() }
    guard !isClosed, !Task.isCancelled else { throw MessageNotWritten() }
    let startedTurn = activeTurn == nil ? beginTurn() : nil
    if handle == nil, startedTurn != nil {
      _ = await start()
    } else if handle == nil {
      for task in starting { _ = await task.value }
    }
    guard let handle, !isClosed, !Task.isCancelled else {
      if let startedTurn, activeTurn?.id == startedTurn { activeTurn = nil }
      throw MessageNotWritten()
    }
    do {
      try await writeUserMessage(text, to: handle, isMidTurn: startedTurn == nil)
    } catch {
      if let startedTurn, activeTurn?.id == startedTurn, activeTurn?.isEchoed == false { activeTurn = nil }
      throw error
    }
    if let startedTurn, activeTurn?.id == startedTurn {
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

  func attachmentTapped(_ item: TranscriptItem) {
    guard let parsed = attachment(for: item) else { return }
    do {
      try attachments.open(URL(fileURLWithPath: parsed.path))
    } catch {
      attachmentAlert = error.localizedDescription
    }
  }

  func attachmentAlertDismissed() {
    attachmentAlert = nil
  }

  func clockTicked() {
    guard isWorking else { return }
    now = date.now
  }

  /// A running Claude doesn't load the hook and answer tool a link installs, so a process that
  /// predates the link is dropped once idle. The next send resumes in a fresh one.
  func streamLinked() {
    linkedSinceLaunch = true
    guard handle != nil || !starting.isEmpty else { return }
    if isWorking || hasUnreadInput {
      reloadWhenIdle = true
    } else {
      retireProcess()
    }
  }

  /// A capture read shows this chat linked, perhaps from outside the app or after a read that
  /// lagged the link; a process launched before it knew is handled as if just linked.
  func linkSeen() {
    guard !launchedLinked, handle != nil || !starting.isEmpty else { return }
    streamLinked()
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

  /// Projects the message and writes it, taking the row back out when the write fails. A
  /// mid-turn message carries its id, so its own echo marks it read.
  private func writeUserMessage(_ text: String, to handle: AgentProcessHandle, isMidTurn: Bool = false) async throws {
    let id = uuid()
    let launch = handleGeneration
    let isQueued = !isMidTurn && hasUnreadInput
    projection.userSent(text, id: id.uuidString)
    if isQueued { queuedSends += 1 }
    if isMidTurn { unreadEnqueues.insert(id) }
    let sentInstructions = takeInstructions(for: text)
    do {
      try await handle.write(
        ClaudeInvocation.userMessage(
          SlipstreamInstruction.prefixed(text, with: sentInstructions), uuid: isMidTurn ? id : nil))
    } catch {
      if launch == handleGeneration, !sentInstructions.isEmpty { instructions = sentInstructions }
      if isQueued, launch == handleGeneration { queuedSends = max(0, queuedSends - 1) }
      if launch == handleGeneration { unreadEnqueues.remove(id) }
      projection.removeUserMessage(id: id.uuidString)
      throw error
    }
  }

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
      let wasLinkedAtLaunch = linkedSinceLaunch || isStreamLinked()
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
      unreadEnqueues = []
      launchedLinked = wasLinkedAtLaunch
      let linkedDuringLaunch = linkedSinceLaunch || isStreamLinked()
      linkedSinceLaunch = false
      instructions = Self.instructions(session: session, lookup: lookup, isLinked: launchedLinked)
      // Not cancelled on retire: a retired launch still resolves its relays as it winds down.
      followers[generation] = Task { [weak self] in
        for await event in handle.events {
          self?.received(event, from: handle, generation: generation)
        }
        self?.followers[generation] = nil
      }
      if linkedDuringLaunch, !launchedLinked { streamLinked() }
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

  /// A slash command only runs when it leads the message, so the guidance waits for the next one.
  private func takeInstructions(for text: String) -> [SlipstreamInstruction] {
    guard !text.hasPrefix("/") else { return [] }
    defer { instructions = [] }
    return instructions
  }

  /// A new chat is told it isn't linked yet; a linked one learns its tools once.
  private static func instructions(
    session: ClaudeSessionStart, lookup: TranscriptLookup, isLinked: Bool
  ) -> [SlipstreamInstruction] {
    let lines = if case .found(let lines) = lookup { lines } else { [AgentLine]() }
    var instructions: [SlipstreamInstruction] = []
    if case .new = session { instructions.append(.start) }
    if isLinked, !SlipstreamInstruction.linked.wasSent(in: lines) { instructions.append(.linked) }
    return instructions
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
      let isEnqueued = UUID(uuidString: uuid).map { unreadEnqueues.remove($0) != nil } ?? false
      if !isPickup && !isEnqueued { queuedSends = max(0, queuedSends - 1) }
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
    hasSentMessage = true
    onReadinessChanged()
    projection.endTurn(ending, duration: duration, at: date.now, id: turn.id.uuidString)
    onTurnEnded()
    if reloadWhenIdle, !hasUnreadInput { retireProcess() }
    titleRefresh?.cancel()
    let generation = generation
    titleRefresh = Task { [weak self] in await self?.refreshTitle(generation: generation) }
  }

  /// A process that predates a link stays up until it has read every relay sent to it, every
  /// send queued behind one, and every message enqueued mid-turn.
  private var hasUnreadInput: Bool {
    handle != nil
      && (queuedSends > 0 || !unreadEnqueues.isEmpty || !(unreadRelays[handleGeneration] ?? []).isEmpty)
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

struct MessageNotWritten: Error {}
