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

  /// Called once each time a turn ends, so the page can mark the tab waiting.
  @ObservationIgnored var onTurnEnded: () -> Void = {}

  private var activeTurn: ActiveTurn?
  private var now = Date.distantPast
  private var needsHistory: Bool
  @ObservationIgnored private var handle: AgentProcessHandle?
  @ObservationIgnored private var follower: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  // MARK: - Display Text

  var workingText: String? {
    guard let activeTurn else { return nil }
    let working = Self.durationText(seconds: now.timeIntervalSince(activeTurn.startedAt))
    let quiet = Self.durationText(seconds: now.timeIntervalSince(activeTurn.lastOutputAt))
    return "Working \(working) · last output \(quiet) ago"
  }

  var pickerText: String {
    let model = ChatModelChoice.all.first { $0.id == record.model }?.name ?? record.model
    return "\(model) \(record.effort.name)"
  }

  // MARK: - View Helpers

  func rowText(for item: TranscriptItem) -> String {
    switch item.kind {
    case .userMessage(let text), .reply(let text), .thinking(let text):
      return text
    case .toolCall(let name, let target, let status, _):
      let (running, ran) = Self.verbs(name)
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

  // MARK: - Page Actions

  func shown() async {
    guard needsHistory, handle == nil, activeTurn == nil else { return }
    await loadHistory()
  }

  func send() async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, activeTurn == nil else { return }
    errorText = nil
    now = date.now
    let turn = ActiveTurn(id: uuid(), startedAt: now, lastOutputAt: now)
    activeTurn = turn
    if handle == nil, await !start() {
      if activeTurn?.id == turn.id { activeTurn = nil }
      return
    }
    guard let handle, activeTurn?.id == turn.id else { return }
    do {
      try await handle.write(ClaudeInvocation.userMessage(text))
    } catch {
      guard activeTurn?.id == turn.id else { return }
      activeTurn = nil
      errorText = Self.sendFailedText
      return
    }
    projection.userSent(text, id: uuid().uuidString)
    draft = ""
    $record.withLock { $0.isWaiting = false }
  }

  /// Asks Claude to stop, and gives up on it after the deadline.
  func stop() async {
    guard var turn = activeTurn, !turn.isStopPressed else { return }
    turn.isStopPressed = true
    activeTurn = turn
    guard let handle else {
      generation += 1
      await endTurn(.stopped, duration: duration(of: turn))
      return
    }
    try? await handle.write(ClaudeInvocation.interrupt(requestID: uuid().uuidString))
    try? await clock.sleep(for: Self.stopDeadline)
    guard activeTurn?.id == turn.id else { return }
    await endTurn(.stopped, duration: duration(of: turn))
    await shutdown()
  }

  /// Relaunches with `--resume` and reloads history. Nothing is resent.
  func tryAgain() async {
    guard !isWorking else { return }
    errorText = nil
    await shutdown()
    await loadHistory()
    guard errorText == nil, handle == nil, !isWorking else { return }
    _ = await start()
  }

  /// The new choice applies from the next send.
  func choiceSelected(model: String, effort: ChatEffort) async {
    guard !isWorking else { return }
    $record.withLock {
      $0.model = model
      $0.effort = effort
    }
    if handle != nil { await shutdown() }
  }

  func clockTicked() {
    guard isWorking else { return }
    now = date.now
  }

  /// Stops the process and waits for it to exit. Its late events are dropped.
  func shutdown() async {
    activeTurn = nil
    generation += 1
    follower?.cancel()
    follower = nil
    let handle = handle
    self.handle = nil
    await handle?.shutdown()
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

  private func start() async -> Bool {
    generation += 1
    let generation = generation
    do throws(Failure) {
      let (environment, lookup) = try await readTranscript()
      guard generation == self.generation else { return false }
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
        await handle.shutdown()
        return false
      }
      self.handle = handle
      follower = Task { [weak self] in
        for await event in handle.events {
          await self?.received(event, from: handle, generation: generation)
        }
      }
      return true
    } catch {
      if generation == self.generation { errorText = error.message }
      return false
    }
  }

  private func loadHistory() async {
    generation += 1
    let generation = generation
    do throws(Failure) {
      let (_, lookup) = try await readTranscript()
      guard generation == self.generation else { return }
      needsHistory = false
      let lines = if case .found(let lines) = lookup { lines } else { [AgentLine]() }
      projection = .history(lines)
      title = Self.title(lines)
    } catch {
      if generation == self.generation { errorText = error.message }
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

  private func received(_ event: AgentProcessEvent, from handle: AgentProcessHandle, generation: Int) async {
    guard generation == self.generation else { return }
    switch event {
    case .line(let data):
      outputArrived()
      await received(AgentLine.decode(data), from: handle)
    case .overflow:
      outputArrived()
      await received(.gap, from: handle)
    case .exited(_, let stderrTail):
      await exited(handle, stderrTail: stderrTail)
    }
  }

  private func outputArrived() {
    now = date.now
    activeTurn?.lastOutputAt = now
  }

  private func received(_ line: AgentLine, from handle: AgentProcessHandle) async {
    switch line {
    case .result(let durationMs, let isError, let text):
      guard let turn = activeTurn else { return }
      let ending: TurnEnding = turn.isStopPressed ? .stopped : isError ? .failed : .completed
      if ending == .failed { errorText = text ?? Self.turnFailedText }
      await endTurn(ending, duration: .milliseconds(durationMs))
    case .controlRequest(let requestID, let subtype, let input):
      try? await handle.write(ClaudeInvocation.reply(requestID: requestID, subtype: subtype, input: input))
    default:
      projection.apply(line)
    }
  }

  /// The process ended on its own. A turn still running fails; the next send relaunches.
  private func exited(_ handle: AgentProcessHandle, stderrTail: String) async {
    generation += 1
    self.handle = nil
    follower = nil
    if let turn = activeTurn, turn.isStopPressed {
      await endTurn(.stopped, duration: duration(of: turn))
    } else if let turn = activeTurn {
      let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
      errorText = tail.isEmpty ? Self.crashedText : "\(Self.crashedText)\n\(tail)"
      await endTurn(.failed, duration: duration(of: turn))
    }
    await handle.shutdown()
  }

  private func endTurn(_ ending: TurnEnding, duration: Duration) async {
    guard let turn = activeTurn else { return }
    activeTurn = nil
    projection.endTurn(ending, duration: duration, at: date.now, id: turn.id.uuidString)
    onTurnEnded()
    await refreshTitle()
  }

  private func duration(of turn: ActiveTurn) -> Duration {
    .seconds(date.now.timeIntervalSince(turn.startedAt))
  }

  private func refreshTitle() async {
    let generation = generation
    guard
      case .found(let lines)? = try? await readTranscript().1,
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

  private static func verbs(_ tool: String) -> (running: String, ran: String) {
    switch tool {
    case "Bash": ("Running", "Ran")
    case "Read": ("Reading", "Read")
    case "Edit", "MultiEdit", "Write": ("Editing", "Edited")
    default: ("Using", "Used")
    }
  }

  private static func title(_ lines: [AgentLine]) -> String {
    for line in lines.reversed() {
      if case .title(let title) = line { return title }
    }
    return newChatTitle
  }
}
