import Dependencies
import Sparkle

/// Sparkle's updater, so models never import Sparkle or hold its non-Sendable controller.
struct UpdaterClient: Sendable {
  var start: @MainActor @Sendable () -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
  var installPendingUpdateAndRelaunch: @MainActor @Sendable () -> Bool
}

extension UpdaterClient: DependencyKey {
  static var liveValue: Self {
    Self(
      start: { LiveUpdater.shared.controller.startUpdater() },
      checkForUpdates: { LiveUpdater.shared.controller.updater.checkForUpdates() },
      installPendingUpdateAndRelaunch: { LiveUpdater.shared.delegate.installPendingUpdateAndRelaunch() }
    )
  }

  static var testValue: Self {
    Self(
      start: unimplemented("UpdaterClient.start"),
      checkForUpdates: unimplemented("UpdaterClient.checkForUpdates"),
      installPendingUpdateAndRelaunch: unimplemented("UpdaterClient.installPendingUpdateAndRelaunch", placeholder: false)
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
  let delegate = InstallOnQuitDelegate()
  lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
}

/// Holds Sparkle's install-on-quit block so quitting installs the update and relaunches, instead of
/// leaving the new version for the next launch.
@MainActor
private final class InstallOnQuitDelegate: NSObject, SPUUpdaterDelegate {
  private var installNow: (() -> Void)?

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    installNow = immediateInstallHandler
    return true
  }

  func installPendingUpdateAndRelaunch() -> Bool {
    guard let installNow else { return false }
    // Sparkle quits the app itself once installing, and that second quit must go through normally.
    self.installNow = nil
    installNow()
    return true
  }
}
