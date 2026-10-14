import Dependencies
import Foundation
import Sharing
import SlipstreamCore

@MainActor
@Observable
final class QuestionThreadPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.questionClient) var questionClient
  @ObservationIgnored @Dependency(\.timeZone) var timeZone
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Shared State

  @ObservationIgnored @Shared(.readAnswers) var readAnswers
  @ObservationIgnored @Shared(.replyDrafts) var replyDrafts

  // MARK: - Initialization

  init(key: QuestionThreadKey, thread: QuestionThread) {
    self.key = key
    self.thread = thread
    super.init()
  }

  // MARK: - Properties

  let key: QuestionThreadKey
  private(set) var thread: QuestionThread
  private(set) var isDismissed = false
  var isErrorPresented = false
  private(set) var errorMessage = ""

  var draft: String {
    get { replyDraft.text }
    set {
      guard !isFollowUpDisabled else { return }
      updateReplyDraft { draft in
        if QuestionRequest.trim(newValue) != QuestionRequest.trim(draft.text) { draft.request = nil }
        draft.text = newValue
      }
    }
  }

  private var replyDraft: ReplyDraft { replyDrafts[key] ?? ReplyDraft() }

  // MARK: - Display Text

  let title = "Talk to the agent"
  let closeText = "Close reply"
  let waitingText = "Waiting for the agent to answer…"
  let notDeliveredText = "Not delivered — recording restarted. Ask again."
  let followUpPlaceholder = "Ask a follow-up…"
  let sendText = "Send reply"
  let errorTitle = "Reply not confirmed"
  let errorDismissText = "OK"

  var sourceText: String {
    let context = thread.source.context
    let file = (context.path as NSString).lastPathComponent
    let lines = context.lineStart == context.lineEnd ? "\(context.lineStart)" : "\(context.lineStart)–\(context.lineEnd)"
    let messages = thread.turns.count + thread.turns.filter { $0.answer != nil }.count
    return "\(file):\(lines) · \(messages) \(messages == 1 ? "message" : "messages")"
  }

  var uncertaintyNotice: String? {
    replyDraft.hasUncertainSubmission && !isRetainedRequestDropped
      ? "An earlier reply may already be queued. Send it unchanged to reuse its request ID; editing sends a separate question."
      : nil
  }

  func unansweredText(_ turn: QuestionTurn) -> String {
    turn.status == .notDelivered ? notDeliveredText : waitingText
  }

  func answerText(_ answer: QuestionAnswer) -> String {
    answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func agentText(_ answer: QuestionAnswer) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return "AGENT · " + formatter.string(from: Date(timeIntervalSince1970: Double(answer.answeredAtMs) / 1000))
  }

  // MARK: - View Helpers

  var isFollowUpDisabled: Bool {
    let draft = replyDraft
    let isAwaitingQueuedTurn = draft.queuedTurn.map { queued in
      !thread.turns.contains { $0.questionID == queued.questionID }
    } ?? false
    return isDismissed || draft.isSubmitting || isAwaitingQueuedTurn
      || (thread.turns.last?.status ?? .waiting) == .waiting
  }

  var canSendReply: Bool {
    !isFollowUpDisabled && thread.source.context.isValid && !QuestionRequest.trim(draft).isEmpty
  }

  // MARK: - User Actions

  func answerDisplayed(_ seq: Seq) {
    guard !isDismissed, thread.turns.contains(where: { $0.answer?.seq == seq }) else { return }
    let marker = AnswerReadMarker(storeID: key.storeID, sessionID: key.sessionID, seq: seq)
    $readAnswers.withLock { _ = $0.insert(marker) }
  }

  func sendReplyTapped() async {
    guard canSendReply, let parent = thread.turns.last else { return }
    if isRetainedRequestDropped {
      updateReplyDraft { draft in
        draft.request = nil
        draft.hasUncertainSubmission = false
      }
    }
    let intent = replyDraft.request ?? QuestionRequest(
      sessionID: key.sessionID, requestID: uuid().uuidString.lowercased(), text: draft,
      context: thread.source.context, replyToQuestionID: parent.questionID)
    updateReplyDraft { draft in
      draft.request = intent
      draft.isSubmitting = true
    }
    do {
      let acknowledgment = try await questionClient.send(intent)
      settle(intent) { draft in
        draft.turnQueued(QueuedTurn(questionID: acknowledgment.questionID, seq: acknowledgment.seq))
        draft = ReplyDraft(queuedTurn: draft.queuedTurn)
      }
    } catch {
      settle(intent) { draft in
        if QuestionFailure.isOutcomeUnknown(error) { draft.hasUncertainSubmission = true }
        if !draft.hasUncertainSubmission { draft.request = nil }
      }
      guard !isDismissed else { return }
      errorMessage = QuestionFailure.message(error, hasUncertainSubmission: replyDraft.hasUncertainSubmission)
      isErrorPresented = true
    }
  }

  func threadUpdated(_ thread: QuestionThread) {
    guard !isDismissed, thread.id == key.rootQuestionID else { return }
    self.thread = thread
  }

  func dismissed() {
    isDismissed = true
  }

  // MARK: - Private Helpers

  private var isRetainedRequestDropped: Bool {
    guard let request = replyDraft.request else { return false }
    return thread.turns.contains { $0.requestID == request.requestID && $0.status == .notDelivered }
  }

  private func updateReplyDraft(_ body: (inout ReplyDraft) -> Void) {
    $replyDrafts.withLock { drafts in
      var draft = drafts[key] ?? ReplyDraft()
      body(&draft)
      drafts[key] = draft == ReplyDraft() ? nil : draft
    }
  }

  private func settle(_ intent: QuestionRequest, _ body: (inout ReplyDraft) -> Void) {
    updateReplyDraft { draft in
      guard draft.isSubmitting, draft.request?.requestID == intent.requestID else { return }
      draft.isSubmitting = false
      body(&draft)
    }
  }
}
