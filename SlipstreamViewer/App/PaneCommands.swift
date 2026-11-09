import SwiftUI

struct PaneCommands: Commands {
  @FocusedValue(ChangeStreamPageModel.self) private var model

  var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      Button(model?.sidebarToggleHelpText ?? "Hide Sidebar") {
        withAnimation(DesignTokens.Workspace.paneToggleAnimation) { model?.sidebarToggleTapped() }
      }
      .keyboardShortcut("b")
      .disabled(model == nil)
      Button(model?.rightPaneToggleHelpText ?? "Hide Right Panel") {
        withAnimation(DesignTokens.Workspace.paneToggleAnimation) { model?.rightPaneToggleTapped() }
      }
      .keyboardShortcut("b", modifiers: [.command, .option])
      .disabled(model == nil)
    }
  }
}
