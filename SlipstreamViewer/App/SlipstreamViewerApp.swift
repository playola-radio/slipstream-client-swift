import IssueReporting
import Foundation
import SwiftUI

@main
struct SlipstreamViewerApp: App {
  var body: some Scene {
    WindowGroup {
      if !isTesting {
        if let fixtureArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--function-changes-fixture=") }) {
          FunctionChangesFixtureView(model: FunctionChangesFixtureModel(
            root: ProcessInfo.processInfo.environment["SLIPSTREAM_INTERFACE_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) },
            initialCase: String(fixtureArgument.dropFirst("--function-changes-fixture=".count))
          ))
        } else {
          ChangeStreamPageView()
        }
      }
    }
    .windowToolbarStyle(.unified)
  }
}
