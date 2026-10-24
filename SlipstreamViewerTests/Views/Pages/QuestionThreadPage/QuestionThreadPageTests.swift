import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct QuestionThreadPageTests {
  let storage = InMemoryStorage()
  let uuid = UUIDGenerator.incrementing

  static let key = QuestionThreadKey(storeID: "store-a", sessionID: Fixture.session, rootQuestionID: "q1")
  static let answered = QuestionTurn(
    questionID: "q1", requestID: "r-q1", text: "Why?", queuedAtMs: Fixture.observedAtMs,
    answer: QuestionAnswer(seq: Fixture.seq(3), text: "Because.", answeredAtMs: Fixture.observedAtMs))
  static let waiting = QuestionTurn(questionID: "q2", requestID: "r-q2", text: "And then?", queuedAtMs: Fixture.observedAtMs)
  static let notDelivered = QuestionTurn(
    questionID: "q2", requestID: "r-q2", text: "And then?", queuedAtMs: Fixture.observedAtMs, isDropped: true)
  static let resending = QuestionTurn(
    questionID: "q2", requestID: "r-q2", text: "And then?", queuedAtMs: Fixture.observedAtMs, isMoved: true)

  static func source(lines: ClosedRange<Int> = 7...9) -> QuestionSource {
    QuestionSource(
      context: QuestionContext(
        changeSeq: "1", path: "src/types/user.ts", snapshotSHA256: Fixture.shaB,
        lineStart: lines.lowerBound, lineEnd: lines.upperBound),
      selectedText: "a")
  }

  func makeModel(
    _ turns: [QuestionTurn], source: QuestionSource = source(), timeZone: String = "UTC", uuid: UUIDGenerator? = nil,
    bindingGeneration: String? = "7",
    send: @escaping @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { _ in throw QuestionError.unavailable }
  ) -> QuestionThreadPageModel {
    withDependencies {
      $0.defaultInMemoryStorage = storage
      $0.timeZone = TimeZone(identifier: timeZone)!
      $0.uuid = uuid ?? self.uuid
      $0.questionClient.send = send
    } operation: {
      QuestionThreadPageModel(
        key: Self.key, thread: QuestionThread(id: "q1", source: source, turns: turns), bindingGeneration: bindingGeneration)
    }
  }

  func readAnswers() -> Set<AnswerReadMarker> {
    withDependencies { $0.defaultInMemoryStorage = storage } operation: {
      @Shared(.readAnswers) var readAnswers
      return readAnswers
    }
  }

  @Test func sourceLineCountsQuestionsAndAnswers() {
    expectNoDifference(makeModel([Self.answered, Self.waiting]).sourceText, "user.ts:7–9 · 3 messages")
  }

  @Test func singleLineSourceShowsOneLineNumber() {
    expectNoDifference(makeModel([Self.waiting], source: Self.source(lines: 7...7)).sourceText, "user.ts:7 · 1 message")
  }

  @Test func agentTimeUsesTheInjectedTimeZone() throws {
    let answer = try #require(Self.answered.answer)
    expectNoDifference(makeModel([Self.answered]).agentText(answer), "AGENT · 10:42")
    expectNoDifference(makeModel([Self.answered], timeZone: "America/Chicago").agentText(answer), "AGENT · 05:42")
  }

  @Test func answerTextStartsAtItsFirstVisibleLine() {
    let answer = QuestionAnswer(seq: Fixture.seq(3), text: "\n\n  Actual answer\n", answeredAtMs: Fixture.observedAtMs)
    expectNoDifference(makeModel([Self.answered]).answerText(answer), "Actual answer")
  }

  @Test func followUpIsDisabledWhileTheLatestTurnWaits() {
    let model = makeModel([Self.answered, Self.waiting])
    #expect(model.isFollowUpDisabled)
    model.draft = "Ignored"
    expectNoDifference(model.draft, "")
    model.threadUpdated(QuestionThread(id: "q1", source: Self.source(), turns: [Self.answered]))
    #expect(!model.isFollowUpDisabled)
    model.draft = "Kept"
    expectNoDifference(model.draft, "Kept")
  }

  @Test func anUnansweredTurnSaysWhetherItIsWaitingOrWasNotDelivered() {
    let model = makeModel([Self.answered, Self.waiting])
    expectNoDifference(model.unansweredText(Self.waiting), "Waiting for the agent to answer…")
    expectNoDifference(model.unansweredText(Self.notDelivered), "Not delivered — recording restarted. Ask again.")
  }

  @Test func resendingText() {
    let model = makeModel([Self.answered, Self.resending])
    expectNoDifference(
      model.unansweredText(Self.resending), "Re-sending to the newly connected chat — waiting for the agent to answer…")
  }

  @Test func recordingRestartedKeepsTodayText() {
    var droppedAfterMove = Self.resending
    droppedAfterMove.isDropped = true
    let model = makeModel([Self.answered, droppedAfterMove])
    expectNoDifference(model.unansweredText(droppedAfterMove), "Not delivered — recording restarted. Ask again.")
  }

  @Test func resendingDisablesFollowUpsLikeWaiting() {
    let model = makeModel([Self.answered, Self.resending])
    #expect(model.isFollowUpDisabled)
    model.draft = "Ignored"
    expectNoDifference(model.draft, "")
  }

  @Test func aLatestTurnThatWasNotDeliveredCanBeAskedAgainAsANewFollowUp() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered, Self.notDelivered]) { request in
      requests.withValue { $0.append(request) }
      return try AskAgentPageTests.ack(request)
    }
    #expect(!model.isFollowUpDisabled)
    model.draft = "And then?"
    await model.sendReplyTapped()
    expectNoDifference(requests.value.map(\.replyToQuestionID), ["q2"])
  }

  @Test func aNewReplyRequiresAKnownBindingGeneration() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered], bindingGeneration: nil) { request in
      requests.withValue { $0.append(request) }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    #expect(!model.canSendReply)
    await model.sendReplyTapped()
    expectNoDifference(requests.value, [])
    model.captureChanged(Fixture.capture(binding: CaptureBinding(generation: "8", state: .connected)))
    #expect(model.canSendReply)
    await model.sendReplyTapped()
    expectNoDifference(requests.value.map(\.bindingGeneration), ["8"])
  }

  @Test func followUpUsesCurrentGeneration() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      return try AskAgentPageTests.ack(request)
    }
    model.captureChanged(Fixture.capture(binding: CaptureBinding(generation: "8", state: .connected)))
    model.captureChanged(nil)
    model.draft = "And then?"
    await model.sendReplyTapped()
    expectNoDifference(requests.value.map(\.bindingGeneration), ["8"])
  }

  @Test func inFlightFollowUpKeepsItsBody() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      throw QuestionError.outcomeUnknown
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    model.isErrorPresented = false
    model.captureChanged(Fixture.capture(binding: CaptureBinding(generation: "8", state: .connected)))
    await model.sendReplyTapped()
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(requests.value[1], requests.value[0])
    expectNoDifference(requests.value[1].bindingGeneration, "7")
  }

  @Test func displayingAnAnswerMarksOnlyThatAnswerRead() {
    let model = makeModel([Self.answered, Self.waiting])
    model.answerDisplayed(Fixture.seq(99))
    #expect(readAnswers().isEmpty)
    model.answerDisplayed(Fixture.seq(3))
    expectNoDifference(readAnswers(), [AnswerReadMarker(storeID: "store-a", sessionID: Fixture.session, seq: Fixture.seq(3))])
  }
}

extension QuestionThreadPageTests {
  static let followUp = QuestionTurn(
    questionID: "q2", requestID: "r-q2", text: "And then?", queuedAtMs: Fixture.observedAtMs,
    answer: QuestionAnswer(seq: Fixture.seq(5), text: "Then this.", answeredAtMs: Fixture.observedAtMs))

  static func thread(_ turns: [QuestionTurn]) -> QuestionThread {
    QuestionThread(id: "q1", source: source(), turns: turns)
  }

  @Test func sendReplyTargetsTheLatestTurnWithTheRootSourceUnchanged() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered, Self.followUp]) { request in
      requests.withValue { $0.append(request) }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "Could this suspend an account?"
    #expect(model.canSendReply)
    await model.sendReplyTapped()
    expectNoDifference(requests.value, [
      QuestionRequest(
        sessionID: Fixture.session, requestID: "00000000-0000-0000-0000-000000000000",
        text: "Could this suspend an account?", context: Self.source().context, replyToQuestionID: "q2",
        bindingGeneration: "7"),
    ])
    expectNoDifference(model.draft, "")
    #expect(!model.isErrorPresented)
  }

  @Test func sentReplyKeepsInputDisabledUntilItsTurnArrivesAndIsAnswered() async {
    let model = makeModel([Self.answered]) { try AskAgentPageTests.ack($0) }
    model.draft = "And then?"
    await model.sendReplyTapped()
    #expect(model.isFollowUpDisabled)
    model.draft = "Too soon"
    expectNoDifference(model.draft, "")
    let queuedID = "33333333-3333-4333-8333-333333333333"
    model.threadUpdated(Self.thread([Self.answered, QuestionTurn(questionID: queuedID, requestID: "r", text: "And then?", queuedAtMs: 1)]))
    #expect(model.isFollowUpDisabled)
    model.threadUpdated(Self.thread([Self.answered, QuestionTurn(
      questionID: queuedID, requestID: "r", text: "And then?", queuedAtMs: 1,
      answer: QuestionAnswer(seq: Fixture.seq(7), text: "Then.", answeredAtMs: 2))]))
    #expect(!model.isFollowUpDisabled)
  }

  @Test func replyWhoseTurnArrivedBeforeItsAcknowledgmentStillWaitsForTheAnswer() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let queuedID = "33333333-3333-4333-8333-333333333333"
    let model = makeModel([Self.answered]) { request in
      for await _ in gate { break }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    let send = Task { await model.sendReplyTapped() }
    await Task.megaYield()
    model.threadUpdated(Self.thread([Self.answered, QuestionTurn(questionID: queuedID, requestID: "r", text: "And then?", queuedAtMs: 1)]))
    resume.yield()
    await send.value
    #expect(model.isFollowUpDisabled)
    model.threadUpdated(Self.thread([Self.answered, QuestionTurn(
      questionID: queuedID, requestID: "r", text: "And then?", queuedAtMs: 1,
      answer: QuestionAnswer(seq: Fixture.seq(7), text: "Then.", answeredAtMs: 2))]))
    #expect(!model.isFollowUpDisabled)
  }

  @Test func uncertainReplyRetriedAfterReopenReusesItsRequestAndOriginalTarget() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let send: @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { request in
      requests.withValue { $0.append(request) }
      throw QuestionError.outcomeUnknown
    }
    let first = makeModel([Self.answered], send: send)
    first.draft = "And then?"
    await first.sendReplyTapped()
    #expect(first.isErrorPresented)
    #expect(first.errorMessage.contains("Retry unchanged to reuse its request ID"))
    first.dismissed()
    let reopened = makeModel([Self.answered, Self.followUp], send: send)
    expectNoDifference(reopened.draft, "And then?")
    expectNoDifference(reopened.uncertaintyNotice, "An earlier reply may already be queued. Send it unchanged to reuse its request ID; editing sends a separate question.")
    await reopened.sendReplyTapped()
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(requests.value[1], requests.value[0])
    expectNoDifference(requests.value[1].replyToQuestionID, "q1")
  }

  @Test func anUncertainReplyThatARestartDroppedIsAskedAgainWithAFreshRequest() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      if requests.value.count == 1 { throw QuestionError.outcomeUnknown }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    model.threadUpdated(Self.thread([Self.answered, QuestionTurn(
      questionID: "q2", requestID: requests.value[0].requestID, text: "And then?", queuedAtMs: 1, isDropped: true)]))
    expectNoDifference(model.uncertaintyNotice, nil)
    await model.sendReplyTapped()
    expectNoDifference(requests.value.map(\.requestID), [
      "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000001",
    ])
    expectNoDifference(requests.value.map(\.replyToQuestionID), ["q1", "q2"])
    expectNoDifference(model.draft, "")
  }

  @Test func anUncertainAskAgainOfANotDeliveredTurnReusesItsRequest() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered, Self.notDelivered]) { request in
      requests.withValue { $0.append(request) }
      throw QuestionError.outcomeUnknown
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    #expect(model.uncertaintyNotice != nil)
    await model.sendReplyTapped()
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(requests.value[1], requests.value[0])
  }

  @Test func anUncertainReplyThatWasAnsweredIsReusedWhenAnotherWindowsLaterTurnWasDropped() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      throw QuestionError.outcomeUnknown
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    model.threadUpdated(Self.thread([
      Self.answered,
      QuestionTurn(
        questionID: "q2", requestID: requests.value[0].requestID, text: "And then?", queuedAtMs: 1,
        answer: QuestionAnswer(seq: Fixture.seq(7), text: "Then.", answeredAtMs: 2)),
      QuestionTurn(questionID: "q3", requestID: "r-other-window", text: "Why?", queuedAtMs: 3, isDropped: true),
    ]))
    #expect(model.uncertaintyNotice != nil)
    await model.sendReplyTapped()
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(requests.value[1], requests.value[0])
  }

  @Test func editingAnUncertainReplySendsASeparateRequestToTheLatestTurn() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      if requests.value.count == 1 { throw QuestionError.rejected(code: "STORAGE_UNAVAILABLE", message: "") }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    model.threadUpdated(Self.thread([Self.answered, Self.followUp]))
    model.draft = "What next?"
    await model.sendReplyTapped()
    expectNoDifference(requests.value.map(\.requestID), [
      "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000001",
    ])
    expectNoDifference(requests.value.map(\.replyToQuestionID), ["q1", "q2"])
    expectNoDifference(model.draft, "")
    expectNoDifference(model.uncertaintyNotice, nil)
  }

  @Test func lateAcknowledgmentOfARetryKeepsANewerTurnAnotherWindowSaw() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      if requests.value.count == 1 { throw QuestionError.outcomeUnknown }
      for await _ in gate { break }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    model.threadUpdated(Self.thread([Self.answered, QuestionTurn(
      questionID: "33333333-3333-4333-8333-333333333333", requestID: "r", text: "And then?", queuedAtMs: 1,
      answer: QuestionAnswer(seq: Fixture.seq(7), text: "Then.", answeredAtMs: 2))]))
    let retry = Task { await model.sendReplyTapped() }
    await Task.megaYield()
    withDependencies { $0.defaultInMemoryStorage = storage } operation: {
      @Shared(.replyDrafts) var replyDrafts
      $replyDrafts.withLock { $0[Self.key, default: ReplyDraft()].turnQueued(QueuedTurn(questionID: "q4", seq: Fixture.seq(20))) }
    }
    resume.yield()
    await retry.value
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(requests.value[1], requests.value[0])
    #expect(model.isFollowUpDisabled)
  }

  @Test func definiteRejectionKeepsTheDraftWithoutUncertainty() async {
    let model = makeModel([Self.answered]) { _ in throw QuestionError.rejected(code: "SESSION_NOT_SELECTED", message: "") }
    model.draft = "And then?"
    await model.sendReplyTapped()
    #expect(model.isErrorPresented)
    expectNoDifference(model.errorMessage, "This capture is no longer attached to the agent. The question stays bound to its original capture. Your draft is kept.")
    expectNoDifference(model.draft, "And then?")
    expectNoDifference(model.uncertaintyNotice, nil)
    #expect(model.canSendReply)
  }

  @Test func retryAfterADefiniteRejectionFollowsTheLatestTurn() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      requests.withValue { $0.append(request) }
      if requests.value.count == 1 { throw QuestionError.rejected(code: "QUESTION_LIMIT", message: "") }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    model.threadUpdated(Self.thread([Self.answered, Self.followUp]))
    await model.sendReplyTapped()
    expectNoDifference(requests.value.map(\.requestID), [
      "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000001",
    ])
    expectNoDifference(requests.value.map(\.replyToQuestionID), ["q1", "q2"])
  }

  @Test func sentReplyEncodesItsParentOnTheWire() async throws {
    let parentID = "44444444-4444-4444-8444-444444444444"
    let parent = QuestionTurn(
      questionID: parentID, requestID: "r", text: "Why?", queuedAtMs: Fixture.observedAtMs,
      answer: QuestionAnswer(seq: Fixture.seq(3), text: "Because.", answeredAtMs: Fixture.observedAtMs))
    let bodies = LockIsolated<[Data]>([])
    let model = makeModel([parent], uuid: UUIDGenerator { UUID(uuidString: "55555555-5555-4555-8555-555555555555")! }) { request in
      try bodies.withValue { $0.append(try request.encoded()) }
      return try AskAgentPageTests.ack(request)
    }
    model.draft = "And then?"
    await model.sendReplyTapped()
    #expect(!model.isErrorPresented)
    let body = try #require(bodies.value.first)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    expectNoDifference(json["reply_to_question_id"] as? String, parentID)
  }

  @Test func anotherWindowCannotEditOrResendWhileAReplyIsInFlight() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[QuestionRequest]>([])
    let send: @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { request in
      requests.withValue { $0.append(request) }
      for await _ in gate { break }
      return try AskAgentPageTests.ack(request)
    }
    let first = makeModel([Self.answered], send: send)
    let second = makeModel([Self.answered], send: send)
    first.draft = "And then?"
    let sending = Task { await first.sendReplyTapped() }
    await Task.megaYield()
    #expect(second.isFollowUpDisabled)
    #expect(!second.canSendReply)
    second.draft = "Something else"
    await second.sendReplyTapped()
    expectNoDifference(second.draft, "And then?")
    resume.yield()
    await sending.value
    expectNoDifference(requests.value.count, 1)
    expectNoDifference(second.draft, "")
  }

  @Test func lateFailureAfterCollapseKeepsTheRetryWithoutAlertingTheClosedPopover() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[QuestionRequest]>([])
    let send: @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { request in
      requests.withValue { $0.append(request) }
      for await _ in gate { break }
      throw QuestionError.outcomeUnknown
    }
    let first = makeModel([Self.answered], send: send)
    first.draft = "And then?"
    let sending = Task { await first.sendReplyTapped() }
    await Task.megaYield()
    first.dismissed()
    let reopened = makeModel([Self.answered], send: send)
    #expect(!reopened.canSendReply)
    resume.yield()
    await sending.value
    #expect(!first.isErrorPresented)
    #expect(!reopened.isErrorPresented)
    expectNoDifference(reopened.draft, "And then?")
    #expect(reopened.uncertaintyNotice != nil)
    #expect(reopened.canSendReply)
    let retry = Task { await reopened.sendReplyTapped() }
    await Task.megaYield()
    resume.yield()
    await retry.value
    expectNoDifference(Set(requests.value.map(\.requestID)).count, 1)
  }
}
