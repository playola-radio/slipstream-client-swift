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
      $0.agentProcess = agent.processClient
      $0.transcripts = agent.transcriptClient
      $0.askFork = fork.client
      $0.questionClient = recorder.client
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
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

    model.threadsFolded(storeID: "store-1", sessionID: Self.capture, folder: "/w", isReplaying: false, threads: thread(requestID: Self.firstRequest))

    expectNoDifference(model.pending, [])
  }

  // MARK: - Lifetime

  @Test func recordedEntryLeavesWhenFoldHasQuestionID() async {
    let model = makeModel()
    recorder.script(.success("q-1"))
    await asking(model, question())
    fork.answer()
    await Task.megaYield()

    model.threadsFolded(storeID: "store-1", sessionID: Self.capture, folder: "/w", isReplaying: false, threads: thread(requestID: "someone-elses"))
    expectNoDifference(model.pending.count, 1)
    model.threadsFolded(storeID: "store-1", sessionID: Self.capture, folder: "/w", isReplaying: false, threads: thread(requestID: Self.firstRequest))

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

    model.threadsFolded(storeID: "store-1", sessionID: Self.capture, folder: "/w", isReplaying: false, threads: thread(requestID: Self.firstRequest))
    await clock.advance(by: .seconds(5))
    await Task.megaYield()

    expectNoDifference(recorder.requests.count, 1)
    expectNoDifference(model.pending, [])
  }

  // MARK: - Change requests

  nonisolated static let firstRelay = "00000000-0000-0000-0000-000000000001"
  nonisolated static let firstRelayID = UUID(uuidString: firstRelay)!
  nonisolated static let label = "From Ask · greet.py:3-5"

  struct Step: Equatable {
    let relayID: String
    let questionID: String
    let update: RelayUpdate
  }

  var steps: [Step] {
    recorder.updates.map { Step(relayID: $0.relayID, questionID: $0.questionID, update: $0.update) }
  }

  func changeRecording(_ text: String = "Rename it", chat: UUID = linked) -> QuestionRequest {
    QuestionRequest(
      sessionID: Self.capture, requestID: Self.firstRequest, text: text, context: Self.source.context,
      verb: .recordExchange(
        answerText: "On it.",
        conversation: ExchangeConversation(parentSessionID: chat.uuidString, forkSessionID: "fork-1"),
        relay: ExchangeRelay(relayID: Self.firstRelay, chatSessionID: chat.uuidString.lowercased())))
  }

  func relayWrite(_ words: String = "Rename it", earlier: [AskPrompt.Exchange] = [], relayID: UUID = firstRelayID)
    throws -> JSONValue
  {
    let text = try #require(AskPrompt.relayMessage(source: Self.source, earlier: earlier, words: words))
    return json(ClaudeInvocation.userMessage(text, uuid: relayID))
  }

  /// Asks a change request of a daemon that has relays, and lets it record and write.
  func askingChangeRequest(_ model: InstantAskModel, _ question: InstantQuestion? = nil) async {
    recorder.setRelaySupport(.success(true))
    recorder.script(.success("q-1"))
    await asking(model, question ?? self.question("Rename it"))
    fork.changeRequest()
    await Task.megaYield()
  }

  func pickedUp(_ chat: ChatPageModel, _ relayID: UUID = firstRelayID, tab: UUID = linked) {
    chat.onRelayDelivery(tab, .pickedUp(relayID: relayID))
  }

  func turnEnded(_ chat: ChatPageModel, tab: UUID = linked) async {
    chat.onTabTurnEnded(tab)
    await Task.megaYield()
  }

  func loggedRelay(
    _ id: String = firstRelay, chat: UUID = linked, pickedUp: Bool = false, report: RelayReport? = nil
  ) -> QuestionRelay {
    QuestionRelay(
      id: id, questionID: "q-1", chatSessionID: chat.uuidString.lowercased(), sent: RelayStep(seq: Seq("43")!, atMs: 1),
      pickedUp: pickedUp ? RelayStep(seq: Seq("44")!, atMs: 2) : nil, report: report)
  }

  /// The selected capture's log folding in, as on a restart.
  func handOver(_ model: InstantAskModel, isReplaying: Bool = false, _ relays: QuestionRelay...) {
    model.threadsFolded(
      storeID: "store-1", sessionID: Self.capture, folder: "/w", isReplaying: isReplaying,
      threads: [
        QuestionThread(
          id: "q-1", source: Self.source,
          turns: [
            QuestionTurn(
              questionID: "q-1", requestID: Self.firstRequest, text: "Rename it", queuedAtMs: 1,
              answer: QuestionAnswer(seq: Seq("43")!, text: "On it.", answeredAtMs: 1), relays: relays)
          ],
          link: .recorded(chatSessionID: Self.linked.uuidString.lowercased()))
      ])
  }

  @Test func noRelaysWhenDaemonLacksVerb() async {
    let model = makeModel()
    recorder.script(.success("q-1"))

    await asking(model, question())
    fork.answer()
    await Task.megaYield()

    expectNoDifference(recorder.capabilityChecks, [Self.capture])
    expectNoDifference(fork.requests.map(\.kind), [.answer(allowsChangeRequests: false)])
    expectNoDifference(
      fork.requests.map(\.prompt),
      [AskPrompt.answer(source: Self.source, earlier: [], words: "Why return early?", allowsChangeRequests: false)])
    expectNoDifference(recorder.requests, [recording()])
    expectNoDifference(agent.launches, [])
  }

  @Test func capabilityCheckedOncePerConnection() async {
    let model = makeModel()
    recorder.setRelaySupport(.success(true))

    await asking(model, question())
    await asking(model, question("Another?"))
    expectNoDifference(recorder.capabilityChecks.count, 1)
    await model.daemonConnected(storeID: "store-1")
    await asking(model, question("A third?"))

    expectNoDifference(recorder.capabilityChecks.count, 2)
    expectNoDifference(
      fork.requests.map(\.kind), Array(repeating: AskForkKind.answer(allowsChangeRequests: true), count: 3))
  }

  @Test func failedCapabilityCheckMeansNoRelaysAndIsAskedAgain() async {
    let model = makeModel()
    recorder.setRelaySupport(.failure(.outcomeUnknown))

    await asking(model, question())
    recorder.setRelaySupport(.success(true))
    await asking(model, question("Another?"))

    expectNoDifference(
      fork.requests.map(\.kind), [.answer(allowsChangeRequests: false), .answer(allowsChangeRequests: true)])
  }

  @Test func changeRequestRecordsExchangeWithRelayThenWritesTab() async throws {
    let model = makeModel()
    recorder.setRelaySupport(.success(true))
    recorder.script(.failure(.outcomeUnknown), .success("q-1"))

    await asking(model, question("Rename it"))
    fork.changeRequest()
    await Task.megaYield()
    expectNoDifference(recorder.requests, [changeRecording()])
    expectNoDifference(agent.launches, [])
    await clock.advance(by: .milliseconds(2500))
    await Task.megaYield()

    expectNoDifference(recorder.requests, [changeRecording(), changeRecording()])
    expectNoDifference(agent.writes(0), [try relayWrite()])
    expectNoDifference(model.relayRuns[Self.firstRelay]?.delivery, .waitingForEcho)
  }

  @Test func plainAnswerOnRelayDaemonSendsNoRelay() async {
    let model = makeModel()
    recorder.setRelaySupport(.success(true))
    recorder.script(.success("q-1"))

    await asking(model, question())
    fork.answer()
    await Task.megaYield()

    expectNoDifference(recorder.requests, [recording()])
    expectNoDifference(agent.launches, [])
    expectNoDifference(model.relayRuns, [:])
  }

  @Test func relayTextQuotesQAAndKeepsUsersWords() async throws {
    let (model, chat) = makeModelAndChat(records: [
      ChatTabRecord(id: Self.threadChat, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false),
      ChatTabRecord(id: Self.linked, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false),
    ])
    let earlier = [
      AskPrompt.Exchange(question: "Does it greet empty names?", answer: "No. Want me to greet a friend instead?")
    ]
    let words = "yes, and say hello"

    await askingChangeRequest(model, question(words, replyTo: "q-1", threadChat: Self.threadChat, earlier: earlier))

    expectNoDifference(agent.writes(0), [try relayWrite(words, earlier: earlier)])
    let text = try #require(AskPrompt.relayMessage(source: Self.source, earlier: earlier, words: words))
    #expect(text.hasSuffix("\n\n" + words))
    #expect(!text.contains("On it."))
    expectNoDifference(
      chat.tabs[id: Self.threadChat]?.projection.items.last?.kind,
      .userMessage(text, relay: RelayMark(label: Self.label, delivery: .waiting)))
  }

  @Test func echoDuringWriteStillCountsAsPickup() async {
    let (model, chat) = makeModelAndChat()
    agent.hold(.writes)

    await askingChangeRequest(model)
    pickedUp(chat)
    agent.release(.writes)
    await Task.megaYield()

    expectNoDifference(model.relayRuns[Self.firstRelay]?.delivery, .pickedUp)
  }

  @Test func pickupRecordsPickedUp() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)

    pickedUp(chat)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.delivery, .pickedUp)
    await Task.megaYield()

    expectNoDifference(steps, [Step(relayID: Self.firstRelay, questionID: "q-1", update: .pickedUp)])
    expectNoDifference(model.relayStatus(loggedRelay()), .pickedUp)
  }

  @Test func exitUnreadRecordsNotDelivered() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)

    chat.onRelayDelivery(Self.linked, .exitedUnread(relayID: Self.firstRelayID))
    await Task.megaYield()

    expectNoDifference(model.relayRuns[Self.firstRelay]?.delivery, .exitedUnread)
    expectNoDifference(steps, [Step(relayID: Self.firstRelay, questionID: "q-1", update: .notDelivered)])
    expectNoDifference(model.relayStatus(loggedRelay()), .notDelivered)
  }

  @Test func unwrittenRelayRecordsNotDelivered() async {
    let model = makeModel()
    agent.setWriteError(CancellationError())

    await askingChangeRequest(model)

    expectNoDifference(model.relayRuns[Self.firstRelay]?.delivery, .exitedUnread)
    expectNoDifference(steps, [Step(relayID: Self.firstRelay, questionID: "q-1", update: .notDelivered)])
  }

  @Test func unsentRelayIsDeliveryUnknownUntilWritten() async {
    let model = makeModel()

    expectNoDifference(model.relayStatus(loggedRelay()), .deliveryUnknown)
    await askingChangeRequest(model)

    expectNoDifference(model.relayStatus(loggedRelay()), .sent)
  }

  // MARK: - Recording relay steps

  @Test func eachUpdateRecordedOnItsOwn() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    recorder.scriptUpdates(.failure(.outcomeUnknown))

    pickedUp(chat)
    await turnEnded(chat)
    fork.report(.done)
    await Task.megaYield()

    expectNoDifference(
      steps.map(\.update), [.pickedUp, .reported(.done, text: "Done. It greets a friend now.")])
    await clock.advance(by: .milliseconds(2500))
    expectNoDifference(
      steps.map(\.update), [.pickedUp, .reported(.done, text: "Done. It greets a friend now."), .pickedUp])
  }

  @Test func failedUpdateRetriedOnReconnect() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    recorder.scriptUpdates(
      .failure(.outcomeUnknown), .failure(.rejected(code: "STORAGE_UNAVAILABLE", message: "")), .failure(.unavailable))

    pickedUp(chat)
    await Task.megaYield()
    await clock.advance(by: .seconds(5))
    await Task.megaYield()
    let first = recorder.updates[0]
    expectNoDifference(recorder.updates, [first, first, first])
    expectNoDifference(model.relayRuns[Self.firstRelay]?.unrecorded, [first])

    await model.daemonConnected(storeID: "store-1")

    expectNoDifference(recorder.updates, [first, first, first, first])
    expectNoDifference(model.relayRuns[Self.firstRelay]?.unrecorded, [])
  }

  @Test func invalidRelayUpdateIsNeverRetried() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    recorder.scriptUpdates(.failure(.rejected(code: "INVALID_RELAY_UPDATE", message: "")))

    pickedUp(chat)
    await Task.megaYield()
    await clock.advance(by: .seconds(5))
    await model.daemonConnected(storeID: "store-1")

    expectNoDifference(recorder.updates.count, 1)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.unrecorded, [])
    expectNoDifference(model.relayRuns[Self.firstRelay]?.delivery, .pickedUp)
  }

  // MARK: - Reports

  @Test func turnEndAfterPickupStartsReport() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)

    pickedUp(chat)
    await turnEnded(chat)

    expectNoDifference(
      fork.requests.last,
      AskForkRequest(
        parentSessionID: Self.linked, folder: "/w", environment: AgentFake.environment, model: "claude-opus-5-5",
        effort: .high, prompt: AskPrompt.report(source: Self.source, earlier: [], request: "Rename it"), kind: .report))
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .checking(rerun: false))
  }

  @Test func turnEndBeforePickupStartsNoReport() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)

    await turnEnded(chat)

    expectNoDifference(fork.requests.count, 1)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .idle)
  }

  @Test func turnEndInAnotherTabStartsNoReport() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)

    pickedUp(chat)
    await turnEnded(chat, tab: Self.threadChat)

    expectNoDifference(fork.requests.count, 1)
  }

  @Test func turnEndDuringReportSetsRerun() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)

    await turnEnded(chat)

    expectNoDifference(fork.requests.count, 2)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .checking(rerun: true))
  }

  @Test func twoTurnEndsDuringReportRunOneMore() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)
    await turnEnded(chat)
    await turnEnded(chat)

    fork.report(.notDoneYet, "Not yet.")
    await Task.megaYield()
    expectNoDifference(fork.requests.count, 3)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .checking(rerun: false))
    fork.report(.notDoneYet, "Not yet.")
    await Task.megaYield()

    expectNoDifference(fork.requests.count, 3)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .idle)
    expectNoDifference(
      steps.map(\.update),
      [.pickedUp, .reported(.notDoneYet, text: "Not yet."), .reported(.notDoneYet, text: "Not yet.")])
  }

  @Test func doneEndsChecks() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)
    await turnEnded(chat)

    fork.report(.done)
    await Task.megaYield()
    await turnEnded(chat)

    expectNoDifference(fork.requests.count, 2)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .idle)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.isDone, true)
  }

  @Test func failedReportIsCouldntCheck() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)

    fork.reply(.failure(.timedOut))
    await Task.megaYield()

    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .idle)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.checkFailedAtMs, 1_700_000_000_000)
    expectNoDifference(model.relayStatus(loggedRelay(pickedUp: true)), .couldntCheck)
    expectNoDifference(steps.map(\.update), [.pickedUp])
  }

  @Test func failedCheckStillRerunsAfterTurnEnd() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)
    await turnEnded(chat)

    fork.reply(.failure(.timedOut))
    await Task.megaYield()

    expectNoDifference(fork.requests.count, 3)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .checking(rerun: false))
  }

  @Test func refusedDoneReportIsCouldntCheck() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)
    recorder.scriptUpdates(.failure(.rejected(code: "INVALID_RELAY_UPDATE", message: "")))

    fork.report(.done)
    await Task.megaYield()

    expectNoDifference(model.relayRuns[Self.firstRelay]?.isDone, false)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.checkFailedAtMs, 1_700_000_000_000)
    expectNoDifference(model.relayStatus(loggedRelay(pickedUp: true)), .couldntCheck)
  }

  @Test func reportForClosedTabIsCouldntCheck() async {
    let (model, chat) = makeModelAndChat()
    handOver(model, loggedRelay(chat: Self.threadChat, pickedUp: true))

    await model.checkAgainTapped(relayID: Self.firstRelay)
    _ = chat

    expectNoDifference(fork.requests, [])
    expectNoDifference(model.relayRuns[Self.firstRelay]?.checkFailedAtMs, 1_700_000_000_000)
  }

  @Test func checkAgainKeepsFailureUntilItsReport() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)
    fork.reply(.failure(.timedOut))
    await Task.megaYield()

    let checking = Task { await model.checkAgainTapped(relayID: Self.firstRelay) }
    await Task.megaYield()
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .checking(rerun: false))
    expectNoDifference(model.relayStatus(loggedRelay(pickedUp: true)), .couldntCheck)
    expectNoDifference(fork.requests.count, 3)
    fork.report(.done)
    await checking.value

    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .idle)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.checkFailedAtMs, nil)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.isDone, true)
  }

  @Test func checkAgainIgnoredWhileChecking() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)

    await model.checkAgainTapped(relayID: Self.firstRelay)

    expectNoDifference(fork.requests.count, 2)
    expectNoDifference(model.relayRuns[Self.firstRelay]?.report, .checking(rerun: false))
  }

  @Test func captureDeletedStopsReportAndForgetsRelays() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)

    model.captureDeleted(Self.capture)
    await Task.megaYield()

    expectNoDifference(fork.stopCount, 1)
    expectNoDifference(model.relayRuns, [:])
    expectNoDifference(steps.map(\.update), [.pickedUp])
  }

  @Test func quitWaitsForRunningReport() async {
    let (model, chat) = makeModelAndChat()
    await askingChangeRequest(model)
    pickedUp(chat)
    await turnEnded(chat)
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

    expectNoDifference(fork.stopCount, 1)
  }

  // MARK: - Restart

  @Test func pickedUpWithoutDoneChecksAtNextIdle() async throws {
    let (model, chat) = makeModelAndChat()
    let tab = try #require(chat.tabs[id: Self.linked])
    try await tab.relay(AskRelayMessage(relayID: UUID(), text: "Keep going", label: Self.label))
    #expect(tab.isWorking)

    handOver(model, loggedRelay(pickedUp: true))
    expectNoDifference(fork.requests, [])
    await turnEnded(chat)

    expectNoDifference(fork.requests.map(\.kind), [.report])
    expectNoDifference(
      fork.requests.map(\.prompt), [AskPrompt.report(source: Self.source, earlier: [], request: "Rename it")])
  }

  @Test func replayedPickupIsCheckedOnceReplayEnds() async {
    let model = makeModel()

    handOver(model, isReplaying: true, loggedRelay())
    handOver(model, isReplaying: true, loggedRelay(pickedUp: true))
    await Task.megaYield()
    expectNoDifference(fork.requests, [])
    handOver(model, loggedRelay(pickedUp: true))
    handOver(model, loggedRelay(pickedUp: true))
    await Task.megaYield()

    expectNoDifference(fork.requests.map(\.kind), [.report])
  }

  @Test func turnEndDuringReplayWaitsForReplayToEnd() async {
    let (model, chat) = makeModelAndChat()
    let done = RelayReport(outcome: .done, text: "Done.", seq: Seq("45")!, atMs: 45)

    handOver(model, isReplaying: true, loggedRelay(pickedUp: true))
    await turnEnded(chat)
    handOver(model, isReplaying: true, loggedRelay(pickedUp: true, report: done))
    handOver(model, loggedRelay(pickedUp: true, report: done))
    await Task.megaYield()

    expectNoDifference(fork.requests, [])
  }

  @Test func replayedDoneRelayIsNeverChecked() async {
    let model = makeModel()
    let done = RelayReport(outcome: .done, text: "Done.", seq: Seq("45")!, atMs: 45)

    handOver(model, isReplaying: true, loggedRelay())
    handOver(model, isReplaying: true, loggedRelay(pickedUp: true))
    handOver(model, isReplaying: true, loggedRelay(pickedUp: true, report: done))
    handOver(model, loggedRelay(pickedUp: true, report: done))
    await Task.megaYield()

    expectNoDifference(fork.requests, [])
  }

  @Test func doneRelayIsNeverChecked() async {
    let (model, chat) = makeModelAndChat()

    handOver(model, loggedRelay(pickedUp: true, report: RelayReport(outcome: .done, text: "Done.", seq: Seq("45")!, atMs: 45)))
    await turnEnded(chat)

    expectNoDifference(fork.requests, [])
  }

  @Test func sentNeverPickedUpIsDeliveryUnknown() {
    let model = makeModel()

    handOver(model, loggedRelay())

    expectNoDifference(model.relayStatus(loggedRelay()), .deliveryUnknown)
  }

  @Test func deliveryUnknownNeverResentAutomatically() async {
    let (model, chat) = makeModelAndChat()

    handOver(model, loggedRelay())
    await turnEnded(chat)
    await model.daemonConnected(storeID: "store-1")

    expectNoDifference(agent.launches, [])
    expectNoDifference(fork.requests, [])
    expectNoDifference(recorder.updates, [])
  }

  // MARK: - Send again

  @Test func sendAgainRecordsSentWithNewRelayIDThenWrites() async throws {
    let model = makeModel()
    handOver(model, loggedRelay())
    recorder.scriptUpdates(.failure(.outcomeUnknown))
    let newRelay = UUID(0)

    let sending = Task { await model.sendAgainTapped(relayID: Self.firstRelay) }
    await Task.megaYield()
    expectNoDifference(
      steps,
      [
        Step(
          relayID: newRelay.uuidString.lowercased(), questionID: "q-1",
          update: .sent(chatSessionID: Self.linked.uuidString.lowercased()))
      ])
    expectNoDifference(agent.launches, [])
    await clock.advance(by: .milliseconds(2500))
    await sending.value

    expectNoDifference(recorder.updates.count, 2)
    expectNoDifference(recorder.updates[0], recorder.updates[1])
    expectNoDifference(agent.writes(0), [try relayWrite(relayID: newRelay)])
    expectNoDifference(model.relayRuns[newRelay.uuidString.lowercased()]?.delivery, .waitingForEcho)
  }

  @Test func refusedSendAgainWritesNothing() async {
    let model = makeModel()
    handOver(model, loggedRelay())
    recorder.scriptUpdates(.failure(.rejected(code: "INVALID_RELAY_UPDATE", message: "")))

    await model.sendAgainTapped(relayID: Self.firstRelay)

    expectNoDifference(recorder.updates.count, 1)
    expectNoDifference(agent.launches, [])
    expectNoDifference(Array(model.relayRuns.keys), [Self.firstRelay])
  }

  @Test func sendAgainIgnoredWhileItsReplacementIsSending() async throws {
    let model = makeModel()
    handOver(model, loggedRelay())
    recorder.scriptUpdates(.failure(.unavailable))
    let newRelay = UUID(0).uuidString.lowercased()

    let sending = Task { await model.sendAgainTapped(relayID: Self.firstRelay) }
    await Task.megaYield()
    handOver(model, loggedRelay(), loggedRelay(newRelay))
    await model.sendAgainTapped(relayID: newRelay)
    await model.sendAgainTapped(relayID: Self.firstRelay)
    expectNoDifference(recorder.updates.count, 1)
    await clock.advance(by: .milliseconds(2500))
    await sending.value
    await model.sendAgainTapped(relayID: Self.firstRelay)

    expectNoDifference(recorder.updates.count, 2)
    expectNoDifference(agent.writes(0), [try relayWrite(relayID: UUID(0))])
  }

  @Test func unrecordedSendAgainIsSentAgainOnReconnect() async {
    let model = makeModel()
    handOver(model, loggedRelay())
    recorder.scriptUpdates(.failure(.unavailable), .failure(.unavailable), .failure(.unavailable))
    let newRelay = UUID(0).uuidString.lowercased()

    let sending = Task { await model.sendAgainTapped(relayID: Self.firstRelay) }
    await Task.megaYield()
    await clock.advance(by: .seconds(5))
    await sending.value
    let first = recorder.updates[0]
    expectNoDifference(model.relayRuns[newRelay]?.unrecorded, [first])
    await model.daemonConnected(storeID: "store-1")

    expectNoDifference(recorder.updates, [first, first, first, first])
    expectNoDifference(agent.launches, [])
  }

  @Test func quitStopsSendAgain() async {
    let model = makeModel()
    handOver(model, loggedRelay())
    recorder.scriptUpdates(.failure(.unavailable))

    let sending = Task { await model.sendAgainTapped(relayID: Self.firstRelay) }
    await Task.megaYield()
    await model.quitConfirmed()
    await clock.advance(by: .seconds(5))
    await sending.value

    expectNoDifference(recorder.updates.count, 1)
    expectNoDifference(agent.launches, [])
  }

  @Test func sendAgainToClosedThreadChatUsesLinkedTab() async throws {
    let model = makeModel(records: [
      ChatTabRecord(id: Self.linked, folder: "/w", model: "claude-opus-5-5", effort: .high, isWaiting: false)
    ])
    handOver(model, loggedRelay(chat: Self.threadChat))

    await model.sendAgainTapped(relayID: Self.firstRelay)

    expectNoDifference(steps.map(\.update), [.sent(chatSessionID: Self.linked.uuidString.lowercased())])
    expectNoDifference(agent.writes(0), [try relayWrite(relayID: UUID(0))])
    expectNoDifference(agent.launches.count, 1)
  }

  // MARK: - Crash boundaries

  @Test func crashBeforeExchangeRecordedLeavesNothing() async {
    let model = makeModel()

    model.threadsFolded(storeID: "store-1", sessionID: Self.capture, folder: "/w", isReplaying: false, threads: [])
    await Task.megaYield()

    expectNoDifference(model.relayRuns, [:])
    expectNoDifference(agent.launches, [])
  }

  @Test func crashAfterPickupBeforeReportChecksAtNextIdle() async {
    let restarted = makeModel()

    handOver(restarted, loggedRelay(pickedUp: true))
    await Task.megaYield()

    expectNoDifference(restarted.relayStatus(loggedRelay(pickedUp: true)), .pickedUp)
    expectNoDifference(fork.requests.map(\.kind), [.report])
  }

  @Test func crashWhileRecordingStepShowsStrongestRecordedStep() async {
    let (first, chat) = makeModelAndChat()
    await askingChangeRequest(first)
    recorder.scriptUpdates(.failure(.outcomeUnknown))
    pickedUp(chat)
    await Task.megaYield()
    let restarted = makeModel()

    handOver(restarted, loggedRelay())

    expectNoDifference(restarted.relayStatus(loggedRelay()), .deliveryUnknown)
    expectNoDifference(first.relayStatus(loggedRelay()), .pickedUp)
  }
}
