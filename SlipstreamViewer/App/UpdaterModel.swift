import Dependencies
import SwiftUI

enum QuitOutcome: Equatable {
  case quit
  case updateRelaunches
}

@MainActor
@Observable
final class UpdaterModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.updater) var updater

  // MARK: - User Actions

  func appLaunched() { updater.start() }
  func checkForUpdatesTapped() { updater.checkForUpdates() }
  func quitRequested() -> QuitOutcome { updater.installPendingUpdateAndRelaunch() ? .updateRelaunches : .quit }
}
