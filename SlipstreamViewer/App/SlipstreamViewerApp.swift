import IssueReporting
import SwiftUI

@main
struct SlipstreamViewerApp: App {
  @State private var fontSize = FontSizeModel()
  @State private var chat = ChatPageModel()
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

  var body: some Scene {
    Window("Slipstream", id: Self.windowID) {
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
      .modifier(QuitFlowHandoff(chat: chat, appDelegate: appDelegate, windowID: Self.windowID))
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

  private static let windowID = "main"
}

/// Gives the quit flow the chat, and a way back to the window when closing it is cancelled.
private struct QuitFlowHandoff: ViewModifier {
  let chat: ChatPageModel
  let appDelegate: AppDelegate
  let windowID: String
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      appDelegate.chat = chat
      appDelegate.reopenWindow = { openWindow(id: windowID) }
    }
  }
}
