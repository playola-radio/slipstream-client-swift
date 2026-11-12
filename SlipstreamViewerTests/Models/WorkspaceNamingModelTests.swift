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
  let suggestionFake = WorkspaceNameSuggestionFake()
  let agent = AgentFake()
  let refreshes = LockIsolated(0)
  let writeFailures = LockIsolated<[[String]]>([])
  let copied = LockIsolated<[String]>([])

  func makeModel() -> WorkspaceNamingModel {
    withDependencies {
      $0.workspaceName = nameFake.client
      $0.workspaceNameSuggestion = suggestionFake.client
      $0.agentEnvironment = agent.environmentClient
      $0.pasteboard = PasteboardClient(copy: { [copied] text in copied.withValue { $0.append(text) } })
    } operation: {
      let model = WorkspaceNamingModel()
      model.onWriteFinished = { [refreshes] in refreshes.withValue { $0 += 1 } }
      model.onWriteFailed = { [writeFailures] title, detail in writeFailures.withValue { $0.append([title, detail]) } }
      return model
    }
  }

  static func listed(userName: String?) -> SessionOption {
    SessionOption(id: session, label: session, naming: SessionNaming(agentName: "Agent's name", userName: userName))
  }

  @Test func opensWithCurrentName() {
    let model = makeModel()

    model.renameTapped(sessionID: Self.session, currentName: "Workspace rename menu")

    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.session, draft: "Workspace rename menu", phase: .editing))
    expectNoDifference(
      [model.titleText, model.fieldAccessibilityLabel, model.helperText, model.primaryButtonTitle],
      [
        "Rename workspace", "Workspace name", "Only changes the name shown in Slipstream. The folder and branch stay the same.",
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

  @Test func renameClosesAndShowsTheNameBeforeTheDaemonAnswers() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    model.draftChanged("  Sidebar polling backoff ")
    nameFake.hold()

    let save = Task { await model.renameConfirmed() }
    await Task.megaYield()

    expectNoDifference(model.dialog, nil)
    expectNoDifference(model.userName(Self.listed(userName: "Old name")), "Sidebar polling backoff")
    nameFake.release()
    await save.value
  }

  @Test func successClosesAndRefreshes() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")

    await model.renameConfirmed()

    expectNoDifference(model.dialog, nil)
    expectNoDifference(refreshes.value, 1)
  }

  @Test func theNewNameStaysUntilTheDaemonListsIt() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    model.draftChanged("New name")
    await model.renameConfirmed()

    model.sessionsListed([Self.listed(userName: "Old name")])
    expectNoDifference(model.userName(Self.listed(userName: "Old name")), "New name")

    model.sessionsListed([Self.listed(userName: "New name")])
    expectNoDifference(model.pendingNames, [:])
  }

  @Test func aListingWhileTheRenameIsOnItsWayKeepsTheNewName() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    model.draftChanged("New name")
    nameFake.hold()
    let save = Task { await model.renameConfirmed() }
    await Task.megaYield()

    model.sessionsListed([Self.listed(userName: "New name")])

    expectNoDifference(model.pendingNames, [Self.session: .init(write: 1, userName: "New name")])
    nameFake.release()
    await save.value
  }

  @Test func failedRenamePutsTheOldNameBackAndReopensWithTheDraftAndError() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    model.draftChanged("New name ")
    nameFake.setFailure(.rejected(code: "STORAGE_UNAVAILABLE", message: "store lock lost"))
    nameFake.hold()
    let save = Task { await model.renameConfirmed() }
    await Task.megaYield()
    expectNoDifference(model.userName(Self.listed(userName: "Old name")), "New name")

    nameFake.release()
    await save.value

    expectNoDifference(model.userName(Self.listed(userName: "Old name")), "Old name")
    expectNoDifference(
      model.dialog,
      WorkspaceNamingModel.Dialog(
        id: Self.session, draft: "New name ",
        phase: .saveFailed(headline: "Slipstream refused the rename.", detail: "STORAGE_UNAVAILABLE: store lock lost")))
    expectNoDifference(refreshes.value, 1)
  }

  @Test func failedRenameWhileAnotherDialogIsOpenShowsTheErrorInstead() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    nameFake.setFailure(.rejected(code: "STORAGE_UNAVAILABLE", message: "store lock lost"))
    nameFake.hold()
    let save = Task { await model.renameConfirmed() }
    await Task.megaYield()
    model.renameTapped(sessionID: Self.otherSession, currentName: "Other")

    nameFake.release()
    await save.value

    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.otherSession, draft: "Other", phase: .editing))
    expectNoDifference(writeFailures.value, [["Couldn't rename the workspace", "STORAGE_UNAVAILABLE: store lock lost"]])
  }

  @Test func aSecondRenameWaitsForTheFirstAndWins() async {
    let model = makeModel()
    nameFake.hold()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    model.draftChanged("First")
    let first = Task { await model.renameConfirmed() }
    await Task.megaYield()
    model.renameTapped(sessionID: Self.session, currentName: "First")
    model.draftChanged("Second")
    let second = Task { await model.renameConfirmed() }
    await Task.megaYield()
    expectNoDifference(nameFake.calls, [.init(sessionID: Self.session, name: "First")])

    nameFake.release()
    await first.value
    await second.value

    expectNoDifference(
      nameFake.calls, [.init(sessionID: Self.session, name: "First"), .init(sessionID: Self.session, name: "Second")])
    expectNoDifference(model.userName(Self.listed(userName: "Old name")), "Second")
  }

  @Test func anEarlierRenamesFailureLeavesTheLaterNameAlone() async {
    let model = makeModel()
    nameFake.setFailure(.unavailable)
    nameFake.hold()
    model.renameTapped(sessionID: Self.session, currentName: "Old name")
    model.draftChanged("First")
    let first = Task { await model.renameConfirmed() }
    await Task.megaYield()
    model.renameTapped(sessionID: Self.session, currentName: "First")
    model.draftChanged("Second")
    let second = Task { await model.renameConfirmed() }
    await Task.megaYield()

    nameFake.release()
    await first.value
    await second.value

    expectNoDifference(model.userName(Self.listed(userName: "Old name")), "Second")
    expectNoDifference(model.dialog, nil)
    expectNoDifference(writeFailures.value, [])
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
    expectNoDifference(writeFailures.value, [])
  }

  @Test func useAgentNameShowsTheAgentsNameBeforeTheDaemonAnswers() async {
    let model = makeModel()
    nameFake.hold()

    let clear = Task { await model.useAgentNameTapped(sessionID: Self.session) }
    await Task.megaYield()

    expectNoDifference(model.userName(Self.listed(userName: "My name")), nil)
    nameFake.release()
    await clear.value
  }

  @Test func failedUseAgentNamePutsTheNameBackAndShowsTheError() async {
    let model = makeModel()
    nameFake.setFailure(.rejected(code: "STORAGE_UNAVAILABLE", message: "store lock lost"))

    await model.useAgentNameTapped(sessionID: Self.session)

    expectNoDifference(model.userName(Self.listed(userName: "My name")), "My name")
    expectNoDifference(
      writeFailures.value, [["Couldn't switch back to the agent's name", "STORAGE_UNAVAILABLE: store lock lost"]])
  }

  @Test func firstMessageStoresTheSuggestedNameAsTheAgentsNameAndRefreshes() async {
    let model = makeModel()

    model.messageSent(sessionID: Self.session, text: "Slow down the sidebar polling")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, ["Slow down the sidebar polling"])
    expectNoDifference(
      nameFake.calls, [.init(sessionID: Self.session, name: "Sidebar Polling Backoff", isAgentName: true)])
    expectNoDifference(refreshes.value, 1)
    expectNoDifference(writeFailures.value, [])
  }

  @Test func eachSessionIsSuggestedForOnlyOnce() async {
    let model = makeModel()

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()
    model.messageSent(sessionID: Self.session, text: "Second")
    await Task.megaYield()
    model.messageSent(sessionID: Self.otherSession, text: "Third")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, ["First", "Third"])
    expectNoDifference(nameFake.calls.map(\.sessionID), [Self.session, Self.otherSession])
  }

  @Test func aMessageWhileTheSuggestionIsRunningDoesNotStartAnother() async {
    let model = makeModel()
    agent.hold(.environment)

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()
    model.messageSent(sessionID: Self.session, text: "Second")
    agent.release(.environment)
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, ["First"])
  }

  @Test func failedSuggestionWritesNothingAndDoesNotRefresh() async {
    let model = makeModel()
    suggestionFake.setFails()

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()

    expectNoDifference(nameFake.calls, [])
    expectNoDifference(refreshes.value, 0)
    expectNoDifference(writeFailures.value, [])
  }

  @Test func failedSuggestionIsNotRetriedOnTheNextMessage() async {
    let model = makeModel()
    suggestionFake.setFails()
    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()

    model.messageSent(sessionID: Self.session, text: "Second")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, ["First"])
  }

  @Test func unresolvedEnvironmentSuggestsNothing() async {
    let model = makeModel()
    agent.setEnvironmentError(.claudeNotFound)

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, [])
    expectNoDifference(nameFake.calls, [])
    expectNoDifference(refreshes.value, 0)
  }

  @Test(arguments: [
    QuestionError.outcomeUnknown, .unavailable, .rejected(code: "PROTOCOL", message: "unknown verb: name_session"),
  ])
  func failedWriteStillRefreshesAndShowsNothing(error: QuestionError) async {
    let model = makeModel()
    nameFake.setFailure(error)

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()

    expectNoDifference(nameFake.calls.count, 1)
    expectNoDifference(refreshes.value, 1)
    expectNoDifference(writeFailures.value, [])
    expectNoDifference(model.dialog, nil)
  }

  @Test func suggestionWriteLeavesAnOpenRenameDialogAlone() async {
    let model = makeModel()
    model.renameTapped(sessionID: Self.session, currentName: "Sidebar polling backoff")
    model.draftChanged("My own name")
    nameFake.hold()

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()

    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.session, draft: "My own name", phase: .editing))
    #expect(model.isRenameEnabled)

    nameFake.release()
    await Task.megaYield()
    expectNoDifference(
      model.dialog, WorkspaceNamingModel.Dialog(id: Self.session, draft: "My own name", phase: .editing))
  }

  @Test func quitStopsARunningSuggestionAndWritesNoName() async {
    let model = makeModel()
    suggestionFake.hold()
    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()
    expectNoDifference(suggestionFake.messages, ["First"])

    await model.quitConfirmed()

    expectNoDifference(nameFake.calls, [])
    expectNoDifference(refreshes.value, 0)
  }

  @Test func nothingIsSuggestedAfterQuit() async {
    let model = makeModel()
    await model.quitConfirmed()

    model.messageSent(sessionID: Self.session, text: "First")
    await Task.megaYield()

    expectNoDifference(suggestionFake.messages, [])
  }
}
