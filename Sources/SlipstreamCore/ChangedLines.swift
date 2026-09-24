public struct ClipLine: Equatable, Sendable {
  public var number: Int
  public var text: String
  public var isChanged: Bool

  public init(number: Int, text: String, isChanged: Bool) {
    self.number = number
    self.text = text
    self.isChanged = isChanged
  }
}

public enum ChangedLines {
  public static func split(_ text: String) -> [Substring] {
    guard !text.isEmpty else { return [] }
    var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
      .map { text[$0.startIndex..<$0.endIndex] }
    if endsWithNewlineScalar(text) {
      lines.removeLast()
    }
    return lines
  }

  public static func clipLines(
    before: String?, after: String, lineStart: Int, lineEnd: Int
  ) -> [ClipLine] {
    let afterLines = split(after)
    let clampedStart = max(1, lineStart)
    let clampedEnd = min(lineEnd, afterLines.count)
    guard clampedStart <= clampedEnd else { return [] }

    guard let before else {
      return (clampedStart...clampedEnd).map { number in
        ClipLine(number: number, text: displayText(afterLines[number - 1]), isChanged: true)
      }
    }

    let changed = changedLineNumbers(before: before, after: after, lineEnd: clampedEnd)
    return (clampedStart...clampedEnd).map { number in
      ClipLine(
        number: number,
        text: displayText(afterLines[number - 1]),
        isChanged: changed.contains(number)
      )
    }
  }

  private static func displayText(_ line: Substring) -> String {
    String(line.hasSuffix("\r") ? line.dropLast() : line)
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

  private static func changedLineNumbers(before: String, after: String, lineEnd: Int) -> Set<Int> {
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

    var marks = Set<Int>()
    var anchors = Set<Int>()
    if beforeMiddle.count > maximumDiffedLines || afterMiddle.count > maximumDiffedLines {
      var positions: [String: [Int]] = [:]
      for (offset, unit) in beforeMiddle.enumerated() {
        positions[unit, default: []].append(offset)
      }
      var unmatchedCount = beforeMiddle.count
      for (offset, unit) in afterMiddle.enumerated() {
        if var candidates = positions[unit], !candidates.isEmpty {
          let matchedOffset = candidates.removeFirst()
          positions[unit] = candidates
          unmatchedCount -= 1
          if abs(matchedOffset - offset) > maximumDiffedLines {
            marks.insert(prefix + 1 + offset)
          }
        } else {
          marks.insert(prefix + 1 + offset)
        }
      }
      if unmatchedCount > 0 { anchors.insert(prefix + 1) }
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
      while i < prefix + beforeMiddle.count || j < prefix + afterMiddle.count {
        if removed.contains(i) {
          anchors.insert(j + 1)
          i += 1
        } else if inserted.contains(j) {
          marks.insert(j + 1)
          j += 1
        } else {
          i += 1
          j += 1
        }
      }
    }

    var changed = marks.union(anchors)
    if anchors.contains(lineEnd + 1) {
      changed.insert(lineEnd)
    }
    return changed
  }
}
