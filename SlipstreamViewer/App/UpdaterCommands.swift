import SwiftUI

struct UpdaterCommands: Commands {
  let model: UpdaterModel

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") { model.checkForUpdatesTapped() }
    }
  }
}
