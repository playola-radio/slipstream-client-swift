import Foundation
import SwiftTerm
import Testing

@testable import SlipstreamViewer

final class IgnoringTerminalDelegate: TerminalDelegate {
  func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor
struct TerminalSurfaceTests {
  let delegate = IgnoringTerminalDelegate()
  let terminal: Terminal

  init() {
    terminal = Terminal(
      delegate: delegate,
      options: TerminalOptions(scrollback: TerminalSurface.scrollback)
    )
  }

  func feed(_ text: String) {
    terminal.feed(byteArray: Array(text.utf8))
  }

  func feedReplayReset() {
    terminal.feed(byteArray: TerminalSurface.replayReset)
  }

  func normalBufferLines() -> [String] {
    String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  @Test func replayResetLeavesAlternateScreen() {
    feed("keep\r\n\u{1b}[?1049hvim")
    #expect(terminal.isCurrentBufferAlternate)

    feedReplayReset()

    #expect(!terminal.isCurrentBufferAlternate)
    #expect(normalBufferLines().contains("keep"))
  }

  @Test func replayResetTurnsOffMouseAndPaste() {
    feed("\u{1b}[?1003h\u{1b}[?2004h")
    #expect(terminal.mouseMode != .off)
    #expect(terminal.bracketedPasteMode)

    feedReplayReset()

    #expect(terminal.mouseMode == .off)
    #expect(!terminal.bracketedPasteMode)
  }

  @Test func replayResetAbortsHalfSequence() {
    feed("\u{1b}[3")
    feedReplayReset()
    feed("x")

    #expect(normalBufferLines().contains { $0.hasSuffix("x") })
  }

  @Test func scrollbackHoldsTheHistoryCap() throws {
    for line in 1...4_100 {
      feed("line \(line)\r\n")
    }

    let first = try #require(normalBufferLines().first)
    let number = try #require(Int(first.dropFirst("line ".count)))
    #expect(first.hasPrefix("line "))
    #expect(number <= 101)
  }
}
