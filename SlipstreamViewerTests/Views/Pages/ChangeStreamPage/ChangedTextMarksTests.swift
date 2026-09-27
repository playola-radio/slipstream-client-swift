import CustomDump
import Testing

@testable import SlipstreamViewer

struct ChangedTextMarksTests {
  @Test func eachGlyphIsTintedWhenItsCharacterChanged() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 2, 3], length: 4, isTruncated: false, changedRanges: [1..<3], removalOffsets: []),
      ChangedTextMarks(tinted: [1, 2])
    )
  }

  @Test func changeInsideAClusterTintsTheWholeGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 3], length: 4, isTruncated: false, changedRanges: [2..<3], removalOffsets: []),
      ChangedTextMarks(tinted: [1])
    )
  }

  @Test func changeInsideAClusterAtTheLineEndTintsTheWholeGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1], length: 3, isTruncated: false, changedRanges: [2..<3], removalOffsets: []),
      ChangedTextMarks(tinted: [1])
    )
  }

  @Test func removalInsideAClusterTicksBeforeTheGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1, 3], length: 4, isTruncated: false, changedRanges: [], removalOffsets: [2]),
      ChangedTextMarks(ticks: [.before(1)])
    )
  }

  @Test func removalAtTheLineEndTicksAfterTheLastGlyph() {
    expectNoDifference(
      ChangedTextMarks(glyphOffsets: [0, 1], length: 3, isTruncated: false, changedRanges: [], removalOffsets: [3]),
      ChangedTextMarks(ticks: [.after(1)])
    )
  }

  @Test func truncatedLineMarksOnlyWhatItShows() {
    expectNoDifference(
      ChangedTextMarks(
        glyphOffsets: [0, 1, 2], length: 11, isTruncated: true,
        changedRanges: [2..<3, 6..<7], removalOffsets: [8, 11]
      ),
      ChangedTextMarks(tinted: [2])
    )
  }
}
