import CustomDump
import SlipstreamCore
import Testing

private struct Token: Equatable {
  var text: String
  var kind: SyntaxKind

  init(_ text: String, _ kind: SyntaxKind) {
    self.text = text
    self.kind = kind
  }
}

private func displayLines(_ source: String) -> [[UInt16]] {
  ChangedLines.split(source).map { line in
    var units = Array(line.utf16)
    if units.last == 13 { units.removeLast() }
    return units
  }
}

private func tokens(_ source: String, _ language: SyntaxLanguage) -> [[Token]] {
  zip(displayLines(source), SyntaxLexer.lines(source, language: language)).map { units, runs in
    runs.map { Token(String(decoding: units[$0.range], as: UTF16.self), $0.kind) }
  }
}

struct SyntaxLexerTests {
  @Test func swiftDeclarations() {
    expectNoDifference(
      tokens("func isAllowed(_ user: User) -> Bool {", .swift),
      [
        [
          Token("func", .keyword), Token("isAllowed", .function), Token("(", .punctuation),
          Token("_", .plain), Token("user", .plain), Token(":", .punctuation),
          Token("User", .type), Token(")", .punctuation), Token("->", .punctuation),
          Token("Bool", .type), Token("{", .punctuation),
        ]
      ]
    )
  }

  @Test func swiftImplicitMember() {
    expectNoDifference(
      tokens("guard user.isActive != .suspended else { return false }", .swift),
      [
        [
          Token("guard", .keyword), Token("user", .plain), Token(".", .punctuation),
          Token("isActive", .plain), Token("!=", .punctuation), Token(".", .punctuation),
          Token("suspended", .number), Token("else", .keyword), Token("{", .punctuation),
          Token("return", .keyword), Token("false", .number), Token("}", .punctuation),
        ]
      ]
    )
  }

  @Test func swiftImplicitMemberFollowsKeywordsButNotChains() {
    expectNoDifference(
      tokens("case .active: x\n}\n.padding()\nself.y\na ?? .none", .swift),
      [
        [
          Token("case", .keyword), Token(".", .punctuation), Token("active", .number),
          Token(":", .punctuation), Token("x", .plain),
        ],
        [Token("}", .punctuation)],
        [
          Token(".", .punctuation), Token("padding", .function), Token("(", .punctuation),
          Token(")", .punctuation),
        ],
        [Token("self", .keyword), Token(".", .punctuation), Token("y", .plain)],
        [
          Token("a", .plain), Token("??", .punctuation), Token(".", .punctuation),
          Token("none", .number),
        ],
      ]
    )
  }

  @Test func swiftMultilineAndRawStrings() {
    expectNoDifference(
      tokens("let s = \"\"\"\n  a \"b\"\n  \"\"\"\nlet r = #\"a \"b\" c\"#", .swift),
      [
        [
          Token("let", .keyword), Token("s", .plain), Token("=", .punctuation),
          Token("\"\"\"", .string),
        ],
        [Token("  a \"b\"", .string)],
        [Token("  \"\"\"", .string)],
        [
          Token("let", .keyword), Token("r", .plain), Token("=", .punctuation),
          Token("#\"a \"b\" c\"#", .string),
        ],
      ]
    )
  }

  @Test func swiftInterpolationKeepsInnerQuotesInTheString() {
    expectNoDifference(
      tokens(#"print("\(d["k"]) x") @MainActor #if"#, .swift),
      [
        [
          Token("print", .function), Token("(", .punctuation),
          Token(#""\(d["k"]) x""#, .string), Token(")", .punctuation),
          Token("@MainActor", .keyword), Token("#if", .keyword),
        ]
      ]
    )
  }

  @Test func nestedBlockComment() {
    expectNoDifference(
      tokens("/* a /* b */ c */ let x", .swift),
      [[Token("/* a /* b */ c */", .comment), Token("let", .keyword), Token("x", .plain)]]
    )
  }

  @Test func typescriptTemplateSpansLines() {
    expectNoDifference(
      tokens("const a = `x\n${y}\nz`", .typescript),
      [
        [
          Token("const", .keyword), Token("a", .plain), Token("=", .punctuation),
          Token("`x", .string),
        ],
        [Token("${y}", .string)],
        [Token("z`", .string)],
      ]
    )
  }

  @Test func typescriptEnumMember() {
    expectNoDifference(
      tokens("isActive: ActivityState.Inactive,\nid: crypto.randomUUID(),", .typescript),
      [
        [
          Token("isActive", .plain), Token(":", .punctuation), Token("ActivityState", .type),
          Token(".", .punctuation), Token("Inactive", .number), Token(",", .punctuation),
        ],
        [
          Token("id", .plain), Token(":", .punctuation), Token("crypto", .plain),
          Token(".", .punctuation), Token("randomUUID", .function), Token("(", .punctuation),
          Token(")", .punctuation), Token(",", .punctuation),
        ],
      ]
    )
  }

  @Test func typescriptNumbers() {
    expectNoDifference(
      tokens("x = 0x1F + 1_000 - 1.5e3 + 2e-3", .typescript),
      [
        [
          Token("x", .plain), Token("=", .punctuation), Token("0x1F", .number),
          Token("+", .punctuation), Token("1_000", .number), Token("-", .punctuation),
          Token("1.5e3", .number), Token("+", .punctuation), Token("2e-3", .number),
        ]
      ]
    )
  }

  @Test func jsonValuesAndComments() {
    expectNoDifference(
      tokens(#"{"id": 1, "ok": true} // c"#, .json),
      [
        [
          Token("{", .punctuation), Token(#""id""#, .string), Token(":", .punctuation),
          Token("1", .number), Token(",", .punctuation), Token(#""ok""#, .string),
          Token(":", .punctuation), Token("true", .number), Token("}", .punctuation),
          Token("// c", .comment),
        ]
      ]
    )
  }

  @Test func rangesAreUTF16AndIgnoreCarriageReturns() {
    expectNoDifference(
      SyntaxLexer.lines("let a = \"👩‍👩‍👧\"\r\nlet b = 1\r\n", language: .swift),
      [
        [
          SyntaxRun(range: 0..<3, kind: .keyword), SyntaxRun(range: 4..<5, kind: .plain),
          SyntaxRun(range: 6..<7, kind: .punctuation), SyntaxRun(range: 8..<18, kind: .string),
        ],
        [
          SyntaxRun(range: 0..<3, kind: .keyword), SyntaxRun(range: 4..<5, kind: .plain),
          SyntaxRun(range: 6..<7, kind: .punctuation), SyntaxRun(range: 8..<9, kind: .number),
        ],
      ]
    )
  }

  @Test func unterminatedConstructsRunToTheEnd() {
    expectNoDifference(
      tokens("let s = \"abc\nlet t = 1", .swift),
      [
        [
          Token("let", .keyword), Token("s", .plain), Token("=", .punctuation),
          Token("\"abc", .string),
        ],
        [
          Token("let", .keyword), Token("t", .plain), Token("=", .punctuation),
          Token("1", .number),
        ],
      ]
    )
    expectNoDifference(
      tokens("x /* open\nlet y\n", .typescript),
      [[Token("x", .plain), Token("/* open", .comment)], [Token("let y", .comment)]]
    )
  }

  @Test func everyNonWhitespaceUnitIsCoveredOnce() {
    let source = """
      let 🎉 = ["a": 1, "b": 2.5e3] // done ✅
      let s = \"\"\"
      \tmulti 🎈 line
        \"\"\"
      x?.y!(z) ?? .none /* c */ + 0x1F
      """
    for (units, runs) in zip(displayLines(source), SyntaxLexer.lines(source, language: .swift)) {
      var covered = Array(repeating: 0, count: units.count)
      for run in runs { for offset in run.range { covered[offset] += 1 } }
      expectNoDifference(runs, runs.sorted { $0.range.lowerBound < $1.range.lowerBound })
      for (offset, unit) in units.enumerated() {
        let isWhitespace = unit == 32 || unit == 9
        #expect(isWhitespace ? covered[offset] <= 1 : covered[offset] == 1)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func lexesOneMebibyteInLinearTime() {
    let line = "const total = items.map((item) => item.price * 2); // \"sum\"\n"
    let source = String(repeating: line, count: 1_048_576 / line.utf8.count)
    #expect(SyntaxLexer.lines(source, language: .typescript).count == 1_048_576 / line.utf8.count)
    let minified = String(repeating: "a=b(\"c\")+1;", count: 1_048_576 / 11)
    #expect(SyntaxLexer.lines(minified, language: .typescript).count == 1)
  }
}
