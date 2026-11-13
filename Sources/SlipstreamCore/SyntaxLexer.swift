/// What a token looks like. These are lexical guesses: when unsure, a word is `.plain`.
public enum SyntaxKind: Equatable, Sendable {
  case keyword, string, number, type, function, comment, punctuation, plain
}

/// A token's span on one line, in UTF-16 offsets into that line.
public struct SyntaxRun: Equatable, Sendable {
  public var range: Range<Int>
  public var kind: SyntaxKind

  public init(range: Range<Int>, kind: SyntaxKind) {
    self.range = range
    self.kind = kind
  }
}

public enum SyntaxLexer {
  /// Lexes the whole source in one pass and returns the runs for each line of
  /// `ChangedLines.split(source)`, without a trailing `\r`, so index `n - 1` is line `n`.
  /// Whitespace between tokens is uncovered; a token that spans lines gets one run per line.
  public static func lines(_ source: String, language: SyntaxLanguage) -> [[SyntaxRun]] {
    let lines = ChangedLines.split(source).map(units)
    switch language {
    case .swift, .typescript, .json:
      var scanner = CodeScanner(language: language)
      return lines.map { scanner.scan($0) }
    case .yaml, .shell, .markdown, .python, .css, .html:
      return lines.map { _ in [] }
    }
  }

  private static func units(_ line: Substring) -> [UInt16] {
    var units = Array(line.utf16)
    if units.last == .ascii("\r") { units.removeLast() }
    return units
  }
}

/// The scanner for C-like languages. It keeps the state a line can end in (inside a block
/// comment or a multi-line string), so each line is lexed once, in order.
private struct CodeScanner {
  enum State {
    case code
    case blockComment(depth: Int)
    case string(Delimiter)
  }

  struct Delimiter {
    var close: [UInt16]
    var escapes: Bool
    var spansLines: Bool
  }

  /// What the last token was, for the guesses that depend on it: `Type.member` and Swift's
  /// implicit `.member`.
  enum Previous { case other, value, typeName }

  let language: SyntaxLanguage
  let keywords: Set<String>
  var state = State.code
  var previous = Previous.other
  var line: [UInt16] = []
  var runs: [SyntaxRun] = []
  /// A lone `.` just emitted on this line: where it ends, and what came before it.
  var dot: (end: Int, before: Previous)?

  init(language: SyntaxLanguage) {
    self.language = language
    self.keywords = Self.keywords[language] ?? []
  }

  mutating func scan(_ line: [UInt16]) -> [SyntaxRun] {
    self.line = line
    runs = []
    dot = nil
    var index = 0
    switch state {
    case .code: break
    case .blockComment(let depth): index = blockComment(from: 0, start: 0, depth: depth)
    case .string(let delimiter): index = string(delimiter, from: 0, start: 0)
    }
    while index < line.count {
      index = token(at: index)
    }
    if case .string(let delimiter) = state, !delimiter.spansLines {
      state = .code
    }
    return runs
  }

  // MARK: Tokens

  private mutating func token(at index: Int) -> Int {
    let unit = line[index]
    if unit.isWhitespace { return index + 1 }
    if startsComment(at: index) {
      if has("/*", at: index) { return blockComment(from: index + 2, start: index, depth: 1) }
      emit(index..<line.count, .comment)
      return line.count
    }
    if let (delimiter, contentStart) = stringOpening(at: index) {
      return string(delimiter, from: contentStart, start: index)
    }
    if let end = prefixedKeyword(at: index) {
      emit(index..<end, .keyword)
      return end
    }
    if unit.isDigit { return number(at: index) }
    if isIdentifierStart(unit) { return identifier(at: index) }
    return punctuation(at: index)
  }

  private func startsComment(at index: Int) -> Bool {
    has("//", at: index) || has("/*", at: index)
  }

  private mutating func blockComment(from index: Int, start: Int, depth: Int) -> Int {
    var index = index
    var depth = depth
    while index < line.count {
      if has("*/", at: index) {
        index += 2
        depth -= 1
        if depth == 0 {
          state = .code
          emit(start..<index, .comment)
          return index
        }
      } else if language == .swift, has("/*", at: index) {
        index += 2
        depth += 1
      } else {
        index += 1
      }
    }
    state = .blockComment(depth: depth)
    emit(start..<line.count, .comment)
    return line.count
  }

  private func stringOpening(at index: Int) -> (Delimiter, contentStart: Int)? {
    switch language {
    case .swift:
      var quote = index
      while quote < line.count, line[quote] == .ascii("#") { quote += 1 }
      guard quote < line.count, line[quote] == .ascii("\"") else { return nil }
      let hashes = Array(line[index..<quote])
      if has("\"\"\"", at: quote) {
        return (Delimiter(close: Array("\"\"\"".utf16) + hashes, escapes: hashes.isEmpty, spansLines: true), quote + 3)
      }
      return (Delimiter(close: [.ascii("\"")] + hashes, escapes: hashes.isEmpty, spansLines: false), quote + 1)
    case .typescript:
      let unit = line[index]
      guard unit == .ascii("\"") || unit == .ascii("'") || unit == .ascii("`") else { return nil }
      return (Delimiter(close: [unit], escapes: true, spansLines: unit == .ascii("`")), index + 1)
    case .json:
      guard line[index] == .ascii("\"") else { return nil }
      return (Delimiter(close: [.ascii("\"")], escapes: true, spansLines: false), index + 1)
    default:
      return nil
    }
  }

  private mutating func string(_ delimiter: Delimiter, from index: Int, start: Int) -> Int {
    var index = index
    while index < line.count {
      if delimiter.escapes, line[index] == .ascii("\\") {
        index = has("\\(", at: index) && language == .swift ? interpolationEnd(from: index + 2) : index + 2
      } else if has(delimiter.close, at: index) {
        index += delimiter.close.count
        state = .code
        emit(start..<index, .string)
        return index
      } else {
        index += 1
      }
    }
    state = .string(delimiter)
    emit(start..<line.count, .string)
    return line.count
  }

  /// Swift's `\(…)` can hold quotes, as in `"\(d["k"])"`, so it is skipped by matching parens.
  private func interpolationEnd(from index: Int) -> Int {
    var depth = 1
    for offset in index..<line.count {
      if line[offset] == .ascii("(") { depth += 1 }
      if line[offset] == .ascii(")") { depth -= 1 }
      if depth == 0 { return offset + 1 }
    }
    return line.count
  }

  /// Swift's `@attribute` and `#directive`.
  private func prefixedKeyword(at index: Int) -> Int? {
    guard language == .swift, line[index] == .ascii("@") || line[index] == .ascii("#"),
      index + 1 < line.count, isIdentifierStart(line[index + 1])
    else { return nil }
    return identifierEnd(from: index + 1)
  }

  private mutating func number(at index: Int) -> Int {
    let isHex = has("0x", at: index) || has("0X", at: index)
    var end = index + 1
    while end < line.count {
      let unit = line[end]
      let next = end + 1 < line.count ? line[end + 1] : 0
      if !isHex, unit == .ascii("e") || unit == .ascii("E"), next == .ascii("+") || next == .ascii("-") {
        end += 2
      } else if unit.isASCIIAlphanumeric || unit == .ascii("_") {
        end += 1
      } else if unit == .ascii("."), next.isDigit {
        end += 2
      } else {
        break
      }
    }
    emit(index..<end, .number)
    return end
  }

  private mutating func identifier(at index: Int) -> Int {
    let end = identifierEnd(from: index)
    let text = String(decoding: line[index..<end], as: UTF16.self)
    let isCall = nextNonWhitespace(from: end) == .ascii("(")
    let kind: SyntaxKind
    if let afterDot = dot.flatMap({ $0.end == index ? $0.before : nil }) {
      if afterDot == .typeName, !isCall {
        kind = .number
      } else if language == .swift, afterDot == .other {
        kind = .number
      } else {
        kind = line[index].isUppercase ? .type : isCall ? .function : .plain
      }
    } else if Self.constants.contains(text) {
      kind = .number
    } else if keywords.contains(text) {
      kind = .keyword
    } else {
      kind = line[index].isUppercase ? .type : isCall ? .function : .plain
    }
    emit(index..<end, kind)
    if kind == .keyword, Self.valueKeywords.contains(text) {
      previous = .value
    }
    return end
  }

  private mutating func punctuation(at index: Int) -> Int {
    let unit = line[index]
    var end = index + 1
    if unit == .ascii(".") {
      while end < line.count, line[end] == .ascii(".") { end += 1 }
      let before = previous
      emit(index..<end, .punctuation)
      if end == index + 1 { dot = (end, before) }
      return end
    }
    if !Self.brackets.contains(unit) {
      while end < line.count, isOperator(line[end]), !startsComment(at: end) { end += 1 }
    }
    emit(index..<end, .punctuation)
    let isPostfix =
      end == index + 1 && (unit == .ascii("?") || unit == .ascii("!")) && index > 0
      && !line[index - 1].isWhitespace
    if Self.closers.contains(unit) || isPostfix {
      previous = .value
    }
    return end
  }

  // MARK: Helpers

  private mutating func emit(_ range: Range<Int>, _ kind: SyntaxKind) {
    guard !range.isEmpty else { return }
    runs.append(SyntaxRun(range: range, kind: kind))
    dot = nil
    switch kind {
    case .comment: break
    case .string, .number, .plain, .function: previous = .value
    case .type: previous = .typeName
    case .keyword, .punctuation: previous = .other
    }
  }

  private func has(_ text: String, at index: Int) -> Bool {
    has(text.utf16, at: index)
  }

  private func has(_ units: some Collection<UInt16>, at index: Int) -> Bool {
    var offset = index
    for unit in units {
      guard offset < line.count, line[offset] == unit else { return false }
      offset += 1
    }
    return true
  }

  private func isIdentifierStart(_ unit: UInt16) -> Bool {
    unit.isASCIILetter || unit == .ascii("_") || unit >= 0x80
      || (language == .typescript && unit == .ascii("$"))
  }

  private func identifierEnd(from index: Int) -> Int {
    var end = index
    while end < line.count, isIdentifierStart(line[end]) || line[end].isDigit { end += 1 }
    return end
  }

  private func nextNonWhitespace(from index: Int) -> UInt16? {
    line[index...].first { !$0.isWhitespace }
  }

  private func isOperator(_ unit: UInt16) -> Bool {
    unit < 0x80 && !unit.isASCIIAlphanumeric && !unit.isWhitespace && !Self.brackets.contains(unit)
      && !Self.nonOperators.contains(unit)
  }

  private static let brackets = Set("()[]{},;".utf16)
  private static let closers = Set(")]}".utf16)
  private static let nonOperators = Set("._\"'`#@$".utf16)
  private static let constants: Set = ["true", "false", "nil", "null", "undefined", "None", "True", "False"]
  private static let valueKeywords: Set = ["self", "Self", "super", "this"]
  private static let keywords: [SyntaxLanguage: Set<String>] = [
    .swift: [
      "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
      "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else",
      "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "guard", "if",
      "import", "in", "indirect", "init", "inout", "internal", "is", "lazy", "let", "macro",
      "mutating", "nonisolated", "open", "operator", "override", "private", "protocol", "public",
      "repeat", "required", "rethrows", "return", "self", "Self", "some", "static", "struct",
      "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned", "var",
      "weak", "where", "while", "willSet",
    ],
    .typescript: [
      "abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
      "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum",
      "export", "extends", "finally", "for", "from", "function", "if", "implements", "import",
      "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "of", "private",
      "protected", "public", "readonly", "return", "satisfies", "static", "super", "switch",
      "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
    ],
  ]
}

extension UInt16 {
  fileprivate static func ascii(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

  fileprivate var isWhitespace: Bool {
    self == .ascii(" ") || self == .ascii("\t") || self == 0x0B || self == 0x0C
  }
  fileprivate var isDigit: Bool { (0x30...0x39).contains(self) }
  fileprivate var isUppercase: Bool { (0x41...0x5A).contains(self) }
  fileprivate var isASCIILetter: Bool { isUppercase || (0x61...0x7A).contains(self) }
  fileprivate var isASCIIAlphanumeric: Bool { isASCIILetter || isDigit }
}
