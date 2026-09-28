import CustomDump
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

  @Test func failedAndIdenticalAreDifferentFromReadyWithNoChanges() throws {
    let failed = FunctionChangesPageModel(comparison: try fixture("range-all-failed-page"))
    expectNoDifference(failed.detectedChanges, 0)
    expectNoDifference(failed.filesNotCompared, 2)
    #expect(!failed.summaryText.contains("0 changes"))
    let ready = FunctionChangesPageModel(comparison: try fixture("ts-unchanged-signature"))
    #expect(ready.nodes.contains { $0.statusText == "No detected interface change" })
    let identical = FunctionChangesPageModel(comparison: try fixture("range-reverted-listed"))
    #expect(!identical.nodes.contains { $0.kind == .file })
    identical.showUnchangedTapped()
    #expect(identical.nodes.contains { $0.statusText == "No net change at recorded endpoints" })
  }

  @Test func pageSkipIsNotAnEmptySuccess() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-admission-skipped"))
    #expect(model.noticeText.contains("overloaded"))
    #expect(model.summaryText.contains("loaded"))
  }

  @Test func searchOnlyFiltersLoadedPathsAndDeclarations() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-page-boundary-first"))
    #expect(model.searchPrompt.contains("loaded"))
    model.searchText = "not-in-this-page"
    expectNoDifference(model.visibleFileCount, 0)
    #expect(model.searchNotice.contains("loaded"))
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

  @Test func zoomAndFitClampToReadableBounds() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("ts-parameter-change"))
    model.zoomOutTapped()
    #expect(model.zoom < 1)
    model.viewportChanged(width: 900, height: 600)
    model.fitTreeTapped()
    #expect(model.zoom >= 0.5 && model.zoom <= 1.5)
    let declaration = try #require(model.nodes.first { $0.kind == .declaration })
    model.declarationTapped(declaration.id)
    model.zoomToSelectionTapped()
    #expect(model.focusedNodeID == declaration.id)
    let firstRequest = model.focusRequest
    model.zoomToSelectionTapped()
    expectNoDifference(model.focusRequest, firstRequest + 1)
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

  @Test func secondPageCompletesCountsAndRejectsOtherComparisons() throws {
    let model = FunctionChangesPageModel(comparison: try fixture("range-page-boundary-first"))
    expectNoDifference(model.detectedChanges, 1)
    #expect(model.summaryText.contains("loaded"))
    #expect(!model.pageReceived(try fixture("ts-parameter-change")))
    #expect(model.pageReceived(try fixture("range-page-boundary-second")))
    expectNoDifference(model.detectedChanges, 2)
    #expect(!model.summaryText.contains("loaded"))
    #expect(!model.pageReceived(try fixture("range-page-boundary-second")))
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

  @Test func demoLoadsOnlyNamedPinnedCases() {
    let demo = FunctionChangesFixtureModel(root: fixtureRoot, initialCase: "ts-parameter-change")
    demo.viewAppeared()
    #expect(demo.page != nil)
    #expect(demo.errorText == nil)
    demo.caseSelected("not-a-pinned-case")
    #expect(demo.page == nil)
    #expect(demo.errorText == "Unknown pinned fixture: not-a-pinned-case")
  }

}
