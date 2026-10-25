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

public struct RelayStep: Equatable, Sendable {
  public let seq: Seq
  public let atMs: Int64

  public init(seq: Seq, atMs: Int64) {
    self.seq = seq
    self.atMs = atMs
  }
}

public struct RelayReport: Equatable, Sendable {
  public let outcome: ReportOutcome
  public let text: String
  public let seq: Seq

  public init(outcome: ReportOutcome, text: String, seq: Seq) {
    self.outcome = outcome
    self.text = text
    self.seq = seq
  }
}

public enum QuestionRelayStatus: Equatable, Sendable {
  case done
  case couldntCheck
  case notDelivered
  case notDoneYet
  case working
  case pickedUp
  case deliveryUnknown
  case sent
}

public struct QuestionRelay: Identifiable, Equatable, Sendable {
  public let id: String
  public let questionID: String
  public let chatSessionID: String
  public let sent: RelayStep
  public var pickedUp: RelayStep?
  public var isNotDelivered: Bool
  public var report: RelayReport?
  public var changedPaths: [String]
  public var lastChangeSeq: Seq?

  public init(
    id: String, questionID: String, chatSessionID: String, sent: RelayStep, pickedUp: RelayStep? = nil,
    isNotDelivered: Bool = false, report: RelayReport? = nil, changedPaths: [String] = [], lastChangeSeq: Seq? = nil
  ) {
    self.id = id
    self.questionID = questionID
    self.chatSessionID = chatSessionID
    self.sent = sent
    self.pickedUp = pickedUp
    self.isNotDelivered = isNotDelivered
    self.report = report
    self.changedPaths = changedPaths
    self.lastChangeSeq = lastChangeSeq
  }

  public var isDone: Bool { report?.outcome == .done }

  /// `livePickup` and `liveWrite` are what this app run saw before the log caught up.
  public func status(livePickup: Bool, liveWrite: Bool, lastCheckFailed: Bool) -> QuestionRelayStatus {
    let isPickedUp = pickedUp != nil || livePickup
    if isDone { return .done }
    if lastCheckFailed { return .couldntCheck }
    if isNotDelivered && !isPickedUp { return .notDelivered }
    if let report, report.outcome == .notDoneYet, lastChangeSeq.map({ $0 < report.seq }) ?? true {
      return .notDoneYet
    }
    if isPickedUp { return changedPaths.isEmpty ? .pickedUp : .working }
    return liveWrite ? .sent : .deliveryUnknown
  }

  mutating func apply(_ update: RelayUpdate, seq: Seq, atMs: Int64) {
    switch update {
    case .sent:
      break
    case .pickedUp:
      guard pickedUp == nil else { return }
      pickedUp = RelayStep(seq: seq, atMs: atMs)
      isNotDelivered = false
    case .notDelivered:
      guard !isDone else { return }
      isNotDelivered = pickedUp == nil
    case .reported(let outcome, let text):
      guard !isDone else { return }
      report = RelayReport(outcome: outcome, text: text, seq: seq)
    }
  }

  mutating func fileChanged(_ path: String, seq: Seq) {
    guard !isDone, sent.seq < seq else { return }
    if !changedPaths.contains(path) { changedPaths.append(path) }
    lastChangeSeq = seq
  }
}

public struct QuestionTurn: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case waiting
    case answered
    case notDelivered
    case resending
  }

  public let questionID: String
  public let requestID: String
  public let text: String
  public let queuedAtMs: Int64
  public var answer: QuestionAnswer?
  public var isDropped: Bool
  public var isMoved: Bool
  public var relays: [QuestionRelay]

  public init(
    questionID: String, requestID: String, text: String, queuedAtMs: Int64, answer: QuestionAnswer? = nil,
    isDropped: Bool = false, isMoved: Bool = false, relays: [QuestionRelay] = []
  ) {
    self.questionID = questionID
    self.requestID = requestID
    self.text = text
    self.queuedAtMs = queuedAtMs
    self.answer = answer
    self.isDropped = isDropped
    self.isMoved = isMoved
    self.relays = relays
  }

  public var status: Status {
    if answer != nil { return .answered }
    if isDropped { return .notDelivered }
    return isMoved ? .resending : .waiting
  }
}

public enum QuestionThreadLink: Equatable, Sendable {
  case hook
  case recorded(chatSessionID: String)
}

public struct QuestionThread: Identifiable, Equatable, Sendable {
  public let id: String
  public let source: QuestionSource
  public var turns: [QuestionTurn]
  public let link: QuestionThreadLink

  public init(id: String, source: QuestionSource, turns: [QuestionTurn], link: QuestionThreadLink = .hook) {
    self.id = id
    self.source = source
    self.turns = turns
    self.link = link
  }
}

public struct QuestionThreads: Equatable, Sendable {
  public private(set) var threads: IdentifiedArrayOf<QuestionThread> = []
  private var rootByQuestionID: [String: String] = [:]
  private var undispatchedQuestionIDs: Set<String> = []
  private var queuedSinceResumeIDs: Set<String> = []
  private var questionIDByRelayID: [String: String] = [:]
  private var openRelayIDs: Set<String> = []

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
      queuedSinceResumeIDs.insert(question.questionID)
    case .questionExchangeRecorded(let exchange):
      guard rootByQuestionID[exchange.questionID] == nil else { return }
      let turn = QuestionTurn(
        questionID: exchange.questionID, requestID: exchange.requestID, text: exchange.text,
        queuedAtMs: exchange.recordedAtMs,
        answer: QuestionAnswer(seq: event.seq, text: exchange.answerText, answeredAtMs: exchange.recordedAtMs))
      if let parentID = exchange.replyToQuestionID {
        guard let rootID = rootByQuestionID[parentID], case .recorded = threads[id: rootID]?.link else { return }
        rootByQuestionID[exchange.questionID] = rootID
        threads[id: rootID]?.turns.append(turn)
      } else {
        rootByQuestionID[exchange.questionID] = exchange.questionID
        threads.append(
          QuestionThread(
            id: exchange.questionID, source: exchange.source, turns: [turn],
            link: .recorded(chatSessionID: exchange.chatSessionID)))
      }
      if let relay = exchange.relay {
        addRelay(
          relay.relayID, questionID: exchange.questionID, chatSessionID: relay.chatSessionID,
          sent: RelayStep(seq: event.seq, atMs: exchange.recordedAtMs))
      }
    case .questionRelayUpdated(let relay):
      if case .sent(let chatSessionID) = relay.update {
        addRelay(
          relay.relayID, questionID: relay.questionID, chatSessionID: chatSessionID,
          sent: RelayStep(seq: event.seq, atMs: relay.recordedAtMs))
        return
      }
      guard questionIDByRelayID[relay.relayID] == relay.questionID else { return }
      updateRelay(relay.relayID) { $0.apply(relay.update, seq: event.seq, atMs: relay.recordedAtMs) }
    case .fileChanged(let change):
      for relayID in openRelayIDs {
        updateRelay(relayID) { $0.fileChanged(change.path, seq: event.seq) }
      }
    case .questionDispatchAttempted(let attempt):
      undispatchedQuestionIDs.remove(attempt.questionID)
      updateTurn(attempt.questionID) { $0.isMoved = false }
    case .agentUnlinked(let unlinked):
      guard unlinked.reason == "unlinked" else { return }
      for thread in threads {
        for turn in thread.turns where turn.answer == nil && queuedSinceResumeIDs.contains(turn.questionID) {
          undispatchedQuestionIDs.insert(turn.questionID)
          updateTurn(turn.questionID) { $0.isMoved = true }
        }
      }
    case .sessionResumed:
      for questionID in undispatchedQuestionIDs {
        updateTurn(questionID) { $0.isDropped = true }
      }
      undispatchedQuestionIDs.removeAll()
      queuedSinceResumeIDs.removeAll()
    case .questionAnswered(let answer):
      updateTurn(answer.questionID) { turn in
        guard turn.answer == nil else { return }
        turn.answer = QuestionAnswer(seq: event.seq, text: answer.text, answeredAtMs: answer.answeredAtMs)
      }
    default:
      break
    }
  }

  private mutating func addRelay(_ relayID: String, questionID: String, chatSessionID: String, sent: RelayStep) {
    guard questionIDByRelayID[relayID] == nil, rootByQuestionID[questionID] != nil else { return }
    questionIDByRelayID[relayID] = questionID
    openRelayIDs.insert(relayID)
    updateTurn(questionID) {
      $0.relays.append(QuestionRelay(id: relayID, questionID: questionID, chatSessionID: chatSessionID, sent: sent))
    }
  }

  private mutating func updateRelay(_ relayID: String, _ body: (inout QuestionRelay) -> Void) {
    guard let questionID = questionIDByRelayID[relayID] else { return }
    var isDone = false
    updateTurn(questionID) { turn in
      guard let index = turn.relays.firstIndex(where: { $0.id == relayID }) else { return }
      body(&turn.relays[index])
      isDone = turn.relays[index].isDone
    }
    if isDone { openRelayIDs.remove(relayID) }
  }

  private mutating func updateTurn(_ questionID: String, _ body: (inout QuestionTurn) -> Void) {
    guard let rootID = rootByQuestionID[questionID],
      let index = threads[id: rootID]?.turns.firstIndex(where: { $0.questionID == questionID }),
      var turn = threads[id: rootID]?.turns[index]
    else { return }
    body(&turn)
    threads[id: rootID]?.turns[index] = turn
  }
}
