import Dependencies
import Sparkle

/// Sparkle's updater, so models never import Sparkle or hold its non-Sendable controller.
struct UpdaterClient: Sendable {
  var start: @MainActor @Sendable () -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
}

extension UpdaterClient: DependencyKey {
  static var liveValue: Self {
    Self(
      start: { LiveUpdater.shared.controller.startUpdater() },
      checkForUpdates: { LiveUpdater.shared.controller.updater.checkForUpdates() }
    )
  }

  static var testValue: Self {
    Self(
      start: unimplemented("UpdaterClient.start"),
      checkForUpdates: unimplemented("UpdaterClient.checkForUpdates")
    )
  }
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}

/// The app's one Sparkle controller, started (idempotently) when the window launches.
@MainActor
private final class LiveUpdater {
  static let shared = LiveUpdater()
  let controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
}
