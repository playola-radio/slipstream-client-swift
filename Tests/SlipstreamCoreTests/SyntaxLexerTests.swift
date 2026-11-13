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

  @Test func pythonTripleQuotedAndDecorator() {
    let source = """
      @dataclass
      def load(path):
          \"\"\"Load it.
          More.
          \"\"\"
          return None
      x = f"hi {y}"  # note
      """
    expectNoDifference(
      tokens(source, .python),
      [
        [Token("@dataclass", .keyword)],
        [
          Token("def", .keyword), Token("load", .function), Token("(", .punctuation),
          Token("path", .plain), Token(")", .punctuation), Token(":", .punctuation),
        ],
        [Token("\"\"\"Load it.", .string)],
        [Token("    More.", .string)],
        [Token("    \"\"\"", .string)],
        [Token("return", .keyword), Token("None", .number)],
        [
          Token("x", .plain), Token("=", .punctuation), Token("f\"hi {y}\"", .string),
          Token("# note", .comment),
        ],
      ]
    )
  }

  @Test func shellVariablesAndHeredoc() {
    let source = """
      echo "$HOME" ${PATH} $1 # note
      a#b
      deploy() {
      if x; then
      cat <<EOF
      hi $x
      EOF
      ls
      """
    expectNoDifference(
      tokens(source, .shell),
      [
        [
          Token("echo", .plain), Token("\"$HOME\"", .string), Token("${PATH}", .type),
          Token("$1", .type), Token("# note", .comment),
        ],
        [Token("a", .plain), Token("#", .punctuation), Token("b", .plain)],
        [
          Token("deploy", .function), Token("(", .punctuation), Token(")", .punctuation),
          Token("{", .punctuation),
        ],
        [Token("if", .keyword), Token("x", .plain), Token(";", .punctuation), Token("then", .keyword)],
        [Token("cat", .plain), Token("<<", .punctuation), Token("EOF", .string)],
        [Token("hi $x", .string)],
        [Token("EOF", .string)],
        [Token("ls", .plain)],
      ]
    )
  }

  @Test func shellIndentedHeredocTrimsLeadingWhitespace() {
    expectNoDifference(
      tokens("cat <<-'END'\n\tx\n    END\nfi", .shell),
      [
        [Token("cat", .plain), Token("<<-", .punctuation), Token("'END'", .string)],
        [Token("\tx", .string)],
        [Token("    END", .string)],
        [Token("fi", .keyword)],
      ]
    )
  }

  @Test func shellLeftShiftIsNotAHeredoc() {
    for source in ["echo $((1 << 2))\necho hi", "(( x << y ))\necho hi"] {
      expectNoDifference(tokens(source, .shell)[1], tokens("echo hi", .shell)[0])
    }
  }

  @Test func shellArithmeticSpansLines() {
    expectNoDifference(
      tokens("v=$((1 +\n  2 << foo\n))\necho hi", .shell)[3], tokens("echo hi", .shell)[0])
  }

  @Test func shellHeredocWordKeepsItsPunctuation() {
    let source = "cat <<END-OF-FILE\nbody\nEND-OF-FILE\necho hi"
    expectNoDifference(tokens(source, .shell)[3], tokens("echo hi", .shell)[0])
  }

  @Test func cssRules() {
    expectNoDifference(
      tokens("@media (max-width: 600px) { .card { color: #fff !important; } } /* c */", .css),
      [
        [
          Token("@media", .keyword), Token("(", .punctuation), Token("max-width", .type),
          Token(":", .punctuation), Token("600px", .number), Token(")", .punctuation),
          Token("{", .punctuation), Token(".", .punctuation), Token("card", .plain),
          Token("{", .punctuation), Token("color", .type), Token(":", .punctuation),
          Token("#fff", .number), Token("!important", .keyword), Token(";", .punctuation),
          Token("}", .punctuation), Token("}", .punctuation), Token("/* c */", .comment),
        ]
      ]
    )
  }

  @Test func yamlKeysValuesAndBlockScalar() {
    let source = """
      ---
      name: app # c
      port: 8080
      on: true
      run: |
        echo hi

        echo bye
      - "quoted: x"
      """
    expectNoDifference(
      tokens(source, .yaml),
      [
        [Token("---", .punctuation)],
        [
          Token("name", .type), Token(":", .punctuation), Token("app", .string),
          Token("# c", .comment),
        ],
        [Token("port", .type), Token(":", .punctuation), Token("8080", .number)],
        [Token("on", .type), Token(":", .punctuation), Token("true", .number)],
        [Token("run", .type), Token(":", .punctuation), Token("|", .punctuation)],
        [Token("  echo hi", .string)],
        [],
        [Token("  echo bye", .string)],
        [Token("-", .punctuation), Token("\"quoted: x\"", .string)],
      ]
    )
  }

  @Test func yamlEmptyKeyIsJustItsColon() {
    expectNoDifference(
      tokens("  : foo\n- : bar", .yaml),
      [
        [Token(":", .punctuation), Token("foo", .string)],
        [Token("-", .punctuation), Token(":", .punctuation), Token("bar", .string)],
      ]
    )
  }

  @Test func yamlSequenceBlockScalarKeepsItsBody() {
    expectNoDifference(
      tokens("- |\n  key: value", .yaml),
      [[Token("-", .punctuation), Token("|", .punctuation)], [Token("  key: value", .string)]]
    )
  }

  @Test func markdownHeadingsAndCode() {
    let source = """
      ## Setup
      Run `npm i` then snake_case words
      ```sh
        npm test
      ```
      """
    expectNoDifference(
      tokens(source, .markdown),
      [
        [Token("## Setup", .keyword)],
        [
          Token("Run", .plain), Token("`npm i`", .string), Token("then", .plain),
          Token("snake_case", .plain), Token("words", .plain),
        ],
        [Token("```sh", .plain)],
        [Token("  npm test", .string)],
        [Token("```", .plain)],
      ]
    )
  }

  @Test func htmlTagsAttributesAndComments() {
    expectNoDifference(
      tokens("<a href=\"/x\" class=y>Go &amp; see</a><!-- c\n-->", .html),
      [
        [
          Token("<", .punctuation), Token("a", .keyword), Token("href", .type),
          Token("=", .punctuation), Token("\"/x\"", .string), Token("class", .type),
          Token("=", .punctuation), Token("y", .string), Token(">", .punctuation),
          Token("Go", .plain), Token("&amp;", .number), Token("see", .plain),
          Token("</", .punctuation), Token("a", .keyword), Token(">", .punctuation),
          Token("<!-- c", .comment),
        ],
        [Token("-->", .comment)],
      ]
    )
  }

  @Test func htmlTagSpansLines() {
    expectNoDifference(
      tokens("<div\n  id=\"x\">", .html),
      [
        [Token("<", .punctuation), Token("div", .keyword)],
        [
          Token("id", .type), Token("=", .punctuation), Token("\"x\"", .string),
          Token(">", .punctuation),
        ],
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
    expectNoDifference(
      tokens("cat <<EOF\nhi\n", .shell),
      [[Token("cat", .plain), Token("<<", .punctuation), Token("EOF", .string)], [Token("hi", .string)]]
    )
    expectNoDifference(
      tokens("<!-- open\n<a>", .html),
      [[Token("<!-- open", .comment)], [Token("<a>", .comment)]]
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
    let hashes = String(repeating: "#", count: 1_048_576)
    #expect(SyntaxLexer.lines(hashes, language: .swift).count == 1)
    let ticks = (1...1_400).map { String(repeating: "`", count: $0) }.joined(separator: " ")
    #expect(SyntaxLexer.lines(ticks, language: .markdown).count == 1)
  }

  @Test func shortInputsGiveOrderedRunsInsideTheLine() {
    let alphabet = [" ", "a", "1", ":", "-", "#", "\"", "'", "`", "<", ">", "&", ";", "=", "/", "*", "\\", "$", "(", "\n"]
    var inputs = [""]
    for _ in 1...3 { inputs = inputs.flatMap { prefix in alphabet.map { prefix + $0 } } }
    let languages: [SyntaxLanguage] = [.swift, .typescript, .json, .yaml, .shell, .markdown, .python, .css, .html]
    for language in languages {
      for input in inputs {
        for (units, runs) in zip(displayLines(input), SyntaxLexer.lines(input, language: language)) {
          var end = 0
          for run in runs {
            #expect(run.range.lowerBound >= end && run.range.upperBound <= units.count, "\(language) \(input.debugDescription)")
            end = run.range.upperBound
          }
        }
      }
    }
  }
}
