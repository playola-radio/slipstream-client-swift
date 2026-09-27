import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct InterfaceCorpusTests {
  @Test(arguments: try InterfaceFixtures.successCaseNames())
  func decodesAndAgreesWithTheRawFixture(caseName: String) throws {
    let data = try InterfaceFixtures.expected(caseName)
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    expectNoDifference(summary(try InterfaceComparison.decode(data)), summary(raw))
  }

  @Test func coversEveryOutcomeTheCorpusRecords() throws {
    let comparisons = try InterfaceFixtures.successCaseNames().map { try InterfaceComparison.decode(InterfaceFixtures.expected($0)) }
    let files = comparisons.flatMap(\.files)
    let rows = files.flatMap { rowsOf($0.changes) }
    expectNoDifference(comparisons.count, 62)
    expectNoDifference(files.count, 66)
    expectNoDifference(rows.count, 37)
    expectNoDifference(tally(comparisons.map { label($0.status) }), ["partial": 17, "ready": 44, "skipped(overloaded)": 1])
    expectNoDifference(
      tally(files.map { label($0.status).split(separator: "(").first.map(String.init) ?? "" }),
      ["identical": 6, "incomplete": 6, "ready": 42, "skipped": 3, "unavailable": 8, "unsupported": 1]
    )
    expectNoDifference(tally(files.map { language($0.changes) }), ["-": 3, "swift/swift.v1": 24, "typescript/typescript.v2": 39])
    expectNoDifference(tally(rows.map { kindName($0.kind) }), ["added": 6, "removed": 6, "signatureChanged": 25])
    expectNoDifference(files.filter { $0.before == .unknownBoundary }.count, 2)
    expectNoDifference(files.filter { $0.after.gapRef != nil }.count, 1)
    expectNoDifference(rows.filter { $0.result == nil }.count, 1)
  }
}

struct InterfaceFixtureValueTests {
  private let sessionID = "11111111-1111-4111-8111-111111111111"
  private let baseline = InterfaceInventory(baselineCompletedSeq: Seq("3"), unknownScopes: [], unknownScopesComplete: true)
  private let finished = InterfacePage(complete: true, nextAfterPath: nil)

  private func content(_ sha256: String, _ size: Int) -> Snapshot {
    .content(sha256: sha256, size: size)
  }

  private func number(_ position: Int, _ name: String, _ type: String) -> InterfaceParameter {
    InterfaceParameter(position: position, name: name, type: .written(type))
  }

  private var tsVoid: InterfaceDelta<InterfaceResult> { .equal(.returnType(.written("void"))) }
  private var tsThrows: InterfaceDelta<InterfaceThrowsClause> { .equal(InterfaceThrowsClause(mode: .notExpressible)) }
  private var emptyHeader: InterfaceDelta<InterfaceHeader> { .equal(InterfaceHeader()) }

  @Test func typescriptParameterChange() throws {
    expectNoDifference(
      try InterfaceComparison.decode(InterfaceFixtures.expected("ts-parameter-change")),
      InterfaceComparison(
        sessionID: sessionID,
        beforeSeq: Seq("3")!,
        afterSeq: Seq("4")!,
        status: .ready,
        inventory: baseline,
        gaps: [],
        gapsComplete: true,
        files: [
          InterfaceFileResult(
            path: "src/f.ts",
            before: .recorded(
              InterfaceRecord(
                recordSeq: Seq("2")!, field: .snapshot,
                snapshot: content("86e1381da984ad21459e1e796d08963d95ee1ef6eca5987ecf6fa1fef5d64e46", 31)
              )
            ),
            after: InterfaceRecord(
              recordSeq: Seq("4")!, field: .after,
              snapshot: content("a0f5933b9b22cb5a09402ec1d063c10504d634ea717c939360f5fde690a4be6d", 31),
              observation: .watcher
            ),
            status: .ready,
            beforeCoverage: .complete,
            afterCoverage: .complete,
            changes: .typescript([
              InterfaceChange(
                kind: .signatureChanged(
                  before: InterfaceDeclaration(displayName: "f", byteRange: 0..<30),
                  after: InterfaceDeclaration(displayName: "f", byteRange: 0..<30)
                ),
                identity: InterfaceIdentity(kind: "function", scope: [], name: "f", guards: []),
                parameters: [.changed(before: number(0, "x", "number"), after: number(0, "x", "string"))],
                result: tsVoid,
                throwsClause: tsThrows,
                header: emptyHeader
              )
            ])
          )
        ],
        page: finished
      )
    )
  }

  @Test func swiftLabelsDefaultsAndEffects() throws {
    let file = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("swift-labels-defaults-effects")).files.first)
    let point = { (label: String) in
      InterfaceParameter(position: 0, label: label, name: "point", type: .written("Point"), modifiers: ["inout"])
    }
    let count = { (defaultValue: String) in
      InterfaceParameter(position: 1, name: "count", type: .written("Int"), defaultValue: defaultValue)
    }
    expectNoDifference(
      file.changes,
      .swift([
        InterfaceChange(
          kind: .signatureChanged(
            before: InterfaceDeclaration(displayName: "move(from:count:)", byteRange: 0..<80),
            after: InterfaceDeclaration(displayName: "move(at:count:)", byteRange: 0..<78)
          ),
          identity: InterfaceIdentity(kind: "function", scope: [], name: "move", guards: []),
          parameters: [
            .changed(before: point("from"), after: point("at")),
            .changed(before: count("1"), after: count("2")),
          ],
          result: .equal(.returnType(.written("Bool"))),
          throwsClause: .equal(InterfaceThrowsClause(mode: .throwing)),
          header: .equal(InterfaceHeader(modifiers: ["async"]))
        )
      ])
    )
  }

  @Test func swiftFailableInitializer() throws {
    let file = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("swift-init-failable")).files.first)
    let row = try #require(rowsOf(file.changes).first)
    expectNoDifference(row.identity, InterfaceIdentity(kind: "initializer", scope: [.init(kind: "struct", name: "P")], name: "init", guards: []))
    expectNoDifference(row.result, .changed(before: .initializer(failable: nil), after: .initializer(failable: .optional)))
    expectNoDifference(row.throwsClause, .equal(InterfaceThrowsClause(mode: .notWritten)))
  }

  @Test func typescriptConstructorHasNoResultSlot() throws {
    let file = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("ts-constructor-change")).files.first)
    let row = try #require(rowsOf(file.changes).first)
    expectNoDifference(row.identity.kind, "constructor")
    expectNoDifference(row.result, nil)
  }

  @Test func parameterRowsKeepTheDaemonsOrder() throws {
    let file = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("ts-parameter-reorder")).files.first)
    expectNoDifference(
      try #require(rowsOf(file.changes).first).parameters,
      [
        .changed(before: number(0, "a", "number"), after: number(1, "a", "number")),
        .removed(number(1, "b", "number")),
        .changed(before: number(2, "c", "number"), after: number(0, "c", "number")),
      ]
    )
  }

  @Test func reconciliationKeepsItsGapReference() throws {
    let comparison = try InterfaceComparison.decode(InterfaceFixtures.expected("range-restart-reconciliation"))
    expectNoDifference(comparison.gaps, [InterfaceGap(seq: Seq("4")!, reason: .restart, scope: .session)])
    expectNoDifference(
      comparison.files.first?.after,
      InterfaceRecord(
        recordSeq: Seq("5")!, field: .after,
        snapshot: content("a0f5933b9b22cb5a09402ec1d063c10504d634ea717c939360f5fde690a4be6d", 31),
        observation: .reconciliation, gapRef: Seq("4")!
      )
    )
  }

  @Test func unknownBoundaryIsNotAnAbsentFile() throws {
    let comparison = try InterfaceComparison.decode(InterfaceFixtures.expected("ts-unknown-boundary"))
    expectNoDifference(comparison.beforeSeq, .zero)
    let file = try #require(comparison.files.first)
    expectNoDifference(file.before, .unknownBoundary)
    expectNoDifference(file.status, .unavailable(reason: "before-unknown-boundary"))
    expectNoDifference(file.beforeCoverage, .unavailable(reason: "unknown-boundary"))
    expectNoDifference(file.changes, .typescript([]))
  }

  @Test func missingBlobIsUnavailableCoverageOverContent() throws {
    let file = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("swift-missing-blob")).files.first)
    expectNoDifference(
      file.before,
      .recorded(
        InterfaceRecord(
          recordSeq: Seq("2")!, field: .snapshot,
          snapshot: content("c8b5c7f8d1396e03d98a7704dcfe46b69f6aae0f9504c5eb838fbcba58cd3ab8", 20)
        )
      )
    )
    expectNoDifference(file.status, .unavailable(reason: "before-blob-missing"))
    expectNoDifference(file.beforeCoverage, .unavailable(reason: "blob-missing"))
  }

  @Test func partialPageListsEachFailure() throws {
    let comparison = try InterfaceComparison.decode(InterfaceFixtures.expected("range-all-failed-page"))
    expectNoDifference(comparison.status, .partial)
    expectNoDifference(comparison.files.map(\.status), [
      .incomplete(reason: "before-parse-error"),
      .unavailable(reason: "before-blob-missing"),
    ])
    expectNoDifference(comparison.files.map(\.beforeCoverage), [
      .incomplete(reason: "parse-error"),
      .unavailable(reason: "blob-missing"),
    ])
  }

  @Test func skippedPageHasNoFilesAndDoesNotAdvance() throws {
    expectNoDifference(
      try InterfaceComparison.decode(InterfaceFixtures.expected("range-admission-skipped")),
      InterfaceComparison(
        sessionID: sessionID,
        beforeSeq: Seq("3")!,
        afterSeq: Seq("4")!,
        status: .skipped(.overloaded),
        inventory: baseline,
        gaps: [],
        gapsComplete: true,
        files: [],
        page: InterfacePage(complete: false, nextAfterPath: nil)
      )
    )
  }

  @Test func pathWithoutALanguageModule() throws {
    let file = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("py-unsupported-language")).files.first)
    expectNoDifference(file.status, .unsupported(reason: "unsupported-language"))
    expectNoDifference(file.changes, .noLanguageModule)
    expectNoDifference(file.beforeCoverage, .unsupported)
  }

  @Test func identicalIsDistinctFromReadyWithNoRows() throws {
    let identical = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("range-reverted-listed")).files.first)
    expectNoDifference(identical.status, .identical)
    expectNoDifference(identical.beforeCoverage, .notEvaluated)
    let unchanged = try #require(try InterfaceComparison.decode(InterfaceFixtures.expected("ts-unchanged-signature")).files.first)
    expectNoDifference(unchanged.status, .ready)
    expectNoDifference(unchanged.changes, .typescript([]))
  }

  @Test func firstPageCarriesTheCursor() throws {
    let comparison = try InterfaceComparison.decode(InterfaceFixtures.expected("range-page-boundary-first"))
    expectNoDifference(comparison.page, InterfacePage(complete: false, nextAfterPath: "src/a.ts"))
  }

  @Test func cappedMetadataIsMarkedIncomplete() throws {
    let comparison = try InterfaceComparison.decode(InterfaceFixtures.expected("range-gap-cap"))
    expectNoDifference(comparison.gapsComplete, false)
    expectNoDifference(comparison.inventory.unknownScopesComplete, false)
  }
}

struct InterfaceSyntheticTests {
  @Test func seqsBeyondUInt64AreKeptExactly() throws {
    let comparison = try InterfaceComparison.decode(
      edited(
        "ts-parameter-change",
        (#""before_seq":"3""#, #""before_seq":"18446744073709551617""#),
        (#""after_seq":"4""#, #""after_seq":"340282366920938463463374607431768211457""#),
        (#""record_seq":"4""#, #""record_seq":"340282366920938463463374607431768211457""#)
      )
    )
    expectNoDifference(comparison.beforeSeq.decimal, "18446744073709551617")
    expectNoDifference(comparison.afterSeq.decimal, "340282366920938463463374607431768211457")
    expectNoDifference(comparison.files.first?.after.recordSeq.decimal, "340282366920938463463374607431768211457")
  }

  @Test func typeStatesStayDistinct() throws {
    let comparison = try InterfaceComparison.decode(
      edited(
        "ts-parameter-change",
        (#"{"state":"written","text":"number"}"#, #"{"state":"unknown","reason":"inferred-not-computed"}"#),
        (#"{"state":"written","text":"string"}"#, #"{"state":"written","text":"unknown"}"#)
      )
    )
    let row = try firstRow(comparison)
    expectNoDifference(
      row.parameters,
      [
        .changed(
          before: InterfaceParameter(position: 0, name: "x", type: .inferredNotComputed),
          after: InterfaceParameter(position: 0, name: "x", type: .written("unknown"))
        )
      ]
    )
  }

  @Test func typedThrowsAndRethrows() throws {
    let comparison = try InterfaceComparison.decode(
      edited(
        "swift-labels-defaults-effects",
        (
          #""throws":{"op":"equal","before":{"mode":"throws"},"after":{"mode":"throws"}}"#,
          #""throws":{"op":"changed","before":{"mode":"throws","type":"ParseError"},"after":{"mode":"rethrows"}}"#
        )
      )
    )
    let row = try firstRow(comparison)
    expectNoDifference(
      row.throwsClause,
      .changed(before: InterfaceThrowsClause(mode: .throwing, type: "ParseError"), after: InterfaceThrowsClause(mode: .rethrowing))
    )
  }

  @Test func implicitlyUnwrappedInitializer() throws {
    let comparison = try InterfaceComparison.decode(edited("swift-init-failable", (#""failable":"?""#, #""failable":"!""#)))
    let row = try firstRow(comparison)
    expectNoDifference(row.result, .changed(before: .initializer(failable: nil), after: .initializer(failable: .implicitlyUnwrapped)))
  }

  @Test func changedTextThatOnlyDiffersInNormalizationIsKept() throws {
    let comparison = try InterfaceComparison.decode(
      edited(
        "ts-parameter-change",
        (#"{"state":"written","text":"number"}"#, #"{"state":"written","text":"\u00e9"}"#),
        (#"{"state":"written","text":"string"}"#, #"{"state":"written","text":"e\u0301"}"#)
      )
    )
    let row = try firstRow(comparison)
    expectNoDifference(
      row.parameters,
      [
        .changed(
          before: InterfaceParameter(position: 0, name: "x", type: .written("\u{e9}")),
          after: InterfaceParameter(position: 0, name: "x", type: .written("e\u{301}"))
        )
      ]
    )
  }

  @Test func unknownProjectionVersionIsRejectedBeforeItsBody() throws {
    #expect(throws: InterfaceDecodingError.unsupportedProjectionVersion("interface.v3")) {
      try InterfaceComparison.decode(Data(#"{"projection_version":"interface.v3","files":"anything"}"#.utf8))
    }
    #expect(throws: InterfaceDecodingError.unsupportedProjectionVersion("interface.v3")) {
      try InterfaceComparison.decode(edited("ts-parameter-change", (#""interface.v2""#, #""interface.v3""#)))
    }
  }

  @Test(arguments: [
    (#""typescript","language_version":"typescript.v2""#, #""typescript","language_version":"typescript.v3""#, "typescript", "typescript.v3"),
    (#""typescript","language_version":"typescript.v2""#, #""swift","language_version":"typescript.v2""#, "swift", "typescript.v2"),
    (#""typescript","language_version":"typescript.v2""#, #""kotlin","language_version":"kotlin.v1""#, "kotlin", "kotlin.v1"),
  ])
  func unsupportedLanguageVersionIsExplicit(find: String, replace: String, language: String, version: String) throws {
    let comparison = try InterfaceComparison.decode(
      edited("ts-parameter-change", (find, replace), (#""changes":[{"kind""#, #""changes":[{"future":true},{"kind""#))
    )
    expectNoDifference(comparison.files.first?.changes, .unsupportedLanguageVersion(language: language, version: version))
  }

  @Test(arguments: [
    Mutation("ts-parameter-change", "not JSON", #"{"projection_version""#, #"{"projection_version"#),
    Mutation("ts-parameter-change", "missing projection version", #""projection_version":"interface.v2","#, ""),
    Mutation("ts-parameter-change", "missing required nullable key", #","next_after_path":null"#, ""),
    Mutation("ts-parameter-change", "null for an optional key", #""status":"ready","coverage""#, #""status":"ready","fallback_reason":null,"coverage""#),
    Mutation("ts-parameter-change", "unknown row kind", #""kind":"signatureChanged""#, #""kind":"renamed""#),
    Mutation("ts-parameter-change", "non-canonical seq", #""record_seq":"4""#, #""record_seq":"04""#),
    Mutation("ts-parameter-change", "zero record seq", #""record_seq":"4""#, #""record_seq":"0""#),
    Mutation("ts-parameter-change", "range runs backwards", #""before_seq":"3""#, #""before_seq":"5""#),
    Mutation("ts-parameter-change", "analysis claimed", #""effects":"notAnalyzed""#, #""effects":"analyzed""#),
    Mutation("ts-parameter-change", "unknown policy exclusion", #""symlinks""#, #""node_modules""#),
    Mutation("ts-parameter-change", "reason on a ready file", #""status":"ready","coverage""#, #""status":"ready","fallback_reason":"x","coverage""#),
    Mutation("ts-parameter-change", "equal delta with different sides", #"[{"op":"changed","before":{"position":0"#, #"[{"op":"equal","before":{"position":0"#),
    Mutation("ts-parameter-change", "unsupported version without changes", #""typescript.v2""#, #""typescript.v3""#, #","changes":[{"#, #","rows":[{"#),
    Mutation("ts-parameter-change", "ready file with unavailable coverage", #""before":{"state":"complete"}"#, #""before":{"state":"unavailable","reason":"blob-missing"}"#),
    Mutation("ts-unknown-boundary", "unknown boundary covered as absent", #""before":{"state":"unavailable","reason":"unknown-boundary"}"#, #""before":{"state":"absent"}"#),
    Mutation("swift-capture-unavailable", "unavailable capture covered as complete", #""before":{"state":"unavailable","reason":"oversize"}"#, #""before":{"state":"complete"}"#),
    Mutation("ts-parameter-change", "content covered as absent", #""before":{"state":"complete"}"#, #""before":{"state":"absent"}"#),
    Mutation("range-reverted-listed", "identical file that was evaluated", #""before":{"state":"notEvaluated"}"#, #""before":{"state":"complete"}"#),
    Mutation("ts-parameter-change", "typescript function without a result slot", #""result":{"op":"equal","before":{"kind":"return","type":{"state":"written","text":"void"}},"after":{"kind":"return","type":{"state":"written","text":"void"}}}"#, #""result":null"#),
    Mutation("swift-labels-defaults-effects", "swift declaration without a result slot", #""result":{"op":"equal","before":{"kind":"return","type":{"state":"written","text":"Bool"}},"after":{"kind":"return","type":{"state":"written","text":"Bool"}}}"#, #""result":null"#),
    Mutation("ts-parameter-change", "policy exclusions not exact", #"["store-directory",".git","symlinks"]"#, #"[]"#),
    Mutation("ts-parameter-change", "added delta with a before side", #"{"op":"changed","before":{"position":0"#, #"{"op":"added","before":{"position":0"#),
    Mutation("ts-parameter-change", "added row with a before side", #""kind":"signatureChanged""#, #""kind":"added""#),
    Mutation("ts-parameter-change", "span runs backwards", #""byte_start":0,"byte_end":30}},"parameters""#, #""byte_start":31,"byte_end":30}},"parameters""#),
    Mutation("ts-parameter-change", "negative parameter position", #""position":0,"label":null,"name":"x""#, #""position":-1,"label":null,"name":"x""#),
    Mutation("ts-parameter-change", "unknown type state", #"{"state":"written","text":"number"}"#, #"{"state":"guessed","text":"number"}"#),
    Mutation("ts-parameter-change", "unknown type with another reason", #"{"state":"written","text":"number"}"#, #"{"state":"unknown","reason":"later"}"#),
    Mutation("ts-parameter-change", "language without a version", #""language_version":"typescript.v2""#, #""language_version":null"#),
    Mutation(
      "ts-parameter-change", "rows on an unsettled file",
      #""status":"ready","coverage""#, #""status":"incomplete","fallback_reason":"before-parse-error","coverage""#,
      #""status":"ready","inventory""#, #""status":"partial","inventory""#
    ),
    Mutation("range-reverted-listed", "ready page with an unsettled file", #""status":"identical""#, #""status":"skipped","fallback_reason":"scan-limit""#),
    Mutation("ts-parameter-change", "partial page with only settled files", #""status":"ready","inventory""#, #""status":"partial","inventory""#),
    Mutation("ts-parameter-change", "complete page with a cursor", #""next_after_path":null"#, #""next_after_path":"src/f.ts""#),
    Mutation("ts-parameter-change", "file.changed record without observation", #","observation":"watcher""#, ""),
    Mutation("ts-parameter-change", "baseline record with observation", #""field":"snapshot","snapshot""#, #""field":"snapshot","observation":"watcher","snapshot""#),
    Mutation("ts-parameter-change", "unknown after endpoint", #""after":{"kind":"recorded","record_seq":"4","field":"after","observation":"watcher","snapshot":{"kind":"content","sha256":"a0f5933b9b22cb5a09402ec1d063c10504d634ea717c939360f5fde690a4be6d","size":31}}"#, #""after":{"kind":"unknownBoundary"}"#),
    Mutation("ts-parameter-change", "uppercase content hash", #""sha256":"86e1381da"#, #""sha256":"86E1381DA"#),
    Mutation("range-admission-skipped", "skipped page without a reason", #","fallback_reason":"overloaded""#, ""),
    Mutation("range-admission-skipped", "complete skipped page", #""complete":false"#, #""complete":true"#),
    Mutation("range-all-failed-page", "ready page over failures", #""status":"partial""#, #""status":"ready""#),
    Mutation("range-restart-reconciliation", "unknown gap reason", #""reason":"restart""#, #""reason":"reboot""#),
    Mutation("ts-parameter-change", "rows without a language module", #""language":"typescript","language_version":"typescript.v2""#, #""language":null,"language_version":null"#),
    Mutation("swift-capture-unavailable", "unknown unavailable reason", #""reason":"oversize""#, #""reason":"too-big""#),
  ])
  func malformedBodiesAreRejected(_ mutation: Mutation) throws {
    let data = try edited(mutation.caseName, mutation.edits)
    do {
      let comparison = try InterfaceComparison.decode(data)
      Issue.record("decoded \(mutation.label) as \(comparison)")
    } catch {
      guard case .malformed = error else {
        Issue.record("\(mutation.label) threw \(error)")
        return
      }
    }
  }

  @Test func malformedNamesTheOffendingField() throws {
    let data = try edited("ts-parameter-change", (#""kind":"signatureChanged""#, #""kind":"renamed""#))
    #expect(throws: InterfaceDecodingError.malformed(".files[0].changes[0].kind: Cannot initialize KindName from invalid String value renamed")) {
      try InterfaceComparison.decode(data)
    }
  }
}

struct Mutation: Sendable, CustomTestStringConvertible {
  var caseName: String
  var label: String
  var edits: [(String, String)]

  init(_ caseName: String, _ label: String, _ find: String, _ replace: String, _ moreFind: String? = nil, _ moreReplace: String? = nil) {
    self.caseName = caseName
    self.label = label
    edits = [(find, replace)] + (moreFind.map { [($0, moreReplace ?? "")] } ?? [])
  }

  var testDescription: String { "\(caseName): \(label)" }
}

private func edited(_ caseName: String, _ edits: (String, String)...) throws -> Data {
  try edited(caseName, edits)
}

private func edited(_ caseName: String, _ edits: [(String, String)]) throws -> Data {
  var text = compacted(String(decoding: try InterfaceFixtures.expected(caseName), as: UTF8.self))
  for (find, replace) in edits {
    let range = try #require(text.range(of: find), "\(caseName) has no \(find)")
    text.replaceSubrange(range, with: replace)
  }
  return Data(text.utf8)
}

private func compacted(_ json: String) -> String {
  var output = ""
  var inString = false
  var escaped = false
  for character in json {
    if inString {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        inString = false
      }
    } else if character.isWhitespace {
      continue
    } else if character == "\"" {
      inString = true
    }
    output.append(character)
  }
  return output
}

// MARK: - Summaries

private func firstRow(_ comparison: InterfaceComparison) throws -> InterfaceChange {
  try #require(comparison.files.first.map { rowsOf($0.changes) }?.first)
}

private func tally(_ labels: [String]) -> [String: Int] {
  labels.reduce(into: [:]) { $0[$1, default: 0] += 1 }
}

private func rowsOf(_ changes: InterfaceFileResult.Changes) -> [InterfaceChange] {
  switch changes {
  case .typescript(let rows), .swift(let rows): rows
  case .noLanguageModule, .unsupportedLanguageVersion: []
  }
}

private func language(_ changes: InterfaceFileResult.Changes) -> String {
  switch changes {
  case .typescript: "typescript/typescript.v2"
  case .swift: "swift/swift.v1"
  case .noLanguageModule: "-"
  case .unsupportedLanguageVersion(let language, let version): "\(language)/\(version)"
  }
}

private func label(_ status: InterfaceComparison.Status) -> String {
  switch status {
  case .ready: "ready"
  case .partial: "partial"
  case .skipped(let reason): "skipped(\(reason.rawValue))"
  }
}

private func label(_ status: InterfaceFileResult.Status) -> String {
  switch status {
  case .identical: "identical"
  case .ready: "ready"
  case .incomplete(let reason): "incomplete(\(reason))"
  case .unavailable(let reason): "unavailable(\(reason))"
  case .unsupported(let reason): "unsupported(\(reason))"
  case .skipped(let reason): "skipped(\(reason))"
  }
}

private func label(_ coverage: InterfaceCoverage) -> String {
  switch coverage {
  case .complete: "complete"
  case .absent: "absent"
  case .incomplete(let reason): "incomplete(\(reason))"
  case .unavailable(let reason): "unavailable(\(reason))"
  case .unsupported: "unsupported"
  case .notEvaluated: "notEvaluated"
  }
}

private func label(_ record: InterfaceRecord) -> String {
  let snapshot: String
  switch record.snapshot {
  case .content(let sha256, let size): snapshot = "content(\(sha256.prefix(8)),\(size))"
  case .absent: snapshot = "absent"
  case .unavailable(let reason): snapshot = "unavailable(\(reason))"
  }
  return "\(record.recordSeq):\(record.field.rawValue):\(snapshot):\(record.observation?.rawValue ?? "-"):\(record.gapRef?.decimal ?? "-")"
}

private func kindName(_ kind: InterfaceChange.Kind) -> String {
  switch kind {
  case .added: "added"
  case .removed: "removed"
  case .signatureChanged: "signatureChanged"
  }
}

private func label<Value>(_ delta: InterfaceDelta<Value>, name: (Value) -> String = { _ in "" }) -> String {
  switch delta {
  case .equal(let value): "equal\(name(value))"
  case .added(let value): "added\(name(value))"
  case .removed(let value): "removed\(name(value))"
  case .changed(let before, _): "changed\(name(before))"
  }
}

private func summary(_ comparison: InterfaceComparison) -> [String] {
  var lines = [
    [
      "range=\(comparison.beforeSeq)..\(comparison.afterSeq)",
      "status=\(label(comparison.status))",
      "baseline=\(comparison.inventory.baselineCompletedSeq?.decimal ?? "-")",
      "unknownScopes=\(comparison.inventory.unknownScopes.joined(separator: ","))/\(comparison.inventory.unknownScopesComplete)",
      "gaps=\(comparison.gaps.map { "\($0.seq):\($0.reason.rawValue)" }.joined(separator: ","))/\(comparison.gapsComplete)",
      "page=\(comparison.page.complete):\(comparison.page.nextAfterPath ?? "-")",
    ].joined(separator: " ")
  ]
  for file in comparison.files {
    let before = switch file.before {
    case .unknownBoundary: "unknownBoundary"
    case .recorded(let record): label(record)
    }
    lines.append(
      "file \(file.path) \(label(file.status)) before=\(before) after=\(label(file.after)) "
        + "coverage=\(label(file.beforeCoverage))/\(label(file.afterCoverage)) language=\(language(file.changes))"
    )
    for row in rowsOf(file.changes) {
      let parameters = row.parameters.map { label($0, name: { ":\($0.name)" }) }.joined(separator: ",")
      let result = row.result.map { label($0) } ?? "-"
      lines.append(
        "  \(kindName(row.kind)) \(row.identity.kind) \(row.identity.name) "
          + "parameters=\(parameters) result=\(result) throws=\(label(row.throwsClause)) header=\(label(row.header))"
      )
    }
  }
  return lines
}

private func summary(_ raw: [String: Any]) -> [String] {
  func string(_ value: Any?) -> String { (value as? String) ?? "-" }
  func object(_ value: Any?) -> [String: Any] { (value as? [String: Any]) ?? [:] }
  func objects(_ value: Any?) -> [[String: Any]] { (value as? [[String: Any]]) ?? [] }
  func bool(_ value: Any?) -> String { (value as? Bool).map(String.init) ?? "?" }
  func status(_ value: [String: Any]) -> String {
    value["fallback_reason"].map { "\(string(value["status"]))(\(string($0)))" } ?? string(value["status"])
  }
  func coverage(_ value: [String: Any]) -> String {
    value["reason"].map { "\(string(value["state"]))(\(string($0)))" } ?? string(value["state"])
  }
  func record(_ value: [String: Any]) -> String {
    if string(value["kind"]) == "unknownBoundary" { return "unknownBoundary" }
    let snapshot = object(value["snapshot"])
    let tag = switch string(snapshot["kind"]) {
    case "content": "content(\(string(snapshot["sha256"]).prefix(8)),\(snapshot["size"] as? Int ?? -1))"
    case "unavailable": "unavailable(\(string(snapshot["reason"])))"
    case let kind: kind
    }
    return "\(string(value["record_seq"])):\(string(value["field"])):\(tag):\(string(value["observation"])):\(string(value["gap_ref"]))"
  }
  func op(_ value: [String: Any]) -> String { string(value["op"]) }

  let inventory = object(raw["inventory"])
  let range = object(raw["range"])
  let page = object(raw["page"])
  var lines = [
    [
      "range=\(string(range["before_seq"]))..\(string(range["after_seq"]))",
      "status=\(status(raw))",
      "baseline=\(string(inventory["baseline_completed_seq"]))",
      "unknownScopes=\(((inventory["unknown_scopes"] as? [String]) ?? []).joined(separator: ","))/\(bool(inventory["unknown_scopes_complete"]))",
      "gaps=\(objects(raw["gaps"]).map { "\(string($0["seq"])):\(string($0["reason"]))" }.joined(separator: ","))/\(bool(raw["gaps_complete"]))",
      "page=\(bool(page["complete"])):\(string(page["next_after_path"]))",
    ].joined(separator: " ")
  ]
  for file in objects(raw["files"]) {
    let coverageSides = object(file["coverage"])
    let language = file["language"] is String ? "\(string(file["language"]))/\(string(file["language_version"]))" : "-"
    lines.append(
      "file \(string(file["path"])) \(status(file)) before=\(record(object(file["before"]))) after=\(record(object(file["after"]))) "
        + "coverage=\(coverage(object(coverageSides["before"])))/\(coverage(object(coverageSides["after"]))) language=\(language)"
    )
    for row in objects(file["changes"]) {
      let identity = object(row["identity"])
      let parameters = objects(row["parameters"]).map { delta in
        let side = (delta["before"] as? [String: Any]) ?? object(delta["after"])
        return "\(op(delta)):\(string(side["name"]))"
      }.joined(separator: ",")
      let result = row["result"] is NSNull ? "-" : op(object(row["result"]))
      lines.append(
        "  \(string(row["kind"])) \(string(identity["kind"])) \(string(identity["name"])) "
          + "parameters=\(parameters) result=\(result) throws=\(op(object(row["throws"]))) header=\(op(object(row["header"])))"
      )
    }
  }
  return lines
}
