import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct QuestionThreadPageTests {
  let storage = InMemoryStorage()
  let clock = TestClock()
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

  static let tab = UUID(uuidString: "4BAD416C-1D04-4063-9E76-61EBB936AE06")!
  static let recorded = QuestionThreadLink.recorded(chatSessionID: tab.uuidString.lowercased())

  let fork = ForkFake()
  let recorder = RecordFake()

  func makeModel(
    _ turns: [QuestionTurn], source: QuestionSource = source(), timeZone: String = "UTC", uuid: UUIDGenerator? = nil,
    bindingGeneration: String? = "7", link: QuestionThreadLink = .hook, folder: String? = "/w",
    instantAsk: InstantAskModel? = nil,
    send: @escaping @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { _ in throw QuestionError.unavailable }
  ) -> QuestionThreadPageModel {
    withDependencies {
      $0.defaultInMemoryStorage = storage
      $0.timeZone = TimeZone(identifier: timeZone)!
      $0.uuid = uuid ?? self.uuid
      $0.questionClient.send = send
    } operation: {
      QuestionThreadPageModel(
        key: Self.key, thread: QuestionThread(id: "q1", source: source, turns: turns, link: link),
        bindingGeneration: bindingGeneration, folder: folder, instantAsk: instantAsk ?? makeInstantAsk())
    }
  }

  /// The thread's chat is open as a tab in `/w`.
  func makeInstantAsk(agent: AgentFake = AgentFake(), clock: TestClock<Duration>? = nil) -> InstantAskModel {
    withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock {
        $0 = [ChatTabRecord(id: Self.tab, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false)]
      }
      return InstantAskModel.fake(chat: ChatPageModel(), fork: fork, recorder: recorder, agent: agent, clock: clock)
    }
  }

  func followUpSent(_ model: QuestionThreadPageModel, _ text: String = "And then?") async {
    model.draft = text
    await model.sendReplyTapped()
    await Task.megaYield()
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
    expectNoDifference(requests.value.map(\.verb), [.ask(bindingGeneration: "8")])
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
    expectNoDifference(requests.value.map(\.verb), [.ask(bindingGeneration: "8")])
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
    expectNoDifference(requests.value[1].verb, .ask(bindingGeneration: "7"))
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
        verb: .ask(bindingGeneration: "7")),
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

extension QuestionThreadPageTests {
  @Test func answeringTurnShowsThinking() async throws {
    let model = makeModel([Self.answered], link: Self.recorded)
    await followUpSent(model)
    let pending = try #require(model.pendingTurn)
    expectNoDifference(pending.text, "And then?")
    expectNoDifference(pending.state, .answering)
    #expect(model.pendingFailureText == nil)
    expectNoDifference(model.thinkingText, "AGENT · thinking…")
    expectNoDifference(model.sourceText, "user.ts:7–9 · 3 messages")
  }

  @Test func sendReplyDisabledWhileAnswering() async {
    let model = makeModel([Self.answered], link: Self.recorded)
    await followUpSent(model)
    model.draft = "One more?"
    #expect(model.isFollowUpDisabled)
    #expect(!model.canSendReply)
    expectNoDifference(model.draft, "")
  }

  @Test func oversizedRecordedFollowUpKeepsItsDraftAndDoesNotStartAnAnswer() async {
    let model = makeModel([Self.answered], link: Self.recorded)
    let text = String(repeating: "😀", count: 2049)
    model.draft = text

    #expect(!model.canSendReply)
    await model.sendReplyTapped()

    expectNoDifference(model.draft, text)
    expectNoDifference(fork.requests, [])
  }

  @Test(arguments: [
    (AskForkError.timedOut, "no reply within 120 seconds", nil),
    (.unavailable("Claude Code exited with status 1."), "the chat couldn't be reached", "Claude Code exited with status 1."),
    (.badReply("The reply was empty."), "the reply couldn't be read", "The reply was empty."),
  ])
  func couldntAnswerShowsReasonAndTryAgain(error: AskForkError, reason: String, detail: String?) async {
    let model = makeModel([Self.answered], link: Self.recorded)
    await followUpSent(model)
    fork.reply(.failure(error))
    await Task.megaYield()
    expectNoDifference(model.pendingFailureText, reason)
    expectNoDifference(model.pendingFailureDetail, detail)
    expectNoDifference(model.couldntAnswerText, "Couldn't get an answer")
    expectNoDifference(model.tryAgainText, "Try again")
    model.tryAgainTapped()
    await Task.megaYield()
    #expect(model.pendingFailureText == nil)
    #expect(model.pendingFailureDetail == nil)
    expectNoDifference(fork.requests.count, 2)
  }

  @Test func missingEnvironmentShowsClaudeIsntReady() async {
    let agent = AgentFake()
    agent.setEnvironmentError(.claudeNotFound)
    let model = makeModel([Self.answered], link: Self.recorded, instantAsk: makeInstantAsk(agent: agent))
    await followUpSent(model)
    expectNoDifference(model.pendingFailureText, "Claude Code isn't ready")
    expectNoDifference(model.pendingFailureDetail, "Couldn't find claude on your login shell's PATH.")
  }

  @Test func followUpWithoutAChatShowsNoChatIsOpen() async {
    let instantAsk = withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      InstantAskModel.fake(chat: ChatPageModel(), fork: fork, recorder: recorder)
    }
    let model = makeModel([Self.answered], link: Self.recorded, instantAsk: instantAsk)
    await followUpSent(model)
    expectNoDifference(model.pendingFailureText, "no chat is connected to this folder")
    expectNoDifference(model.pendingFailureDetail, "No chat is connected to w. Send a message in a chat tab to connect it, then try again.")
  }

  @Test func couldntSaveShowsReasonAndTryAgain() async {
    recorder.script(.failure(.rejected(code: "INVALID_CONTEXT", message: "No.")))
    let model = makeModel([Self.answered], link: Self.recorded)
    await followUpSent(model)
    fork.answer()
    await Task.megaYield()
    expectNoDifference(model.pendingFailureText, "it couldn't be saved")
    expectNoDifference(
      model.pendingFailureDetail,
      "This source selection couldn't be verified. Select up to 200 lines totaling at most 16 KiB from an available snapshot. The daemon said: No."
    )
  }

  @Test func unconfirmedSaveShowsDaemonDidntConfirm() async {
    recorder.script(.failure(.outcomeUnknown), .failure(.outcomeUnknown), .failure(.outcomeUnknown))
    let model = makeModel([Self.answered], link: Self.recorded, instantAsk: makeInstantAsk(clock: clock))
    await followUpSent(model)
    fork.answer()
    await Task.megaYield()
    await clock.advance(by: .seconds(5))
    await Task.megaYield()
    expectNoDifference(model.pendingFailureText, "it couldn't be saved")
    expectNoDifference(model.pendingFailureDetail, "The daemon didn't confirm it saved the answer.")
  }

  @Test func followUpOnRecordedThreadUsesInstantAsk() async throws {
    let model = makeModel([Self.answered], link: Self.recorded)
    await followUpSent(model)
    let request = try #require(fork.requests.first)
    expectNoDifference(request.parentSessionID, Self.tab)
    expectNoDifference(
      request.prompt,
      AskPrompt.answer(
        source: Self.source(), earlier: [AskPrompt.Exchange(question: "Why?", answer: "Because.")], words: "And then?",
        allowsChangeRequests: false))
    expectNoDifference(model.pendingTurn?.replyToQuestionID, "q1")
  }

  @Test func recordedThreadNeverSendsAsk() async {
    let sent = LockIsolated(0)
    let model = makeModel([Self.answered], link: Self.recorded) { _ in
      sent.withValue { $0 += 1 }
      throw QuestionError.unavailable
    }
    await followUpSent(model)
    let noFolder = makeModel([Self.answered], link: Self.recorded, folder: nil) { _ in
      sent.withValue { $0 += 1 }
      throw QuestionError.unavailable
    }
    noFolder.draft = "And then?"
    #expect(!noFolder.canSendReply)
    await noFolder.sendReplyTapped()
    expectNoDifference(sent.value, 0)
  }

  @Test func hookThreadKeepsTodayFollowUp() async {
    let sent = LockIsolated<[QuestionRequest]>([])
    let model = makeModel([Self.answered]) { request in
      sent.withValue { $0.append(request) }
      throw QuestionError.unavailable
    }
    await followUpSent(model)
    expectNoDifference(sent.value.map(\.verb), [.ask(bindingGeneration: "7")])
    #expect(fork.requests.isEmpty)
  }

  @Test func newQuestionTryAgainFollowsNewRequest() async throws {
    let instantAsk = makeInstantAsk()
    let requestID = try #require(
      instantAsk.ask(
        InstantQuestion(
          storeID: Self.key.storeID, sessionID: Self.key.sessionID, folder: "/w", source: Self.source(),
          replyToQuestionID: nil, threadChatSessionID: Self.tab.uuidString.lowercased(), earlier: [], text: "Why?")))
    let entry = try #require(instantAsk.pending[id: requestID])
    let model = withDependencies { $0.defaultInMemoryStorage = storage } operation: {
      QuestionThreadPageModel(
        key: QuestionThreadKey(storeID: Self.key.storeID, sessionID: Self.key.sessionID, rootQuestionID: requestID),
        thread: entry.rootThread, bindingGeneration: nil, folder: "/w", instantAsk: instantAsk)
    }
    await Task.megaYield()
    fork.reply(.failure(.timedOut))
    await Task.megaYield()
    model.tryAgainTapped()
    let retried = try #require(instantAsk.pending.first)
    #expect(retried.id != requestID)
    expectNoDifference(model.key.rootQuestionID, retried.id)
    expectNoDifference(model.pendingTurn?.state, .answering)
  }
}

extension QuestionThreadPageTests {
  static let at1402: Int64 = 1_699_970_520_000
  static let at1403: Int64 = 1_699_970_580_000
  static let at1405: Int64 = 1_699_970_700_000
  static let loggedRelay = "aaaaaaaa-0000-4000-8000-000000000001"

  static func relay(
    _ id: String = loggedRelay, pickedUp: Bool = false, notDelivered: Bool = false, paths: [String] = [],
    report: RelayReport? = nil
  ) -> QuestionRelay {
    QuestionRelay(
      id: id, questionID: "q2", chatSessionID: tab.uuidString.lowercased(), sent: RelayStep(seq: Fixture.seq(6), atMs: at1402),
      pickedUp: pickedUp ? RelayStep(seq: Fixture.seq(7), atMs: at1403) : nil, isNotDelivered: notDelivered,
      report: report, changedPaths: paths)
  }

  static func report(_ outcome: ReportOutcome, _ text: String) -> RelayReport {
    RelayReport(outcome: outcome, text: text, seq: Fixture.seq(9), atMs: at1405)
  }

  static func onIt(requestID: String = "r-q2", _ relays: QuestionRelay...) -> QuestionTurn {
    QuestionTurn(
      questionID: "q2", requestID: requestID, text: "Rename it", queuedAtMs: at1402,
      answer: QuestionAnswer(seq: Fixture.seq(5), text: "On it.", answeredAtMs: at1402), relays: relays)
  }

  static func recordedThread(_ turns: [QuestionTurn]) -> IdentifiedArrayOf<QuestionThread> {
    [QuestionThread(id: "q1", source: source(), turns: turns, link: recorded)]
  }

  /// The thread's chat is an idle tab the agent can be written to, and it is 14:05.
  func makeRelayingInstantAsk(_ agent: AgentFake) -> (instantAsk: InstantAskModel, chat: ChatPageModel) {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.agentEnvironment = agent.environmentClient
      $0.agentProcess = agent.processClient
      $0.transcripts = agent.transcriptClient
      $0.askFork = fork.client
      $0.questionClient = recorder.client
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: Double(Self.at1405) / 1000))
      $0.uuid = .incrementing
    } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock {
        $0 = [ChatTabRecord(id: Self.tab, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false)]
      }
      let chat = ChatPageModel()
      return (InstantAskModel(chat: chat), chat)
    }
  }

  func handOver(_ instantAsk: InstantAskModel, _ turns: [QuestionTurn]) {
    instantAsk.threadsFolded(
      storeID: Self.key.storeID, sessionID: Self.key.sessionID, folder: "/w", isReplaying: false,
      threads: Self.recordedThread(turns))
  }

  func progress(_ model: QuestionThreadPageModel, turn: Int = 1) -> RelayProgress? {
    model.progress(model.thread.turns[turn])
  }

  @Test func sentLineWhileAgentBusy() async throws {
    let (instantAsk, _) = makeRelayingInstantAsk(AgentFake())
    let turns = [Self.answered, Self.onIt(Self.relay())]
    handOver(instantAsk, turns)
    let model = makeModel(turns, link: Self.recorded, instantAsk: instantAsk)

    await model.sendAgainTapped(try #require(progress(model)))
    let resent = Self.relay(UUID(0).uuidString.lowercased())
    model.threadUpdated(Self.thread([Self.answered, Self.onIt(Self.relay(), resent)]))

    expectNoDifference(
      progress(model),
      RelayProgress(
        relayID: resent.id,
        lines: [.init(mark: .waiting, label: "Sent", detail: "14:02 · the agent will read this after its current step")],
        action: nil, isActionDisabled: false, report: nil))
  }

  @Test func pickedUpLine() {
    let model = makeModel([Self.answered, Self.onIt(Self.relay(pickedUp: true))], link: Self.recorded)

    expectNoDifference(
      progress(model)?.lines,
      [.init(mark: .done, label: "Sent", detail: "14:02"), .init(mark: .done, label: "Picked up", detail: "14:03")])
  }

  @Test func workingLineForEachChangedFile() {
    let model = makeModel(
      [Self.answered, Self.onIt(Self.relay(pickedUp: true, paths: ["greet.py", "app/main.py"]))], link: Self.recorded)

    expectNoDifference(
      progress(model)?.lines,
      [
        .init(mark: .done, label: "Sent", detail: "14:02"),
        .init(mark: .done, label: "Picked up", detail: "14:03"),
        .init(mark: .working, label: "Working", detail: "changes seen in greet.py"),
        .init(mark: .working, label: "Working", detail: "changes seen in app/main.py"),
      ])
  }

  @Test func notDoneYetLineThenReport() {
    let model = makeModel(
      [Self.answered, Self.onIt(Self.relay(pickedUp: true, report: Self.report(.notDoneYet, "Not yet.\n")))],
      link: Self.recorded)

    expectNoDifference(
      progress(model),
      RelayProgress(
        relayID: Self.loggedRelay,
        lines: [
          .init(mark: .done, label: "Sent", detail: "14:02"),
          .init(mark: .done, label: "Picked up", detail: "14:03"),
          .init(mark: .notDoneYet, label: "Not done yet", detail: "checking again when the agent's next turn ends"),
        ],
        action: nil, isActionDisabled: false,
        report: RelayProgress.Report(seq: Fixture.seq(9), agentText: "AGENT · 14:05", text: "Not yet.")))
  }

  @Test func doneFoldsProgressToOneLineThenReport() {
    let model = makeModel(
      [Self.answered, Self.onIt(Self.relay(pickedUp: true, paths: ["greet.py"], report: Self.report(.done, "Renamed it.")))],
      link: Self.recorded)

    expectNoDifference(
      progress(model),
      RelayProgress(
        relayID: Self.loggedRelay,
        lines: [.init(mark: .done, label: "Done", detail: "sent 14:02 · picked up 14:03 · greet.py")],
        action: nil, isActionDisabled: false,
        report: RelayProgress.Report(seq: Fixture.seq(9), agentText: "AGENT · 14:05", text: "Renamed it.")))
  }

  @Test func notDeliveredLine() {
    let model = makeModel([Self.answered, Self.onIt(Self.relay(notDelivered: true))], link: Self.recorded)

    expectNoDifference(
      progress(model)?.lines,
      [
        .init(mark: .done, label: "Sent", detail: "14:02"),
        .init(mark: .failed, label: "Not delivered", detail: "the chat stopped before the agent read this"),
      ])
  }

  @Test func deliveryUnknownLine() {
    let model = makeModel([Self.answered, Self.onIt(Self.relay())], link: Self.recorded)

    expectNoDifference(
      progress(model)?.lines,
      [
        .init(mark: .done, label: "Sent", detail: "14:02"),
        .init(mark: .failed, label: "Delivery unknown", detail: "the app restarted before delivery was confirmed"),
      ])
  }

  @Test func sendAgainShownForNotDeliveredAndDeliveryUnknown() {
    let notDelivered = makeModel([Self.answered, Self.onIt(Self.relay(notDelivered: true))], link: Self.recorded)
    let deliveryUnknown = makeModel([Self.answered, Self.onIt(Self.relay())], link: Self.recorded)
    let pickedUp = makeModel([Self.answered, Self.onIt(Self.relay(pickedUp: true))], link: Self.recorded)

    expectNoDifference(progress(notDelivered)?.action, .sendAgain)
    expectNoDifference(progress(deliveryUnknown)?.action, .sendAgain)
    expectNoDifference(progress(pickedUp)?.action, nil)
    expectNoDifference(notDelivered.actionText(.sendAgain), "Send again")
  }

  @Test func couldntCheckLine() async {
    let (instantAsk, _) = makeRelayingInstantAsk(AgentFake())
    let turns = [Self.answered, Self.onIt(Self.relay(pickedUp: true))]
    handOver(instantAsk, turns)
    await Task.megaYield()
    fork.reply(.failure(.timedOut))
    await Task.megaYield()
    let model = makeModel(turns, link: Self.recorded, instantAsk: instantAsk)

    expectNoDifference(
      progress(model),
      RelayProgress(
        relayID: Self.loggedRelay,
        lines: [
          .init(mark: .done, label: "Sent", detail: "14:02"),
          .init(mark: .done, label: "Picked up", detail: "14:03"),
          .init(mark: .warning, label: "Couldn't check whether this was done", detail: "14:05"),
        ],
        action: .checkAgain, isActionDisabled: false, report: nil,
        failure: "Claude Code didn't answer within 120 seconds."))
    expectNoDifference(model.actionText(.checkAgain), "Check again")
  }

  @Test func couldntCheckShowsTheCauseOnItsOwn() async {
    let (instantAsk, _) = makeRelayingInstantAsk(AgentFake())
    let turns = [Self.answered, Self.onIt(Self.relay(pickedUp: true))]
    handOver(instantAsk, turns)
    await Task.megaYield()
    fork.reply(.failure(.unavailable("Claude Code exited with status 1: Invalid API key")))
    await Task.megaYield()
    let model = makeModel(turns, link: Self.recorded, instantAsk: instantAsk)

    expectNoDifference(progress(model)?.failure, "Claude Code exited with status 1: Invalid API key")
  }

  @Test func checkAgainDisabledWhileChecking() async throws {
    let (instantAsk, _) = makeRelayingInstantAsk(AgentFake())
    let turns = [Self.answered, Self.onIt(Self.relay(pickedUp: true))]
    handOver(instantAsk, turns)
    await Task.megaYield()
    fork.reply(.failure(.timedOut))
    await Task.megaYield()
    let model = makeModel(turns, link: Self.recorded, instantAsk: instantAsk)

    let checking = Task { [progress = try #require(progress(model))] in await model.checkAgainTapped(progress) }
    await Task.megaYield()

    expectNoDifference(fork.requests.count, 2)
    expectNoDifference(progress(model)?.action, .checkAgain)
    expectNoDifference(progress(model)?.isActionDisabled, true)
    fork.report(.notDoneYet, "Not yet.")
    await checking.value
    expectNoDifference(progress(model)?.action, nil)
  }

  @Test func sendAgainDisabledOnceTapped() async throws {
    let agent = AgentFake()
    let (instantAsk, _) = makeRelayingInstantAsk(agent)
    let turns = [Self.answered, Self.onIt(Self.relay())]
    handOver(instantAsk, turns)
    let model = makeModel(turns, link: Self.recorded, instantAsk: instantAsk)
    agent.hold(.environment)

    let sending = Task { [progress = try #require(progress(model))] in await model.sendAgainTapped(progress) }
    await Task.megaYield()
    expectNoDifference(progress(model)?.isActionDisabled, true)
    agent.release(.environment)
    await sending.value

    expectNoDifference(progress(model)?.isActionDisabled, true)
  }

  @Test func idleAgentGoesFromOnItToPickedUp() async throws {
    let (instantAsk, chat) = makeRelayingInstantAsk(AgentFake())
    recorder.setRelaySupport(.success(true))
    recorder.script(.success("q2"))
    let model = makeModel([Self.answered], link: Self.recorded, instantAsk: instantAsk)
    await followUpSent(model, "Rename it")
    fork.changeRequest()
    await Task.megaYield()
    let relayID = UUID(1)
    let requestID = UUID(0).uuidString.lowercased()
    let turns = [Self.answered, Self.onIt(requestID: requestID, Self.relay(relayID.uuidString.lowercased()))]
    handOver(instantAsk, turns)
    model.threadUpdated(Self.thread(turns))
    expectNoDifference(model.pendingTurn, nil)
    expectNoDifference(progress(model)?.lines.map(\.label), ["Sent"])

    chat.onRelayDelivery(Self.tab, .pickedUp(relayID: relayID))

    expectNoDifference(
      progress(model)?.lines,
      [.init(mark: .done, label: "Sent", detail: "14:02"), .init(mark: .done, label: "Picked up", detail: "")])
    model.threadUpdated(
      Self.thread([Self.answered, Self.onIt(requestID: requestID, Self.relay(relayID.uuidString.lowercased(), pickedUp: true))]))
    expectNoDifference(progress(model)?.lines.last, .init(mark: .done, label: "Picked up", detail: "14:03"))
  }

  @Test func twoRequestsShowUnderTheirOwnTurns() {
    let firstTurn = QuestionTurn(
      questionID: "q1", requestID: "r-q1", text: "Why?", queuedAtMs: Self.at1402,
      answer: QuestionAnswer(seq: Fixture.seq(3), text: "On it.", answeredAtMs: Self.at1402),
      relays: [Self.relay("rl-old", notDelivered: true), Self.relay("rl-new", pickedUp: true)])
    let secondTurn = Self.onIt(Self.relay("rl-2", pickedUp: true, report: Self.report(.done, "Done.")))
    let model = makeModel([firstTurn, secondTurn, Self.followUp], link: Self.recorded)

    expectNoDifference(model.thread.turns.map { model.progress($0)?.relayID }, ["rl-new", "rl-2", nil])
    expectNoDifference(model.progress(firstTurn)?.lines.map(\.label), ["Sent", "Picked up"])
    expectNoDifference(model.progress(secondTurn)?.lines.map(\.label), ["Done"])
  }

  @Test func sourceLineCountsShownReports() {
    let model = makeModel(
      [Self.answered, Self.onIt(Self.relay(pickedUp: true, report: Self.report(.notDoneYet, "Not yet.")))],
      link: Self.recorded)

    expectNoDifference(model.sourceText, "user.ts:7–9 · 5 messages")
  }

  @Test func displayingReportMarksItRead() {
    let model = makeModel(
      [Self.answered, Self.onIt(Self.relay(pickedUp: true, report: Self.report(.done, "Done.")))], link: Self.recorded)

    model.answerDisplayed(Fixture.seq(9))

    expectNoDifference(readAnswers(), [AnswerReadMarker(storeID: "store-a", sessionID: Fixture.session, seq: Fixture.seq(9))])
  }

  @Test func displayingReplacementReportMarksItsOwnSequenceRead() {
    let replacement = RelayReport(outcome: .done, text: "Done again.", seq: Fixture.seq(10), atMs: Self.at1405)
    let model = makeModel(
      [Self.answered, Self.onIt(Self.relay(pickedUp: true, report: replacement))], link: Self.recorded)

    model.answerDisplayed(Fixture.seq(10))

    expectNoDifference(readAnswers(), [AnswerReadMarker(storeID: "store-a", sessionID: Fixture.session, seq: Fixture.seq(10))])
  }
}
