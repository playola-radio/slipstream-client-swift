import IssueReporting
import SwiftUI

@main
struct SlipstreamViewerApp: App {
  var body: some Scene {
    WindowGroup {
      if !isTesting {
        ChangeStreamPageView()
      }
    }
    .windowToolbarStyle(.unified)
  }
}
