import CustomDump
import SlipstreamCore
import Testing

struct DiagnosticTextTests {
  @Test func joinsLinesAndDropsControlCharacters() {
    expectNoDifference(DiagnosticText.line(" \u{1B}[31mfirst\u{7}\r\n\tsecond  line \n"), "[31mfirst second line")
  }

  @Test func capsLongTextKeepingTheStart() {
    let line = DiagnosticText.line(String(repeating: "a", count: 600))
    expectNoDifference(line, String(repeating: "a", count: 499) + "…")
  }
}
