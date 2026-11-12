import CustomDump
import Testing

@testable import SlipstreamViewer

struct TokenTextViewTests {
  @Test func caretBeforeAnInsertStays() {
    expectNoDifference(TokenNSTextView.caretOffset(1, from: "hello", to: "hello world"), 1)
  }

  @Test func caretAfterAnInsertMovesWithIt() {
    expectNoDifference(TokenNSTextView.caretOffset(5, from: "hello", to: "big hello"), 9)
  }

  @Test func caretAfterAReplacementGoesToTheEnd() {
    expectNoDifference(TokenNSTextView.caretOffset(5, from: "hello", to: ""), 0)
  }
}
