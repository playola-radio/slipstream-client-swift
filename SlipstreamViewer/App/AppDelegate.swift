import AppKit

/// Quitting, or closing the window, stops every agent and terminal and the recorder's start-up work first, and asks only
/// when an agent is mid-turn.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var chat: ChatPageModel?
  var instantAsk: InstantAskModel?
  var terminals: TerminalPageModel?
  var recorder: RecorderModel?
  var naming: WorkspaceNamingModel?
  var updater: UpdaterModel?
  var reopenWindow: () -> Void = {}

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if updater?.quitRequested() == .updateRelaunches { return .terminateCancel }
    guard let chat else { return .terminateNow }
    if let quitAlertText = chat.quitAlertText {
      let alert = NSAlert()
      alert.messageText = chat.quitAlertTitle
      alert.informativeText = quitAlertText
      alert.addButton(withTitle: chat.quitText)
      alert.addButton(withTitle: chat.cancelText)
      guard alert.runModal() == .alertFirstButtonReturn else {
        // Closing the window asks too, and by then it is already gone.
        reopenWindow()
        return .terminateCancel
      }
    }
    recorder?.quitConfirmed()
    let instantAsk = instantAsk
    let terminals = terminals
    let naming = naming
    Task {
      async let chatStopped: Void = chat.quitConfirmed()
      async let copiesStopped: Void? = instantAsk?.quitConfirmed()
      async let terminalsStopped: Void? = terminals?.quitConfirmed()
      async let namingStopped: Void? = naming?.quitConfirmed()
      _ = await (chatStopped, copiesStopped, terminalsStopped, namingStopped)
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
