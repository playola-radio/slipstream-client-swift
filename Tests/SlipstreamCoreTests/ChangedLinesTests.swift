import CustomDump
import SlipstreamCore
import Testing

struct ChangedLinesTests {
  @Test func splitTrailingNewlineDoesNotAddPhantomLine() {
    expectNoDifference(ChangedLines.split("a\nb\n"), ["a", "b"])
  }

  @Test func splitNoTrailingNewlineKeepsFinalLine() {
    expectNoDifference(ChangedLines.split("a\nb"), ["a", "b"])
  }

  @Test func splitKeepsCarriageReturnOnEachLine() {
    expectNoDifference(ChangedLines.split("a\r\nb\r\n"), ["a\r", "b\r"])
  }

  @Test func splitEmptyTextHasNoLines() {
    expectNoDifference(ChangedLines.split(""), [])
  }

  @Test func splitLoneNewlineIsOneEmptyLine() {
    expectNoDifference(ChangedLines.split("\n"), [""])
  }

  @Test func splitBlankLineBeforeTrailingNewline() {
    expectNoDifference(ChangedLines.split("a\n\n"), ["a", ""])
  }

  @Test func modifiedLineInsideSpanOnlyMarksThatLine() {
    let before = "func f() {\n  let a = 1\n  return a\n}\n"
    let after = "func f() {\n  let a = 2\n  return a\n}\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 4)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "func f() {", isChanged: false),
        ClipLine(number: 2, text: "  let a = 2", isChanged: true),
        ClipLine(number: 3, text: "  return a", isChanged: false),
        ClipLine(number: 4, text: "}", isChanged: false),
      ]
    )
  }

  @Test func insertedLineIsMarkedAndNeighborsAreNot() {
    let before = "a\nb\n"
    let after = "a\nx\nb\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 3)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "x", isChanged: true),
        ClipLine(number: 3, text: "b", isChanged: false),
      ]
    )
  }

  @Test func removeOnlyInMiddleMarksNextLine() {
    let before = "a\nb\nc\n"
    let after = "a\nc\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 2)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "c", isChanged: true),
      ]
    )
  }

  @Test func removeOnlyAtEndOfSpanMarksLineEnd() {
    let before = "a\nb\nc\n"
    let after = "a\nc\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 1)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: true)
      ]
    )
  }

  @Test func removeOnlyAtEndOfFileMarksLastLine() {
    let before = "a\nb\nc\n"
    let after = "a\nb\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 2)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "b", isChanged: true),
      ]
    )
  }

  @Test func crlfOnlyChangeMarksAllLinesAndStripsCarriageReturn() {
    let before = "a\nb\n"
    let after = "a\r\nb\r\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 2)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: true),
        ClipLine(number: 2, text: "b", isChanged: true),
      ]
    )
  }

  @Test func addingFinalNewlineMarksLastLine() {
    let before = "a\nb"
    let after = "a\nb\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 2)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "b", isChanged: true),
      ]
    )
  }

  @Test func noFinalNewlineWithModifiedMiddleLine() {
    let before = "a\nb\nc"
    let after = "a\nB\nc"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 3)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "B", isChanged: true),
        ClipLine(number: 3, text: "c", isChanged: false),
      ]
    )
  }

  @Test func newFileMarksAllShownLines() {
    let after = "x\ny\nz\n"
    let clip = ChangedLines.clipLines(before: nil, after: after, lineStart: 1, lineEnd: 3)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "x", isChanged: true),
        ClipLine(number: 2, text: "y", isChanged: true),
        ClipLine(number: 3, text: "z", isChanged: true),
      ]
    )
  }

  @Test func multipleClipsOfSameFileGetIndependentMarkers() {
    let before = "a\nb\nc\nd\ne\nf\n"
    let after = "a\nB\nc\nd\nE\nf\n"

    let firstClip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 3)
    expectNoDifference(
      firstClip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "B", isChanged: true),
        ClipLine(number: 3, text: "c", isChanged: false),
      ]
    )

    let secondClip = ChangedLines.clipLines(before: before, after: after, lineStart: 4, lineEnd: 6)
    expectNoDifference(
      secondClip,
      [
        ClipLine(number: 4, text: "d", isChanged: false),
        ClipLine(number: 5, text: "E", isChanged: true),
        ClipLine(number: 6, text: "f", isChanged: false),
      ]
    )
  }

  @Test func lineEndBeyondFileIsClamped() {
    let before = "a\nb\n"
    let after = "a\nB\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 10)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "B", isChanged: true),
      ]
    )
  }

  @Test func changesAboveTheSpanDoNotAppear() {
    let before = "a\nb\nc\nd\n"
    let after = "a\nB\nc\nD\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 3, lineEnd: 4)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 3, text: "c", isChanged: false),
        ClipLine(number: 4, text: "D", isChanged: true),
      ]
    )
  }

  @Test func hugeRewriteMarksEveryRewrittenLineWithoutDiffing() {
    let before = "head\n" + (0..<6000).map { "old \($0)\n" }.joined() + "tail\n"
    let after = "head\n" + (0..<6000).map { "new \($0)\n" }.joined() + "tail\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 6002)
    expectNoDifference(clip.filter { !$0.isChanged }.map(\.number), [1, 6002])
  }

  @Test func hugeFileWithEditsAtBothEndsMarksOnlyTheEditedLines() {
    let middle = (0..<6000).map { "same \($0)\n" }.joined()
    let before = "old head\n" + middle + "old tail\n"
    let after = "new head\n" + middle + "new tail\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 6002)
    expectNoDifference(clip.filter(\.isChanged).map(\.number), [1, 6002])
  }

  @Test func hugeReorderedBlockIsNotReportedAsUnchanged() {
    let lines = (0..<6000).map { "line \($0)\n" }
    let before = "head\n" + lines.joined() + "tail\n"
    let after = "head\n" + lines.reversed().joined() + "tail\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 6002)
    #expect(clip.filter(\.isChanged).count > 0)
  }

  @Test func lineMovedAShortDistanceInTheFallbackIsMarked() {
    let lines = (0..<3000).map { "line \($0)\n" }
    let before = "head\n" + lines.joined() + "tail\n"
    let after = "head\n" + lines.last! + lines.dropLast().joined() + "tail\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 3002)
    expectNoDifference(clip.filter(\.isChanged).map(\.number), [2])
  }

  @Test func hugeFileWithManyRepeatedLinesStaysFast() {
    let repeated = String(repeating: "same line\n", count: 200_000)
    let before = "old head\n" + repeated + "old tail\n"
    let after = "new head\n" + repeated + "new tail\n"
    let clock = ContinuousClock()
    let start = clock.now
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 200_002)
    #expect(clock.now - start < .seconds(3))
    expectNoDifference(clip.filter(\.isChanged).map(\.number), [1, 200_002])
  }

  @Test func combinedMiddleOverThresholdFallsBackEvenWhenEachSideIsUnderIt() {
    // Neither side alone exceeds ChangedLines.maximumDiffedLines (5000), but the
    // combined middle (3000 + 3000 = 6000) does — this must use the cheap fallback,
    // not the exact diff, or a 5000-vs-5000 all-different clip becomes very costly.
    let before = "head\n" + (0..<3000).map { "old \($0)\n" }.joined() + "tail\n"
    let after = "head\n" + (0..<3000).map { "new \($0)\n" }.joined() + "tail\n"
    let clip = ChangedLines.clipLines(before: before, after: after, lineStart: 1, lineEnd: 3002)
    expectNoDifference(clip.filter { !$0.isChanged }.map(\.number), [1, 3002])
  }
}
