import AppKit
import SwiftUI

struct SourceDragAdapter: NSViewRepresentable {
  var dragged: (CGFloat, CGFloat) -> Void
  var ended: () -> Void

  func makeNSView(context: Context) -> SourceDragView { SourceDragView() }

  func updateNSView(_ view: SourceDragView, context: Context) {
    view.dragged = dragged
    view.ended = ended
  }
}

final class SourceDragView: NSView {
  var dragged: ((CGFloat, CGFloat) -> Void)?
  var ended: (() -> Void)?
  private var startY: CGFloat?

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y
    startY = y
    dragged?(y, y)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let startY else { return }
    dragged?(startY, convert(event.locationInWindow, from: nil).y)
  }

  override func mouseUp(with event: NSEvent) {
    guard let startY else { return }
    dragged?(startY, convert(event.locationInWindow, from: nil).y)
    self.startY = nil
    ended?()
  }
}
