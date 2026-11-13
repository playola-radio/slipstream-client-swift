/// YAML, one line at a time. A `|` or `>` block scalar carries across lines: every line
/// indented past its key is string.
struct YAMLScanner {
  private var blockScalarKeyColumn: Int?

  mutating func scan(_ line: [UInt16]) -> [SyntaxRun] {
    var runs: [SyntaxRun] = []
    let indent = line.prefix(while: \.isWhitespace).count
    if let keyColumn = blockScalarKeyColumn {
      if indent == line.count { return runs }
      if indent > keyColumn {
        runs.add(0..<line.count, .string)
        return runs
      }
      blockScalarKeyColumn = nil
    }
    var index = indent
    if index == 0, line.matches("---".utf16, at: 0) || line.matches("...".utf16, at: 0),
      line.count == 3 || line[3].isWhitespace
    {
      runs.add(0..<3, .punctuation)
      index = line.skippingWhitespace(from: 3)
    }
    while index < line.count, line[index] == .ascii("-"),
      index + 1 == line.count || line[index + 1].isWhitespace
    {
      runs.add(index..<(index + 1), .punctuation)
      index = line.skippingWhitespace(from: index + 1)
    }
    let keyColumn = index
    if let colon = keyColon(in: line, from: index) {
      runs.add(index..<line.trimmingWhitespace(before: colon), .type)
      runs.add(colon..<(colon + 1), .punctuation)
      index = line.skippingWhitespace(from: colon + 1)
    }
    guard index < line.count else { return runs }
    let unit = line[index]
    if unit == .ascii("#") {
      runs.add(index..<line.count, .comment)
      return runs
    }
    if unit == .ascii("|") || unit == .ascii(">") {
      let end = line[index...].firstIndex(where: \.isWhitespace) ?? line.count
      runs.add(index..<end, .punctuation)
      blockScalarKeyColumn = keyColumn
      index = end
    } else if unit == .ascii("\"") || unit == .ascii("'") {
      let end = line.quoteEnd(from: index)
      runs.add(index..<end, .string)
      index = end
    } else {
      let end = line.commentStart(from: index) ?? line.count
      let valueEnd = line.trimmingWhitespace(before: end)
      runs.add(index..<valueEnd, isScalarNumber(line[index..<valueEnd]) ? .number : .string)
      index = end
    }
    index = line.skippingWhitespace(from: index)
    if index < line.count, line[index] == .ascii("#") {
      runs.add(index..<line.count, .comment)
    }
    return runs
  }

  /// The first `:` followed by a space or the end of the line, outside a leading quote and
  /// before a comment.
  private func keyColon(in line: [UInt16], from start: Int) -> Int? {
    var index = start
    if index < line.count, line[index] == .ascii("\"") || line[index] == .ascii("'") {
      index = line.quoteEnd(from: index)
    }
    while index < line.count {
      if line[index] == .ascii("#"), index > start, line[index - 1].isWhitespace { return nil }
      if line[index] == .ascii(":"), index + 1 == line.count || line[index + 1].isWhitespace {
        return index
      }
      index += 1
    }
    return nil
  }

  private func isScalarNumber(_ units: ArraySlice<UInt16>) -> Bool {
    let text = String(decoding: units, as: UTF16.self)
    if Self.constants.contains(text) { return true }
    guard let first = units.first else { return false }
    let startsNumeric =
      first.isDigit
      || ((first == .ascii("-") || first == .ascii("+")) && units.dropFirst().first?.isDigit == true)
    return startsNumeric && Double(text) != nil
  }

  private static let constants: Set = ["true", "false", "null", "~"]
}

/// Markdown, one line at a time. A fenced code block carries across lines: its fence lines are
/// plain and every line inside is string.
struct MarkdownScanner {
  private var fence: (marker: UInt16, count: Int)?

  mutating func scan(_ line: [UInt16]) -> [SyntaxRun] {
    var runs: [SyntaxRun] = []
    let start = line.skippingWhitespace(from: 0)
    let end = line.trimmingWhitespace(before: line.count)
    let markerCount = start < line.count ? line[start...].prefix(while: { $0 == line[start] }).count : 0
    if let open = fence {
      if start < line.count, line[start] == open.marker, markerCount >= open.count,
        start + markerCount == end
      {
        runs.add(start..<end, .plain)
        fence = nil
      } else {
        runs.add(0..<line.count, .string)
      }
      return runs
    }
    guard start < line.count else { return runs }
    if line[start] == .ascii("`") || line[start] == .ascii("~"), markerCount >= 3 {
      runs.add(start..<end, .plain)
      fence = (line[start], markerCount)
      return runs
    }
    if line[start] == .ascii("#"), markerCount <= 6,
      start + markerCount == line.count || line[start + markerCount].isWhitespace
    {
      runs.add(start..<end, .keyword)
      return runs
    }
    var index = start
    while index < line.count {
      if line[index].isWhitespace {
        index += 1
      } else if line[index] == .ascii("`"), let spanEnd = codeSpanEnd(in: line, from: index) {
        runs.add(index..<spanEnd, .string)
        index = spanEnd
      } else {
        let wordEnd =
          line[(index + 1)...].firstIndex { $0.isWhitespace || $0 == .ascii("`") } ?? line.count
        runs.add(index..<wordEnd, .plain)
        index = wordEnd
      }
    }
    return runs
  }

  /// The end of a code span opened at `index`: the next run of exactly as many backticks.
  private func codeSpanEnd(in line: [UInt16], from index: Int) -> Int? {
    let ticks = line[index...].prefix { $0 == .ascii("`") }.count
    var search = index + ticks
    while search < line.count {
      guard line[search] == .ascii("`") else {
        search += 1
        continue
      }
      let closing = line[search...].prefix { $0 == .ascii("`") }.count
      if closing == ticks { return search + closing }
      search += closing
    }
    return nil
  }
}

/// HTML, one line at a time. A comment and an open tag both carry across lines.
struct HTMLScanner {
  private enum State {
    case text
    case comment
    case tag(afterEquals: Bool)
  }

  private var state = State.text

  mutating func scan(_ line: [UInt16]) -> [SyntaxRun] {
    var runs: [SyntaxRun] = []
    var index = 0
    while index < line.count {
      switch state {
      case .comment:
        index = comment(in: line, at: index, searchFrom: index, runs: &runs)
      case .tag(let afterEquals):
        index = tagToken(in: line, at: index, afterEquals: afterEquals, runs: &runs)
      case .text:
        index = textToken(in: line, at: index, runs: &runs)
      }
    }
    return runs
  }

  private mutating func comment(
    in line: [UInt16], at index: Int, searchFrom: Int, runs: inout [SyntaxRun]
  ) -> Int {
    let close = line.firstMatch("-->".utf16, from: searchFrom)
    let end = close.map { $0 + 3 } ?? line.count
    runs.add(index..<end, .comment)
    state = close == nil ? .comment : .text
    return end
  }

  private mutating func textToken(in line: [UInt16], at index: Int, runs: inout [SyntaxRun]) -> Int {
    let unit = line[index]
    if unit.isWhitespace { return index + 1 }
    if line.matches("<!--".utf16, at: index) {
      return comment(in: line, at: index, searchFrom: index + 4, runs: &runs)
    }
    if unit == .ascii("<") {
      let hasPrefix = index + 1 < line.count && (line[index + 1] == .ascii("/") || line[index + 1] == .ascii("!"))
      let nameStart = index + (hasPrefix ? 2 : 1)
      if nameStart < line.count, line[nameStart].isASCIILetter {
        let nameEnd = line.nameEnd(from: nameStart)
        runs.add(index..<nameStart, .punctuation)
        runs.add(nameStart..<nameEnd, .keyword)
        state = .tag(afterEquals: false)
        return nameEnd
      }
    }
    if unit == .ascii("&"), let semicolon = line[index...].prefix(32).firstIndex(of: .ascii(";")),
      semicolon > index + 1,
      line[(index + 1)..<semicolon].allSatisfy({ $0.isASCIIAlphanumeric || $0 == .ascii("#") })
    {
      runs.add(index..<(semicolon + 1), .number)
      return semicolon + 1
    }
    let end =
      line[(index + 1)...].firstIndex { $0.isWhitespace || $0 == .ascii("<") || $0 == .ascii("&") }
      ?? line.count
    runs.add(index..<end, .plain)
    return end
  }

  private mutating func tagToken(
    in line: [UInt16], at index: Int, afterEquals: Bool, runs: inout [SyntaxRun]
  ) -> Int {
    let unit = line[index]
    if unit.isWhitespace { return index + 1 }
    state = .tag(afterEquals: false)
    if unit == .ascii(">") || line.matches("/>".utf16, at: index) {
      let end = unit == .ascii(">") ? index + 1 : index + 2
      runs.add(index..<end, .punctuation)
      state = .text
      return end
    }
    if unit == .ascii("=") {
      runs.add(index..<(index + 1), .punctuation)
      state = .tag(afterEquals: true)
      return index + 1
    }
    if unit == .ascii("\"") || unit == .ascii("'") {
      let end = line.quoteEnd(from: index)
      runs.add(index..<end, .string)
      return end
    }
    if unit == .ascii("/") {
      runs.add(index..<(index + 1), .punctuation)
      return index + 1
    }
    let end =
      line[index...].firstIndex {
        $0.isWhitespace || $0 == .ascii(">") || (!afterEquals && ($0 == .ascii("=") || $0 == .ascii("/")))
      } ?? line.count
    runs.add(index..<end, afterEquals ? .string : .type)
    return end
  }
}

extension [SyntaxRun] {
  fileprivate mutating func add(_ range: Range<Int>, _ kind: SyntaxKind) {
    guard !range.isEmpty else { return }
    append(SyntaxRun(range: range, kind: kind))
  }
}

extension [UInt16] {
  fileprivate func skippingWhitespace(from index: Int) -> Int {
    self[index...].firstIndex { !$0.isWhitespace } ?? count
  }

  fileprivate func trimmingWhitespace(before index: Int) -> Int {
    (self[..<index].lastIndex { !$0.isWhitespace } ?? -1) + 1
  }

  /// The end of a quoted run opened at `index`, or the end of the line if it never closes.
  fileprivate func quoteEnd(from index: Int) -> Int {
    let quote = self[index]
    var offset = index + 1
    while offset < count {
      if self[offset] == .ascii("\\"), quote == .ascii("\"") {
        offset += 2
        continue
      }
      if self[offset] == quote { return offset + 1 }
      offset += 1
    }
    return count
  }

  /// A `#` that starts a comment: at the start or after whitespace.
  fileprivate func commentStart(from index: Int) -> Int? {
    self[index...].indices.first { self[$0] == .ascii("#") && ($0 == 0 || self[$0 - 1].isWhitespace) }
  }

  fileprivate func firstMatch(_ units: some Collection<UInt16>, from index: Int) -> Int? {
    guard index < count else { return nil }
    return self[index...].indices.first { matches(units, at: $0) }
  }

  fileprivate func nameEnd(from index: Int) -> Int {
    self[index...].firstIndex {
      !($0.isASCIIAlphanumeric || $0 == .ascii("-") || $0 == .ascii(":") || $0 == .ascii("_"))
    } ?? count
  }
}
