import Dependencies
import Foundation
import Sharing
import SlipstreamCore

@MainActor
@Observable
final class QuestionThreadPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.timeZone) var timeZone

  // MARK: - Shared State

  @ObservationIgnored @Shared(.readAnswers) var readAnswers
  @ObservationIgnored @Shared(.questionDrafts) var drafts

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

  var draft: String {
    get { drafts[key] ?? "" }
    set {
      guard !isFollowUpDisabled else { return }
      $drafts.withLock { $0[key] = newValue.isEmpty ? nil : newValue }
    }
  }

  // MARK: - Display Text

  let title = "Talk to the agent"
  let closeText = "Close reply"
  let waitingText = "Waiting for the agent to answer…"
  let followUpPlaceholder = "Ask a follow-up…"

  var sourceText: String {
    let context = thread.source.context
    let file = (context.path as NSString).lastPathComponent
    let lines = context.lineStart == context.lineEnd ? "\(context.lineStart)" : "\(context.lineStart)–\(context.lineEnd)"
    let messages = thread.turns.count + thread.turns.filter { $0.answer != nil }.count
    return "\(file):\(lines) · \(messages) \(messages == 1 ? "message" : "messages")"
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

  var isFollowUpDisabled: Bool { isDismissed || thread.turns.last?.answer == nil }

  // MARK: - User Actions

  func answerDisplayed(_ seq: Seq) {
    guard !isDismissed, thread.turns.contains(where: { $0.answer?.seq == seq }) else { return }
    let marker = AnswerReadMarker(storeID: key.storeID, sessionID: key.sessionID, seq: seq)
    $readAnswers.withLock { _ = $0.insert(marker) }
  }

  func threadUpdated(_ thread: QuestionThread) {
    guard !isDismissed, thread.id == key.rootQuestionID else { return }
    self.thread = thread
  }

  func dismissed() {
    isDismissed = true
  }
}
