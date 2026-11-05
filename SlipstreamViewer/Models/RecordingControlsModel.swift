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

  // MARK: - Initialization

  init(
    onChanged: @escaping @MainActor (_ preferring: String?) async -> Void,
    onRecorded: @escaping @MainActor (String) -> Void
  ) {
    self.onChanged = onChanged
    self.onRecorded = onRecorded
    super.init()
  }

  // MARK: - Properties

  @ObservationIgnored private let onChanged: @MainActor (_ preferring: String?) async -> Void
  @ObservationIgnored private let onRecorded: @MainActor (String) -> Void

  /// Keyed by normalized folder.
  private(set) var operations: [String: RecordingOperation] = [:]
  /// Keyed by normalized folder; cleared by the next tap on that folder.
  private(set) var messages: [String: RecordingMessage] = [:]
  private(set) var footerMessage: RecordingMessage?

  // MARK: - View Helpers

  func operation(for folder: String) -> RecordingOperation? {
    operations[ChangeStreamPageModel.normalizedFolder(folder)]
  }

  func message(for folder: String) -> RecordingMessage? {
    messages[ChangeStreamPageModel.normalizedFolder(folder)]
  }

  // MARK: - User Actions

  func pauseTapped(folder: String) async {
    guard let folder = begin(.pausing, folder: folder) else { return }
    defer { operations[folder] = nil }
    do {
      try await recording.pause(folder)
    } catch {
      messages[folder] = Self.pauseMessage(error)
      guard Self.refreshesAfterPause(error) else { return }
    }
    await onChanged(nil)
  }

  func recordTapped(folder: String) async {
    guard let folder = begin(.recording, folder: folder) else { return }
    defer { operations[folder] = nil }
    if let message = await record(folder, preferring: nil) {
      messages[folder] = message
    }
  }

  func recordFolderTapped() async {
    footerMessage = nil
    guard let url = await workspace.chooseFolder("Choose a folder to record", "Record"),
      let folder = begin(.recording, folder: url.path)
    else { return }
    defer { operations[folder] = nil }
    footerMessage = await record(folder, preferring: folder)
  }

  // MARK: - Private Helpers

  private func begin(_ operation: RecordingOperation, folder: String) -> String? {
    let folder = ChangeStreamPageModel.normalizedFolder(folder)
    footerMessage = nil
    guard operations[folder] == nil else { return nil }
    messages[folder] = nil
    operations[folder] = operation
    return folder
  }

  /// Records `folder` and refreshes when the outcome is or might be a change. Returns the message
  /// to show, if any.
  private func record(_ folder: String, preferring: String?) async -> RecordingMessage? {
    do {
      try await recording.record(folder)
    } catch {
      let message = Self.recordMessage(error, folder: folder)
      if error as? QuestionError == .outcomeUnknown {
        await onChanged(preferring)
      }
      return message
    }
    await onChanged(preferring)
    onRecorded(folder)
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
