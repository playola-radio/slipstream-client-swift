import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import SlipstreamCore

struct InstantQuestion: Equatable, Sendable {
  let storeID: String
  let sessionID: String
  let folder: String
  let source: QuestionSource
  let replyToQuestionID: String?
  /// The tab that answered the thread's first question; `nil` for a new question.
  let threadChatSessionID: String?
  let earlier: [AskPrompt.Exchange]
  let text: String
}

struct PendingAsk: Identifiable, Equatable, Sendable {
  let id: String
  let storeID: String
  let sessionID: String
  let chatSessionID: UUID
  let source: QuestionSource
  let replyToQuestionID: String?
  let text: String
  let askedAtMs: Int64
  var state: State

  enum State: Equatable, Sendable {
    case answering
    case recording(AskForkResult)
    case recorded(questionID: String)
    case couldntAnswer(AskFailure)
    /// The daemon's reply never came back, so the exact request is kept to send again.
    case couldntRecord(AskForkResult)
  }
}

enum AskFailure: Equatable, Sendable {
  case noReply, chatUnavailable, badReply, notSaved
}

/// Answers questions from a read-only copy of a chat tab, then records each question with its
/// answer. One per app: it owns every copy run and recording, so closing the panel or selecting
/// another capture cancels nothing. Work stops only when its capture is deleted or the app quits.
@MainActor
@Observable
final class InstantAskModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.agentEnvironment) var agentEnvironment
  @ObservationIgnored @Dependency(\.askFork) var askFork
  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.date) var date
  @ObservationIgnored @Dependency(\.questionClient) var questionClient
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Initialization

  init(chat: ChatPageModel) {
    self.chat = chat
    super.init()
  }

  // MARK: - Properties

  static let recordingAttempts = 3
  static let recordingRetryDelay = Duration.milliseconds(2500)

  /// Questions whose answer hasn't folded into a thread yet.
  private(set) var pending: IdentifiedArrayOf<PendingAsk> = []

  @ObservationIgnored private let chat: ChatPageModel
  @ObservationIgnored private var questions: [String: InstantQuestion] = [:]
  @ObservationIgnored private var recordings: [String: QuestionRequest] = [:]
  /// Keyed by request id. Each run bumps the attempt, so only the latest run can publish.
  @ObservationIgnored private var runs: [String: Run] = [:]

  // MARK: - User Actions

  func ask(_ question: InstantQuestion) async {
    await start(question, at: pending.endIndex)
  }

  /// A recording whose outcome is unknown is sent again unchanged; anything else runs a new copy
  /// under a new request id.
  func tryAgainTapped(requestID: String) async {
    guard let entry = pending[id: requestID] else { return }
    switch entry.state {
    case .couldntRecord(let result):
      pending[id: requestID]?.state = .recording(result)
      await run(requestID) { attempt in await self.record(requestID, result: result, attempt: attempt) }
    case .couldntAnswer:
      guard let question = questions[requestID], let index = pending.index(id: requestID) else { return }
      forget(requestID)
      await start(question, at: index)
    case .answering, .recording, .recorded:
      break
    }
  }

  /// An entry leaves once its exchange is in the capture's log, even if an error showed first.
  func threadsFolded(sessionID: String, threads: IdentifiedArrayOf<QuestionThread>) {
    let folded = Set(threads.flatMap { $0.turns.map(\.requestID) })
    for entry in pending where entry.sessionID == sessionID && folded.contains(entry.id) {
      forget(entry.id)
    }
  }

  /// Selecting the capture again replays its log, which brings recorded answers back.
  func captureDeselected(_ sessionID: String) {
    for entry in pending where entry.sessionID == sessionID {
      if case .recorded = entry.state { forget(entry.id) }
    }
  }

  func captureDeleted(_ sessionID: String) {
    for entry in pending where entry.sessionID == sessionID { forget(entry.id) }
  }

  /// Stops every copy and returns once they have all exited.
  func quitConfirmed() async {
    let running = runs.values.map(\.task)
    for id in pending.ids { forget(id) }
    for task in running { await task.value }
  }

  // MARK: - Private Helpers

  private struct Run {
    let attempt: Int
    let task: Task<Void, Never>
  }

  private func start(_ question: InstantQuestion, at index: Int) async {
    guard let tab = answeringTab(for: question) else {
      reportIssue("No chat tab can answer a question in \(question.folder)")
      return
    }
    let requestID = uuid().uuidString.lowercased()
    pending.insert(
      PendingAsk(
        id: requestID,
        storeID: question.storeID,
        sessionID: question.sessionID,
        chatSessionID: tab.id,
        source: question.source,
        replyToQuestionID: question.replyToQuestionID,
        text: question.text,
        askedAtMs: Int64((date.now.timeIntervalSince1970 * 1000).rounded()),
        state: .answering
      ),
      at: index
    )
    questions[requestID] = question
    let record = tab.record
    await run(requestID) { attempt in await self.answer(requestID, question: question, tab: record, attempt: attempt) }
  }

  /// The thread's own chat while it is open, otherwise the tab the folder is linked to.
  private func answeringTab(for question: InstantQuestion) -> ChatTabModel? {
    if let id = question.threadChatSessionID.flatMap(UUID.init(uuidString:)), let tab = chat.tabs[id: id] {
      return tab
    }
    return chat.linkedAppTab(forFolder: question.folder)
  }

  private func run(_ requestID: String, _ work: @escaping @MainActor (Int) async -> Void) async {
    let attempt = (runs[requestID]?.attempt ?? 0) + 1
    let task = Task { await work(attempt) }
    runs[requestID] = Run(attempt: attempt, task: task)
    await task.value
  }

  /// Request ids are fresh per store and capture, so the id and attempt identify the run.
  private func isCurrent(_ requestID: String, _ attempt: Int) -> Bool {
    runs[requestID]?.attempt == attempt && !Task.isCancelled
  }

  private func answer(_ requestID: String, question: InstantQuestion, tab: ChatTabRecord, attempt: Int) async {
    guard let environment = try? await agentEnvironment.resolve() else {
      return publish(requestID, attempt, .couldntAnswer(.chatUnavailable))
    }
    let result: AskForkResult
    do throws(AskForkError) {
      result = try await askFork.run(
        AskForkRequest(
          parentSessionID: tab.id,
          folder: tab.folder,
          environment: environment,
          model: tab.model,
          effort: tab.effort,
          prompt: AskPrompt.answer(
            source: question.source, earlier: question.earlier, words: question.text, allowsChangeRequests: false),
          kind: .answer(allowsChangeRequests: false)
        )
      )
    } catch {
      return publish(requestID, attempt, .couldntAnswer(Self.failure(error)))
    }
    guard isCurrent(requestID, attempt), case .answer(let forkSessionID, let reply, _) = result else { return }
    pending[id: requestID]?.state = .recording(result)
    recordings[requestID] = QuestionRequest(
      sessionID: question.sessionID,
      requestID: requestID,
      text: question.text,
      context: question.source.context,
      replyToQuestionID: question.replyToQuestionID,
      verb: .recordExchange(
        answerText: reply,
        conversation: ExchangeConversation(parentSessionID: tab.id.uuidString, forkSessionID: forkSessionID)
      )
    )
    await record(requestID, result: result, attempt: attempt)
  }

  /// An unknown outcome is retried with the identical body; a refusal is final.
  private func record(_ requestID: String, result: AskForkResult, attempt: Int) async {
    guard let request = recordings[requestID] else { return }
    for remaining in (0..<Self.recordingAttempts).reversed() {
      do {
        let acknowledgment = try await questionClient.record(request)
        return publish(requestID, attempt, .recorded(questionID: acknowledgment.questionID))
      } catch where QuestionFailure.isOutcomeUnknown(error) {
        guard remaining > 0 else { return publish(requestID, attempt, .couldntRecord(result)) }
        guard (try? await clock.sleep(for: Self.recordingRetryDelay)) != nil, isCurrent(requestID, attempt) else {
          return
        }
      } catch {
        return publish(requestID, attempt, .couldntAnswer(.notSaved))
      }
    }
  }

  private func publish(_ requestID: String, _ attempt: Int, _ state: PendingAsk.State) {
    guard isCurrent(requestID, attempt) else { return }
    pending[id: requestID]?.state = state
  }

  private func forget(_ requestID: String) {
    runs.removeValue(forKey: requestID)?.task.cancel()
    pending.remove(id: requestID)
    questions[requestID] = nil
    recordings[requestID] = nil
  }

  private static func failure(_ error: AskForkError) -> AskFailure {
    switch error {
    case .timedOut: .noReply
    case .unavailable: .chatUnavailable
    case .badReply: .badReply
    }
  }
}
