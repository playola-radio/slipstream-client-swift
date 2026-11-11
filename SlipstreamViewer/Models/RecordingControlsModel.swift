import Dependencies
import Foundation
import SlipstreamCore

enum RecordingOperation: Equatable {
  case pausing, recording
}

struct RecordingMessage: Equatable {
  var text: String
  /// Shown in amber: every recording slot is held.
  var isFull: Bool
}

/// Record and Pause for every folder, shared by the sidebar and Ask so both show one operation and
/// one message per folder. Rows follow the refresh after each reply, never the reply itself.
@MainActor
@Observable
final class RecordingControlsModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.recording) var recording
  @ObservationIgnored @Dependency(\.workspace) var workspace

  // MARK: - Properties

  /// Refreshes captures, selecting the given folder if one is passed.
  @ObservationIgnored var onChanged: @MainActor (_ preferring: String?) async -> Void = { _ in }
  /// Lets chat link the recorded folder once.
  @ObservationIgnored var onRecorded: @MainActor (_ folder: String) -> Void = { _ in }
  /// Keeps chat reconnection pending until a capture read confirms an uncertain Record reply.
  @ObservationIgnored var onRecordOutcomeUnknown: @MainActor (_ folder: String) -> Void = { _ in }

  /// Keyed by normalized folder.
  private(set) var operations: [String: RecordingOperation] = [:]
  /// Keyed by normalized folder; cleared by the next tap on that folder.
  private(set) var messages: [String: RecordingMessage] = [:]
  private(set) var footerMessage: RecordingMessage?
  /// Bumped by every tap, so only the latest footer Record publishes its outcome.
  @ObservationIgnored private var footerGeneration = 0

  // MARK: - View Helpers

  func operation(for folder: String) -> RecordingOperation? {
    operations[Self.key(folder)]
  }

  func message(for folder: String) -> RecordingMessage? {
    messages[Self.key(folder)]
  }

  // MARK: - User Actions

  /// Returns whether the folder is confirmed not recording: paused, or with no recording to pause.
  @discardableResult
  func pauseTapped(folder: String) async -> Bool {
    guard let key = begin(.pausing, folder: folder) else { return false }
    defer { operations[key] = nil }
    do {
      try await recording.pause(folder)
    } catch {
      messages[key] = Self.pauseMessage(error)
      if Self.refreshesAfterPause(error) { await onChanged(nil) }
      if case .rejected(code: "TARGET_NOT_FOUND", _) = error as? QuestionError { return true }
      return false
    }
    await onChanged(nil)
    return true
  }

  func recordTapped(folder: String) async {
    guard let key = begin(.recording, folder: folder) else { return }
    defer { operations[key] = nil }
    if let message = await record(folder, key: key) {
      messages[key] = message
    }
  }

  /// `keepsSelection` is asked once the reply lands: the refresh selects the folder only if it says so
  /// and no newer tap has started since.
  func recordFolderTapped(keepsSelection: @MainActor () -> Bool = { true }) async {
    footerMessage = nil
    guard let url = await workspace.chooseFolder("Choose a folder to record", "Record"),
      let key = begin(.recording, folder: url.path)
    else { return }
    defer { operations[key] = nil }
    let generation = footerGeneration
    let message = await record(url.path, key: key) {
      generation == footerGeneration && keepsSelection() ? key : nil
    }
    if generation == footerGeneration { footerMessage = message }
  }

  // MARK: - Private Helpers

  private static func key(_ folder: String) -> String {
    ChangeStreamPageModel.normalizedFolder(folder)
  }

  /// Returns the folder's key, or `nil` while another operation runs for it.
  private func begin(_ operation: RecordingOperation, folder: String) -> String? {
    let key = Self.key(folder)
    footerMessage = nil
    footerGeneration += 1
    guard operations[key] == nil else { return nil }
    messages[key] = nil
    operations[key] = operation
    return key
  }

  /// Refreshes when the outcome is or might be a change. Returns the message to show, if any.
  private func record(
    _ folder: String, key: String, preferring: @MainActor () -> String? = { nil }
  ) async -> RecordingMessage? {
    do {
      try await recording.record(folder)
    } catch {
      if error as? QuestionError == .outcomeUnknown {
        onRecordOutcomeUnknown(key)
        await onChanged(preferring())
      }
      return Self.recordMessage(error, folder: key)
    }
    await onChanged(preferring())
    onRecorded(key)
    return nil
  }

  private static func recordMessage(_ error: any Error, folder: String) -> RecordingMessage {
    switch error as? QuestionError {
    case .rejected(code: "CAPTURE_LIMIT_REACHED", _):
      RecordingMessage(text: "All recording slots are in use. Pause a workspace first.", isFull: true)
    case .rejected(code: "ROOT_OVERLAP", _):
      RecordingMessage(
        text: "Couldn't record \(URL(fileURLWithPath: folder).lastPathComponent): it overlaps a folder that's already recording.",
        isFull: false)
    case let .rejected(_, message):
      RecordingMessage(text: "Couldn't record: \(message)", isFull: false)
    case .outcomeUnknown:
      RecordingMessage(text: "Recording not confirmed. Checking…", isFull: false)
    case .unavailable, nil:
      RecordingMessage(text: "Couldn't record: couldn't reach Slipstream.", isFull: false)
    }
  }

  private static func pauseMessage(_ error: any Error) -> RecordingMessage {
    switch error as? QuestionError {
    case .rejected(code: "TARGET_NOT_FOUND", _):
      RecordingMessage(text: "This workspace's recording no longer exists. Refreshing…", isFull: false)
    case let .rejected(_, message):
      RecordingMessage(text: "Couldn't pause: \(message)", isFull: false)
    case .outcomeUnknown:
      RecordingMessage(text: "Couldn't pause: Slipstream didn't confirm it. Checking again…", isFull: false)
    case .unavailable, nil:
      RecordingMessage(text: "Couldn't pause: couldn't reach Slipstream.", isFull: false)
    }
  }

  private static func refreshesAfterPause(_ error: any Error) -> Bool {
    switch error as? QuestionError {
    case .outcomeUnknown, .rejected(code: "TARGET_NOT_FOUND", _): true
    default: false
    }
  }
}
