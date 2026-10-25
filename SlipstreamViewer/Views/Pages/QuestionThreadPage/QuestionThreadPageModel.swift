import Dependencies
import Foundation
import Sharing
import SlipstreamCore

/// What a turn's change request has got to, from its newest attempt.
struct RelayProgress: Equatable {
  let relayID: String
  let lines: [Line]
  let action: Action?
  let isActionDisabled: Bool
  /// The agent's answer to whether it made the change.
  let report: Report?

  struct Line: Equatable, Hashable {
    let mark: Mark
    let label: String
    let detail: String
  }

  enum Mark: Equatable, Hashable {
    case done, waiting, working, notDoneYet, failed, warning
  }

  enum Action: Equatable {
    case sendAgain, checkAgain
  }

  struct Report: Equatable {
    let seq: Seq
    let agentText: String
    let text: String
  }
}

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

  init(
    key: QuestionThreadKey, thread: QuestionThread, bindingGeneration: String?, folder: String?,
    instantAsk: InstantAskModel
  ) {
    self.key = key
    self.thread = thread
    self.bindingGeneration = bindingGeneration
    self.folder = folder
    self.instantAsk = instantAsk
    super.init()
  }

  // MARK: - Properties

  private(set) var key: QuestionThreadKey
  private var bindingGeneration: String?
  private let folder: String?
  @ObservationIgnored private let instantAsk: InstantAskModel
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

  /// A question still being answered shows as the thread's last turn until its answer folds in.
  var pendingTurn: PendingAsk? {
    let questionIDs = Set(thread.turns.map(\.questionID))
    return instantAsk.pending.first { entry in
      entry.storeID == key.storeID && entry.sessionID == key.sessionID
        && (entry.replyToQuestionID.map(questionIDs.contains) ?? (entry.id == thread.id))
    }
  }

  // MARK: - Display Text

  let title = "Talk to the agent"
  let closeText = "Close reply"
  let waitingText = "Waiting for the agent to answer…"
  let notDeliveredText = "Not delivered — recording restarted. Ask again."
  let resendingText = "Re-sending to the newly connected chat — waiting for the agent to answer…"
  let followUpPlaceholder = "Ask a follow-up…"
  let sendText = "Send reply"
  let errorTitle = "Reply not confirmed"
  let errorDismissText = "OK"
  let thinkingText = "AGENT · thinking…"
  let couldntAnswerText = "Couldn't get an answer"
  let tryAgainText = "Try again"
  let sendAgainText = "Send again"
  let checkAgainText = "Check again"

  var sourceText: String {
    let context = thread.source.context
    let file = (context.path as NSString).lastPathComponent
    let lines = context.lineStart == context.lineEnd ? "\(context.lineStart)" : "\(context.lineStart)–\(context.lineEnd)"
    let messages =
      thread.turns.count + thread.turns.filter { $0.answer != nil }.count
      + thread.turns.filter { $0.relays.last?.report != nil }.count + (pendingTurn == nil ? 0 : 1)
    return "\(file):\(lines) · \(messages) \(messages == 1 ? "message" : "messages")"
  }

  var uncertaintyNotice: String? {
    replyDraft.hasUncertainSubmission && !isRetainedRequestDropped
      ? "An earlier reply may already be queued. Send it unchanged to reuse its request ID; editing sends a separate question."
      : nil
  }

  /// Why the pending turn has no answer, or `nil` while it is still being answered.
  var pendingFailureText: String? {
    switch pendingTurn?.state {
    case .couldntAnswer(.noReply): "no reply within 120 seconds"
    case .couldntAnswer(.chatUnavailable): "the chat couldn't be reached"
    case .couldntAnswer(.badReply): "the reply couldn't be read"
    case .couldntAnswer(.notSaved), .couldntRecord: "it couldn't be saved"
    case .answering, .recording, .recorded, nil: nil
    }
  }

  func unansweredText(_ turn: QuestionTurn) -> String {
    switch turn.status {
    case .notDelivered: notDeliveredText
    case .resending: resendingText
    case .waiting, .answered: waitingText
    }
  }

  func answerText(_ answer: QuestionAnswer) -> String {
    answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func agentText(_ answer: QuestionAnswer) -> String {
    "AGENT · " + clockTime(answer.answeredAtMs)
  }

  func progress(_ turn: QuestionTurn) -> RelayProgress? {
    guard let relay = turn.relays.last else { return nil }
    let status = instantAsk.relayStatus(relay)
    let run = instantAsk.relayRuns[relay.id]
    let report = relay.report.map { report in
      RelayProgress.Report(
        seq: report.seq, agentText: "AGENT · " + clockTime(report.atMs),
        text: report.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let pickedUpTime = relay.pickedUp.map { clockTime($0.atMs) }
    if status == .done {
      let detail = ["sent \(clockTime(relay.sent.atMs))"] + (pickedUpTime.map { ["picked up \($0)"] } ?? [])
        + relay.changedPaths
      return RelayProgress(
        relayID: relay.id, lines: [.init(mark: .done, label: "Done", detail: detail.joined(separator: " · "))],
        action: nil, isActionDisabled: false, report: report)
    }
    var lines = [
      status == .sent
        ? .init(
          mark: .waiting, label: "Sent", detail: "\(clockTime(relay.sent.atMs)) · the agent will read this after its current step")
        : RelayProgress.Line(mark: .done, label: "Sent", detail: clockTime(relay.sent.atMs))
    ]
    if [.pickedUp, .working, .notDoneYet, .couldntCheck].contains(status) {
      lines.append(.init(mark: .done, label: "Picked up", detail: pickedUpTime ?? ""))
      lines += relay.changedPaths.map { .init(mark: .working, label: "Working", detail: "changes seen in \($0)") }
    }
    var action: RelayProgress.Action?
    switch status {
    case .notDoneYet:
      lines.append(.init(mark: .notDoneYet, label: "Not done yet", detail: "checking again when the agent's next turn ends"))
    case .couldntCheck:
      let failedAt = run?.checkFailedAtMs.map(clockTime) ?? ""
      lines.append(.init(mark: .warning, label: "Couldn't check whether this was done", detail: failedAt))
      action = .checkAgain
    case .notDelivered:
      lines.append(.init(mark: .failed, label: "Not delivered", detail: "the chat stopped before the agent read this"))
      action = .sendAgain
    case .deliveryUnknown:
      lines.append(.init(mark: .failed, label: "Delivery unknown", detail: "the app restarted before delivery was confirmed"))
      action = .sendAgain
    case .done, .working, .pickedUp, .sent:
      break
    }
    let isChecking = if case .checking = run?.report { true } else { false }
    return RelayProgress(
      relayID: relay.id, lines: lines, action: action, isActionDisabled: action == .checkAgain && isChecking,
      report: report)
  }

  func actionText(_ action: RelayProgress.Action) -> String {
    switch action {
    case .sendAgain: sendAgainText
    case .checkAgain: checkAgainText
    }
  }

  // MARK: - View Helpers

  var isFollowUpDisabled: Bool {
    let draft = replyDraft
    let isAwaitingQueuedTurn = draft.queuedTurn.map { queued in
      !thread.turns.contains { $0.questionID == queued.questionID }
    } ?? false
    return isDismissed || draft.isSubmitting || isAwaitingQueuedTurn || pendingTurn != nil
      || [.waiting, .resending].contains(thread.turns.last?.status ?? .waiting)
  }

  var canSendReply: Bool {
    let text = QuestionRequest.trim(draft)
    guard !isFollowUpDisabled, thread.source.context.isValid, !text.isEmpty,
      text.utf8.count <= QuestionRequest.maximumTextBytes
    else { return false }
    switch thread.link {
    case .recorded: return folder != nil
    case .hook: return replyDraft.request != nil || bindingGeneration != nil
    }
  }

  // MARK: - User Actions

  func answerDisplayed(_ seq: Seq) {
    guard !isDismissed,
      thread.turns.contains(where: { $0.answer?.seq == seq || $0.relays.last?.report?.seq == seq })
    else { return }
    let marker = AnswerReadMarker(storeID: key.storeID, sessionID: key.sessionID, seq: seq)
    $readAnswers.withLock { _ = $0.insert(marker) }
  }

  func sendAgainTapped(_ progress: RelayProgress) async {
    guard !isDismissed else { return }
    await instantAsk.sendAgainTapped(relayID: progress.relayID)
  }

  func checkAgainTapped(_ progress: RelayProgress) async {
    guard !isDismissed else { return }
    await instantAsk.checkAgainTapped(relayID: progress.relayID)
  }

  func sendReplyTapped() async {
    guard canSendReply, let parent = thread.turns.last else { return }
    if case .recorded(let chatSessionID) = thread.link, let folder {
      return followUpAsked(parent: parent, folder: folder, chatSessionID: chatSessionID)
    }
    if isRetainedRequestDropped {
      updateReplyDraft { draft in
        draft.request = nil
        draft.hasUncertainSubmission = false
      }
    }
    let intent = replyDraft.request ?? QuestionRequest(
      sessionID: key.sessionID, requestID: uuid().uuidString.lowercased(), text: draft,
      context: thread.source.context, replyToQuestionID: parent.questionID,
      verb: .ask(bindingGeneration: bindingGeneration))
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

  /// A new question that failed starts over under a new request id, which its panel follows.
  func tryAgainTapped() {
    guard !isDismissed, let entry = pendingTurn,
      let requestID = instantAsk.tryAgainTapped(requestID: entry.id),
      entry.replyToQuestionID == nil, requestID != entry.id,
      let retried = instantAsk.pending[id: requestID]
    else { return }
    key = QuestionThreadKey(storeID: key.storeID, sessionID: key.sessionID, rootQuestionID: requestID)
    thread = retried.rootThread
  }

  func threadUpdated(_ thread: QuestionThread) {
    guard !isDismissed, thread.id == key.rootQuestionID else { return }
    self.thread = thread
  }

  func captureChanged(_ capture: CaptureSummary?) {
    bindingGeneration = capture?.binding?.generation ?? bindingGeneration
  }

  func dismissed() {
    isDismissed = true
  }

  // MARK: - Private Helpers

  private func followUpAsked(parent: QuestionTurn, folder: String, chatSessionID: String) {
    let question = InstantQuestion(
      storeID: key.storeID,
      sessionID: key.sessionID,
      folder: folder,
      source: thread.source,
      replyToQuestionID: parent.questionID,
      threadChatSessionID: chatSessionID,
      earlier: thread.turns.compactMap { turn in
        turn.answer.map { AskPrompt.Exchange(question: turn.text, answer: $0.text) }
      },
      text: draft
    )
    guard instantAsk.ask(question) != nil else { return }
    updateReplyDraft { $0 = ReplyDraft() }
  }

  private func clockTime(_ ms: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
  }

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
