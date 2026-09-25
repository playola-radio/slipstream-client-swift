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

  func model(save: @escaping @Sendable ([String]) async throws -> Void = { _ in }, send: @escaping @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment = { _ in throw QuestionError.unavailable }) -> AskAgentPageModel {
    withDependencies {
      $0.uuid = .incrementing
      $0.questionClient.send = send
      $0.savedQuestions.load = { [] }
      $0.savedQuestions.save = save
    } operation: {
      AskAgentPageModel(sessionID: Self.session, context: Self.context)
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
    let model = model(save: { saved.setValue($0) })
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
    let model = model(save: { _ in throw QuestionError.unavailable })
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
      $0.savedQuestions.save = { _ in }
    } operation: { AskAgentPageModel(sessionID: Self.session, context: Self.context) }
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
  @Test func preferenceFailureHasItsOwnTitleAndDoesNotPromiseReopeningWillRepairData() async {
    let model = withDependencies {
      $0.savedQuestions.load = { throw CocoaError(.fileReadCorruptFile) }
    } operation: { AskAgentPageModel(sessionID: Self.session, context: Self.context) }
    await model.viewAppeared()
    expectNoDifference(model.errorTitle, "Saved questions unavailable")
    #expect(!model.errorMessage.contains("reopening"))
    #expect(!model.presetsLoaded)
    expectNoDifference(model.options, AskAgentPageModel.defaults)
  }
}
