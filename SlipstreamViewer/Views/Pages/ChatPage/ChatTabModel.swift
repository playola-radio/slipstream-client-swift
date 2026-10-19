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
  @ObservationIgnored @Dependency(\.transcripts) var transcripts
  @ObservationIgnored @Dependency(\.date) var date
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

  /// Called once each time a turn ends, so the page can mark the tab waiting.
  @ObservationIgnored var onTurnEnded: () -> Void = {}

  private var activeTurn: ActiveTurn?
  private var needsHistory: Bool
  @ObservationIgnored private var handle: AgentProcessHandle?
  @ObservationIgnored private var follower: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  // MARK: - Page Actions

  func shown() async {
    guard needsHistory, handle == nil, activeTurn == nil else { return }
    await loadHistory()
  }

  func send() async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, activeTurn == nil else { return }
    errorText = nil
    let turn = ActiveTurn(id: uuid(), startedAt: date.now)
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
  }

  private struct Failure: Error {
    let message: String
  }

  private static let newChatTitle = "New chat"
  private static let cantStartText = "Claude couldn't start"
  private static let unreadableText = "Couldn't read this chat's history from Claude"
  private static let sendFailedText = "Couldn't send your message to Claude"
  private static let turnFailedText = "Claude couldn't finish this turn"

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
          await self?.received(event, generation: generation)
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
      if case .found(let lines) = lookup {
        projection = .history(lines)
        title = Self.title(lines)
      }
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

  private func received(_ event: AgentProcessEvent, generation: Int) async {
    guard generation == self.generation else { return }
    switch event {
    case .line(let data): await received(AgentLine.decode(data))
    case .overflow: await received(.gap)
    case .exited: break
    }
  }

  private func received(_ line: AgentLine) async {
    switch line {
    case .result(let durationMs, let isError, let text):
      guard activeTurn != nil else { return }
      if isError { errorText = text ?? Self.turnFailedText }
      await endTurn(isError ? .failed : .completed, duration: .milliseconds(durationMs))
    default:
      projection.apply(line)
    }
  }

  private func endTurn(_ ending: TurnEnding, duration: Duration) async {
    guard let turn = activeTurn else { return }
    activeTurn = nil
    projection.endTurn(ending, duration: duration, at: date.now, id: turn.id.uuidString)
    onTurnEnded()
  }

  private static func title(_ lines: [AgentLine]) -> String {
    for line in lines.reversed() {
      if case .title(let title) = line { return title }
    }
    return newChatTitle
  }
}
