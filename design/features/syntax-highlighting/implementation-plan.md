# Syntax Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. One PR, so `superpowers:executing-plans` is enough; `orchestrate-feature` isn't needed.

**Goal:** Colour change-stream card source lines and chat fenced code blocks by token kind with one muted palette, leaving the blue change marks and copy exactly as they are. Lines inside an Ask selection use the lifted colours.

**Architecture:** A pure, in-house lexer in `SlipstreamCore` turns a whole source text plus a `SyntaxLanguage` into per-line `SyntaxRun`s (UTF-16 ranges and a `SyntaxKind`). A card lexes the whole captured after-file, with tabs already expanded to the displayed 4 spaces, in `CardContentLoader` (off the main actor, cached with the card content), so each `CodeLine` gets runs in display offsets with no remapping. A chat block lexes its own text when `markdownBlocks` builds it. Views turn runs into an `AttributedString` through `DesignTokens.Syntax.styled`, the same pattern as `DesignTokens.Chat.Paragraph.styled`. Each card line stays one `Text`, so `ChangedTextRenderer` is untouched.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), Swift Testing, CustomDump. No new dependencies.

**Spec:** [`spec.md`](./spec.md). Screens: [`screens.md`](./screens.md). Endpoints and models: none (see the spec's Design deliverables).

**Base commit:** `95af09ccedbfd35c34e0049c4e58b53221de3b1b` (`develop`). Re-check that it is still `origin/develop` before branching.

## Global Constraints

- Before writing Swift code, invoke the `pfw-*` skills that apply: `pfw-testing` and `pfw-custom-dump` for every task, and `pfw-modern-swiftui` for Tasks 5 and 6. Subagents must invoke them too.
- Swift 6 language mode, complete strict concurrency, warnings are errors. Every new type is `Sendable`; the values tests compare (`SyntaxLanguage`, `SyntaxKind`, `SyntaxRun`) are also `Equatable`.
- `SlipstreamCore` has no SwiftUI and no Observation. Colours live only in `SlipstreamViewer/DesignTokens.swift`.
- Views contain zero logic. A view may call a `DesignTokens` styling function, as `MarkdownText` already does with `Chat.Paragraph.styled`.
- No new package dependency. The highlighter is in-house (decision: a package such as Splash covers Swift only, Highlightr needs JavaScriptCore and isn't `Sendable`, and tree-sitter brings C grammars and build complexity for nine languages).
- Supported languages and aliases are exactly the table in Task 1. Anything else is flat, as today.
- Palette (spec, scope 3), copied verbatim:

  | `SyntaxKind` | Base | Inside a change tint |
  |---|---|---|
  | `.keyword` | `#C3A6E6` | `#E3D6F4` |
  | `.string` | `#A9CF9B` | `#CBE2C2` |
  | `.number` (number, constant, enum case) | `#E5B98C` | `#F0D7BD` |
  | `.type` | `#8ECDC2` | `#BFE3DC` |
  | `.function` | `#E2D29A` | `#E8DBAE` |
  | `.comment` | `#8399AB` | `#D5DCE2` |
  | `.punctuation` | `#8DA2B4` | `#D5DDE3` |
  | `.plain` | `#C9D6E3` | `#D1DCE7` |

- Fallback is unchanged: an unsupported card is flat `DesignTokens.Colors.sourceLine` (`#BDCDDF`); an untagged or unknown chat fence is flat `DesignTokens.Chat.CodeBlock.color`.
- Never read the working-tree file. Cards lex the captured after-file blob that `CardContentLoader.fetch` already downloads.
- Commits carry no `Co-Authored-By` or other co-sign trailer.
- Test commands. Core: `swift test --filter <Suite>`. App (after `xcodegen generate`): `xcodebuild test -project SlipstreamViewer.xcodeproj -scheme SlipstreamViewer -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:SlipstreamViewerTests/<Suite>`. Before each commit, run the CI command without `-only-testing` (`/verify` can't run Xcode tests).

## Review Focus

1. **A snippet that starts inside a block comment or a multi-line string.** The card must colour it as a comment or string, not as code. Pinned in Task 5, `snippetInsideABlockCommentIsColouredAsComment`.
2. **Tabs before a token.** Runs must land on the displayed columns (tabs expand to 4 spaces), exactly as `changedRanges` do. Pinned in Task 5, `tabsShiftSyntaxRunsAndChangeMarksTogether`.
3. **Emoji, combining marks and CRLF line endings.** Ranges are UTF-16 and lines never include `\r`. Pinned in Task 2, `rangesAreUTF16AndIgnoreCarriageReturns`.
4. **Unterminated constructs** (an unclosed string, block comment, heredoc or chat fence). They colour to the end and never hang or crash. Pinned in Task 2, `unterminatedConstructsRunToTheEnd`, and Task 6, `unclosedFenceIsHighlighted`.
5. **A 1 MiB file or one huge minified line.** Lexing must be linear; the loader already rejects files over 1 MiB. Pinned in Task 2, `lexesOneMebibyteInLinearTime`, with `.timeLimit(.minutes(1))`.

---

### Task 1: Language resolver

**Files:**
- Create: `Sources/SlipstreamCore/SyntaxLanguage.swift`
- Test: `Tests/SlipstreamCoreTests/SyntaxLanguageTests.swift`

**Interfaces:**
- Produces:
  - `public enum SyntaxLanguage: Equatable, Sendable { case swift, typescript, json, yaml, shell, markdown, python, css, html }`
  - `public init?(path: String)` uses the last path component's extension, lowercased. A name with no `.` gives `nil`. A leading-dot name such as `.zshrc` also gives `nil`.
  - `public init?(fenceInfo: String)` uses the info string's first whitespace-separated word, lowercased. An empty info string gives `nil`.

Both initialisers look the word up in one alias table (spec scope 6), so an extension and a fence tag are interchangeable:

| Language | Aliases |
|---|---|
| `.swift` | `swift` |
| `.typescript` | `ts tsx js jsx mjs cjs typescript javascript` |
| `.json` | `json` |
| `.yaml` | `yml yaml` |
| `.shell` | `sh bash zsh` |
| `.markdown` | `md markdown` |
| `.python` | `py python` |
| `.css` | `css` |
| `.html` | `html htm` |

- [ ] **Step 1: Write the failing tests.** These are table-driven (`@Test(arguments:)`):
  - Every alias in the table maps to its language, both as a path extension and as a fence tag.
  - `"src/API/Create-User.TSX"` → `.typescript`; `"types.d.ts"` → `.typescript`.
  - `"Makefile"`, `"Dockerfile"`, `".zshrc"`, `"notes.txt"`, `"infra/nginx.conf"` → `nil`.
  - Fence info `"Swift"` → `.swift`; `"python title=x.py"` → `.python`; `""`, `"console"`, `"text"`, `"diff"` → `nil`.
- [ ] **Step 2:** Run `swift test --filter SyntaxLanguageTests`. Expected: it fails to compile because `SyntaxLanguage` is undefined.
- [ ] **Step 3:** Implement `SyntaxLanguage` with one private static `[String: SyntaxLanguage]` alias table.
- [ ] **Step 4:** Run `swift test --filter SyntaxLanguageTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: resolve a syntax language from a file path or fence tag`.

### Task 2: Lexer core, plus Swift, TypeScript/JavaScript and JSON

**Files:**
- Create: `Sources/SlipstreamCore/SyntaxLexer.swift`
- Test: `Tests/SlipstreamCoreTests/SyntaxLexerTests.swift`

**Interfaces:**
- Consumes: `SyntaxLanguage` (Task 1).
- Produces:
  - `public enum SyntaxKind: Equatable, Sendable { case keyword, string, number, type, function, comment, punctuation, plain }`
  - `public struct SyntaxRun: Equatable, Sendable { public var range: Range<Int>; public var kind: SyntaxKind }`. The range is in UTF-16 offsets into one line.
  - `public enum SyntaxLexer { public static func lines(_ source: String, language: SyntaxLanguage) -> [[SyntaxRun]] }`. It returns one array per line of `ChangedLines.split(source)`, with a trailing `"\r"` excluded exactly as `ChangedLines.displayText` does, so index `n - 1` is after-file line `n`. Every non-whitespace UTF-16 unit is covered by exactly one run. Whitespace between tokens is uncovered; whitespace inside a comment or string belongs to that run. Runs are sorted and never overlap. A token spanning lines (a block comment or multi-line string) becomes one run per line.

Lexical rules (spec, scope 7; when unsure, `.plain`):
- **Shared.** A keyword set → `.keyword`. `true false nil null undefined None True False` → `.number`. Numbers, including `0x…`, `1_000` and `1.5e3` → `.number`. An identifier starting with an uppercase letter → `.type`. An identifier directly followed by `(` (ignoring spaces) → `.function`. A member after a capitalised identifier and `.`, not followed by `(` (`ActivityState.Inactive`, `Color.red`) → `.number`, as the approved mockup colours it. Any other symbol → `.punctuation`.
- **Swift.** An implicit member, meaning an identifier right after a `.` whose previous non-whitespace character is not an identifier character, `)`, `]`, `?` or `!` (`!= .suspended`, `(.active`) → `.number`. `//` and nested `/* */` comments. `"…"`, `"""…"""` (multi-line) and raw `#"…"#` / `#"""…"""#` strings. `@attribute` and `#directive` → `.keyword`. Regex literals are not recognised.
- **TypeScript/JavaScript.** `//` and `/* */`. `'…'`, `"…"`, and backtick template strings, which can span lines and whose `${…}` stays `.string`. JSX markup and regex literals are not recognised; `<Foo` lexes as punctuation then type.
- **JSON.** Strings → `.string`. `//` and `/* */` comments are accepted.

- [ ] **Step 1: Write the failing tests.** Assert by token text through a test-local helper `tokens(_ source: String, _ language: SyntaxLanguage) -> [[Token]]`, where `struct Token: Equatable { var text: String; var kind: SyntaxKind }`, one array per line:
  - `swiftDeclarations`: `"func isAllowed(_ user: User) -> Bool {"` gives `func` keyword, `isAllowed` function, `User` and `Bool` type, `->`, `(`, `:` punctuation, `user` plain.
  - `swiftImplicitMember`: `"guard user.isActive != .suspended else { return false }"` gives `suspended` number, `false` number, `isActive` plain.
  - `swiftMultilineAndRawStrings`: a three-line `"""` string marks all three lines `.string`; `#"a "b" c"#` is a single `.string` run.
  - `nestedBlockComment`: `/* a /* b */ c */ let x` gives a comment through the final `*/`, then `let` keyword.
  - `typescriptTemplateSpansLines`: in `` "const a = `x\n${y}\nz`" ``, lines 2 and 3 are entirely `.string`.
  - `typescriptEnumMember`: `isActive: ActivityState.Inactive,` gives `ActivityState` type, `Inactive` number, `isActive` plain; `crypto.randomUUID()` gives `randomUUID` function.
  - `jsonValuesAndComments`: `{"id": 1, "ok": true} // c` gives `"id"` string, `1` and `true` number, `// c` comment.
  - `rangesAreUTF16AndIgnoreCarriageReturns`: `"let a = \"👩‍👩‍👧\"\r\nlet b = 1\r\n"` (`.swift`) has 2 lines; the string run is `8..<18`; no run on either line reaches past its last visible character.
  - `unterminatedConstructsRunToTheEnd`: an unclosed `"` colours to end of line; an unclosed `/*` colours every following line `.comment`; neither hangs.
  - `everyNonWhitespaceUnitIsCoveredOnce`: a short Swift fixture with punctuation, an emoji, a comment and a multi-line string; runs are sorted, never overlap, and cover every non-whitespace UTF-16 offset.
  - `lexesOneMebibyteInLinearTime` (`.timeLimit(.minutes(1))`): a 1 MiB TypeScript source made from repeated lines, and a 1 MiB single line, each lex without timing out.
- [ ] **Step 2:** Run `swift test --filter SyntaxLexerTests`. Expected: it fails to compile.
- [ ] **Step 3:** Implement `SyntaxLexer.lines`. Scan `Array(line.utf16)` per line with a small carried state (`inBlockComment(depth:)`, `inString(delimiter:)`) so lexing is one linear pass. One scanner, driven by each language's keywords and comment and string delimiters, serves Swift, TypeScript and JSON here and Python, shell and CSS in Task 3, with language-specific branches where a rule needs one. Task 3 adds small dedicated scanners for YAML, Markdown and HTML.
- [ ] **Step 4:** Run `swift test --filter SyntaxLexerTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: lex Swift, TypeScript and JSON into coloured runs`.

### Task 3: Python, shell, CSS, YAML, Markdown and HTML

**Files:**
- Modify: `Sources/SlipstreamCore/SyntaxLexer.swift`. Put the YAML, Markdown and HTML scanners in `Sources/SlipstreamCore/SyntaxLexer+Markup.swift`.
- Test: `Tests/SlipstreamCoreTests/SyntaxLexerTests.swift`

**Interfaces:**
- Consumes and produces `SyntaxLexer.lines` from Task 2, unchanged.

Rules (one language per source; embedded languages use the host rules). Anything not named here is `.plain` or `.punctuation`:
- **Python.** `#` comments. `'…'`, `"…"` and triple-quoted strings, which can span lines; prefixes `f r b rb` are part of the string. `@decorator` → `.keyword`.
- **Shell.** `#` comments, except inside a word such as `a#b`. `'…'` and `"…"` strings. `$VAR`, `${…}` and `$1` → `.type`. Keywords: `if then else elif fi for while until do done case esac function in return export local select`. A heredoc body after `<<WORD` or `<<'WORD'` is `.string` through the first line exactly equal to `WORD`. After `<<-WORD` or `<<-'WORD'`, leading whitespace is trimmed before that match. Cards lex tab-expanded text (S5), so a space-indented terminator also ends a `<<-` heredoc; the shell wouldn't accept it, but the only cost is colour. The terminator line is also `.string`.
- **CSS.** `/* */` comments. `@media`-style at-rules and `!important` → `.keyword`. An identifier before `:` → `.type`. Numbers with units and `#hex` colours → `.number`. Strings → `.string`. Selectors are plain.
- **YAML.** `#` comments, when at line start or after whitespace. A key before `: ` or a line-ending `:` → `.type`. Quoted and plain scalar values → `.string`. Numbers, `true false null ~` → `.number`. `- : --- ...` → `.punctuation`. After `|` or `>`, the more-indented lines that follow are `.string`.
- **Markdown.** A heading line (`#` to `######` then a space) → `.keyword` in full. A code span, or the content of a fenced block inside the file → `.string`. Everything else → `.plain`.
- **HTML.** `<!-- -->` comments, which can span lines. Tag names → `.keyword`. Attribute names → `.type`. Attribute values → `.string`. `< > / =` → `.punctuation`. `&entity;` → `.number`. Text → `.plain`. `<script>` and `<style>` bodies are plain text.

- [ ] **Step 1: Write the failing tests**, one per language, asserted by token text as in Task 2:
  - `pythonTripleQuotedAndDecorator`: `@dataclass` keyword; a `"""` docstring across 3 lines is `.string`; `None` number; `def load(` gives `load` function.
  - `shellVariablesAndHeredoc`: `echo "$HOME" ${PATH} # note` gives `"$HOME"` string, `${PATH}` type, `# note` comment; `cat <<EOF\nhi $x\nEOF\nls` gives lines 2–3 `.string` and `ls` plain.
  - `cssRules`: `@media (max-width: 600px) { .card { color: #fff !important; } }` gives `@media` keyword, `600px` number, `card` plain, `color` type, `#fff` number, `!important` keyword.
  - `yamlKeysValuesAndBlockScalar`: `name: app # c`, `port: 8080`, `on: true`, `run: |`, `  echo hi` gives `name`, `port`, `on`, `run` type; `app` string; `8080`, `true` number; `# c` comment; `  echo hi` string.
  - `markdownHeadingsAndCode`: `## Setup` keyword; `` `npm i` `` string; `snake_case words` plain; a fenced block's inner lines are string.
  - `htmlTagsAttributesAndComments`: `<a href="/x" class=y>Go &amp; see</a><!-- c\n-->` gives `a` keyword, `href` and `class` type, `"/x"` and `y` string, `&amp;` number, `Go` plain, both comment lines `.comment`.
  - Extend `unterminatedConstructsRunToTheEnd` with an unterminated heredoc and an unclosed `<!--`.
- [ ] **Step 2:** Run `swift test --filter SyntaxLexerTests`. Expected: the new tests FAIL.
- [ ] **Step 3:** Add Python, shell and CSS to the shared scanner and write the three markup scanners.
- [ ] **Step 4:** Run `swift test --filter SyntaxLexerTests`. Expected: PASS. Then run all of `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: lex Python, shell, CSS, YAML, Markdown and HTML`.

### Task 4: Syntax palette and styling

**Files:**
- Modify: `SlipstreamViewer/DesignTokens.swift`. Add `enum Syntax` next to `enum Card`.
- Test: `SlipstreamViewerTests/Views/Reusable Components/SyntaxStylingTests.swift`

**Interfaces:**
- Consumes: `SyntaxKind` and `SyntaxRun` (Task 2).
- Produces:
  - A private `color(_ kind: SyntaxKind, isTinted: Bool) -> Color` inside `DesignTokens.Syntax`, using the Global Constraints palette. Tests check colours through `styled`.
  - `DesignTokens.Syntax.styled(_ text: String, runs: [SyntaxRun], tintedRanges: [Range<Int>] = []) -> AttributedString` sets `foregroundColor` on each run's UTF-16 range. Where a run intersects a tinted range, the intersecting UTF-16 units get the tinted colour. Text outside every run gets no `foregroundColor`, so the view's `foregroundStyle` (the flat fallback) shows through. With `runs: []`, the result equals `AttributedString(text)`.

- [ ] **Step 1: Write the failing tests:**
  - `noRunsLeavesTextUnstyled`: `styled("a b", runs: [])` equals `AttributedString("a b")`.
  - `runsColourTheirRanges`: for `"let x"` with `[0..<3 .keyword, 4..<5 .plain]`, the `foregroundColor` runs are `#C3A6E6` over `let`, nil over the space, and `#C9D6E3` over `x`.
  - `tintLiftsOnlyTheTintedUnits`: for `"// note"` with `[0..<7 .comment]` and `tintedRanges: [3..<7]`, `0..<3` is `#8399AB` and `3..<7` is `#D5DCE2`.
  - `rangesAreUTF16`: for `"\"👍\" x"` with `[0..<4 .string, 5..<6 .plain]`, the emoji string is fully `#A9CF9B`.
- [ ] **Step 2:** Run the app tests with `-only-testing:SlipstreamViewerTests/SyntaxStylingTests`. Expected: they fail to compile.
- [ ] **Step 3:** Implement `Syntax.styled` and its private `color`. Convert UTF-16 offsets with `String.Index(utf16Offset:in:)`, then `AttributedString.Index`.
- [ ] **Step 4:** Run the same command. Expected: PASS.
- [ ] **Step 5:** Commit `feat: add the syntax palette and tint-aware styling`.

### Task 5: Change-stream cards

**Files:**
- Modify: `SlipstreamViewer/Models/FeedContent.swift`. Add `var syntaxRuns: [SyntaxRun] = []` to `CodeLine`, plus an `init` parameter defaulting to `[]`. The doc comment says the runs are UTF-16 offsets into `text`.
- Modify: `SlipstreamViewer/Models/CardContentLoader.swift`:
  - `fetch` passes `SyntaxLanguage(path: row.path)`.
  - `content(_:fallbackReason:before:after:isBeforeVerifiable:language:)` gains `language: SyntaxLanguage? = nil`. When it is non-nil, it lexes `after` once with every tab replaced by `tabWidth` spaces, so the runs are already in display offsets.
  - `codeLine` takes the line's runs (index `number - 1`) and stores them unchanged.
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageModel.swift`. Add `func sourceText(_ line: CodeLine, row: FileChangeRow, block: CodeBlock) -> AttributedString` under View Helpers, next to `highlightRect`. It returns `DesignTokens.Syntax.styled(line.text, runs: line.syntaxRuns, tintedRanges:)`. The tinted ranges are the whole line (`[0..<line.text.utf16.count]`) when the line is inside the Ask selection: the same session, row and block guard as `highlightRect`, and `line.id` within `context.lineStart...context.lineEnd`. Otherwise they are `line.changedRanges`. On the selection fill (`#315D7A`) the base colours fall to 2.2–3.3:1 and the lifted ones reach 5.1:1 (Brian, 2026-11-12).
- Modify: `SlipstreamViewer/Views/Pages/ChangeStreamPage/ChangeStreamPageView.swift:787`. Use `Text(model.sourceText(line, row: row, block: block))`, keeping `.foregroundStyle(DesignTokens.Colors.sourceLine)`, `.lineLimit(1)`, `.textRenderer(ChangedTextRenderer(line: line))` and the accessibility label.
- Modify: `SlipstreamViewerTests/Views/Pages/ChangeStreamPage/ChangeStreamPageTests.swift`:
  - `highlightedLines(before:after:clips:)` (line 1300) gains `path: String = "notes.txt"` and loads `Fixture.edited(1, path)`.
  - Existing tests that load a card through the fake with the default `src/user.ts` path and compare exact `CodeLine` values (around lines 1289, 1366, 1390, 1488, 1519, 1544, 1580) pass `Fixture.edited(1, "src/user.txt")`, so their expectations stay syntax-free and unchanged. Tests that call `CardContentLoader.content` directly already get `language: nil`.

**Interfaces:**
- Consumes: `SyntaxLanguage(path:)`, `SyntaxLexer.lines` and `DesignTokens.Syntax.styled` (Tasks 1, 2 and 4).
- Produces: `CodeLine.syntaxRuns`, in display UTF-16 offsets, and `ChangeStreamPageModel.sourceText(_:row:block:)`.

- [ ] **Step 1: Write the failing tests**, using `highlightedLines(..., path:)`:
  - `tabsShiftSyntaxRunsAndChangeMarksTogether`: the fixture of `tabsShiftHighlightsToTheDisplayedColumns` (before `"\tx\t= 1\n"`, after `"\tx\t= 2\n"`) on path `"a.swift"` gives `text == "    x    = 2"`, `sourceText == "\tx\t= 2"`, `changedRanges == [11..<12]` and `syntaxRuns == [4..<5 plain, 9..<10 punctuation, 11..<12 number]`.
  - `unsupportedFileHasNoSyntaxRuns`: path `"infra/nginx.conf"` gives `syntaxRuns == []` on every line.
  - `askSelectionLiftsEveryTokenOnSelectedLines`: on path `"a.ts"`, select line 2 of a three-line card with `sourceDragged`. In `sourceText`, line 2's `foregroundColor` runs use only the lifted column, while lines 1 and 3 use the base column. After `sourceDragEnded` and a cleared selection, line 2 uses the base column again.
  - `snippetInsideABlockCommentIsColouredAsComment`: path `"a.ts"`. After-file line 1 is `/*`, lines 2–4 are comment text, line 5 is `*/` and line 6 is `let y = 2`. A clip shows lines 3–6. Lines 3–5 are entirely `.comment`, and on line 6 `let` is `.keyword`.
- [ ] **Step 2:** Run with `-only-testing:SlipstreamViewerTests/ChangeStreamPageTests`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement the loader changes, `sourceText` and the view line. Lexing happens inside the existing `@concurrent load`, and the result is cached in `cardContents` with the rest of the content, so there are no new caches or generation checks.
- [ ] **Step 4:** Run the full `ChangeStreamPageTests`, `ChangedTextMarksTests` and `SourceSelectionTests` (`AskAgentPage/`), per the touched-area regression rule. Expected: PASS.
- [ ] **Step 5:** Commit `feat: colour change-stream card source lines`.

### Task 6: Chat reply code blocks

**Files:**
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/ChatTabModel.swift`, lines 212–260:
  - `case code(String)` (line 218) becomes `case code(String, runs: [SyntaxRun] = [])`. Ranges are UTF-16 offsets into the whole block's text. The default keeps every existing untagged `.code("…")` expectation compiling unchanged.
  - `markdownBlocks` (line 229) keeps the opening fence's info string (the text after the backticks).
  - `flush` (line 234) resolves `SyntaxLanguage(fenceInfo:)`. When it is non-nil, it lexes the joined code and shifts each line's runs by that line's start offset (each `\n` is 1 UTF-16 unit). Otherwise the runs are `[]`.
- Modify: `SlipstreamViewer/Views/Pages/ChatPage/MarkdownText.swift:45-47`. Match `.code(let code, let runs)` and render `Text(DesignTokens.Syntax.styled(code, runs: runs))`, keeping `.foregroundStyle(DesignTokens.Chat.CodeBlock.color)`.
- Test: `SlipstreamViewerTests/Views/Pages/ChatPage/ChatPageTests.swift`

**Interfaces:**
- Consumes: `SyntaxLanguage(fenceInfo:)`, `SyntaxLexer.lines` and `DesignTokens.Syntax.styled` (Tasks 1, 2 and 4).
- Produces: `ChatTabModel.MarkdownBlock.code(String, runs: [SyntaxRun] = [])`.

`markdownBlocks` runs inside `MarkdownText.body` (`MarkdownText.swift:10`), so chat lexes on every redraw, as Markdown parsing already does. This is accepted: chat code blocks are small and the lexer is linear (Phase 7 disposition S9).

- [ ] **Step 1: Write the failing tests:**
  - `runsAreOffsetAcrossLines`: ```` "```swift\na\nlet b\n```" ```` gives `.code("a\nlet b", runs: [0..<1 plain, 2..<5 keyword, 6..<7 plain])`.
  - `untaggedAndUnknownFencesStayFlat`: ```` ``` ```` and ```` ```console ```` blocks give `runs: []`.
  - `unclosedFenceIsHighlighted`: ```` "```py\nx = None" ```` (no closing fence) gives runs with `None` as `.number`.
  - `longerFenceKeepsInnerFencesAsCode` (line 1672) opens with ```` ````markdown ````, so its first expectation (line 1687) gains Markdown runs. It is the only existing expectation that changes.
- [ ] **Step 2:** Run with `-only-testing:SlipstreamViewerTests/ChatPageTests`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement. Copy keeps using `rowText(for:)` (`ChatTabModel.swift:130`), so the copied text is unchanged.
- [ ] **Step 4:** Run the full `ChatPageTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: colour fenced code in chat replies`.

### Task 7: Release note and visual check

**Files:**
- Create: `changelog.d/syntax-highlighting.md`

- [ ] **Step 1:** Write the note:

  ```markdown
  ### Changes

  - Code in change-stream cards and in chat replies is now coloured by syntax for Swift,
    TypeScript/JavaScript, JSON, YAML, shell, Markdown, Python, CSS and HTML. Changed text
    keeps its blue marks and stays easy to read.
  ```

- [ ] **Step 2:** Run the full CI command (`swift test`, then `xcodegen generate` and the `xcodebuild test` line from `.github/workflows/swift-test.yml`). Expected: everything passes with no warnings.
- [ ] **Step 3: Visual check against `screens.md`.** Use a disposable daemon (`SLIPSTREAM_STORE` plus `npm run qa:daemon` in the daemon repo, never `~/.slipstream`). Edit a `.ts` file, a `.conf` file and a file with tabs and an emoji, and ask an agent for a `swift` fence and an untagged fence. Compare against the five PNGs, and confirm that:
  - the marker, tint and tick are unchanged, and tinted words use the lifted colours;
  - Ask selection still selects lines, and the selected lines use the lifted colours;
  - long lines still truncate, and chat code scrolls horizontally;
  - Copy on a reply gives the original text.
- [ ] **Step 4:** Commit `docs: release note for syntax highlighting`.

## Simplicity gate (Phase 7, 2026-11-12)

Codex (`gpt-6-astra`) and a Claude Opus reviewer, run in parallel and read-only against the code. Neither found a simpler whole approach: no Apple framework colours code, Splash is Swift-only, Highlightr (highlight.js via JavaScriptCore) is unmaintained, not `Sendable`, misses the scope-7 guesses and colours HTML's embedded script, and tree-sitter is heavier.

| # | Finding | Source | Disposition |
|---|---|---|---|
| S1 | "Whitespace is never covered" contradicts whole comment and string runs | both | Adopted (Task 2 interface) |
| S2 | A universal `Rules` value can't serve heredocs, YAML, Markdown and HTML | both | Adopted: one shared scanner plus three markup scanners |
| S3 | Drop `String` raw values and `CaseIterable`; `Equatable` only where compared | both | Adopted |
| S4 | Merge the card helper into `highlightedLines` and the three card tests into one | both | Adopted (Task 5) |
| S5 | Lex tab-expanded text and delete the tab offset mapping | Opus | Adopted. `<<WORD` needs an exact terminator line; `<<-WORD` trims leading whitespace, so it can't tell tabs from spaces (colour-only edge case) |
| S6 | Implicit-member rule is Swift-only and defined negatively (`f(...args)` broke it) | Opus | Adopted; added `Type.Member` → number to match the approved mockup |
| S7 | One alias table; drop `mts cts jsonc pyi python3 shell`, which are outside scope 5 | Opus | Adopted |
| S8 | `runs` defaults to `[]`; delete the duplicate tagged-fence test; `color` is private | Opus | Adopted |
| S9 | Chat lexes on every redraw because `markdownBlocks` runs in `body` | both | Accepted with rationale: it matches today's Markdown parsing, blocks are small and the lexer is linear. Spec R5 corrected. |
| S10 | Trim unrequired rules: Markdown markers and links, CSS selectors, YAML anchors and tags, JSON keys as type | Opus | Adopted; none appear in the approved screens |
| S11 | Existing card tests with exact `CodeLine` values would pick up runs | Opus | Adopted: those loads use a `.txt` path (Task 5) |

After the plan was approved, CodeRabbit flagged two contrast failures on the PR. Brian chose both fixes (2026-11-12): the comment base moves from `#7D93A5` (4.42:1) to `#8399AB` (4.77:1), and lines inside an Ask selection use the lifted colours (`sourceText`, Task 5).

## Unresolved questions

None. The highlighter is in-house (Global Constraints), confirmed by the simplicity gate.
