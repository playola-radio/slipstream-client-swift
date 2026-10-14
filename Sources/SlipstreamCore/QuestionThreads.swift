import IdentifiedCollections

public struct QuestionAnswer: Equatable, Sendable {
  public let seq: Seq
  public let text: String
  public let answeredAtMs: Int64

  public init(seq: Seq, text: String, answeredAtMs: Int64) {
    self.seq = seq
    self.text = text
    self.answeredAtMs = answeredAtMs
  }
}

public struct QuestionTurn: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case waiting
    case answered
    case notDelivered
  }

  public let questionID: String
  public let requestID: String
  public let text: String
  public let queuedAtMs: Int64
  public var answer: QuestionAnswer?
  public var isDropped: Bool

  public init(
    questionID: String, requestID: String, text: String, queuedAtMs: Int64, answer: QuestionAnswer? = nil,
    isDropped: Bool = false
  ) {
    self.questionID = questionID
    self.requestID = requestID
    self.text = text
    self.queuedAtMs = queuedAtMs
    self.answer = answer
    self.isDropped = isDropped
  }

  public var status: Status {
    if answer != nil { return .answered }
    return isDropped ? .notDelivered : .waiting
  }
}

public struct QuestionThread: Identifiable, Equatable, Sendable {
  public let id: String
  public let source: QuestionSource
  public var turns: [QuestionTurn]

  public init(id: String, source: QuestionSource, turns: [QuestionTurn]) {
    self.id = id
    self.source = source
    self.turns = turns
  }
}

public struct QuestionThreads: Equatable, Sendable {
  public private(set) var threads: IdentifiedArrayOf<QuestionThread> = []
  private var rootByQuestionID: [String: String] = [:]
  private var undispatchedQuestionIDs: Set<String> = []

  public init() {}

  public init(_ events: some Sequence<SlipstreamEvent>) {
    for event in events {
      apply(event)
    }
  }

  public mutating func apply(_ event: SlipstreamEvent) {
    switch event.payload {
    case .questionQueued(let question):
      guard rootByQuestionID[question.questionID] == nil else { return }
      let turn = QuestionTurn(
        questionID: question.questionID, requestID: question.requestID, text: question.text,
        queuedAtMs: question.queuedAtMs)
      if let parentID = question.replyToQuestionID {
        guard let rootID = rootByQuestionID[parentID] else { return }
        rootByQuestionID[question.questionID] = rootID
        threads[id: rootID]?.turns.append(turn)
      } else {
        rootByQuestionID[question.questionID] = question.questionID
        threads.append(QuestionThread(id: question.questionID, source: question.source, turns: [turn]))
      }
      undispatchedQuestionIDs.insert(question.questionID)
    case .questionDispatchAttempted(let attempt):
      undispatchedQuestionIDs.remove(attempt.questionID)
    case .sessionResumed:
      for questionID in undispatchedQuestionIDs {
        guard let rootID = rootByQuestionID[questionID],
          let index = threads[id: rootID]?.turns.firstIndex(where: { $0.questionID == questionID })
        else { continue }
        threads[id: rootID]?.turns[index].isDropped = true
      }
      undispatchedQuestionIDs.removeAll()
    case .questionAnswered(let answer):
      guard
        let rootID = rootByQuestionID[answer.questionID],
        let index = threads[id: rootID]?.turns.firstIndex(where: { $0.questionID == answer.questionID }),
        threads[id: rootID]?.turns[index].answer == nil
      else { return }
      threads[id: rootID]?.turns[index].answer = QuestionAnswer(
        seq: event.seq, text: answer.text, answeredAtMs: answer.answeredAtMs)
    default:
      break
    }
  }
}
