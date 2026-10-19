import IssueReporting
import SwiftUI

@main
struct SlipstreamViewerApp: App {
  @State private var fontSize = FontSizeModel()
  @State private var chat = ChatPageModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if !isTesting {
          if let fixtureArgument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--function-changes-fixture=")
          }) {
            ChangeStreamPageView(
              chat: chat,
              functionChangesDemo: FunctionChangesFixtureModel(
                root: ProcessInfo.processInfo.environment["SLIPSTREAM_INTERFACE_FIXTURE_ROOT"].map {
                  URL(fileURLWithPath: $0)
                },
                initialCase: String(fixtureArgument.dropFirst("--function-changes-fixture=".count))
              ))
          } else {
            ChangeStreamPageView(chat: chat)
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
