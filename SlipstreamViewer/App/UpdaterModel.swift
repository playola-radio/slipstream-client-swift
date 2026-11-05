import Dependencies
import SwiftUI

@MainActor
@Observable
final class UpdaterModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.updater) var updater

  // MARK: - User Actions

  func appLaunched() { updater.start() }
  func checkForUpdatesTapped() { updater.checkForUpdates() }
}
