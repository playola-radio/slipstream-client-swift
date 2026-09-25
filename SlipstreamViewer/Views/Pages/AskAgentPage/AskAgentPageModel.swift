import Dependencies
import Foundation
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

  init(sessionID: String, context: QuestionContext) {
    self.sessionID = sessionID
    self.context = context
    super.init()
  }

  // MARK: - Properties

  static let defaults = ["Why are you making this change?", "Explain your thinking here, please."]
  let sessionID: String
  let context: QuestionContext
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
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var isActive = true
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
  let errorTitle = "Question not confirmed"
  let errorDismissText = "OK"

  var contextText: String { "\(context.path) · Lines \(context.lineStart)–\(context.lineEnd)" }
  var options: [String] { Self.defaults + customQuestions }

  // MARK: - View Helpers

  var canSubmit: Bool { isActive && !isSubmitting && context.isValid && !QuestionRequest.trim(draft).isEmpty }
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
      customQuestions = saved.reduce(into: []) { options, text in
        guard !QuestionRequest.trim(text).isEmpty, !Self.defaults.contains(text), !options.contains(text) else { return }
        options.append(text)
      }
      presetsLoaded = true
    } catch {
      guard isActive, operation == generation else { return }
      hasLoadedPresets = false
      showError("Your saved questions couldn't be loaded. Try reopening the composer.")
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
    let updated = options.contains(text) ? customQuestions : customQuestions + [text]
    let operation = generation
    isSavingPreset = true
    do {
      try await savedQuestions.save(updated)
      guard isActive, operation == generation else { return }
      customQuestions = updated
      selectedPreset = text
      isAddingPreset = false
      isMenuOpen = false
      newPreset = ""
      isSavingPreset = false
    } catch {
      guard isActive, operation == generation else { return }
      isSavingPreset = false
      showError("This saved question couldn't be saved. Your question and previous selection are unchanged.")
    }
  }

  func askTapped() async -> Bool {
    guard canSubmit else { return false }
    let intent = request ?? QuestionRequest(
      sessionID: sessionID, requestID: uuid().uuidString.lowercased(), text: draft, context: context
    )
    request = intent
    let operation = generation
    isSubmitting = true
    do {
      let acknowledgment = try await questionClient.send(intent)
      guard acknowledgment.sessionID == intent.sessionID, acknowledgment.requestID == intent.requestID else {
        throw QuestionError.outcomeUnknown
      }
      guard isActive, generation == operation else { return false }
      isSubmitting = false
      return true
    } catch {
      guard isActive, generation == operation else { return false }
      isSubmitting = false
      switch error {
      case QuestionError.unavailable:
        showError("The question service isn't available. Your draft is kept; try again when the daemon is running." + uncertaintyText)
      case QuestionError.rejected(let code, _):
        if code == "STORAGE_UNAVAILABLE" { hasUncertainSubmission = true }
        showError(Self.failureText(code) + uncertaintyText)
      default:
        hasUncertainSubmission = true
        showError("The daemon's response wasn't received or couldn't be verified." + uncertaintyText)
      }
      return false
    }
  }

  func dismissed() {
    isActive = false
    generation += 1
  }

  // MARK: - Private Helpers

  private var uncertaintyText: String {
    hasUncertainSubmission
      ? " An earlier submission may already be queued. Retry unchanged to reuse its request ID. Editing sends a separate question."
      : " Your draft is kept."
  }

  private func showError(_ message: String) {
    errorMessage = message
    isErrorPresented = true
  }

  private static func failureText(_ code: String) -> String {
    switch code {
    case "SESSION_NOT_SELECTED": "This capture is no longer attached to the agent. The question stays bound to its original capture."
    case "CAPTURE_NOT_READY": "The capture isn't ready to accept questions. Try again shortly."
    case "INVALID_CONTEXT": "This source selection couldn't be verified. Select up to 200 lines from an available snapshot."
    case "INVALID_QUESTION": "Use a nonempty question of at most 8192 UTF-8 bytes."
    case "QUESTION_LIMIT": "The question queue is full. Try again later."
    case "STORAGE_UNAVAILABLE": "The daemon couldn't confirm storage of this question."
    case "REQUEST_CONFLICT": "This request ID already belongs to a different question."
    case "DAEMON_UNAVAILABLE": "The question service isn't available."
    default: "The daemon couldn't accept this question (\(code))."
    }
  }
}
