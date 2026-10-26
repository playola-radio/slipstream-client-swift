import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SlipstreamViewer

@MainActor
struct OpenInModelTests {
  struct OpenFailed: LocalizedError {
    var errorDescription: String? { "The app quit." }
  }

  let finder = OpenInApp(id: "com.apple.finder", name: "Finder", url: URL(filePath: "/System/Finder.app"))
  let xcode = OpenInApp(id: "com.apple.dt.Xcode", name: "Xcode", url: URL(filePath: "/Applications/Xcode.app"))
  let opened = LockIsolated<[String]>([])

  func makeModel(folder: String? = "/tmp/project", openError: (any Error)? = nil) -> OpenInModel {
    let apps = [finder, xcode]
    let opened = opened
    let model = withDependencies {
      $0.openIn.installedApps = { apps }
      $0.openIn.open = { folder, app in
        opened.withValue { $0.append("\(app.name) \(folder.path)") }
        if let openError { throw openError }
      }
    } operation: {
      OpenInModel()
    }
    model.folder = folder
    model.viewAppeared()
    return model
  }

  @Test func opensTheFolderInTheFirstInstalledAppByDefault() async {
    let model = makeModel()
    expectNoDifference(model.selectedApp, finder)
    await model.openTapped()
    expectNoDifference(opened.value, ["Finder /tmp/project"])
  }

  @Test func pickingAnAppOpensTheFolderThereAndMakesItTheDefault() async {
    let model = makeModel()
    await model.appSelected(xcode.id)
    await model.openTapped()
    expectNoDifference(opened.value, ["Xcode /tmp/project", "Xcode /tmp/project"])
    expectNoDifference(model.openHelpText, "Open in Xcode")
  }

  @Test func pickedAppIsRememberedAcrossLaunches() async {
    await makeModel().appSelected(xcode.id)
    expectNoDifference(makeModel().selectedApp, xcode)
  }

  @Test func rememberedAppThatIsNoLongerInstalledFallsBackToTheFirst() {
    @Shared(.openInAppID) var selectedAppID
    $selectedAppID.withLock { $0 = "com.example.gone" }
    expectNoDifference(makeModel().selectedApp, finder)
  }

  @Test func isDisabledWithoutAWorkspace() async {
    let model = makeModel(folder: nil)
    #expect(model.isOpenDisabled)
    await model.openTapped()
    expectNoDifference(opened.value, [])
  }

  @Test func failureFromAnEarlierWorkspaceIsNotShownAfterSwitching() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let model = withDependencies {
      $0.openIn.installedApps = { [finder] }
      $0.openIn.open = { _, _ in
        for await _ in gate { break }
        throw OpenFailed()
      }
    } operation: {
      OpenInModel()
    }
    model.folder = "/tmp/project"
    model.viewAppeared()
    let opening = Task { await model.openTapped() }
    await Task.megaYield()
    model.folder = "/tmp/other"
    release.yield()
    await opening.value
    #expect(!model.isFailurePresented)
  }

  @Test func failureToOpenIsShown() async {
    let model = makeModel(openError: OpenFailed())
    await model.openTapped()
    #expect(model.isFailurePresented)
    expectNoDifference(model.failureText, "Finder couldn't open /tmp/project: The app quit.")
  }
}
