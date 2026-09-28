import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
struct FunctionChangesPageTests {
  private var fixtureRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Tests/SlipstreamCoreTests/Fixtures/interface-v2")
  }

  private func fixture(_ name: String) throws -> InterfaceComparison {
    let url = fixtureRoot.appending(path: "cases/\(name)/expected.json")
    return try InterfaceComparison.decode(Data(contentsOf: url))
  }

  @Test func mapIsPrimaryAndTreeRemainsAvailable() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    expectNoDifference(model.displayMode, .map)
    #expect(!model.showsTreeControls)
    #expect(model.showsMap)
    expectNoDifference(model.titleText, "A map of changing contracts.")
    model.modeSelection = .tree
    expectNoDifference(model.displayMode, .tree)
    #expect(model.showsTreeControls)
    #expect(!model.showsMap)
    expectNoDifference(model.titleText, "See where the change lives.")
    model.modeSelection = .map
    expectNoDifference(model.displayMode, .map)
  }

  @Test func contractMapUsesOwnerLaneWidthsWhenSpaceAllows() {
    let compact = DesignTokens.FunctionMap.layout(for: 918)
    expectNoDifference(compact.laneWidth, DesignTokens.FunctionMap.laneWidth)
    let wide = DesignTokens.FunctionMap.layout(for: 1900)
    expectNoDifference(wide.codeWidth, 226)
    expectNoDifference(wide.inputWidth, 336)
    expectNoDifference(wide.functionWidth, 262)
    expectNoDifference(wide.outputWidth, 336)
    expectNoDifference(wide.laneWidth, 1852)
  }

  @Test func mapSummaryCountsOnlyComparableLoadedDeclarations() throws {
    let partial = FunctionChangesPageModel(comparison: try fixture("range-cancelled-mid-page"))
    expectNoDifference(partial.mapStats.map(\.value), ["1", "1", "1"])
    #expect(partial.mapStats.allSatisfy { $0.label.contains("loaded") })
    let failed = FunctionChangesPageModel(comparison: try fixture("range-all-failed-page"))
    #expect(!failed.mapStats.contains { $0.value == "0" && $0.label.contains("change") })
    let skipped = FunctionChangesPageModel(comparison: try fixture("range-admission-skipped"))
    #expect(skipped.mapStats.isEmpty)
  }

  @Test func mapSummaryDoesNotClaimZeroWhenAnObservedFileWasNotCompared() throws {
    var comparison = try fixture("range-cancelled-mid-page")
    comparison.files[0].changes = .typescript([])
    let model = FunctionChangesPageModel(comparison: comparison)
    expectNoDifference(model.mapStats.first?.value, "?")
    #expect(model.summaryText.contains("No changes detected in compared files"))
    #expect(model.mapStats.contains { $0.label.contains("files not compared") })
  }

  @Test func mapStatsKeepLoadedOnlyScopeWhenInventoryIsUncertain() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-unknown-scopes"))
    #expect(model.mapStats.allSatisfy { $0.label.contains("loaded files") })
  }

  @Test func contractMapUsesRecordedInputsAndOutputs() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    let group = try #require(model.mapGroups.first)
    expectNoDifference(group.directory, "src")
    let file = try #require(group.files.first)
    expectNoDifference(file.path, "src/f.ts")
    expectNoDifference(file.changedCount, 1)
    let row = try #require(file.rows.first)
    expectNoDifference(row.label, "Inputs changed")
    expectNoDifference(row.title, "f")
    #expect(row.inputLines.contains { $0.mark == .removed && $0.text == "x: number" })
    #expect(row.inputLines.contains { $0.mark == .added && $0.text == "x: string" })
    #expect(row.outputLines.contains { $0.text == "void" })
    expectNoDifference(
      row.outputLines.filter { $0.text == "Throws not expressible in TypeScript" }.count, 1)
  }

  @Test func contractMapKeepsSwiftImplicitAndHeaderChanges() throws {
    let added = FunctionChangesPageModel(comparison: try fixture("swift-added-function"))
    let addedRow = try #require(added.mapGroups.first?.files.first?.rows.first)
    expectNoDifference(addedRow.label, "Added")
    #expect(addedRow.outputLines.contains { $0.text == "Void (implicit)" })
    #expect(addedRow.outputLines.contains { $0.text == "No declared throws" })
    let generics = FunctionChangesPageModel(comparison: try fixture("swift-generics-where"))
    let genericsRow = try #require(generics.mapGroups.first?.files.first?.rows.first)
    expectNoDifference(genericsRow.label, "Header changed")
    #expect(genericsRow.headerLines.contains { $0.text.contains("T: Comparable") })
  }

  @Test func contractMapDistinguishesGuardedRemoveAndAdd() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("swift-guard-move"))
    let rows = try #require(model.mapGroups.first?.files.first?.rows)
    expectNoDifference(rows.map(\.label), ["Removed", "Added"])
    #expect(rows[0].subtitle.contains("DEBUG"))
    #expect(rows[1].subtitle.contains("!(DEBUG)"))
  }

  @Test func contractMapGroupsRootFilesAndQualifiesSearchCounts() throws {
    var comparison = try fixture("ts-parameter-change")
    comparison.files[0].path = "f.ts"
    let model = FunctionChangesPageModel(comparison: comparison)
    let group = try #require(model.mapGroups.first)
    expectNoDifference(group.directory, "/")
    expectNoDifference(group.files.first?.rows.first?.id, "declaration:f.ts:0")
    model.searchText = "f"
    #expect(model.mapGroups.first?.summaryText.contains("matching") == true)
    #expect(model.mapGroups.first?.files.first?.summaryText.contains("matching") == true)
    model.modeSelection = .tree
    #expect(model.legendText.contains("matching changed declarations"))
  }

  @Test func contractMapShowsPartialAndFailedFilesWithoutInventedRows() throws {
    let partial = FunctionChangesPageModel(comparison: try fixture("range-cancelled-mid-page"))
    let files = partial.mapGroups.flatMap(\.files)
    expectNoDifference(files.map(\.path), ["src/a.ts", "src/b.ts"])
    #expect(files[1].isUnknown)
    expectNoDifference(files[1].statusText, "Skipped: cancelled")
    expectNoDifference(files[1].statusMarker, "?")
    #expect(files[1].rows.isEmpty)
    let failed = FunctionChangesPageModel(comparison: try fixture("range-all-failed-page"))
    #expect(failed.mapGroups.flatMap(\.files).allSatisfy { $0.isUnknown })
    #expect(failed.mapGroups.flatMap(\.files).flatMap(\.rows).allSatisfy { $0.marker == nil })
  }

  @Test func contractMapSeparatesIdenticalAndUnsupportedStatusRows() throws {
    let identical = FunctionChangesPageModel(comparison: try fixture("range-reverted-listed"))
    #expect(identical.mapGroups.isEmpty)
    identical.showUnchangedTapped()
    expectNoDifference(
      identical.mapGroups.first?.files.first?.statusText,
      "No net change at recorded endpoints")
    expectNoDifference(identical.mapGroups.first?.files.first?.statusMarker, "=")
    var comparison = try fixture("ts-parameter-change")
    comparison.files[0].changes = .unsupportedLanguageVersion(
      language: "typescript", version: "typescript.v3")
    let unsupported = FunctionChangesPageModel(comparison: comparison)
    #expect(unsupported.mapGroups.first?.files.first?.isUnknown == true)
    expectNoDifference(
      unsupported.mapGroups.first?.files.first?.statusText,
      "Unsupported language version: typescript typescript.v3")
    comparison.files.append(comparison.files[0])
    #expect(FunctionChangesPageModel(comparison: comparison).mapGroups.isEmpty)
  }

  @Test func contractMapIgnoresTreeZoomAndPreservesSelectionOnModeSwitch() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-unicode-span"))
    let row = try #require(model.mapGroups.first?.files.first?.rows.first)
    model.declarationTapped(row.id)
    let source = try #require(model.sourceSelection)
    model.displayModeSelected(.tree)
    model.zoomOutTapped()
    model.zoomOutTapped()
    model.displayModeSelected(.map)
    expectNoDifference(model.sourceSelection, source)
    #expect(!((try #require(model.mapGroups.first?.files.first?.rows.first)).inputLines.isEmpty))
    model.searchText = "not-in-this-page"
    #expect(model.sourceSelection == nil)
  }

  @Test func changedDeclarationCountsOnceDespiteMultipleComponentRows() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    expectNoDifference(model.detectedChanges, 1)
    expectNoDifference(model.filesNotCompared, 0)
    #expect(model.summaryText.contains("1 detected change"))
    #expect(model.nodes.filter { $0.kind == .declaration }.count == 1)
  }

  @Test func partialPageCountsLoadedRowsAndDisclosesUncomparedFiles() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-cancelled-mid-page"))
    #expect(model.summaryText.contains("loaded"))
    #expect(model.filesNotCompared == 1)
    #expect(model.nodes.contains { $0.statusText?.contains("cancelled") == true })
  }

  @Test func incompleteEmptyPageDoesNotClaimEndpointFilesAreEmpty() throws {
    var comparison = try fixture("ts-parameter-change")
    comparison.files = []
    comparison.page = InterfacePage(complete: false, nextAfterPath: "src/f.ts")
    let model = FunctionChangesPageModel(comparison: comparison)
    #expect(model.emptyStateText.contains("more files may exist"))
  }

  @Test func incompletePageSummaryQualifiesComparedFiles() throws {
    var comparison = try fixture("range-cancelled-mid-page")
    comparison.files[0].changes = .typescript([])
    let model = FunctionChangesPageModel(comparison: comparison)
    #expect(model.summaryText.contains("in loaded files"))
  }

  @Test func failedAndIdenticalAreDifferentFromReadyWithNoChanges() throws {
    let failed = FunctionChangesPageModel(comparison: try fixture("range-all-failed-page"))
    expectNoDifference(failed.detectedChanges, 0)
    expectNoDifference(failed.filesNotCompared, 2)
    #expect(!failed.summaryText.contains("0 changes"))
    #expect(failed.summaryText.contains("not compared"))
    #expect(failed.summaryText.contains("Changes unknown"))
    let ready = FunctionChangesPageModel(comparison: try fixture("ts-unchanged-signature"))
    #expect(ready.nodes.contains { $0.statusText == "No detected interface change" })
    let identical = FunctionChangesPageModel(comparison: try fixture("range-reverted-listed"))
    #expect(!identical.nodes.contains { $0.kind == .file })
    #expect(identical.emptyStateText.contains("hidden"))
    identical.showUnchangedTapped()
    #expect(identical.nodes.contains { $0.statusText == "No net change at recorded endpoints" })
  }

  @Test func pageSkipIsNotAnEmptySuccess() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-admission-skipped"))
    #expect(model.noticeText.contains("overloaded"))
    #expect(model.summaryText.contains("changes unknown"))
  }

  @Test func searchOnlyFiltersLoadedPathsAndDeclarations() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-page-boundary-first"))
    model.searchText = "a"
    #expect(model.nodes.contains { $0.kind == .declaration && $0.title == "a" })
    model.searchText = "not-in-this-page"
    expectNoDifference(model.nodes.filter { $0.kind == .file }.count, 0)
  }

  @Test func selectionCarriesActualEndpointSideHashAndUTF8Span() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-unicode-span"))
    let declaration = try #require(model.nodes.first { $0.kind == .declaration })
    model.declarationTapped(declaration.id)
    let selection = try #require(model.sourceSelection)
    expectNoDifference(selection.side, .after)
    expectNoDifference(selection.path, "src/f.ts")
    expectNoDifference(selection.sessionID, "11111111-1111-4111-8111-111111111111")
    expectNoDifference(selection.beforeSeq, Seq("3")!)
    expectNoDifference(selection.afterSeq, Seq("4")!)
    expectNoDifference(selection.projectionVersion, "interface.v2")
    expectNoDifference(selection.languageVersion, "typescript.v2")
    expectNoDifference(
      selection.identity, InterfaceIdentity(kind: "function", scope: [], name: "f", guards: []))
    #expect(selection.sha256.count == 64)
    expectNoDifference(selection.byteRange, 20..<50)
    model.sourceSideTapped(.before)
    expectNoDifference(model.sourceSelection?.side, .before)
    #expect(model.sourceSelection?.sha256 != selection.sha256)
  }

  @Test func typeStatesAndThrowsSemanticsStayVisible() throws {
    let ts = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    #expect(
      ts.nodes.flatMap(\.lines).contains { $0.text == "Throws not expressible in TypeScript" })
    let added = FunctionChangesPageModel(comparison: try fixture("swift-added-function"))
    #expect(added.nodes.flatMap(\.lines).contains { $0.text.contains("implicit") })
    var inferred = try fixture("ts-parameter-change")
    if case .typescript(var changes) = inferred.files[0].changes {
      changes[0].parameters[0] = .changed(
        before: InterfaceParameter(position: 0, name: "x", type: .inferredNotComputed),
        after: InterfaceParameter(position: 0, name: "x", type: .written("unknown"))
      )
      inferred.files[0].changes = .typescript(changes)
    }
    let lines = FunctionChangesPageModel(comparison: inferred).nodes.flatMap(\.lines).map(\.text)
    #expect(lines.contains("x: type inferred, not computed"))
    #expect(lines.contains("x: unknown"))
  }

  @Test func zoomAndSelectionCanBeRequestedRepeatedly() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    model.zoomOutTapped()
    #expect(model.zoom < 1)
    model.zoomOutTapped()
    #expect(try #require(model.nodes.first { $0.kind == .declaration }).lines.isEmpty)
    model.zoomInTapped()
    #expect(!((try #require(model.nodes.first { $0.kind == .declaration })).lines.isEmpty))
    let declaration = try #require(model.nodes.first { $0.kind == .declaration })
    model.declarationTapped(declaration.id)
    model.viewportChanged(width: 900, height: 600)
    model.zoomToSelectionTapped()
    let point = try #require(model.selectionScrollPoint)
    expectNoDifference(model.scrollPosition.point, point)
    model.zoomToSelectionTapped()
    expectNoDifference(model.scrollPosition.point, point)
  }

  @Test func fitTreeCanShowAWideLoadedTree() throws {
    var comparison = try fixture("ts-parameter-change")
    let file = try #require(comparison.files.first)
    comparison.files = (0..<12).map { index in
      var copy = file
      copy.path = "src/f\(index).ts"
      return copy
    }
    let model = FunctionChangesPageModel(comparison: comparison)
    model.viewportChanged(width: 900, height: 650)
    model.fitTreeTapped()
    #expect(model.canvasSize.width * model.zoom <= 900)
  }

  @Test func zoomOutNeverIncreasesZoomAfterFit() throws {
    var comparison = try fixture("ts-parameter-change")
    let file = try #require(comparison.files.first)
    comparison.files = (0..<50).map { index in
      var copy = file
      copy.path = "src/f\(index).ts"
      return copy
    }
    let model = FunctionChangesPageModel(comparison: comparison)
    model.viewportChanged(width: 900, height: 650)
    model.fitTreeTapped()
    let fittedZoom = model.zoom
    #expect(fittedZoom < 0.1)
    model.zoomOutTapped()
    #expect(model.zoom <= fittedZoom)
  }

  @Test func unsupportedLanguageVersionIsAnUnknownFile() throws {
    var comparison = try fixture("ts-parameter-change")
    comparison.files[0].changes = .unsupportedLanguageVersion(
      language: "typescript", version: "typescript.v3")
    let model = FunctionChangesPageModel(comparison: comparison)
    expectNoDifference(model.detectedChanges, 0)
    expectNoDifference(model.filesNotCompared, 1)
    #expect(
      model.nodes.contains {
        $0.statusText == "Unsupported language version: typescript typescript.v3"
      })
  }

  @Test func addedAndRemovedSourceSelectionUsesThePresentSide() throws {
    let added = FunctionChangesPageModel(comparison: try fixture("ts-added-function"))
    added.declarationTapped(try #require(added.nodes.first { $0.kind == .declaration }).id)
    expectNoDifference(added.sourceSelection?.side, .after)
    added.sourceSideTapped(.before)
    expectNoDifference(added.sourceSelection?.side, .after)
    let removed = FunctionChangesPageModel(comparison: try fixture("ts-removed-function"))
    removed.declarationTapped(try #require(removed.nodes.first { $0.kind == .declaration }).id)
    expectNoDifference(removed.sourceSelection?.side, .before)
  }

  @Test func outOfRangeAfterSpanFallsBackToRecordedBeforeSide() throws {
    var comparison = try fixture("ts-unicode-span")
    if case .typescript(var changes) = comparison.files[0].changes,
      case .signatureChanged(let before, let after) = changes[0].kind
    {
      changes[0].kind = .signatureChanged(
        before: before,
        after: InterfaceDeclaration(displayName: after.displayName, byteRange: 20..<999)
      )
      comparison.files[0].changes = .typescript(changes)
    }
    let model = FunctionChangesPageModel(comparison: comparison)
    model.declarationTapped(try #require(model.nodes.first { $0.kind == .declaration }).id)
    expectNoDifference(model.sourceSelection?.side, .before)
    #expect(!model.canSelectAfter)
    #expect(model.selectionText.contains("After source reference unavailable"))
  }

  @Test func unavailableSourceReferenceExplainsSelectedDeclaration() throws {
    var comparison = try fixture("ts-added-function")
    if case .typescript(var changes) = comparison.files[0].changes,
      case .added(let after) = changes[0].kind
    {
      changes[0].kind = .added(
        after: InterfaceDeclaration(displayName: after.displayName, byteRange: 0..<999_999))
      comparison.files[0].changes = .typescript(changes)
    }
    let model = FunctionChangesPageModel(comparison: comparison)
    model.declarationTapped(try #require(model.mapGroups.first?.files.first?.rows.first?.id))
    #expect(model.sourceSelection == nil)
    #expect(model.selectionText.contains("Source reference unavailable"))
  }

  @Test func changedAbsentThrowsModesShowBothRecordedStates() throws {
    var comparison = try fixture("ts-parameter-change")
    if case .typescript(var changes) = comparison.files[0].changes {
      changes[0].throwsClause = .changed(
        before: InterfaceThrowsClause(mode: .notWritten),
        after: InterfaceThrowsClause(mode: .notExpressible))
      comparison.files[0].changes = .typescript(changes)
    }
    let row = try #require(
      FunctionChangesPageModel(comparison: comparison).mapGroups.first?.files.first?.rows.first)
    #expect(row.outputLines.contains { $0.mark == .removed && $0.text == "No declared throws" })
    #expect(
      row.outputLines.contains {
        $0.mark == .added && $0.text == "Throws not expressible in TypeScript"
      })
  }

  @Test func directoryCountsIgnoreComponentRowsAndExposeUnknownFiles() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-cancelled-mid-page"))
    let root = try #require(model.nodes.first { $0.kind == .root })
    expectNoDifference(root.changedCount, 1)
    expectNoDifference(root.unknownCount, 1)
  }

  @Test func aSingleFixtureTreeIsCenteredInTheCanvas() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    let root = try #require(model.nodes.first { $0.kind == .root })
    expectNoDifference(root.x, model.canvasSize.width / 2)
  }

  @Test func unsupportedAndIncompleteFilesNameTheirReasons() throws {
    let unsupported = FunctionChangesPageModel(comparison: try fixture("py-unsupported-language"))
    #expect(unsupported.nodes.contains { $0.statusText == "Unsupported: unsupported-language" })
    let incomplete = FunctionChangesPageModel(comparison: try fixture("swift-parse-failure"))
    #expect(incomplete.nodes.contains { $0.statusText?.contains("parse-error") == true })
  }

  @Test func gapAndInventoryCaveatsStayVisible() throws {
    let gap = FunctionChangesPageModel(comparison: try fixture("range-gap-cap"))
    #expect(gap.noticeText.contains("gaps"))
    #expect(gap.noticeText.contains("unknown"))
    let boundary = FunctionChangesPageModel(comparison: try fixture("swift-unknown-boundary"))
    #expect(boundary.nodes.contains { $0.statusText?.contains("unknown-boundary") == true })
  }

  @Test func guardMoveUsesDistinctDeclarationNodeIDs() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("swift-guard-move"))
    let ids = model.nodes.filter { $0.kind == .declaration }.map(\.id)
    expectNoDifference(Set(ids).count, ids.count)
  }

  @Test func addedDeclarationsDoNotClaimThrowsOrShowEmptyHeaders() throws {
    for caseName in [
      "ts-added-function", "swift-added-function", "ts-removed-function", "swift-removed-function",
    ] {
      let model = FunctionChangesPageModel(comparison: try fixture(caseName))
      let lines = try #require(model.nodes.first { $0.kind == .declaration }).lines
      #expect(!lines.contains { $0.text == "HEADER" || $0.text == "DECLARED THROWS" })
      #expect(!lines.contains { $0.text.isEmpty })
      #expect(!lines.contains { $0.text.localizedLowercase.contains("throws") && $0.mark != .note })
    }
  }

  @Test func swiftVariadicUsesWrittenSuffix() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("swift-variadic"))
    let lines = model.nodes.flatMap(\.lines).map(\.text)
    #expect(lines.contains { $0.contains("Int...") })
    #expect(!lines.contains { $0.hasPrefix("...values") })
  }

  @Test func filteringASelectedDeclarationClearsItsSource() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    model.declarationTapped(try #require(model.nodes.first { $0.kind == .declaration }).id)
    #expect(model.sourceSelection != nil)
    model.searchText = "not-in-this-page"
    #expect(model.sourceSelection == nil)
    #expect(!model.canZoomToSelection)
  }

  @Test func filteringASiblingDeclarationClearsItsSource() throws {
    var comparison = try fixture("ts-parameter-change")
    guard case .typescript(let changes) = comparison.files[0].changes,
      let original = changes.first
    else {
      Issue.record("Expected a TypeScript change")
      return
    }
    var foo = original
    foo.kind = .signatureChanged(
      before: .init(displayName: "foo", byteRange: 0..<10),
      after: .init(displayName: "foo", byteRange: 0..<10))
    var bar = original
    bar.kind = .signatureChanged(
      before: .init(displayName: "bar", byteRange: 0..<10),
      after: .init(displayName: "bar", byteRange: 0..<10))
    comparison.files[0].changes = .typescript([foo, bar])
    let model = FunctionChangesPageModel(comparison: comparison)
    model.declarationTapped(try #require(model.nodes.first { $0.title == "bar" }).id)
    #expect(model.sourceSelection != nil)
    model.searchText = "foo"
    #expect(model.nodes.contains { $0.title == "foo" })
    #expect(!model.nodes.contains { $0.title == "bar" })
    #expect(model.sourceSelection == nil)
    #expect(!model.canSelectAfter)
  }

  @Test func repeatedZoomOutStopsAtATenth() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    for _ in 0..<50 { model.zoomOutTapped() }
    expectNoDifference(model.zoom, 0.1)
  }

  @Test func unchangedToggleOnlyOffersLoadedIdenticalResults() throws {
    let hidden = FunctionChangesPageModel(comparison: try fixture("range-reverted-hidden"))
    #expect(!hidden.canShowUnchanged)
    #expect(hidden.emptyStateText.contains("No files listed"))
    let listed = FunctionChangesPageModel(comparison: try fixture("range-reverted-listed"))
    #expect(listed.canShowUnchanged)
  }

  @Test func duplicateFilePathsAreUnavailableInsteadOfCrashing() throws {
    var comparison = try fixture("ts-parameter-change")
    comparison.files.append(try #require(comparison.files.first))
    let model = FunctionChangesPageModel(comparison: comparison)
    #expect(model.emptyStateText.contains("duplicate"))
    #expect(model.nodes.isEmpty)
    #expect(!model.summaryText.contains("0 detected changes"))
  }

  @Test func identicalUnknownVersionIsStillNoNetChange() throws {
    var comparison = try fixture("range-reverted-listed")
    comparison.files[0].changes = .unsupportedLanguageVersion(
      language: "typescript", version: "typescript.v3")
    let model = FunctionChangesPageModel(comparison: comparison)
    expectNoDifference(model.filesNotCompared, 0)
    model.showUnchangedTapped()
    #expect(model.nodes.contains { $0.statusText == "No net change at recorded endpoints" })
  }

  @Test func missingLanguageModuleCannotClaimZeroChanges() throws {
    var comparison = try fixture("ts-parameter-change")
    comparison.files[0].changes = .noLanguageModule
    let model = FunctionChangesPageModel(comparison: comparison)
    expectNoDifference(model.filesNotCompared, 1)
    #expect(model.summaryText.contains("not compared"))
    #expect(model.nodes.contains { $0.statusText == "Unsupported language" })
  }

  @Test func demoLoadsOnlyNamedPinnedCases() {
    let demo = withDependencies {
      $0.functionFixtures = .liveValue
    } operation: {
      FunctionChangesFixtureModel(root: fixtureRoot, initialCase: "ts-parameter-change")
    }
    demo.viewAppeared()
    #expect(demo.page != nil)
    #expect(demo.errorText == nil)
    #expect(demo.feedContextText.contains("not from this feed session"))
    demo.caseSelected("not-a-pinned-case")
    #expect(demo.page == nil)
    #expect(demo.errorText == "Unknown pinned fixture: not-a-pinned-case")
    #expect(demo.caseNames.contains("ts-parameter-change"))
    #expect(demo.caseNames.contains(demo.selectedCase))
    demo.caseSelected("ts-parameter-change")
    #expect(demo.page != nil)
  }

  @Test func demoRecoversFromAnUnknownInitialCase() {
    let demo = withDependencies {
      $0.functionFixtures = .liveValue
    } operation: {
      FunctionChangesFixtureModel(root: fixtureRoot, initialCase: "not-a-pinned-case")
    }
    demo.viewAppeared()
    #expect(demo.page == nil)
    #expect(demo.errorText == "Unknown pinned fixture: not-a-pinned-case")
    #expect(demo.caseNames.contains("ts-parameter-change"))
    demo.caseSelected("ts-parameter-change")
    #expect(demo.page != nil)
    #expect(demo.errorText == nil)
  }

  @Test func demoUsesItsInjectedFixtureClient() throws {
    let comparison = try fixture("ts-parameter-change")
    let demo = withDependencies {
      $0.functionFixtures = FunctionFixtureClient { _, _ in
        FunctionFixtureCatalog(caseNames: ["synthetic"], comparison: comparison)
      }
    } operation: {
      FunctionChangesFixtureModel(root: URL(fileURLWithPath: "/unused"), initialCase: "synthetic")
    }
    demo.viewAppeared()
    expectNoDifference(demo.caseNames, ["synthetic"])
    expectNoDifference(demo.page?.detectedChanges, 1)
    let page = try #require(demo.page)
    demo.viewAppeared()
    #expect(demo.page === page)
  }

  @Test func demoKeepsFailedCaseSelectedForRetry() throws {
    let comparison = try fixture("ts-parameter-change")
    let demo = withDependencies {
      $0.functionFixtures = FunctionFixtureClient { _, name in
        if name == "bad" { throw URLError(.badServerResponse) }
        return FunctionFixtureCatalog(caseNames: ["good", "bad"], comparison: comparison)
      }
    } operation: {
      FunctionChangesFixtureModel(root: URL(fileURLWithPath: "/unused"), initialCase: "good")
    }
    demo.viewAppeared()
    demo.caseSelection = "bad"
    expectNoDifference(demo.selectedCase, "bad")
    #expect(demo.errorText?.contains("fixture bad") == true)
    demo.retryTapped()
    expectNoDifference(demo.selectedCase, "bad")
    #expect(demo.errorText?.contains("fixture bad") == true)
  }

}
