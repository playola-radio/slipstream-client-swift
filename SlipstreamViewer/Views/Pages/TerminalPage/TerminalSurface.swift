import AppKit
import SwiftTerm

@MainActor
final class TerminalSurface {
  static let scrollback = 4_000

  static let replayReset: [UInt8] = Array(
    "\u{18}\u{1b}[?1049l\u{1b}[!p\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[0m\r\n"
      .utf8
  )

  let view: TerminalView
  var onInput: @MainActor ([UInt8]) -> Void = { _ in }
  var onResize: @MainActor (TerminalSize) -> Void = { _ in }
  var onFocusChange: @MainActor (Bool) -> Void = { _ in }

  var size: TerminalSize {
    TerminalSize(columns: view.terminal.cols, rows: view.terminal.rows)
  }

  init() {
    let font =
      DesignTokens.TerminalPane.font.nsFont(scale: 1)
      ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let view = FocusReportingTerminalView(
      frame: .zero,
      font: font,
      options: TerminalOptions(scrollback: Self.scrollback)
    )
    view.nativeBackgroundColor = NSColor(DesignTokens.TerminalPane.background)
    view.nativeForegroundColor = NSColor(DesignTokens.TerminalPane.foreground)
    self.view = view
    view.terminalDelegate = self
    view.onFocusChange = { [weak self] hasFocus in self?.onFocusChange(hasFocus) }
  }

  func feed(_ bytes: [UInt8]) {
    view.feed(byteArray: bytes[...])
  }

  func focus() {
    view.window?.makeFirstResponder(view)
  }
}

extension TerminalSurface: @MainActor TerminalViewDelegate {
  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    onInput(Array(data))
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    onResize(TerminalSize(columns: newCols, rows: newRows))
  }

  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private final class FocusReportingTerminalView: TerminalView {
  var onFocusChange: @MainActor (Bool) -> Void = { _ in }

  override var hasFocus: Bool {
    didSet { onFocusChange(hasFocus) }
  }
}
