import CustomDump
import SlipstreamCore
import SwiftUI
import Testing

@testable import SlipstreamViewer

struct SyntaxStylingTests {
  @Test func noRunsLeavesTextUnstyled() {
    expectNoDifference(DesignTokens.Syntax.styled("a b", runs: []), AttributedString("a b"))
  }

  @Test func runsColourTheirRanges() {
    let styled = DesignTokens.Syntax.styled(
      "let x",
      runs: [SyntaxRun(range: 0..<3, kind: .keyword), SyntaxRun(range: 4..<5, kind: .plain)]
    )

    expectNoDifference(
      colours(styled),
      [Coloured("let", hex(0xC3A6E6)), Coloured(" ", nil), Coloured("x", hex(0xC9D6E3))]
    )
  }

  @Test func tintLiftsOnlyTheTintedUnits() {
    let styled = DesignTokens.Syntax.styled(
      "// note",
      runs: [SyntaxRun(range: 0..<7, kind: .comment)],
      tintedRanges: [3..<7]
    )

    expectNoDifference(
      colours(styled),
      [Coloured("// ", hex(0x8399AB)), Coloured("note", hex(0xD5DCE2))]
    )
  }

  @Test func rangesAreUTF16() {
    let styled = DesignTokens.Syntax.styled(
      "\"👍\" x",
      runs: [SyntaxRun(range: 0..<4, kind: .string), SyntaxRun(range: 5..<6, kind: .plain)]
    )

    expectNoDifference(
      colours(styled),
      [Coloured("\"👍\"", hex(0xA9CF9B)), Coloured(" ", nil), Coloured("x", hex(0xC9D6E3))]
    )
  }

  private struct Coloured: Equatable {
    var text: String
    var colour: Color?

    init(_ text: String, _ colour: Color?) {
      self.text = text
      self.colour = colour
    }
  }

  private func colours(_ text: AttributedString) -> [Coloured] {
    text.runs[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self].map {
      Coloured(String(text[$1].characters), $0)
    }
  }

  private func hex(_ value: UInt32) -> Color {
    Color(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255,
      opacity: 1
    )
  }
}
