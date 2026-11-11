import CustomDump
import Dependencies
import DependenciesTestSupport
import Testing

@testable import SlipstreamViewer

@MainActor
struct UpdaterModelTests {
  @Test func launchingStartsTheUpdater() {
    let started = LockIsolated(false)
    let model = withDependencies {
      $0.updater.start = { started.setValue(true) }
    } operation: {
      UpdaterModel()
    }
    model.appLaunched()
    expectNoDifference(started.value, true)
  }

  @Test func checkForUpdatesAsksTheUpdater() {
    let checked = LockIsolated(false)
    let model = withDependencies {
      $0.updater.checkForUpdates = { checked.setValue(true) }
    } operation: {
      UpdaterModel()
    }
    model.checkForUpdatesTapped()
    expectNoDifference(checked.value, true)
  }

  @Test func quitWithPendingUpdateRelaunches() {
    let installed = LockIsolated(false)
    let model = withDependencies {
      $0.updater.installPendingUpdateAndRelaunch = {
        installed.setValue(true)
        return true
      }
    } operation: {
      UpdaterModel()
    }

    expectNoDifference(model.quitRequested(), .updateRelaunches)
    expectNoDifference(installed.value, true)
  }

  @Test func quitWithoutPendingUpdateQuits() {
    let model = withDependencies {
      $0.updater.installPendingUpdateAndRelaunch = { false }
    } operation: {
      UpdaterModel()
    }

    expectNoDifference(model.quitRequested(), .quit)
  }
}
