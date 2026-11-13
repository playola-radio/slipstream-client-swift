import SwiftUI

struct BugReportCommands: Commands {
  let model: BugReportModel

  var body: some Commands {
    CommandGroup(after: .help) {
      Button("Copy Logs for Bug Report") { model.copyLogsTapped() }
    }
  }
}
