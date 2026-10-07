import SwiftUI

struct FontSizeCommands: Commands {
  let model: FontSizeModel

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Divider()
      Button("Actual Size") { model.actualSizeTapped() }
        .keyboardShortcut("0")
        .disabled(model.isActualSize)
      Button("Make Text Bigger") { model.biggerTapped() }
        .keyboardShortcut("+")
        .disabled(!model.canMakeBigger)
      Button("Make Text Smaller") { model.smallerTapped() }
        .keyboardShortcut("-")
        .disabled(!model.canMakeSmaller)
    }
  }
}
