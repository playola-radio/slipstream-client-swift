import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct WorkspaceNamingModelTests {
  nonisolated static let session = "0f8c2a4e-5b1d-4c3e-9a7f-2d6b8e1c4a90"
  nonisolated static let otherSession = "1b2c3d4e-2222-4c55-9a7e-2f4b8c9d0e1b"

  let nameFake = WorkspaceNameFake()
  let refreshes = LockIsolated(0)
  let clearFailures = LockIsolated<[String]>([])
  let copied = LockIsolated<[String]>([])

  func makeModel() -> WorkspaceNamingModel {
    withDependencies {
      $0.workspaceName = nameFake.client
      $0.pasteboard = PasteboardClient(copy: { [copied] text in copied.withValue { $0.append(text) } })
    } operation: {
      let model = WorkspaceNamingModel()
      model.onWriteFinished = { [refreshes] in refreshes.withValue { $0 += 1 } }
      model.onClearFailed = { [clearFailures] detail in clearFailures.withValue { $0.append(detail) } }
      return model
    }
  }

  @Test func opensWithCurrentName() {
    let model = makeModel()

    model.renameTapped(sessionID: Self.session, currentName: "Workspace rename menu")

    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.session, draft: "Workspace rename menu", phase: .editing))
    expectNoDifference(
      [model.titleText, model.helperText, model.primaryButtonTitle],
      [
        "Rename workspace", "Only changes the name shown in Slipstream. The folder and branch stay the same.",
        "Rename",
      ])
    #expect(model.isRenameEnabled)
  }

  @Test(arguments: ["", "   ", "\u{FEFF} "])
  func emptyDisablesRename(draft: String) {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Workspace rename menu")

    model.draftChanged(draft)

    #expect(!model.isRenameEnabled)
    expectNoDifference(model.validationMessage, nil)
  }

  @Test func tooLongShowsMessage() {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "")

    model.draftChanged(String(repeating: "🙂", count: 16))
    expectNoDifference([model.isRenameEnabled ? "enabled" : "disabled", model.validationMessage], ["enabled", nil])

    model.draftChanged(String(repeating: "🙂", count: 16) + "a")
    expectNoDifference(
      [model.isRenameEnabled ? "enabled" : "disabled", model.validationMessage],
      ["disabled", "That name is too long. Shorten it to save."])
    expectNoDifference(
      [model.errorText, model.isFieldInvalid ? "invalid" : "valid"],
      ["That name is too long. Shorten it to save.", "invalid"])
  }

  @Test(arguments: ["Two\nlines", "Two\u{2028}lines", "\tTabbed"])
  func controlCharacterShowsMessage(draft: String) {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "")

    model.draftChanged(draft)

    #expect(!model.isRenameEnabled)
    expectNoDifference(model.validationMessage, "Names can't contain line breaks or special characters.")
  }

  @Test func sendsTrimmedName() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "")
    model.draftChanged("  Sidebar polling backoff\u{FEFF} ")

    await model.renameConfirmed()

    expectNoDifference(nameFake.calls, [.init(sessionID: Self.session, name: "Sidebar polling backoff")])
  }

  @Test func savingDisablesFieldAndCancel() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.hold()

    let save = Task { await model.renameConfirmed() }
    await Task.megaYield()

    expectNoDifference(
      [model.isSaving, model.isMutationInFlight, model.isRenameEnabled, model.isFieldDisabled, model.isPrimaryDimmed],
      [true, true, false, true, false])
    expectNoDifference(model.primaryButtonTitle, "Saving…")
    model.cancelTapped()
    model.isDialogPresented = false
    model.draftChanged("Something else")
    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.session, draft: "Sidebar polling backoff", phase: .saving))

    nameFake.release()
    await save.value
  }

  @Test func successClosesAndRefreshes() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")

    await model.renameConfirmed()

    expectNoDifference(model.dialog, nil)
    expectNoDifference(refreshes.value, 1)
    #expect(!model.isMutationInFlight)
  }

  @Test func outcomeUnknownShowsSaveFailedAndRefreshes() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.setFailure(.outcomeUnknown)

    await model.renameConfirmed()

    expectNoDifference(
      model.dialog?.phase,
      .saveFailed(
        headline: "Couldn't confirm the name was saved. Slipstream didn't reply.",
        detail: "OUTCOME_UNKNOWN: the rename was sent but no valid reply came back"))
    expectNoDifference(model.primaryButtonTitle, "Try again")
    expectNoDifference(model.errorText, "Couldn't confirm the name was saved. Slipstream didn't reply.")
    expectNoDifference(refreshes.value, 1)
    expectNoDifference(nameFake.calls.count, 1)
    #expect(model.isRenameEnabled)
  }

  @Test(arguments: [
    (
      QuestionError.outcomeUnknown,
      [
        "Couldn't confirm the name was saved. Slipstream didn't reply.",
        "OUTCOME_UNKNOWN: the rename was sent but no valid reply came back",
      ]
    ),
    (
      .unavailable,
      [
        "Couldn't reach Slipstream, so the name wasn't saved.",
        "DAEMON_UNAVAILABLE: couldn't connect to Slipstream's control socket",
      ]
    ),
    (
      .rejected(code: "STORAGE_UNAVAILABLE", message: "store lock lost"),
      ["Slipstream refused the rename.", "STORAGE_UNAVAILABLE: store lock lost"]
    ),
  ])
  func saveFailedShowsHeadlineAndRawError(error: QuestionError, expected: [String]) async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.setFailure(error)

    await model.renameConfirmed()

    expectNoDifference([model.failureHeadline, model.failureDetail], expected)
  }

  @Test func editingAfterAFailedSaveClearsTheFailure() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.setFailure(.unavailable)
    await model.renameConfirmed()

    model.draftChanged("Sidebar polling")

    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.session, draft: "Sidebar polling", phase: .editing))
    expectNoDifference([model.primaryButtonTitle, model.errorText], ["Rename", nil])
  }

  @Test func copyErrorCopiesDetail() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.setFailure(.rejected(code: "STORAGE_UNAVAILABLE", message: "store lock lost"))
    await model.renameConfirmed()

    model.copyErrorTapped()

    expectNoDifference(copied.value, ["STORAGE_UNAVAILABLE: store lock lost"])
  }

  @Test func sessionNotFoundShowsGone() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.setFailure(.rejected(code: "SESSION_NOT_FOUND", message: "session was deleted"))

    await model.renameConfirmed()

    expectNoDifference(model.dialog?.phase, .gone)
    expectNoDifference(
      [model.failureHeadline, model.failureDetail], ["This workspace was deleted, so it can't be renamed.", nil])
    expectNoDifference(
      [model.isCloseOnly, model.isRenameEnabled, model.isFieldDisabled, model.isHelperShown], [true, false, true, false])
    expectNoDifference(refreshes.value, 1)
    model.closeTapped()
    expectNoDifference(model.dialog, nil)
  }

  @Test func editingThroughTheFieldUpdatesDraft() {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")

    model.draft = "Sidebar polling"

    expectNoDifference(model.dialog?.draft, "Sidebar polling")
    expectNoDifference([model.isHelperShown, model.isPrimaryDimmed, model.isFieldInvalid], [true, false, false])
  }

  @Test func emptyDraftDimsRename() {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")

    model.draft = ""

    expectNoDifference([model.isPrimaryDimmed, model.isFieldInvalid], [true, false])
    expectNoDifference(model.errorText, nil)
  }

  @Test func dismissingTheSheetCancels() {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    #expect(model.isDialogPresented)

    model.isDialogPresented = false

    expectNoDifference(model.dialog, nil)
  }

  @Test func invalidNameShowsDaemonMessage() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    nameFake.setFailure(.rejected(code: "INVALID_NAME", message: "name is not well-formed UTF-16"))

    await model.renameConfirmed()

    expectNoDifference(model.validationMessage, "name is not well-formed UTF-16")
    #expect(!model.isRenameEnabled)
    model.draftChanged("Sidebar polling")
    expectNoDifference(model.validationMessage, nil)
    #expect(model.isRenameEnabled)
  }

  @Test func useAgentNameSendsNull() async {
    let model = makeModel()

    await model.useAgentNameTapped(sessionID: Self.session)

    expectNoDifference(nameFake.calls, [.init(sessionID: Self.session, name: nil)])
    expectNoDifference(refreshes.value, 1)
    expectNoDifference(clearFailures.value, [])
  }

  @Test func clearBlocksSubsequentRename() async {
    let model = makeModel()
    nameFake.hold()
    let clear = Task { await model.useAgentNameTapped(sessionID: Self.session) }
    await Task.megaYield()

    #expect(model.isMutationInFlight)
    model.renameTapped(sessionID: Self.otherSession, currentName: "Other")
    await model.renameConfirmed()
    await model.useAgentNameTapped(sessionID: Self.otherSession)
    expectNoDifference(nameFake.calls, [.init(sessionID: Self.session, name: nil)])

    nameFake.release()
    await clear.value
    model.renameTapped(sessionID: Self.otherSession, currentName: "Other")
    await model.renameConfirmed()

    expectNoDifference(
      nameFake.calls, [.init(sessionID: Self.session, name: nil), .init(sessionID: Self.otherSession, name: "Other")])
  }
}
