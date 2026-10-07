import IssueReporting
import SwiftUI

@main
struct SlipstreamViewerApp: App {
  @State private var fontSize = FontSizeModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if !isTesting {
          if let fixtureArgument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--function-changes-fixture=")
          }) {
            ChangeStreamPageView(
              functionChangesDemo: FunctionChangesFixtureModel(
                root: ProcessInfo.processInfo.environment["SLIPSTREAM_INTERFACE_FIXTURE_ROOT"].map {
                  URL(fileURLWithPath: $0)
                },
                initialCase: String(fixtureArgument.dropFirst("--function-changes-fixture=".count))
              ))
          } else {
            ChangeStreamPageView()
          }
        }
      }
      .environment(\.fontScale, fontSize.scale)
      .background {
        Button("Make Text Bigger") { fontSize.biggerTapped() }
          .keyboardShortcut("=")
          .opacity(0)
          .accessibilityHidden(true)
      }
    }
    .windowToolbarStyle(.unified)
    .commands { FontSizeCommands(model: fontSize) }
  }
}
