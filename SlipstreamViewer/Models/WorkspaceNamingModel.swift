import Dependencies
import Foundation
import SlipstreamCore

/// Owns every workspace-name write: the Rename dialog and "Use agent's name". One write runs at a
/// time, every write refreshes the list (a lost reply may still have saved), and none is resent.
@MainActor
@Observable
final class WorkspaceNamingModel: ViewModel {
  struct Dialog: Equatable, Identifiable {
    /// The session being renamed.
    let id: String
    var draft: String
    var phase: Phase
  }

  enum Phase: Equatable {
    case editing
    case saving
    case saveFailed(headline: String, detail: String)
    case gone
    case rejected(String)
  }

  struct Mutation: Equatable {
    enum Kind { case rename, clear }

    let sessionID: String
    let kind: Kind
  }

  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.workspaceName) var workspaceName
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard

  // MARK: - Properties

  static let maximumNameBytes = 64

  /// Refreshes the session list after every write.
  @ObservationIgnored var onWriteFinished: @MainActor () async -> Void = {}
  /// Shows a failed "Use agent's name" with its raw error.
  @ObservationIgnored var onClearFailed: @MainActor (_ detail: String) -> Void = { _ in }

  private(set) var dialog: Dialog?
  private(set) var activeMutation: Mutation?

  // MARK: - Display Text

  let titleText = "Rename workspace"
  let helperText = "Only changes the name shown in Slipstream. The folder and branch stay the same."
  let cancelButtonTitle = "Cancel"
  let closeButtonTitle = "Close"
  let copyButtonTitle = "Copy"

  var validationMessage: String? {
    guard let dialog else { return nil }
    if case .rejected(let message) = dialog.phase { return message }
    return Self.validate(dialog.draft).message
  }

  var failureHeadline: String? {
    switch dialog?.phase {
    case .saveFailed(let headline, _): headline
    case .gone: "This workspace was deleted, so it can't be renamed."
    default: nil
    }
  }

  var failureDetail: String? {
    guard case .saveFailed(_, let detail) = dialog?.phase else { return nil }
    return detail
  }

  var primaryButtonTitle: String {
    switch dialog?.phase {
    case .saving: "Saving…"
    case .saveFailed: "Try again"
    default: "Rename"
    }
  }

  /// The single line under the field: what's wrong with the draft, else why the last save failed.
  var errorText: String? { validationMessage ?? failureHeadline }

  // MARK: - View Helpers

  var isRenameEnabled: Bool {
    guard let dialog, activeMutation == nil else { return false }
    switch dialog.phase {
    case .editing, .saveFailed: return Self.validate(dialog.draft).name != nil
    case .saving, .gone, .rejected: return false
    }
  }

  var isSaving: Bool { dialog?.phase == .saving }

  var isMutationInFlight: Bool { activeMutation != nil }

  var isCloseOnly: Bool { dialog?.phase == .gone }

  var isFieldInvalid: Bool { validationMessage != nil }

  var isFieldDisabled: Bool { isSaving || isCloseOnly }

  var isHelperShown: Bool { !isCloseOnly }

  /// Saving keeps the primary button lit behind its spinner.
  var isPrimaryDimmed: Bool { !isRenameEnabled && !isSaving }

  var draft: String {
    get { dialog?.draft ?? "" }
    set { draftChanged(newValue) }
  }

  var isDialogPresented: Bool {
    get { dialog != nil }
    set { if !newValue { cancelTapped() } }
  }

  // MARK: - User Actions

  func renameTapped(sessionID: String, currentName: String) {
    guard activeMutation == nil else { return }
    dialog = Dialog(id: sessionID, draft: currentName, phase: .editing)
  }

  func draftChanged(_ draft: String) {
    guard var dialog, dialog.phase != .saving, dialog.phase != .gone else { return }
    dialog.draft = draft
    if case .rejected = dialog.phase { dialog.phase = .editing }
    self.dialog = dialog
  }

  func renameConfirmed() async {
    guard isRenameEnabled, let dialog, let name = Self.validate(dialog.draft).name else { return }
    let mutation = Mutation(sessionID: dialog.id, kind: .rename)
    activeMutation = mutation
    self.dialog?.phase = .saving
    let phase: Phase?
    do {
      try await workspaceName.rename(dialog.id, name)
      phase = nil
    } catch {
      phase = Self.failurePhase(error)
    }
    if self.dialog?.id == dialog.id {
      if let phase { self.dialog?.phase = phase } else { self.dialog = nil }
    }
    await onWriteFinished()
    if activeMutation == mutation { activeMutation = nil }
  }

  func cancelTapped() {
    guard !isSaving else { return }
    dialog = nil
  }

  func closeTapped() {
    guard !isSaving else { return }
    dialog = nil
  }

  func useAgentNameTapped(sessionID: String) async {
    guard activeMutation == nil else { return }
    let mutation = Mutation(sessionID: sessionID, kind: .clear)
    activeMutation = mutation
    do {
      try await workspaceName.rename(sessionID, nil)
    } catch {
      onClearFailed(Self.errorDetail(error))
    }
    await onWriteFinished()
    if activeMutation == mutation { activeMutation = nil }
  }

  func copyErrorTapped() {
    guard let failureDetail else { return }
    pasteboard.copy(failureDetail)
  }

  // MARK: - Private Helpers

  /// The daemon is the authority; this only drives the dialog's live states. `name` is the
  /// trimmed draft to send, nil when it can't be sent.
  private static func validate(_ draft: String) -> (name: String?, message: String?) {
    if draft.unicodeScalars.contains(where: isForbidden) {
      return (nil, "Names can't contain line breaks or special characters.")
    }
    let trimmed = draft.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
    if trimmed.isEmpty { return (nil, nil) }
    if trimmed.utf8.count > maximumNameBytes { return (nil, "That name is too long. Shorten it to save.") }
    return (trimmed, nil)
  }

  private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: true
    default: false
    }
  }

  private static func failurePhase(_ error: any Error) -> Phase {
    switch error as? QuestionError {
    case .rejected(code: "SESSION_NOT_FOUND", message: _):
      .gone
    case .rejected(code: "INVALID_NAME", let message):
      .rejected(message)
    case .rejected:
      .saveFailed(headline: "Slipstream refused the rename.", detail: errorDetail(error))
    case .unavailable:
      .saveFailed(headline: "Couldn't reach Slipstream, so the name wasn't saved.", detail: errorDetail(error))
    case .outcomeUnknown, nil:
      .saveFailed(
        headline: "Couldn't confirm the name was saved. Slipstream didn't reply.", detail: errorDetail(error))
    }
  }

  private static func errorDetail(_ error: any Error) -> String {
    switch error as? QuestionError {
    case .rejected(let code, let message): "\(code): \(message)"
    case .outcomeUnknown: "OUTCOME_UNKNOWN: the rename was sent but no valid reply came back"
    case .unavailable: "DAEMON_UNAVAILABLE: couldn't connect to Slipstream's control socket"
    case nil: String(describing: error)
    }
  }
}
