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
struct InstantAskModelTests {
  nonisolated static let linked = UUID(uuidString: "5896F28C-F4A9-46C2-B481-7CA57E8714A8")!
  nonisolated static let threadChat = UUID(uuidString: "4BAD416C-1D04-4063-9E76-61EBB936AE06")!
  nonisolated static let capture = "6f3c1e0a-2b4d-4c8e-9a1f-3d5e7b9c0a12"
  nonisolated static let firstRequest = "00000000-0000-0000-0000-000000000000"
  nonisolated static let secondRequest = "00000000-0000-0000-0000-000000000001"
  nonisolated static let source = QuestionSource(
    context: QuestionContext(
      changeSeq: "41", path: "greet.py", snapshotSHA256: String(repeating: "a", count: 64), lineStart: 3, lineEnd: 5),
    selectedText: "if not name:\n    return"
  )
  nonisolated static let answer = AskForkResult.answer(
    forkSessionID: "fork-1", reply: "It returns early.", isChangeRequest: false)

  let agent = AgentFake()
  let fork = ForkFake()
  let recorder = RecordFake()
  let clock = TestClock()

  func makeModel(
    records: [ChatTabRecord] = [
      ChatTabRecord(id: threadChat, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false),
      ChatTabRecord(id: linked, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false),
    ]
  ) -> InstantAskModel {
    makeModelAndChat(records: records).model
  }

  func makeModelAndChat(
    records: [ChatTabRecord] = [
      ChatTabRecord(id: linked, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false)
    ]
  ) -> (model: InstantAskModel, chat: ChatPageModel) {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.agentEnvironment = agent.environmentClient
      $0.askFork = fork.client
      $0.questionClient = recorder.client
      $0.continuousClock = clock
      $0.uuid = .incrementing
    } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock { $0 = IdentifiedArray(uniqueElements: records) }
      let chat = ChatPageModel()
      chat.capturesArrived([
        CaptureSummary(
          sessionID: Self.capture, root: "/w", state: .recording,
          binding: CaptureBinding(generation: "g1", state: .connected, harnessSessionID: Self.linked.uuidString.lowercased()))
      ])
      return (InstantAskModel(chat: chat), chat)
    }
  }

  func question(
    _ text: String = "Why return early?", replyTo: String? = nil, threadChat: UUID? = nil,
    earlier: [AskPrompt.Exchange] = []
  ) -> InstantQuestion {
    InstantQuestion(
      storeID: "store-1", sessionID: Self.capture, folder: "/w", source: Self.source, replyToQuestionID: replyTo,
      threadChatSessionID: threadChat?.uuidString.lowercased(), earlier: earlier, text: text)
  }

  func entry(_ id: String = firstRequest, chat: UUID = linked, state: PendingAsk.State) -> PendingAsk {
    PendingAsk(
      id: id, storeID: "store-1", sessionID: Self.capture, chatSessionID: chat, source: Self.source,
      replyToQuestionID: nil, text: "Why return early?", state: state)
  }

  func recording(_ requestID: String = firstRequest) -> QuestionRequest {
    QuestionRequest(
      sessionID: Self.capture, requestID: requestID, text: "Why return early?", context: Self.source.context,
      verb: .recordExchange(
        answerText: "It returns early.",
        conversation: ExchangeConversation(parentSessionID: Self.linked.uuidString, forkSessionID: "fork-1")))
  }

  func thread(requestID: String) -> IdentifiedArrayOf<QuestionThread> {
    [
      QuestionThread(
        id: "q-1", source: Self.source,
        turns: [
          QuestionTurn(
            questionID: "q-1", requestID: requestID, text: "Why return early?", queuedAtMs: 1,
            answer: QuestionAnswer(seq: Seq("42")!, text: "It returns early.", answeredAtMs: 1))
        ],
        link: .recorded(chatSessionID: Self.linked.uuidString.lowercased()))
    ]
  }

  func asking(_ model: InstantAskModel, _ question: InstantQuestion) async {
    model.ask(question)
    await Task.megaYield()
  }

  /// Answers the running copy and lets the recording retries run out.
  func askUntilCouldntRecord(_ model: InstantAskModel) async {
    await asking(model, question())
    fork.answer()
    await Task.megaYield()
    await clock.advance(by: .seconds(5))
    await Task.megaYield()
  }

  // MARK: - Asking

  @Test func askRunsCopyThenRecordsWithSameRequestID() async {
    let model = makeModel()
    recorder.script(.success("q-1"))

    await asking(model, question())
    expectNoDifference(model.pending, [entry(state: .answering)])
    fork.answer()
    await Task.megaYield()

    expectNoDifference(recorder.requests, [recording()])
    expectNoDifference(model.pending, [entry(state: .recorded)])
  }

  @Test func copyGetsAnswerPrompt() async {
    let model = makeModel()
    let earlier = [AskPrompt.Exchange(question: "What is this?", answer: "A guard.")]

    await asking(model, question("And why?", replyTo: "q-1", threadChat: Self.threadChat, earlier: earlier))

    expectNoDifference(
      fork.requests.map(\.prompt),
      [AskPrompt.answer(source: Self.source, earlier: earlier, words: "And why?", allowsChangeRequests: false)])
    expectNoDifference(fork.requests.map(\.kind), [.answer(allowsChangeRequests: false)])
  }

  @Test func newQuestionUsesLinkedTab() async {
    let model = makeModel()

    await asking(model, question())

    expectNoDifference(fork.requests.map(\.parentSessionID), [Self.linked])
  }

  @Test func followUpUsesThreadChat() async {
    let model = makeModel()

    await asking(model, question(replyTo: "q-1", threadChat: Self.threadChat))

    expectNoDifference(fork.requests.map(\.parentSessionID), [Self.threadChat])
  }

  @Test func followUpAfterThreadChatClosedUsesLinkedTab() async {
    let model = makeModel()

    await asking(model, question(replyTo: "q-1", threadChat: UUID(uuidString: "11111111-2222-4333-8444-555555555555")))

    expectNoDifference(fork.requests.map(\.parentSessionID), [Self.linked])
  }

  @Test func copyUsesTabModelAndEffort() async {
    let model = makeModel(records: [
      ChatTabRecord(id: Self.linked, folder: "/w", model: "claude-sonnet-5-5", effort: .low, isWaiting: false)
    ])

    await asking(model, question())

    expectNoDifference(
      fork.requests,
      [
        AskForkRequest(
          parentSessionID: Self.linked, folder: "/w", environment: AgentFake.environment, model: "claude-sonnet-5-5",
          effort: .low,
          prompt: AskPrompt.answer(source: Self.source, earlier: [], words: "Why return early?", allowsChangeRequests: false),
          kind: .answer(allowsChangeRequests: false))
      ])
  }

  @Test(arguments: [
    (AskForkError.timedOut, AskFailure.noReply),
    (.unavailable, .chatUnavailable),
    (.badReply, .badReply),
  ])
  func copyFailureMapsToReason(error: AskForkError, failure: AskFailure) async {
    let model = makeModel()

    await asking(model, question())
    fork.reply(.failure(error))
    await Task.megaYield()

    expectNoDifference(model.pending, [entry(state: .couldntAnswer(failure))])
    expectNoDifference(recorder.requests, [])
  }

  @Test func unresolvedEnvironmentIsChatUnavailable() async {
    agent.setEnvironmentError(.claudeNotFound)
    let model = makeModel()

    await asking(model, question())

    expectNoDifference(model.pending, [entry(state: .couldntAnswer(.chatUnavailable))])
  }

  // MARK: - Recording

  @Test func unknownRecordingOutcomeRetriesIdenticalBody() async {
    let model = makeModel()
    recorder.script(.failure(.outcomeUnknown), .failure(.rejected(code: "STORAGE_UNAVAILABLE", message: "")), .success("q-1"))

    await asking(model, question())
    fork.answer()
    await Task.megaYield()
    expectNoDifference(recorder.requests.count, 1)
    expectNoDifference(model.pending, [entry(state: .recording)])
    await clock.advance(by: .milliseconds(2500))
    expectNoDifference(recorder.requests.count, 2)
    await clock.advance(by: .milliseconds(2500))
    await Task.megaYield()

    expectNoDifference(recorder.requests, [recording(), recording(), recording()])
    expectNoDifference(model.pending, [entry(state: .recorded)])
  }

  @Test func exhaustedRetriesAreCouldntRecord() async {
    let model = makeModel()

    await askUntilCouldntRecord(model)

    expectNoDifference(recorder.requests.count, 3)
    expectNoDifference(model.pending, [entry(state: .couldntRecord)])
  }

  @Test func tryAgainOnCouldntRecordResendsSameRequest() async {
    let model = makeModel()
    await askUntilCouldntRecord(model)
    recorder.script(.success("q-1"))

    model.tryAgainTapped(requestID: Self.firstRequest)
    await Task.megaYield()

    expectNoDifference(recorder.requests, Array(repeating: recording(), count: 4))
    expectNoDifference(fork.requests.count, 1)
    expectNoDifference(model.pending, [entry(state: .recorded)])
  }

  @Test func refusalAfterUnknownOutcomeKeepsRequestForTryAgain() async {
    let model = makeModel()
    recorder.script(.failure(.outcomeUnknown), .failure(.unavailable))

    await asking(model, question())
    fork.answer()
    await Task.megaYield()
    await clock.advance(by: .milliseconds(2500))
    await Task.megaYield()

    expectNoDifference(recorder.requests, [recording(), recording()])
    expectNoDifference(model.pending, [entry(state: .couldntRecord)])
  }

  @Test func refusedRecordingIsNotSaved() async {
    let model = makeModel()
    recorder.script(.failure(.rejected(code: "INVALID_CONTEXT", message: "")))

    await asking(model, question())
    fork.answer()
    await Task.megaYield()

    expectNoDifference(recorder.requests.count, 1)
    expectNoDifference(model.pending, [entry(state: .couldntAnswer(.notSaved))])
  }

  @Test func tryAgainOnCouldntAnswerRunsNewCopyWithNewRequestID() async {
    let model = makeModel()
    await asking(model, question())
    fork.reply(.failure(.unavailable))
    await Task.megaYield()

    let retried = model.tryAgainTapped(requestID: Self.firstRequest)
    await Task.megaYield()

    #expect(retried == Self.secondRequest)

    expectNoDifference(fork.requests.count, 2)
    expectNoDifference(model.pending, [entry(Self.secondRequest, state: .answering)])
  }

  @Test func tryAgainWithNoTabKeepsQuestion() async {
    let (model, chat) = makeModelAndChat()
    await asking(model, question())
    fork.reply(.failure(.unavailable))
    await Task.megaYield()
    chat.capturesArrived([CaptureSummary(sessionID: Self.capture, root: "/w", state: .recording)])

    let retried = model.tryAgainTapped(requestID: Self.firstRequest)

    #expect(retried == Self.firstRequest)
    expectNoDifference(model.pending, [entry(state: .couldntAnswer(.chatUnavailable))])
    expectNoDifference(fork.requests.count, 1)
  }

  @Test func lateEventAfterErrorDropsPendingEntry() async {
    let model = makeModel()
    await askUntilCouldntRecord(model)

    model.threadsFolded(sessionID: Self.capture, threads: thread(requestID: Self.firstRequest))

    expectNoDifference(model.pending, [])
  }

  // MARK: - Lifetime

  @Test func recordedEntryLeavesWhenFoldHasQuestionID() async {
    let model = makeModel()
    recorder.script(.success("q-1"))
    await asking(model, question())
    fork.answer()
    await Task.megaYield()

    model.threadsFolded(sessionID: Self.capture, threads: thread(requestID: "someone-elses"))
    expectNoDifference(model.pending.count, 1)
    model.threadsFolded(sessionID: Self.capture, threads: thread(requestID: Self.firstRequest))

    expectNoDifference(model.pending, [])
  }

  @Test func recordedEntryLeavesWhenCaptureDeselected() async {
    let model = makeModel()
    recorder.script(.success("q-1"))
    await asking(model, question())
    fork.answer()
    await Task.megaYield()
    await asking(model, question("Another?"))

    model.captureDeselected(Self.capture)

    expectNoDifference(model.pending.map(\.id), [Self.secondRequest])
  }

  @Test func closingPanelOrDeselectingDoesNotCancel() async {
    let model = makeModel()
    recorder.script(.success("q-1"))
    await asking(model, question())

    model.captureDeselected(Self.capture)
    fork.answer()
    await Task.megaYield()

    expectNoDifference(fork.stopCount, 0)
    expectNoDifference(model.pending, [entry(state: .recorded)])
  }

  @Test func captureDeletedCancelsRunAndPublishesNothing() async {
    let model = makeModel()
    await asking(model, question())

    model.captureDeleted(Self.capture)
    await Task.megaYield()

    expectNoDifference(fork.stopCount, 1)
    expectNoDifference(model.pending, [])
    expectNoDifference(recorder.requests, [])
  }

  @Test func quitCancelsAndWaitsForRunningCopies() async {
    let model = makeModel()
    await asking(model, question())
    await asking(model, question("Another?"))
    fork.holdStops()
    let isDone = LockIsolated(false)

    let quit = Task {
      await model.quitConfirmed()
      isDone.setValue(true)
    }
    await Task.megaYield()
    #expect(!isDone.value)
    fork.releaseStops()
    await quit.value

    expectNoDifference(fork.stopCount, 2)
  }

  @Test func askAfterQuitStartsNothing() async {
    let model = makeModel()
    await model.quitConfirmed()

    let requestID = model.ask(question())

    #expect(requestID == nil)
    expectNoDifference(model.pending, [])
    expectNoDifference(fork.requests, [])
  }

  @Test func followUpWithNoTabIsChatUnavailable() async {
    let model = makeModel(records: [])

    await asking(model, question(replyTo: "q-1", threadChat: Self.threadChat))

    expectNoDifference(model.pending.map(\.state), [.couldntAnswer(.chatUnavailable)])
    expectNoDifference(model.pending.map(\.chatSessionID), [Self.threadChat])
    expectNoDifference(fork.requests, [])
  }

  @Test func staleCompletionPublishesNothing() async {
    let model = makeModel()
    await asking(model, question())
    fork.answer()
    await Task.megaYield()

    model.threadsFolded(sessionID: Self.capture, threads: thread(requestID: Self.firstRequest))
    await clock.advance(by: .seconds(5))
    await Task.megaYield()

    expectNoDifference(recorder.requests.count, 1)
    expectNoDifference(model.pending, [])
  }
}
