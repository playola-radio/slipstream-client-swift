import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing
@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct AskAgentPageTests {
  static let context = QuestionContext(changeSeq: "12", path: "user.ts", snapshotSHA256: String(repeating: "a", count: 64), lineStart: 7, lineEnd: 9)
  static let session = "11111111-1111-4111-8111-111111111111"
  static func capture(
    _ state: CaptureState = .recording, binding: CaptureBinding? = CaptureBinding(generation: "7", state: .connected)
  ) -> CaptureStatus {
    CaptureStatus(
      availability: .available(checkedAt: Date(timeIntervalSince1970: 0)),
      capture: CaptureSummary(sessionID: session, root: "/work/nairobi", state: state, binding: binding))
  }

  func model(agentConnection: AgentConnection = .connected, captureStatus: CaptureStatus = capture(), add: @escaping @Sendable (String) async throws -> [String] = { [$0] }, send: @escaping @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { _ in throw QuestionError.unavailable }) -> AskAgentPageModel {
    withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = send
      $0.savedQuestions.load = { [] }
      $0.savedQuestions.add = add
    } operation: {
      AskAgentPageModel(
        sessionID: Self.session, context: Self.context, agentConnection: agentConnection, captureStatus: captureStatus)
    }
  }

  @Test func startsEmptyAndPresetSelectionDoesNotAppend() async {
    let model = model()
    await model.viewAppeared()
    expectNoDifference(model.draft, "")
    #expect(!model.canSubmit)
    model.savedQuestionSelected(model.options[1])
    expectNoDifference(model.selectedPreset, "Explain your thinking here, please.")
    expectNoDifference(model.draft, "")
    model.appendTapped()
    expectNoDifference(model.draft, "Explain your thinking here, please.")
    model.appendTapped()
    expectNoDifference(model.draft, "Explain your thinking here, please.\nExplain your thinking here, please.")
    expectNoDifference(model.caretRevision, 2)
    model.draftChanged(" \n\u{FEFF}")
    #expect(!model.canSubmit)
  }

  @Test func inlineSavePersistsCustomOnlyAndCancelRestoresSelection() async {
    let saved = LockIsolated<[String]>([])
    let model = model(add: { text in
      saved.withValue { $0.append(text) }
      return saved.value
    })
    await model.viewAppeared()
    model.draftChanged("Keep draft")
    model.addQuestionTapped()
    model.newPreset = "  Custom? \n"
    await model.savePresetTapped()
    expectNoDifference(saved.value, ["Custom?"])
    expectNoDifference(model.selectedPreset, "Custom?")
    expectNoDifference(model.draft, "Keep draft")
    model.addQuestionTapped()
    model.newPreset = "Discard me"
    model.cancelPresetTapped()
    expectNoDifference(model.selectedPreset, "Custom?")
    expectNoDifference(model.draft, "Keep draft")
    #expect(!model.isAddingPreset)
  }

  @Test func failedPersistenceDoesNotPretendToSave() async {
    let model = model(add: { _ in throw QuestionError.unavailable })
    await model.viewAppeared()
    model.addQuestionTapped()
    model.newPreset = "Custom?"
    await model.savePresetTapped()
    expectNoDifference(model.options, AskAgentPageModel.defaults)
    expectNoDifference(model.selectedPreset, AskAgentPageModel.defaults[0])
    #expect(model.isAddingPreset)
    #expect(model.isErrorPresented)
  }

  @Test func retryKeepsIdentityAndFrozenContextButEditCreatesNewIntent() async {
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = model(send: { request in
      requests.withValue { $0.append(request) }
      throw QuestionError.outcomeUnknown
    })
    model.draftChanged("Why?")
    #expect(await model.askTapped() == false)
    #expect(await model.askTapped() == false)
    expectNoDifference(requests.value.count, 2)
    expectNoDifference(requests.value[0], requests.value[1])
    expectNoDifference(model.draft, "Why?")
    #expect(model.hasUncertainSubmission)
    model.draftChanged("What next?")
    #expect(await model.askTapped() == false)
    #expect(requests.value[2].requestID != requests.value[0].requestID)
    expectNoDifference(requests.value[2].context, Self.context)
    #expect(model.hasUncertainSubmission)
  }

  @Test func inFlightDuplicateAndDismissedCompletionCannotSucceed() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = model(send: { request in
      requests.withValue { $0.append(request) }
      for await _ in gate { break }
      return try Self.ack(request)
    })
    model.draftChanged("Why?")
    let send = Task { await model.askTapped() }
    await Task.megaYield()
    #expect(model.isSubmitting)
    #expect(await model.askTapped() == false)
    expectNoDifference(requests.value.count, 1)
    model.dismissed()
    resume.yield()
    #expect(await send.value == false)
    expectNoDifference(model.draft, "Why?")
  }

  @Test func aLateSuccessForADroppedQuestionDoesNotCloseTheDraft() async throws {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = model(send: { request in
      requests.withValue { $0.append(request) }
      for await _ in gate { break }
      return try Self.ack(request)
    })
    model.draftChanged("Why?")
    let send = Task { await model.askTapped() }
    await Task.megaYield()
    let request = try #require(requests.value.first)
    model.questionsUpdated([
      QuestionThread(
        id: "question-1", source: QuestionSource(context: Self.context, selectedText: ""),
        turns: [QuestionTurn(questionID: "question-1", requestID: request.requestID, text: request.text, queuedAtMs: 1, isDropped: true)]
      )
    ])
    resume.yield()
    #expect(await send.value == false)
    #expect(!model.isSubmitting)
    #expect(!model.isErrorPresented)
    expectNoDifference(model.draft, "Why?")
  }

  @Test func aLateFailureForADroppedQuestionDoesNotShowAnError() async throws {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let requests = LockIsolated<[QuestionRequest]>([])
    let model = model(send: { request in
      requests.withValue { $0.append(request) }
      for await _ in gate { break }
      throw QuestionError.outcomeUnknown
    })
    model.draftChanged("Why?")
    let send = Task { await model.askTapped() }
    await Task.megaYield()
    let request = try #require(requests.value.first)
    model.questionsUpdated([
      QuestionThread(
        id: "question-1", source: QuestionSource(context: Self.context, selectedText: ""),
        turns: [QuestionTurn(questionID: "question-1", requestID: request.requestID, text: request.text, queuedAtMs: 1, isDropped: true)]
      )
    ])
    resume.yield()
    #expect(await send.value == false)
    #expect(!model.isSubmitting)
    #expect(!model.isErrorPresented)
    #expect(!model.hasUncertainSubmission)
    expectNoDifference(model.draft, "Why?")
  }

  @Test func acknowledgmentConfirmsQueueOnly() async {
    let model = model(send: { try Self.ack($0) })
    model.draftChanged("Why?")
    #expect(await model.askTapped())
    #expect(!model.isSubmitting)
  }

  @Test(arguments: [QuestionError.unavailable, .outcomeUnknown,
    .rejected(code: "SESSION_NOT_SELECTED", message: "inactive"),
    .rejected(code: "INVALID_CONTEXT", message: "invalid"),
    .rejected(code: "QUESTION_LIMIT", message: "full"),
    .rejected(code: "STORAGE_UNAVAILABLE", message: "disk"),
    .rejected(code: "REQUEST_CONFLICT", message: "conflict")])
  func failurePreservesDraft(_ failure: QuestionError) async {
    let model = model(send: { _ in throw failure })
    model.draftChanged("Why?")
    #expect(await model.askTapped() == false)
    expectNoDifference(model.draft, "Why?")
    expectNoDifference(model.context, Self.context)
    #expect(model.isErrorPresented)
    #expect(!model.isSubmitting)
  }

  nonisolated static func ack(_ request: QuestionRequest) throws -> QuestionAcknowledgment {
    try QuestionAcknowledgment.decode(Data("""
    {"v":1,"ok":true,"session_id":"\(request.sessionID)","request_id":"\(request.requestID)","question_id":"33333333-3333-4333-8333-333333333333","seq":"13","queued_at_ms":100,"expires_at_ms":1800100,"duplicate":false}
    """.utf8), for: request)
  }
}

extension AskAgentPageTests {
  @Test func addingWaitsForStoredPresetsInsteadOfOverwritingAnUnfinishedLoad() async {
    let (gate, resume) = AsyncStream<Void>.makeStream()
    let model = withDependencies {
      $0.savedQuestions.load = {
        for await _ in gate { break }
        return ["Already saved"]
      }
      $0.savedQuestions.add = { [$0] }
    } operation: { AskAgentPageModel(
      sessionID: Self.session, context: Self.context, agentConnection: .connected, captureStatus: Self.capture()) }
    let load = Task { await model.viewAppeared() }
    await Task.megaYield()
    model.addQuestionTapped()
    #expect(!model.isAddingPreset)
    resume.yield()
    await load.value
    model.addQuestionTapped()
    #expect(model.isAddingPreset)
    expectNoDifference(model.customQuestions, ["Already saved"])
  }
}

extension AskAgentPageTests {
  @Test func savingAPresetMergesWithAnotherWindowsConcurrentSaveInsteadOfOverwritingIt() async {
    let store = LockIsolated<[String]>(["From window A"])
    let model = withDependencies {
      $0.savedQuestions.load = { store.value }
      $0.savedQuestions.add = { text in
        store.withValue { $0.append(text) }
        return store.value
      }
    } operation: { AskAgentPageModel(
      sessionID: Self.session, context: Self.context, agentConnection: .connected, captureStatus: Self.capture()) }
    await model.viewAppeared()
    model.addQuestionTapped()
    model.newPreset = "From window B"
    await model.savePresetTapped()
    expectNoDifference(store.value, ["From window A", "From window B"])
    expectNoDifference(model.customQuestions, ["From window A", "From window B"])
  }
}

extension AskAgentPageTests {
  @Test func preferenceFailureHasItsOwnTitleAndDoesNotPromiseReopeningWillRepairData() async {
    let model = withDependencies {
      $0.savedQuestions.load = { throw CocoaError(.fileReadCorruptFile) }
    } operation: { AskAgentPageModel(
      sessionID: Self.session, context: Self.context, agentConnection: .connected, captureStatus: Self.capture()) }
    await model.viewAppeared()
    expectNoDifference(model.errorTitle, "Saved questions unavailable")
    #expect(!model.errorMessage.contains("reopening"))
    #expect(!model.presetsLoaded)
    expectNoDifference(model.options, AskAgentPageModel.defaults)
  }
}

extension AskAgentPageTests {
  static let waitingText = "The agent chat hasn't confirmed it can answer yet. It confirms on its next tool call after `slipstream attach`."

  @Test(arguments: [
    AgentConnection.setupPending, .disconnected(reason: "capture_not_live"), .disconnected(reason: "no_agent"),
    .disconnected(reason: nil), .unreported,
  ])
  func askWaitsForSetupUntilTheLinkedChatIsReady(state: AgentConnection) {
    let model = model(agentConnection: state)
    model.draftChanged("Why?")
    #expect(!model.canSubmit)
    expectNoDifference(model.askNoticeText, Self.waitingText)
    expectNoDifference(model.draft, "Why?")
  }

  @Test func askIsEnabledWhenRecordingLinkedAndReady() {
    let model = model(agentConnection: .connected)
    #expect(!model.canSubmit)
    model.draftChanged("Why?")
    #expect(model.canSubmit)
    #expect(model.askNoticeText == nil)
  }

  @Test func connectingKeepsTheDraftAndEnablesAsk() {
    let model = model(agentConnection: .setupPending)
    model.draftChanged("Why?")
    #expect(!model.canSubmit)
    model.agentConnectionChanged(.connected)
    #expect(model.canSubmit)
    #expect(model.askNoticeText == nil)
    expectNoDifference(model.draft, "Why?")
  }

  @Test func aCaptureThatStopsRecordingDisablesAskAndKeepsTheDraft() {
    let model = model(agentConnection: .connected)
    model.draftChanged("Why?")
    model.captureChanged(Self.capture(.stopped))
    #expect(!model.canSubmit)
    expectNoDifference(model.askNoticeText, "This workspace isn't recording, so its chat can't receive questions.")
    expectNoDifference(model.draft, "Why?")
    expectNoDifference(model.sessionID, Self.session)
  }

  @Test func aConnectedRuntimeDoesNotEnableAskWithoutALinkedChat() {
    let model = model(agentConnection: .connected, captureStatus: Self.capture(binding: nil))
    model.draftChanged("Why?")
    #expect(!model.canSubmit)
    expectNoDifference(
      model.askNoticeText,
      "No agent chat is linked to this workspace. Run `slipstream attach` inside the agent chat to link one.")
  }

  @Test func askNamesTheLinkedChatsBindingGeneration() async {
    let sent = LockIsolated<[QuestionRequest]>([])
    let model = model(send: { request in
      sent.withValue { $0.append(request) }
      return try Self.ack(request)
    })
    model.draftChanged("Why?")
    #expect(await model.askTapped())
    expectNoDifference(sent.value.map(\.bindingGeneration), ["7"])
  }

  @Test func aRelinkedChatRejectionSaysToRefreshAndTheComposerKeepsItsOriginalLink() async {
    let sent = LockIsolated<[QuestionRequest]>([])
    let model = model(send: { request in
      sent.withValue { $0.append(request) }
      throw QuestionError.rejected(code: "STALE_BINDING", message: "relinked")
    })
    model.draftChanged("Why?")
    #expect(!(await model.askTapped()))
    expectNoDifference(
      model.errorMessage,
      "This workspace's chat was relinked after the app last checked. Refresh to see which chat is linked now, then ask again. Your draft is kept.")
    model.captureChanged(Self.capture(binding: CaptureBinding(generation: "8", state: .connected)))
    #expect(!(await model.askTapped()))
    expectNoDifference(sent.value.map(\.bindingGeneration), ["7", "7"])
  }

  @Test func aComposerOpenedBeforeAChatIsLinkedNamesTheFirstLinkItSees() async {
    let sent = LockIsolated<[QuestionRequest]>([])
    let model = model(captureStatus: Self.capture(binding: nil), send: { request in
      sent.withValue { $0.append(request) }
      return try Self.ack(request)
    })
    model.draftChanged("Why?")
    model.captureChanged(Self.capture(binding: CaptureBinding(generation: "8", state: .connected)))
    model.captureChanged(Self.capture(binding: CaptureBinding(generation: "9", state: .connected)))
    #expect(await model.askTapped())
    expectNoDifference(sent.value.map(\.bindingGeneration), ["8"])
  }

  @Test func askingWhileNotConnectedSendsNothing() async {
    let sent = LockIsolated(0)
    let model = model(agentConnection: .setupPending, send: { request in
      sent.withValue { $0 += 1 }
      return try Self.ack(request)
    })
    model.draftChanged("Why?")
    let queued = await model.askTapped()
    #expect(!queued)
    expectNoDifference(sent.value, 0)
  }

  @Test func agentNotConnectedRejectionKeepsTheDraftAndNamesTheFix() async {
    let model = model(send: { _ in throw QuestionError.rejected(code: "AGENT_NOT_CONNECTED", message: "no") })
    model.draftChanged("Why?")
    _ = await model.askTapped()
    expectNoDifference(
      model.errorMessage,
      "The agent chat for this capture hasn't confirmed it can answer. Run `slipstream attach` inside that chat. The question stays bound to its original capture. Your draft is kept."
    )
    expectNoDifference(model.draft, "Why?")
  }
}
