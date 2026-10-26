import AppKit
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
  let surface: TerminalSurface

  func makeNSView(context: Context) -> NSView {
    NSView()
  }

  func updateNSView(_ container: NSView, context: Context) {
    guard surface.view.superview !== container else { return }
    container.subviews.forEach { $0.removeFromSuperview() }
    surface.view.removeFromSuperview()
    surface.view.frame = container.bounds
    surface.view.autoresizingMask = [.width, .height]
    container.addSubview(surface.view)
  }
}
