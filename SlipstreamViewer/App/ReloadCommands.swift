import SwiftUI

struct ReloadCommands: Commands {
  @FocusedValue(ChangeStreamPageModel.self) private var model

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Reload Workspaces") { Task { await model?.reloadShortcutPressed() } }
        .keyboardShortcut("r")
        .disabled(model == nil)
    }
  }
}
