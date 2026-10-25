import Dependencies
import Foundation
import IdentifiedCollections
import SlipstreamCore
import SwiftUI

@MainActor
@Observable
final class AskAgentPageModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.questionClient) var questionClient
  @ObservationIgnored @Dependency(\.savedQuestions) var savedQuestions
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Initialization

  init(
    sessionID: String, context: QuestionContext, agentConnection: AgentConnection, captureStatus: CaptureStatus,
    isAppTabLinked: Bool
  ) {
    self.sessionID = sessionID
    self.context = context
    self.agentConnection = agentConnection
    self.captureStatus = captureStatus
    self.isAppTabLinked = isAppTabLinked
    bindingGeneration = captureStatus.capture?.binding?.generation
    super.init()
  }

  // MARK: - Properties

  static let defaults = ["Why are you making this change?", "Explain your thinking here, please."]
  let sessionID: String
  let context: QuestionContext
  private(set) var agentConnection: AgentConnection
  private(set) var captureStatus: CaptureStatus
  private(set) var isAppTabLinked: Bool
  private(set) var draft = ""
  private(set) var customQuestions: [String] = []
  private(set) var selectedPreset = defaults[0]
  private(set) var isMenuOpen = false
  private(set) var isAddingPreset = false
  private(set) var isSavingPreset = false
  private(set) var presetsLoaded = false
  private(set) var isSubmitting = false
  private(set) var caretRevision = 0
  private(set) var hasUncertainSubmission = false
  var newPreset = ""
  var isErrorPresented = false
  private(set) var errorMessage = ""
  @ObservationIgnored private var request: QuestionRequest?
  @ObservationIgnored private var bindingGeneration: String?
  @ObservationIgnored private var generation = 0
  private var isActive: Bool { generation == 0 }
  @ObservationIgnored private var hasLoadedPresets = false

  // MARK: - Display Text

  let title = "Talk to the agent"
  let closeText = "Close question"
  let cancelText = "Cancel"
  let askText = "Ask agent"
  let savedQuestionsText = "Or start with a saved question"
  let appendText = "Append to question"
  let addText = "Add a question…"
  let saveText = "Save"
  private(set) var errorTitle = "Question not confirmed"
  let errorDismissText = "OK"

  var contextText: String { "\(context.path) · Lines \(context.lineStart)–\(context.lineEnd)" }
  var options: [String] { Self.defaults + customQuestions }

  var askNoticeText: String? { captureStatus.askNotice(agentConnection: agentConnection, isAppTabLinked: isAppTabLinked) }

  // MARK: - View Helpers

  var canSubmit: Bool {
    isActive && !isSubmitting && context.isValid && askNoticeText == nil && !QuestionRequest.trim(draft).isEmpty
  }
  var canSavePreset: Bool { presetsLoaded && !isSavingPreset && !QuestionRequest.trim(newPreset).isEmpty }
  var dropdownIcon: String { isMenuOpen ? "ChevronUp" : "ChevronDown" }
  var isEditingDisabled: Bool { isSubmitting || !isActive }

  func isSelected(_ option: String) -> Bool { selectedPreset == option }
  func optionFill(_ option: String) -> Color {
    selectedPreset == option ? DesignTokens.Ask.menuSelected : .clear
  }

  // MARK: - User Actions

  func viewAppeared() async {
    guard !hasLoadedPresets else { return }
    hasLoadedPresets = true
    let operation = generation
    do {
      let saved = try await savedQuestions.load()
      guard isActive, operation == generation else { return }
      customQuestions = Self.sanitize(saved)
      presetsLoaded = true
    } catch {
      guard isActive, operation == generation else { return }
      hasLoadedPresets = false
      showError("Your saved questions couldn't be loaded. The defaults are available, but adding questions is disabled to preserve your saved data.", title: "Saved questions unavailable")
    }
  }

  func draftChanged(_ text: String) {
    guard !isEditingDisabled, text != draft else { return }
    if QuestionRequest.trim(text) != QuestionRequest.trim(draft) { request = nil }
    draft = text
  }

  func menuTapped() {
    guard !isSavingPreset else { return }
    if isAddingPreset { cancelPresetTapped() }
    isMenuOpen.toggle()
  }

  func savedQuestionSelected(_ option: String) {
    guard options.contains(option), !isAddingPreset else { return }
    selectedPreset = option
    isMenuOpen = false
  }

  func appendTapped() {
    guard !isEditingDisabled else { return }
    draftChanged(draft + (draft.isEmpty ? "" : "\n") + selectedPreset)
    caretRevision += 1
  }

  func addQuestionTapped() {
    guard presetsLoaded else { return }
    newPreset = ""
    isAddingPreset = true
    isMenuOpen = true
  }

  func cancelPresetTapped() {
    guard !isSavingPreset else { return }
    newPreset = ""
    isAddingPreset = false
  }

  func savePresetTapped() async {
    guard isActive, canSavePreset else { return }
    let text = QuestionRequest.trim(newPreset)
    let operation = generation
    isSavingPreset = true
    do {
      let updated = try await savedQuestions.add(text)
      guard isActive, operation == generation else { return }
      customQuestions = Self.sanitize(updated)
      selectedPreset = text
      isAddingPreset = false
      isMenuOpen = false
      newPreset = ""
      isSavingPreset = false
    } catch {
      guard isActive, operation == generation else { return }
      isSavingPreset = false
      showError("This saved question couldn't be saved. Your question and previous selection are unchanged.", title: "Saved question not saved")
    }
  }

  func askTapped() async -> Bool {
    guard canSubmit else { return false }
    let intent = QuestionRequest(
      sessionID: sessionID, requestID: request?.requestID ?? uuid().uuidString.lowercased(),
      text: request?.text ?? draft, context: context,
      verb: .ask(bindingGeneration: bindingGeneration)
    )
    request = intent
    let operation = generation
    isSubmitting = true
    do {
      _ = try await questionClient.send(intent)
      guard isActive, generation == operation, request == intent else { return false }
      isSubmitting = false
      return true
    } catch {
      guard isActive, generation == operation, request == intent else { return false }
      isSubmitting = false
      if QuestionFailure.isOutcomeUnknown(error) { hasUncertainSubmission = true }
      showError(QuestionFailure.message(error, hasUncertainSubmission: hasUncertainSubmission))
      return false
    }
  }

  func agentConnectionChanged(_ connection: AgentConnection) {
    agentConnection = connection
  }

  func captureChanged(_ status: CaptureStatus, isAppTabLinked: Bool) {
    captureStatus = status
    self.isAppTabLinked = isAppTabLinked
    bindingGeneration = bindingGeneration ?? status.capture?.binding?.generation
  }

  func questionsUpdated(_ threads: IdentifiedArrayOf<QuestionThread>) {
    guard let request,
      threads.contains(where: { thread in
        thread.turns.contains { $0.requestID == request.requestID && $0.status == .notDelivered }
      })
    else { return }
    self.request = nil
    isSubmitting = false
    hasUncertainSubmission = false
  }

  func dismissed() {
    generation += 1
  }

  // MARK: - Private Helpers

  private func showError(_ message: String, title: String = "Question not confirmed") {
    errorTitle = title
    errorMessage = message
    isErrorPresented = true
  }

  private static func sanitize(_ questions: [String]) -> [String] {
    questions.reduce(into: []) { options, text in
      guard !QuestionRequest.trim(text).isEmpty, !Self.defaults.contains(text), !options.contains(text) else { return }
      options.append(text)
    }
  }
}
