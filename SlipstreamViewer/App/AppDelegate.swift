import AppKit

/// Quitting, or closing the window, stops every agent first and asks only when one is mid-turn.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var chat: ChatPageModel?
  var instantAsk: InstantAskModel?
  var reopenWindow: () -> Void = {}

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
    let instantAsk = instantAsk
    Task {
      async let chatStopped: Void = chat.quitConfirmed()
      async let copiesStopped: Void? = instantAsk?.quitConfirmed()
      _ = await (chatStopped, copiesStopped)
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
