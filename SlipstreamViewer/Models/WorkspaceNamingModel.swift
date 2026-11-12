import Dependencies
import Foundation
import IdentifiedCollections
import SlipstreamCore

/// Owns every workspace-name write: the Rename dialog, "Use agent's name", and the first-message
/// suggestion. A rename shows at once and is sent after any earlier one for the same session, so
/// the last one wins. Every write refreshes the list (a lost reply may still have saved), and none
/// is resent.
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
    case saveFailed(headline: String, detail: String)
    case gone
    case rejected(String)
  }

  /// A name shown before the daemon lists it; `userName` nil means the agent's name.
  struct PendingName: Equatable {
    let userName: String?
  }

  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.workspaceName) var workspaceName
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard
  @ObservationIgnored @Dependency(\.workspaceNameSuggestion) var workspaceNameSuggestion
  @ObservationIgnored @Dependency(\.agentEnvironment) var agentEnvironment

  // MARK: - Properties

  static let maximumNameBytes = 64

  /// Refreshes the session list after every write.
  @ObservationIgnored var onWriteFinished: @MainActor () async -> Void = {}
  /// Shows a failed write the dialog can't show, with its raw error.
  @ObservationIgnored var onWriteFailed: @MainActor (_ title: String, _ detail: String) -> Void = { _, _ in }

  private(set) var dialog: Dialog?
  private(set) var pendingNames: [String: PendingName] = [:]
  @ObservationIgnored private var writes: [String: Task<(any Error)?, Never>] = [:]
  @ObservationIgnored private var attemptedSessionIDs: Set<String> = []
  @ObservationIgnored private var suggestions: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var isQuitting = false

  // MARK: - Display Text

  let titleText = "Rename workspace"
  let fieldAccessibilityLabel = "Workspace name"
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
    case .saveFailed: "Try again"
    default: "Rename"
    }
  }

  /// The single line under the field: what's wrong with the draft, else why the last save failed.
  var errorText: String? { validationMessage ?? failureHeadline }

  // MARK: - View Helpers

  var isRenameEnabled: Bool {
    guard let dialog else { return false }
    switch dialog.phase {
    case .editing, .saveFailed: return Self.validate(dialog.draft).name != nil
    case .gone, .rejected: return false
    }
  }

  var isCloseOnly: Bool { dialog?.phase == .gone }

  var isFieldInvalid: Bool { validationMessage != nil }

  var isFieldDisabled: Bool { isCloseOnly }

  var isHelperShown: Bool { !isCloseOnly }

  var isPrimaryDimmed: Bool { !isRenameEnabled }

  var draft: String {
    get { dialog?.draft ?? "" }
    set { draftChanged(newValue) }
  }

  var isDialogPresented: Bool {
    get { dialog != nil }
    set { if !newValue { cancelTapped() } }
  }

  /// The user's name for the session, counting one not yet listed.
  func userName(_ session: SessionOption) -> String? {
    guard let pending = pendingNames[session.id] else { return session.naming?.userName }
    return pending.userName
  }

  // MARK: - User Actions

  func renameTapped(sessionID: String, currentName: String) {
    dialog = Dialog(id: sessionID, draft: currentName, phase: .editing)
  }

  func draftChanged(_ draft: String) {
    guard var dialog, dialog.phase != .gone else { return }
    dialog.draft = draft
    switch dialog.phase {
    case .rejected, .saveFailed: dialog.phase = .editing
    case .editing, .gone: break
    }
    self.dialog = dialog
  }

  /// Closes the dialog and shows the name at once. If the daemon refuses it, the old name comes
  /// back and the dialog reopens with the draft and the error.
  func renameConfirmed() async {
    guard isRenameEnabled, let dialog, let name = Self.validate(dialog.draft).name else { return }
    self.dialog = nil
    if let error = await write(name, to: dialog.id) {
      if self.dialog == nil {
        self.dialog = Dialog(id: dialog.id, draft: dialog.draft, phase: Self.failurePhase(error))
      } else {
        onWriteFailed("Couldn't rename the workspace", Self.errorDetail(error))
      }
    }
    await onWriteFinished()
  }

  func cancelTapped() {
    dialog = nil
  }

  func closeTapped() {
    dialog = nil
  }

  func useAgentNameTapped(sessionID: String) async {
    if let error = await write(nil, to: sessionID) {
      onWriteFailed("Couldn't switch back to the agent's name", Self.errorDetail(error))
    }
    await onWriteFinished()
  }

  /// Stops showing each pending name the daemon now lists, once no write for it is on its way.
  func sessionsListed(_ sessions: IdentifiedArrayOf<SessionOption>) {
    for (id, pending) in pendingNames where writes[id] == nil {
      if let session = sessions[id: id], session.naming?.userName != pending.userName { continue }
      pendingNames[id] = nil
    }
  }

  /// Suggests a name for a session whose first message just went out, once per session for the
  /// life of the app. It never shows a failure or retries, and leaves the Rename dialog alone.
  func messageSent(sessionID: String, text: String) {
    guard !isQuitting, attemptedSessionIDs.insert(sessionID).inserted else { return }
    suggestions[sessionID] = Task { [weak self] in
      await self?.suggestName(sessionID: sessionID, text: text)
      self?.suggestions[sessionID] = nil
    }
  }

  /// Stops every suggestion and returns once they have all exited. None starts after this.
  func quitConfirmed() async {
    isQuitting = true
    let running = Array(suggestions.values)
    for task in running { task.cancel() }
    for task in running { await task.value }
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

  /// Shows the name at once and sends it after any earlier write for the session. Returns the
  /// error, and puts the listed name back, only if no later write has replaced this one.
  private func write(_ userName: String?, to sessionID: String) async -> (any Error)? {
    pendingNames[sessionID] = PendingName(userName: userName)
    let earlier = writes[sessionID]
    let task = Task { [workspaceName] () -> (any Error)? in
      _ = await earlier?.value
      do {
        try await workspaceName.rename(sessionID, userName)
        return nil
      } catch {
        return error
      }
    }
    writes[sessionID] = task
    let error = await task.value
    guard writes[sessionID] == task else { return nil }
    writes[sessionID] = nil
    if error != nil { pendingNames[sessionID] = nil }
    return error
  }

  private func suggestName(sessionID: String, text: String) async {
    guard let environment = try? await agentEnvironment.resolve(),
      let name = try? await workspaceNameSuggestion.suggest(text, environment),
      !Task.isCancelled
    else { return }
    _ = try? await workspaceName.setAgentName(sessionID, name)
    await onWriteFinished()
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
