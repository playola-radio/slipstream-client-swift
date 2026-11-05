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

}
