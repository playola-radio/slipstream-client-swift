import Sharing
import SlipstreamCore

struct AnswerReadMarker: Hashable, Sendable {
  let storeID: String
  let sessionID: String
  let seq: Seq
}

struct QuestionThreadKey: Hashable, Sendable {
  let storeID: String
  let sessionID: String
  let rootQuestionID: String
}

enum QuestionBarStatus: Equatable, Sendable {
  case newReply, waiting, answered
}

struct QuestionBar: Identifiable, Equatable, Sendable {
  let id: String
  let preview: String
  let status: QuestionBarStatus
  let isOpen: Bool

  var statusText: String {
    switch status {
    case .newReply: "New reply"
    case .waiting: "Waiting"
    case .answered: "Answered"
    }
  }
}

extension SharedKey where Self == InMemoryKey<Set<AnswerReadMarker>>.Default {
  static var readAnswers: Self {
    Self[.inMemory("readAnswers"), default: []]
  }
}

struct ReplyDraft: Equatable, Sendable {
  var text = ""
  var request: QuestionRequest?
  var isSubmitting = false
  var hasUncertainSubmission = false
  var queuedQuestionID: String?
}

extension SharedKey where Self == InMemoryKey<[QuestionThreadKey: ReplyDraft]>.Default {
  static var replyDrafts: Self {
    Self[.inMemory("replyDrafts"), default: [:]]
  }
}
