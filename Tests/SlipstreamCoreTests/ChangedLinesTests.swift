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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 4)
    expectNoDifference(
      clip,
      [
        ClipLine(number: 1, text: "func f() {", isChanged: false),
        ClipLine(
          number: 2, text: "  let a = 2", isChanged: true,
          changedText: ChangedText(inserted: [10..<11])
        ),
        ClipLine(number: 3, text: "  return a", isChanged: false),
        ClipLine(number: 4, text: "}", isChanged: false),
      ]
    )
  }

  @Test func insertedLineIsMarkedAndNeighborsAreNot() {
    let before = "a\nb\n"
    let after = "a\nx\nb\n"
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 3)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 2)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 1)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 2)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 2)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 2)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 3)
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
    let clip = clip(before: nil, after: after, lineStart: 1, lineEnd: 3)
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

    let firstClip = clip(before: before, after: after, lineStart: 1, lineEnd: 3)
    expectNoDifference(
      firstClip,
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "B", isChanged: true),
        ClipLine(number: 3, text: "c", isChanged: false),
      ]
    )

    let secondClip = clip(before: before, after: after, lineStart: 4, lineEnd: 6)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 10)
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
    let clip = clip(before: before, after: after, lineStart: 3, lineEnd: 4)
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
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 6002)
    expectNoDifference(clip.filter { !$0.isChanged }.map(\.number), [1, 6002])
  }

  @Test func hugeFileWithEditsAtBothEndsMarksOnlyTheEditedLines() {
    let middle = (0..<6000).map { "same \($0)\n" }.joined()
    let before = "old head\n" + middle + "old tail\n"
    let after = "new head\n" + middle + "new tail\n"
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 6002)
    expectNoDifference(clip.filter(\.isChanged).map(\.number), [1, 6002])
  }

  @Test func hugeReorderedBlockIsNotReportedAsUnchanged() {
    let lines = (0..<6000).map { "line \($0)\n" }
    let before = "head\n" + lines.joined() + "tail\n"
    let after = "head\n" + lines.reversed().joined() + "tail\n"
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 6002)
    #expect(clip.filter(\.isChanged).count > 0)
  }

  @Test func lineMovedAShortDistanceInTheFallbackIsMarked() {
    let lines = (0..<3000).map { "line \($0)\n" }
    let before = "head\n" + lines.joined() + "tail\n"
    let after = "head\n" + lines.last! + lines.dropLast().joined() + "tail\n"
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 3002)
    expectNoDifference(clip.filter(\.isChanged).map(\.number), [2])
  }

  @Test func hugeFileWithManyRepeatedLinesStaysFast() {
    let repeated = String(repeating: "same line\n", count: 200_000)
    let before = "old head\n" + repeated + "old tail\n"
    let after = "new head\n" + repeated + "new tail\n"
    let clock = ContinuousClock()
    let start = clock.now
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 200_002)
    #expect(clock.now - start < .seconds(3))
    expectNoDifference(clip.filter(\.isChanged).map(\.number), [1, 200_002])
  }

  @Test func combinedMiddleOverThresholdFallsBackEvenWhenEachSideIsUnderIt() {
    // Neither side alone exceeds ChangedLines.maximumDiffedLines (5000), but the
    // combined middle (3000 + 3000 = 6000) does — this must use the cheap fallback,
    // not the exact diff, or a 5000-vs-5000 all-different clip becomes very costly.
    let before = "head\n" + (0..<3000).map { "old \($0)\n" }.joined() + "tail\n"
    let after = "head\n" + (0..<3000).map { "new \($0)\n" }.joined() + "tail\n"
    let clip = clip(before: before, after: after, lineStart: 1, lineEnd: 3002)
    expectNoDifference(clip.filter { !$0.isChanged }.map(\.number), [1, 3002])
  }

  @Test func insertionHighlightsOnlyTheNewCharacters() {
    expectNoDifference(
      clip(before: "foo(a)\n", after: "foo(a, b)\n", lineStart: 1, lineEnd: 1),
      [ClipLine(number: 1, text: "foo(a, b)", isChanged: true, changedText: ChangedText(inserted: [5..<8]))]
    )
  }

  @Test func deletionOnlyEditMarksWhereTextWasRemoved() {
    expectNoDifference(
      clip(before: "foo(a, b)\n", after: "foo(a)\n", lineStart: 1, lineEnd: 1),
      [ClipLine(number: 1, text: "foo(a)", isChanged: true, changedText: ChangedText(removedAt: [5]))]
    )
  }

  @Test func separateEditsInOneLineGetSeparateRanges() {
    expectNoDifference(
      clip(before: "let total = price * 2\n", after: "var total = cost * 2\n", lineStart: 1, lineEnd: 1).first?.changedText,
      ChangedText(inserted: [0..<3, 12..<16])
    )
  }

  @Test func deletionAtEndOfLineMarksTheLineEnd() {
    expectNoDifference(
      clip(before: "return a;\n", after: "return a\n", lineStart: 1, lineEnd: 1).first?.changedText,
      ChangedText(removedAt: [8])
    )
  }

  @Test func pairsFollowTheLineAlignmentNotTheLineNumber() {
    expectNoDifference(
      clip(before: "a\nfoo(1)\n", after: "new\na\nfoo(2)\n", lineStart: 1, lineEnd: 3),
      [
        ClipLine(number: 1, text: "new", isChanged: true),
        ClipLine(number: 2, text: "a", isChanged: false),
        ClipLine(number: 3, text: "foo(2)", isChanged: true, changedText: ChangedText(inserted: [4..<5])),
      ]
    )
  }

  @Test func unevenReplacementKeepsLineMarkersOnly() {
    expectNoDifference(
      clip(before: "a\nx = 1\nz\n", after: "a\nx = 2\ny = 3\nz\n", lineStart: 1, lineEnd: 4),
      [
        ClipLine(number: 1, text: "a", isChanged: false),
        ClipLine(number: 2, text: "x = 2", isChanged: true),
        ClipLine(number: 3, text: "y = 3", isChanged: true),
        ClipLine(number: 4, text: "z", isChanged: false),
      ]
    )
  }

  @Test func repeatedLinesAroundAnEditKeepLineMarkersOnly() {
    expectNoDifference(
      clip(before: "}\nfoo(1)\n}\n", after: "}\nfoo(2)\n}\nfoo(3)\n}\n", lineStart: 1, lineEnd: 5),
      [
        ClipLine(number: 1, text: "}", isChanged: false),
        ClipLine(number: 2, text: "foo(2)", isChanged: true),
        ClipLine(number: 3, text: "}", isChanged: true),
        ClipLine(number: 4, text: "foo(3)", isChanged: true),
        ClipLine(number: 5, text: "}", isChanged: false),
      ]
    )
  }

  @Test func mostlyRewrittenLineKeepsItsMarkerOnly() {
    expectNoDifference(
      clip(before: "let x = 1\n", after: "return y\n", lineStart: 1, lineEnd: 1),
      [ClipLine(number: 1, text: "return y", isChanged: true)]
    )
  }

  @Test func emptyLineReplacedByTextKeepsItsMarkerOnly() {
    expectNoDifference(
      clip(before: "a\n\nb\n", after: "a\nx\nb\n", lineStart: 2, lineEnd: 2),
      [ClipLine(number: 2, text: "x", isChanged: true)]
    )
  }

  @Test func emojiAndCombiningMarksAreWholeCharacters() {
    expectNoDifference(
      clip(before: "say(\"👍\", cafe)\n", after: "say(\"👩‍👩‍👧\", café)\n", lineStart: 1, lineEnd: 1).first?.changedText,
      ChangedText(inserted: [5..<6, 12..<13])
    )
  }

  @Test func tabsCountAsOneCharacter() {
    expectNoDifference(
      clip(before: "\tx = 1\n", after: "\tx = 2\n", lineStart: 1, lineEnd: 1).first?.changedText,
      ChangedText(inserted: [5..<6])
    )
  }

  @Test func lineEndingOnlyChangesKeepLineMarkersOnly() {
    let crlf = clip(before: "a = 1\n", after: "a = 1\r\n", lineStart: 1, lineEnd: 1)
    let finalNewline = clip(before: "a = 1", after: "a = 1\n", lineStart: 1, lineEnd: 1)
    expectNoDifference(crlf, [ClipLine(number: 1, text: "a = 1", isChanged: true)])
    expectNoDifference(finalNewline, [ClipLine(number: 1, text: "a = 1", isChanged: true)])
  }

  @Test func crlfLineWithAnEditHighlightsOnlyTheEdit() {
    expectNoDifference(
      clip(before: "x = 1\r\n", after: "x = 2\r\n", lineStart: 1, lineEnd: 1).first?.changedText,
      ChangedText(inserted: [4..<5])
    )
  }

  @Test func newFileAndRemovedLinesKeepLineMarkersOnly() {
    let newFile = clip(before: nil, after: "x = 1\n", lineStart: 1, lineEnd: 1)
    let removedLine = clip(before: "a\nb = 1\nc\n", after: "a\nc\n", lineStart: 1, lineEnd: 2)
    expectNoDifference(newFile, [ClipLine(number: 1, text: "x = 1", isChanged: true)])
    expectNoDifference(
      removedLine,
      [ClipLine(number: 1, text: "a", isChanged: false), ClipLine(number: 2, text: "c", isChanged: true)]
    )
  }

  @Test func longLineKeepsItsMarkerOnly() {
    let long = String(repeating: "a", count: ChangedLines.maximumHighlightedLineBytes)
    expectNoDifference(
      clip(before: long + "\n", after: long + "b\n", lineStart: 1, lineEnd: 1),
      [ClipLine(number: 1, text: long + "b", isChanged: true)]
    )
  }

  @Test func largeEditInsideALineKeepsItsMarkerOnly() {
    let before = "f(" + String(repeating: "a", count: 200) + ", " + String(repeating: "b", count: 200) + ")\n"
    let after = "f(" + String(repeating: "a", count: 200) + ", " + String(repeating: "c", count: 200) + ")\n"
    #expect(clip(before: before, after: after, lineStart: 1, lineEnd: 1).first?.changedText == nil)
  }

  @Test func scatteredEditsInALineKeepItsMarkerOnly() {
    let before = String(repeating: "ab", count: 40) + "\n"
    let after = String(repeating: "aB", count: 40) + "\n"
    let line = clip(before: before, after: after, lineStart: 1, lineEnd: 1).first
    #expect(line?.isChanged == true)
    #expect(line?.changedText == nil)
  }

  @Test func pairBudgetIsSharedByEveryBlockOfTheCard() {
    let count = ChangedLines.maximumHighlightedPairs + 6
    let before = (0..<count).map { "same\nvalue(\($0), 1)\n" }.joined()
    let after = (0..<count).map { "same\nvalue(\($0), 2)\n" }.joined()
    let half = count
    let spans = [
      ClipSpan(lineStart: 1, lineEnd: half, truncated: false),
      ClipSpan(lineStart: half + 1, lineEnd: count * 2, truncated: false),
    ]
    let comparison = ChangedLines.compare(before: before, after: after, spans: spans)
    let first = comparison.clipLines(lineStart: 1, lineEnd: half)
    let second = comparison.clipLines(lineStart: half + 1, lineEnd: count * 2)
    let highlighted = (first + second).filter { $0.changedText != nil }.map(\.number)
    let changed = (first + second).filter(\.isChanged).map(\.number)
    expectNoDifference(highlighted, Array(stride(from: 2, through: ChangedLines.maximumHighlightedPairs * 2, by: 2)))
    expectNoDifference(changed, Array(stride(from: 2, through: count * 2, by: 2)))
  }

  @Test func linesOutsideTheShownSpansDoNotSpendTheBudget() {
    let count = ChangedLines.maximumHighlightedPairs + 6
    let before = (0..<count).map { "same\nvalue(\($0), 1)\n" }.joined()
    let after = (0..<count).map { "same\nvalue(\($0), 2)\n" }.joined()
    let last = count * 2
    let comparison = ChangedLines.compare(
      before: before, after: after, spans: [ClipSpan(lineStart: last - 1, lineEnd: last, truncated: false)]
    )
    expectNoDifference(
      comparison.clipLines(lineStart: last, lineEnd: last).first?.changedText,
      ChangedText(inserted: [10..<11])
    )
  }

  @Test func largeFileFallbackNeverHighlightsCharacters() {
    let middle = (0..<6000).map { "same \($0)\n" }.joined()
    let before = "value = 1\n" + middle + "old tail\n"
    let after = "value = 2\n" + middle + "new tail\n"
    let lines = clip(before: before, after: after, lineStart: 1, lineEnd: 6002)
    expectNoDifference(lines.filter(\.isChanged).map(\.number), [1, 6002])
    expectNoDifference(lines.compactMap(\.changedText), [])
  }

  private func clip(before: String?, after: String, lineStart: Int, lineEnd: Int) -> [ClipLine] {
    ChangedLines.compare(
      before: before, after: after, spans: [ClipSpan(lineStart: lineStart, lineEnd: lineEnd, truncated: false)]
    )
    .clipLines(lineStart: lineStart, lineEnd: lineEnd)
  }
}
