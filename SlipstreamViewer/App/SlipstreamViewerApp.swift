import IssueReporting
import SwiftUI

@main
struct SlipstreamViewerApp: App {
  @State private var fontSize = FontSizeModel()
  @State private var chat: ChatPageModel
  @State private var instantAsk: InstantAskModel
  @State private var terminals: TerminalPageModel
  @State private var updater = UpdaterModel()
  @State private var recorder: RecorderModel
  /// Built once here: building it in the page view would rerun on every redraw and point the shared
  /// models' callbacks at a copy SwiftUI throws away.
  @State private var page: ChangeStreamPageModel?
  @State private var functionChangesDemo: FunctionChangesFixtureModel?
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    let chat = ChatPageModel()
    let instantAsk = InstantAskModel(chat: chat)
    let terminals = TerminalPageModel()
    let recorder = RecorderModel()
    _chat = State(initialValue: chat)
    _instantAsk = State(initialValue: instantAsk)
    _terminals = State(initialValue: terminals)
    _recorder = State(initialValue: recorder)
    guard !isTesting else { return }
    let functionChangesDemo = Self.functionChangesDemo()
    _functionChangesDemo = State(initialValue: functionChangesDemo)
    _page = State(initialValue: ChangeStreamPageModel(
      chat: chat, instantAsk: instantAsk, terminals: terminals, recorder: recorder,
      isFunctionDemoVisible: functionChangesDemo != nil))
  }

  var body: some Scene {
    Window("Slipstream", id: Self.windowID) {
      Group {
        if let page {
          ChangeStreamPageView(model: page, functionChangesDemo: functionChangesDemo)
        }
      }
      .environment(\.fontScale, fontSize.scale)
      .task {
        updater.appLaunched()
        await terminals.launched()
      }
      .task {
        guard !isTesting else { return }
        await recorder.appLaunched()
      }
      .modifier(QuitFlowHandoff(
        chat: chat, instantAsk: instantAsk, terminals: terminals, recorder: recorder, naming: page?.naming,
        updater: updater, appDelegate: appDelegate,
        windowID: Self.windowID))
      .background {
        Button("Make Text Bigger") { fontSize.biggerTapped() }
          .keyboardShortcut("=")
          .opacity(0)
          .accessibilityHidden(true)
      }
    }
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      UpdaterCommands(model: updater)
      ReloadCommands()
      PaneCommands()
      FontSizeCommands(model: fontSize)
    }
  }

  private static let windowID = "main"

  private static func functionChangesDemo() -> FunctionChangesFixtureModel? {
    guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--function-changes-fixture=") })
    else { return nil }
    return FunctionChangesFixtureModel(
      root: ProcessInfo.processInfo.environment["SLIPSTREAM_INTERFACE_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) },
      initialCase: String(argument.dropFirst("--function-changes-fixture=".count))
    )
  }
}

/// Gives the quit flow the chat, instant answers, terminals, recorder, naming and updater, and a way back to the window when closing it
/// is cancelled.
private struct QuitFlowHandoff: ViewModifier {
  let chat: ChatPageModel
  let instantAsk: InstantAskModel
  let terminals: TerminalPageModel
  let recorder: RecorderModel
  let naming: WorkspaceNamingModel?
  let updater: UpdaterModel
  let appDelegate: AppDelegate
  let windowID: String
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      appDelegate.chat = chat
      appDelegate.instantAsk = instantAsk
      appDelegate.terminals = terminals
      appDelegate.recorder = recorder
      appDelegate.naming = naming
      appDelegate.updater = updater
      appDelegate.reopenWindow = { openWindow(id: windowID) }
    }
  }
}
