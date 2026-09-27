import CustomDump
import Testing

@testable import SlipstreamViewer

struct ChangedTextMarksTests {
  @Test func eachGlyphIsTintedWhenItsCharacterChanged() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 2, 3], text: "abcd", changedRanges: [1..<3], removalOffsets: []),
      ChangedTextMarks(tinted: [1, 2])
    )
  }

  @Test func changeInsideAClusterTintsTheWholeGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 3], text: "aلاb", changedRanges: [2..<3], removalOffsets: []),
      ChangedTextMarks(tinted: [1])
    )
  }

  @Test func removalInsideAClusterTicksBeforeTheGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 3], text: "aلاb", changedRanges: [], removalOffsets: [2]),
      ChangedTextMarks(ticks: [.before(1)])
    )
  }

  @Test func removalAtTheLineEndTicksAfterTheLastGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 2], text: "ab😀", changedRanges: [], removalOffsets: [4]),
      ChangedTextMarks(ticks: [.after(2)])
    )
  }

  @Test func truncatedLineMarksOnlyWhatItShows() {
    expectNoDifference(
      ChangedTextMarks(
        glyphOffsets: [0, 1, 2], text: String(repeating: "a", count: 10) + ";",
        changedRanges: [2..<3, 6..<7], removalOffsets: [8, 11]
      ),
      ChangedTextMarks(tinted: [2])
    )
  }
}
