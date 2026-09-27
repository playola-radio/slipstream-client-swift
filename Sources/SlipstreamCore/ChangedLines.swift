public struct ClipLine: Equatable, Sendable {
  public var number: Int
  public var text: String
  public var isChanged: Bool
  public var changedText: ChangedText?

  public init(number: Int, text: String, isChanged: Bool, changedText: ChangedText? = nil) {
    self.number = number
    self.text = text
    self.isChanged = isChanged
    self.changedText = changedText
  }
}

/// Where a changed line differs from the line it replaced, in Character offsets into the
/// line without its trailing carriage return.
public struct ChangedText: Equatable, Sendable {
  public var inserted: [Range<Int>]
  public var removedAt: [Int]

  public init(inserted: [Range<Int>] = [], removedAt: [Int] = []) {
    self.inserted = inserted
    self.removedAt = removedAt
  }
}

public enum ChangedLines {
  public struct Comparison: Sendable {
    let afterLines: [Substring]
    let marks: Set<Int>
    let anchors: Set<Int>
    let changedText: [Int: ChangedText]

    public func clipLines(lineStart: Int, lineEnd: Int) -> [ClipLine] {
      let clampedStart = max(1, lineStart)
      let clampedEnd = min(lineEnd, afterLines.count)
      guard clampedStart <= clampedEnd else { return [] }
      return (clampedStart...clampedEnd).map { number in
        let isChanged =
          marks.contains(number) || anchors.contains(number)
          || (number == clampedEnd && anchors.contains(clampedEnd + 1))
        return ClipLine(
          number: number,
          text: displayText(afterLines[number - 1]),
          isChanged: isChanged,
          changedText: changedText[number]
        )
      }
    }
  }

  public static func split(_ text: String) -> [Substring] {
    guard !text.isEmpty else { return [] }
    var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
      .map { text[$0.startIndex..<$0.endIndex] }
    if endsWithNewlineScalar(text) {
      lines.removeLast()
    }
    return lines
  }

  /// Compares the whole file once. Character-level changes are worked out only for
  /// replaced lines inside `spans`, within one budget shared by every span.
  public static func compare(before: String?, after: String, spans: [ClipSpan]) -> Comparison {
    let afterLines = split(after)
    guard let before else {
      return Comparison(
        afterLines: afterLines, marks: Set(afterLines.indices.map { $0 + 1 }), anchors: [], changedText: [:]
      )
    }
    let beforeLines = split(before)
    let alignment = align(before: before, after: after)
    var changedText: [Int: ChangedText] = [:]
    var pairsLeft = maximumHighlightedPairs
    for pair in alignment.pairs where pairsLeft > 0 {
      guard spans.contains(where: { $0.lineStart <= pair.after && pair.after <= $0.lineEnd }) else { continue }
      pairsLeft -= 1
      changedText[pair.after] = self.changedText(
        before: beforeLines[pair.before], after: afterLines[pair.after - 1]
      )
    }
    return Comparison(
      afterLines: afterLines, marks: alignment.marks, anchors: alignment.anchors, changedText: changedText
    )
  }

  private static func displayText(_ line: Substring) -> String {
    String(withoutCarriageReturn(line))
  }

  private static func endsWithNewlineScalar(_ text: String) -> Bool {
    text.unicodeScalars.last == "\n"
  }

  private static func diffUnits(for text: String) -> [String] {
    let lines = split(text)
    let endsWithNewline = endsWithNewlineScalar(text)
    return lines.enumerated().map { index, line in
      let hasTerminator = index < lines.count - 1 || endsWithNewline
      return hasTerminator ? line + "\n" : String(line)
    }
  }

  static let maximumDiffedLines = 5000
  /// Replaced lines are paired only when a run of removed lines is replaced by the same
  /// number of lines, up to this many.
  static let maximumPairedRunLines = 8
  public static let maximumHighlightedPairs = 64
  public static let maximumHighlightedLineBytes = 2048
  static let maximumComparedCharacters = 128
  /// Unchanged gaps this short between two edits are highlighted with them.
  static let maximumAbsorbedGap = 2

  private static func longestIncreasingRun(_ values: [Int]) -> Set<Int> {
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: values.count)
    for (index, value) in values.enumerated() {
      var low = 0
      var high = tails.count
      while low < high {
        let mid = (low + high) / 2
        if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
      }
      if low > 0 { previous[index] = tails[low - 1] }
      if low == tails.count { tails.append(index) } else { tails[low] = index }
    }
    var run = Set<Int>()
    var index = tails.last ?? -1
    while index >= 0 {
      run.insert(index)
      index = previous[index]
    }
    return run
  }

  private struct Alignment {
    var marks = Set<Int>()
    var anchors = Set<Int>()
    /// After line number (1-based) and the before line index (0-based) it replaced.
    var pairs: [(after: Int, before: Int)] = []
  }

  private static func align(before: String, after: String) -> Alignment {
    let beforeUnits = diffUnits(for: before)
    let afterUnits = diffUnits(for: after)
    let limit = min(beforeUnits.count, afterUnits.count)
    var prefix = 0
    while prefix < limit, beforeUnits[prefix] == afterUnits[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < limit - prefix, beforeUnits[beforeUnits.count - 1 - suffix] == afterUnits[afterUnits.count - 1 - suffix] {
      suffix += 1
    }
    let beforeMiddle = beforeUnits[prefix..<(beforeUnits.count - suffix)]
    let afterMiddle = afterUnits[prefix..<(afterUnits.count - suffix)]

    var alignment = Alignment()
    if beforeMiddle.count + afterMiddle.count > maximumDiffedLines {
      var positions: [String: [Int]] = [:]
      for (offset, unit) in beforeMiddle.enumerated() {
        positions[unit, default: []].append(offset)
      }
      var nextCandidateIndex: [String: Int] = [:]
      var matches: [(after: Int, before: Int)] = []
      for (offset, unit) in afterMiddle.enumerated() {
        let candidates = positions[unit]
        let cursor = nextCandidateIndex[unit, default: 0]
        if let candidates, cursor < candidates.count {
          matches.append((after: offset, before: candidates[cursor]))
          nextCandidateIndex[unit] = cursor + 1
        } else {
          alignment.marks.insert(prefix + 1 + offset)
        }
      }
      let inOrder = longestIncreasingRun(matches.map(\.before))
      for (index, match) in matches.enumerated() where !inOrder.contains(index) {
        alignment.marks.insert(prefix + 1 + match.after)
      }
      if matches.count < beforeMiddle.count { alignment.anchors.insert(prefix + 1) }
    } else {
      let diff = afterMiddle.difference(from: beforeMiddle)
      var inserted = Set<Int>()
      var removed = Set<Int>()
      for change in diff {
        switch change {
        case .insert(let offset, _, _): inserted.insert(prefix + offset)
        case .remove(let offset, _, _): removed.insert(prefix + offset)
        }
      }
      var i = prefix
      var j = prefix
      var runRemoved: [Int] = []
      var runInserted: [Int] = []
      func endRun() {
        if runRemoved.count == runInserted.count, runInserted.count <= maximumPairedRunLines {
          for (b, a) in zip(runRemoved, runInserted) { alignment.pairs.append((after: a + 1, before: b)) }
        }
        runRemoved = []
        runInserted = []
      }
      while i < prefix + beforeMiddle.count || j < prefix + afterMiddle.count {
        if removed.contains(i) {
          alignment.anchors.insert(j + 1)
          runRemoved.append(i)
          i += 1
        } else if inserted.contains(j) {
          alignment.marks.insert(j + 1)
          runInserted.append(j)
          j += 1
        } else {
          endRun()
          i += 1
          j += 1
        }
      }
      endRun()
    }
    return alignment
  }

  static func changedText(before: Substring, after: Substring) -> ChangedText? {
    let beforeLine = withoutCarriageReturn(before)
    let afterLine = withoutCarriageReturn(after)
    guard
      beforeLine.utf8.count <= maximumHighlightedLineBytes, afterLine.utf8.count <= maximumHighlightedLineBytes
    else { return nil }
    let b = Array(beforeLine)
    let a = Array(afterLine)
    guard b != a else { return nil }

    let limit = min(b.count, a.count)
    var prefix = 0
    while prefix < limit, b[prefix] == a[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < limit - prefix, b[b.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }
    let beforeMiddle = Array(b[prefix..<(b.count - suffix)])
    let afterMiddle = Array(a[prefix..<(a.count - suffix)])
    guard beforeMiddle.count + afterMiddle.count <= maximumComparedCharacters else { return nil }

    var inserted = Set<Int>()
    var removed = Set<Int>()
    for change in afterMiddle.difference(from: beforeMiddle) {
      switch change {
      case .insert(let offset, _, _): inserted.insert(offset)
      case .remove(let offset, _, _): removed.insert(offset)
      }
    }

    // An empty edit is a removal with nothing in its place.
    var edits: [Range<Int>] = []
    var editStart: Int?
    func endEdit(at end: Int) {
      if let start = editStart {
        if let last = edits.last, start - last.upperBound <= maximumAbsorbedGap {
          edits[edits.count - 1] = last.lowerBound..<end
        } else {
          edits.append(start..<end)
        }
      }
      editStart = nil
    }
    var i = 0
    var j = 0
    while i < beforeMiddle.count || j < afterMiddle.count {
      if removed.contains(i) {
        if editStart == nil { editStart = prefix + j }
        i += 1
      } else if inserted.contains(j) {
        if editStart == nil { editStart = prefix + j }
        j += 1
      } else {
        endEdit(at: prefix + j)
        i += 1
        j += 1
      }
    }
    endEdit(at: prefix + j)

    let unchanged = a.count - edits.reduce(0) { $0 + $1.count }
    guard unchanged * 2 >= max(a.count, b.count) else { return nil }
    return ChangedText(
      inserted: edits.filter { !$0.isEmpty },
      removedAt: edits.filter(\.isEmpty).map(\.lowerBound)
    )
  }

  private static func withoutCarriageReturn(_ line: Substring) -> Substring {
    line.hasSuffix("\r") ? line.dropLast() : line
  }
}
