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
    case .swift, .typescript, .json, .python, .shell, .css:
      var scanner = CodeScanner(language: language)
      return lines.map { scanner.scan($0) }
    case .yaml:
      var scanner = YAMLScanner()
      return lines.map { scanner.scan($0) }
    case .markdown:
      var scanner = MarkdownScanner()
      return lines.map { scanner.scan($0) }
    case .html:
      var scanner = HTMLScanner()
      return lines.map { scanner.scan($0) }
    }
  }

  private static func units(_ line: Substring) -> [UInt16] {
    var units = Array(line.utf16)
    if units.last == .ascii("\r") { units.removeLast() }
    return units
  }
}

/// The scanner for code: Swift, TypeScript, JSON, Python, shell and CSS. It keeps the state a
/// line can end in (inside a block comment, a multi-line string or a heredoc), so each line is
/// lexed once, in order.
private struct CodeScanner {
  enum State {
    case code
    case blockComment(depth: Int)
    case string(Delimiter)
    case heredoc(Heredoc)
  }

  struct Delimiter {
    var close: [UInt16]
    var escapes: Bool
    var spansLines: Bool
  }

  struct Heredoc {
    var word: [UInt16]
    var trimsIndent: Bool
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
  /// A shell heredoc opened on this line; its body starts on the next line.
  var pendingHeredoc: Heredoc?
  /// `((` arithmetic still open, where `<<` is a shift rather than a heredoc.
  var openArithmetic = 0

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
    case .heredoc(let heredoc):
      emit(0..<line.count, .string)
      let body = heredoc.trimsIndent ? line.drop(while: \.isWhitespace) : line[...]
      if body.elementsEqual(heredoc.word) { state = .code }
      return runs
    }
    while index < line.count {
      index = token(at: index)
    }
    if case .string(let delimiter) = state, !delimiter.spansLines {
      state = .code
    }
    if let heredoc = pendingHeredoc, case .code = state {
      state = .heredoc(heredoc)
      pendingHeredoc = nil
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
    if let end = languageToken(at: index) { return end }
    if unit.isDigit { return number(at: index) }
    if isIdentifierStart(unit) { return identifier(at: index) }
    return punctuation(at: index)
  }

  private func startsComment(at index: Int) -> Bool {
    switch language {
    case .python: line[index] == .ascii("#")
    case .shell: line[index] == .ascii("#") && (index == 0 || line[index - 1].isWhitespace)
    case .css: has("/*", at: index)
    default: has("//", at: index) || has("/*", at: index)
    }
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
    case .python:
      var quote = index
      while quote < line.count, quote - index < 2, Self.pythonPrefixes.contains(line[quote]) { quote += 1 }
      guard quote < line.count, line[quote] == .ascii("\"") || line[quote] == .ascii("'") else { return nil }
      let triple = Array(repeating: line[quote], count: 3)
      if has(triple, at: quote) {
        return (Delimiter(close: triple, escapes: true, spansLines: true), quote + 3)
      }
      return (Delimiter(close: [line[quote]], escapes: true, spansLines: false), quote + 1)
    case .json, .shell, .css:
      let unit = line[index]
      guard unit == .ascii("\"") || (unit == .ascii("'") && language != .json) else { return nil }
      let escapes = !(language == .shell && unit == .ascii("'"))
      return (Delimiter(close: [unit], escapes: escapes, spansLines: false), index + 1)
    case .yaml, .markdown, .html:
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

  /// Tokens only one language has: Swift's `@attribute` and `#directive`, Python's
  /// `@decorator`, CSS's `@media`, `!important` and `#hex`, and shell variables and heredocs.
  private mutating func languageToken(at index: Int) -> Int? {
    let unit = line[index]
    let isPrefixedKeyword =
      switch language {
      case .swift: unit == .ascii("@") || unit == .ascii("#")
      case .python: unit == .ascii("@")
      case .css: unit == .ascii("@") || unit == .ascii("!")
      default: false
      }
    if isPrefixedKeyword, index + 1 < line.count, isIdentifierStart(line[index + 1]) {
      let end = identifierEnd(from: index + 1)
      emit(index..<end, .keyword)
      return end
    }
    if language == .css, unit == .ascii("#") {
      let end = identifierEnd(from: index + 1)
      guard end > index + 1, line[(index + 1)..<end].allSatisfy(\.isHexDigit) else { return nil }
      emit(index..<end, .number)
      return end
    }
    if language == .shell, unit == .ascii("$") { return variable(at: index) }
    if language == .shell, has("<<", at: index), !has("<<<", at: index), openArithmetic == 0 {
      return heredoc(at: index)
    }
    return nil
  }

  /// `$NAME`, `${…}`, `$1` and `$@`-style specials.
  private mutating func variable(at index: Int) -> Int? {
    guard index + 1 < line.count else { return nil }
    let next = line[index + 1]
    let end: Int
    if next == .ascii("{") {
      end = line[index...].firstIndex(of: .ascii("}")).map { $0 + 1 } ?? line.count
    } else if isIdentifierStart(next) {
      end = identifierEnd(from: index + 1)
    } else if next.isDigit || Self.shellSpecials.contains(next) {
      end = index + 2
    } else {
      return nil
    }
    emit(index..<end, .type)
    return end
  }

  /// `<<WORD`, `<<'WORD'` or `<<-WORD`. The body is a string through the line equal to `WORD`.
  private mutating func heredoc(at index: Int) -> Int? {
    var operatorEnd = index + 2
    let trimsIndent = operatorEnd < line.count && line[operatorEnd] == .ascii("-")
    if trimsIndent { operatorEnd += 1 }
    var wordStart = operatorEnd
    while wordStart < line.count, line[wordStart].isWhitespace { wordStart += 1 }
    let quote = wordStart < line.count ? line[wordStart] : 0
    let isQuoted = quote == .ascii("'") || quote == .ascii("\"")
    let nameStart = isQuoted ? wordStart + 1 : wordStart
    let nameEnd =
      line[nameStart...].firstIndex {
        isQuoted ? $0 == quote : $0.isWhitespace || Self.shellWordBreaks.contains($0)
      } ?? line.count
    guard nameEnd > nameStart, !line[nameStart].isDigit, !isQuoted || (nameEnd < line.count && line[nameEnd] == quote) else {
      return nil
    }
    let end = isQuoted ? nameEnd + 1 : nameEnd
    emit(index..<operatorEnd, .punctuation)
    emit(wordStart..<end, .string)
    pendingHeredoc = Heredoc(word: Array(line[nameStart..<nameEnd]), trimsIndent: trimsIndent)
    return end
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
    if language == .css {
      kind = nextNonWhitespace(from: end) == .ascii(":") ? .type : isCall ? .function : .plain
    } else if let afterDot = dot.flatMap({ $0.end == index ? $0.before : nil }) {
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
    if unit == .ascii("#") {
      while end + 1 < line.count, line[end] == .ascii("#"), line[end + 1] == .ascii("#") { end += 1 }
    } else if !Self.brackets.contains(unit) {
      while end < line.count, isOperator(line[end]), !startsComment(at: end) { end += 1 }
    }
    if language == .shell, has("((", at: index) { openArithmetic += 1 }
    if language == .shell, has("))", at: index), openArithmetic > 0 { openArithmetic -= 1 }
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
    line.matches(text.utf16, at: index)
  }

  private func has(_ units: [UInt16], at index: Int) -> Bool {
    line.matches(units, at: index)
  }

  private func isIdentifierStart(_ unit: UInt16) -> Bool {
    unit.isASCIILetter || unit == .ascii("_") || unit >= 0x80
      || (language == .typescript && unit == .ascii("$"))
  }

  private func identifierEnd(from index: Int) -> Int {
    var end = index
    while end < line.count,
      isIdentifierStart(line[end]) || line[end].isDigit || (language == .css && line[end] == .ascii("-"))
    {
      end += 1
    }
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
  private static let shellWordBreaks = Set(";|&<>()\"'".utf16)
  private static let closers = Set(")]}".utf16)
  private static let nonOperators = Set("._\"'`#@$".utf16)
  private static let constants: Set = ["true", "false", "nil", "null", "undefined", "None", "True", "False"]
  private static let valueKeywords: Set = ["self", "Self", "super", "this"]
  private static let pythonPrefixes = Set("rRbBfFuU".utf16)
  private static let shellSpecials = Set("@*#?$!-".utf16)
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
    .python: [
      "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
      "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
      "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ],
    .shell: [
      "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
      "function", "in", "return", "export", "local", "select",
    ],
  ]
}

extension UInt16 {
  static func ascii(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

  var isWhitespace: Bool {
    self == .ascii(" ") || self == .ascii("\t") || self == 0x0B || self == 0x0C
  }
  var isDigit: Bool { (0x30...0x39).contains(self) }
  var isUppercase: Bool { (0x41...0x5A).contains(self) }
  var isASCIILetter: Bool { isUppercase || (0x61...0x7A).contains(self) }
  var isASCIIAlphanumeric: Bool { isASCIILetter || isDigit }
  var isHexDigit: Bool { isDigit || (0x41...0x46).contains(self) || (0x61...0x66).contains(self) }
}

extension [UInt16] {
  func matches(_ units: some Collection<UInt16>, at index: Int) -> Bool {
    var offset = index
    for unit in units {
      guard offset < count, self[offset] == unit else { return false }
      offset += 1
    }
    return true
  }
}
